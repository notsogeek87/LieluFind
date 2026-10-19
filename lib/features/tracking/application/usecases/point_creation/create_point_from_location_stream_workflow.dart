import 'dart:async';
import 'package:dawarich/core/domain/models/point/local/local_point.dart';
import 'package:dawarich/features/tracking/application/repositories/location_provider_interface.dart';
import 'package:dawarich/features/tracking/application/services/adaptive_tracking_policy.dart';
import 'package:dawarich/features/tracking/application/services/tracking_log.dart';
import 'package:dawarich/features/tracking/application/services/tracking_supervisor.dart';
import 'package:dawarich/features/tracking/application/usecases/point_creation/create_point_usecase.dart';
import 'package:dawarich/features/tracking/application/usecases/settings/get_tracker_settings_usecase.dart';
import 'package:dawarich/features/tracking/domain/enum/location_precision.dart';
import 'package:dawarich/features/tracking/domain/models/location_fix.dart';
import 'package:dawarich/features/tracking/domain/models/location_request.dart';
import 'package:dawarich/features/tracking/domain/models/tracker_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:option_result/option_result.dart';

/// Workflow for creating points using either:
/// - Auto mode (0): Event-driven tracking when location changes meaningfully
/// - Timer mode (>0): Fixed interval while moving, slow heartbeat when still
final class CreatePointFromLocationStreamWorkflow {
  final GetTrackerSettingsUseCase _getTrackerSettings;
  final ILocationProvider _locationProvider;
  final CreatePointUseCase _createPointFromLocationFix;

  /// Timer mode: a device that moved less than this since the last recorded
  /// point is considered still (absorbs GPS jitter).
  static const double _stillRadiusMeters = 25;

  /// Timer mode: while still, only one "I'm still here" point per this delay.
  static const Duration _stillHeartbeat = Duration(minutes: 15);

  /// Immobile : vérification gratuite (dernière position connue) pour détecter un départ.
  static const Duration _stillProbeInterval = Duration(minutes: 5);

  /// Une dernière position connue plus récente que ça vaut une position active.
  static const Duration _cheapFixMaxAge = Duration(minutes: 5);

  /// Timer mode: the location stream only reports after this much movement.
  static const int _streamDistanceMeters = 10;


  CreatePointFromLocationStreamWorkflow(
    this._getTrackerSettings,
    this._locationProvider,
    this._createPointFromLocationFix,
  );

  /// Returns a stream of location points based on user settings.
  ///
  /// [health] reçoit les signes de vie du flux (position, minuteur, erreur,
  /// fin) pour que le superviseur détecte un flux muet ou terminé.
  Stream<Result<LocalPoint, String>> getPointStream(int userId, {TrackingHealthSink? health}) async* {
    if (kDebugMode) {
      debugPrint('[LocationStream] Starting location stream for user $userId');
    }

    final TrackerSettings settings = await _getTrackerSettings(userId);
    final LocationPrecision precision = settings.locationPrecision;
    final int trackingFrequencySeconds = settings.trackingFrequency;
    final int minimumDistance = settings.minimumPointDistance;
    final bool isAutoMode = trackingFrequencySeconds == 0;

    if (kDebugMode) {
      debugPrint('[LocationStream] Settings: precision=$precision, frequency=${trackingFrequencySeconds}s, minDistance=${minimumDistance}m, autoMode=$isAutoMode');
    }

    if (isAutoMode) {
      yield* _getAutoModePointStream(userId, precision, minimumDistance, health);
    } else {
      yield* _getTimerPointStream(userId, precision, trackingFrequencySeconds, health);
    }

    if (kDebugMode) {
      debugPrint('[LocationStream] Location stream ended');
    }
  }

  /// Auto mode: track when the device has moved a meaningful distance.
  /// Uses user's minimum distance if set, otherwise derives from precision setting.
  Stream<Result<LocalPoint, String>> _getAutoModePointStream(
    int userId,
    LocationPrecision precision,
    int minimumDistance,
    TrackingHealthSink? health,
  ) async* {
    // Hybrid approach:
    // - If user set a minimum distance, use that (they know what's meaningful to them)
    // - Otherwise, derive from precision (reflects user's tracking mindset)
    final int distanceFilter = minimumDistance > 0
        ? minimumDistance
        : switch (precision) {
            LocationPrecision.best => 5,
            LocationPrecision.high => 5,
            LocationPrecision.balanced => 10,
            LocationPrecision.lowPower => 25,
          };

    final request = LocationRequest(
      precision: precision,
      distanceFilterMeters: distanceFilter,
      timeLimit: null,
      intervalDuration: const Duration(seconds: 5),
    );

    if (kDebugMode) {
      debugPrint('[LocationStream] Auto mode: distance filter = ${distanceFilter}m');
    }

    LocationFix? lastRecordedFix;
    bool isFirstPoint = true;

    try {
      // Listen to location stream, first emission becomes the initial point
      final locationStream = _locationProvider.getLocationStream(request);

      await for (final fix in locationStream) {
        health?.onFix();
        health?.onTick();
        if (isFirstPoint) {
          isFirstPoint = false;
          lastRecordedFix = fix;

          if (kDebugMode) {
            debugPrint('[LocationStream] Auto: Recording initial location');
          }

          final timestamp = DateTime.now().toUtc();
          final pointResult = await _createPointFromLocationFix(fix, timestamp, userId);

          if (pointResult case Ok(value: final point)) {
            yield Ok(point);
          }
          continue;
        }

        // Subsequent points are filtered
        if (_shouldRecordPoint(lastRecordedFix, fix, distanceFilter)) {
          if (kDebugMode) {
            debugPrint('[LocationStream] Auto: Recording new location');
          }

          final timestamp = DateTime.now().toUtc();
          final pointResult = await _createPointFromLocationFix(fix, timestamp, userId);

          if (pointResult case Ok(value: final point)) {
            lastRecordedFix = fix;
            yield Ok(point);
          } else if (pointResult case Err(value: final err)) {
            if (kDebugMode) {
              debugPrint('[LocationStream] Point creation failed: $err');
            }
          }
        } else if (kDebugMode) {
          debugPrint('[LocationStream] Auto: Skipping similar location');
        }
      }
      // Ce flux ne se termine pas normalement : fin = panne.
      health?.onStreamDone();
    } catch (e, s) {
      health?.onStreamError(e);
      if (kDebugMode) {
        debugPrint('[LocationStream] Auto mode error: $e\n$s');
      }
      yield Err('Location stream error: $e');
    }
  }

  /// Check if we should record this point (new location or periodic stationary update).
  bool _shouldRecordPoint(LocationFix? last, LocationFix current, int minDistMeters) {
    if (last == null) {
      return true;
    }

    final dist = Geolocator.distanceBetween(last.latitude, last.longitude, current.latitude, current.longitude);
    if (dist >= minDistMeters) {
      return true;
    }

    final timeDiff = current.timestampUtc.difference(last.timestampUtc).inSeconds;
    return timeDiff > 60;
  }

  /// Max wait for a fix. Without a limit, a GPS that cannot see the sky
  /// (indoors, FOSS build) blocks the whole stream and no point is ever made.
  static const Duration _fixTimeout = Duration(seconds: 20);

  /// Un enregistrement de point (batterie, wifi, base) qui dépasse ce délai est abandonné.
  static const Duration _createPointTimeout = Duration(seconds: 30);

  /// A last-known fix older than this is not worth publishing.
  static const Duration _maxLastKnownAge = Duration(minutes: 10);

  Future<Result<LocationFix, String>> _fixNow(LocationRequest request) async {
    final current = await _locationProvider.getCurrent(request).timeout(
          _fixTimeout,
          onTimeout: () => Err<LocationFix, String>('Timed out waiting for a location fix'),
        );
    if (current case Ok()) return current;

    final last = await _locationProvider.getLastKnown();
    if (last case Some(value: final fix)) {
      final age = DateTime.now().toUtc().difference(fix.timestampUtc);
      if (age < _maxLastKnownAge) return Ok(fix);
    }
    return current;
  }

  /// Timer mode, adaptatif pour la batterie :
  /// - **immobile** : aucune position calculée pour nous en continu ;
  ///   écoute passive ; départ détecté par la dernière position connue toutes
  ///   les 5 min ; un point « toujours là » toutes les 15 min (position active
  ///   seulement si le téléphone n'en a pas de récente) ;
  /// - **en mouvement** : cadence normale ([frequencySeconds]), retour en
  ///   immobile après 3 min sans déplacement.
  Stream<Result<LocalPoint, String>> _getTimerPointStream(
    int userId,
    LocationPrecision precision,
    int frequencySeconds,
    TrackingHealthSink? health,
  ) async* {
    LocationFix? latestFix;
    StreamSubscription<LocationFix>? locationSub;
    Timer? timer;

    final policy = AdaptiveTrackingPolicy(
      distance: (a, b) => Geolocator.distanceBetween(a.latitude, a.longitude, b.latitude, b.longitude),
      stillRadiusMeters: _stillRadiusMeters,
      stillHeartbeat: _stillHeartbeat,
      // Le flux passif ne livre rien de régulier : le minuteur prend le relais pile à l'heure.
      stillFallbackGrace: Duration.zero,
      movingInterval: Duration(seconds: frequencySeconds),
    );

    // Journal horaire : d'où viennent les positions à l'arrêt (pour mesurer le gain).
    var cheapFixes = 0, activeFixes = 0;
    var statsSince = DateTime.now();
    DateTime? lastProbeAt;

    /// Dernière position connue du téléphone si elle est récente : coût nul.
    Future<LocationFix?> cheapFix() async {
      final last = await _locationProvider.getLastKnown();
      if (last case Some(value: final fix)) {
        if (DateTime.now().toUtc().difference(fix.timestampUtc) <= _cheapFixMaxAge) return fix;
      }
      return null;
    }

    LocationRequest requestFor(MotionMode mode) => switch (mode) {
          MotionMode.still => LocationRequest(
              precision: precision,
              // Passif : on profite des positions que le téléphone calcule déjà,
              // sans en demander. Le point « toujours là » vient du minuteur.
              distanceFilterMeters: 0,
              timeLimit: null,
              intervalDuration: _stillHeartbeat,
              passive: true,
            ),
          MotionMode.moving => LocationRequest(
              precision: precision,
              distanceFilterMeters: _streamDistanceMeters,
              timeLimit: null,
              intervalDuration: Duration(seconds: frequencySeconds),
            ),
        };

    final fixRequest = LocationRequest(
      precision: precision,
      distanceFilterMeters: 0,
      timeLimit: null,
      intervalDuration: Duration(seconds: frequencySeconds),
    );

    final controller = StreamController<Result<LocalPoint, String>>();
    bool busy = false;

    Future<void> record(LocationFix fix) async {
      try {
        final timestamp = DateTime.now().toUtc();
        final pointResult =
            await _createPointFromLocationFix(fix, timestamp, userId).timeout(_createPointTimeout);
        if (pointResult case Ok(value: final point)) {
          policy.recorded(fix, DateTime.now());
          if (!controller.isClosed) controller.add(Ok(point));
        } else if (pointResult case Err(value: final err)) {
          if (!controller.isClosed) controller.add(Err('Failed to create point: $err'));
        }
      } catch (e) {
        if (!controller.isClosed) controller.add(Err('Failed to create point: $e'));
      }
    }

    late void Function(MotionMode mode) subscribe;

    Future<void> apply(TrackingDecision decision, LocationFix? fix) async {
      final to = decision.switchTo;
      if (to != null && to != policy.mode) {
        policy.switched(to, DateTime.now());
        subscribe(to);
        if (kDebugMode) debugPrint('[LocationStream] Mode → ${to.name}');
      }
      if (decision.record && fix != null) await record(fix);
    }

    // Les événements (positions, ticks) sont traités un par un : jamais deux
    // créations de point ni deux demandes de position active en parallèle.
    Future<void> serialized(Future<void> Function() job) async {
      if (busy) return;
      busy = true;
      try {
        await job();
      } finally {
        busy = false;
      }
    }

    subscribe = (MotionMode mode) {
      final old = locationSub;
      locationSub = _locationProvider.getLocationStream(requestFor(mode)).listen(
        (fix) {
          latestFix = fix;
          health?.onFix();
          unawaited(serialized(() => apply(policy.onFix(fix, DateTime.now()), fix)));
        },
        onError: (e) {
          health?.onStreamError(e);
          if (kDebugMode) {
            debugPrint('[LocationStream] Stream error: $e');
          }
        },
        onDone: () => health?.onStreamDone(),
      );
      if (old != null) unawaited(old.cancel());
    };

    // Stop the timer and the location stream as soon as the consumer goes
    // away (stop / settings restart); otherwise they keep running forever.
    controller.onCancel = () async {
      timer?.cancel();
      await locationSub?.cancel();
    };

    try {
      subscribe(policy.mode);

      final initialResult = await _fixNow(fixRequest);
      if (initialResult case Ok(value: final fix)) {
        latestFix = fix;
        health?.onFix();
        await record(fix);
      }

      if (kDebugMode) {
        debugPrint('[LocationStream] Adaptive mode: moving interval = ${frequencySeconds}s');
      }

      timer = Timer.periodic(Duration(seconds: frequencySeconds), (t) {
        if (controller.isClosed) {
          t.cancel();
          return;
        }
        health?.onTick();

        unawaited(serialized(() async {
          final now = DateTime.now();
          if (now.difference(statsSince) >= const Duration(hours: 1)) {
            unawaited(TrackingLog.add('Positions (1 h) : $cheapFixes en cache, $activeFixes actives, mode ${policy.mode.name}'));
            cheapFixes = 0;
            activeFixes = 0;
            statsSince = now;
          }

          // Immobile : détection de départ par la dernière position connue (gratuite).
          final probeAt = lastProbeAt;
          if (policy.mode == MotionMode.still &&
              (probeAt == null || now.difference(probeAt) >= _stillProbeInterval)) {
            lastProbeAt = now;
            final probe = await cheapFix();
            final latest = latestFix;
            if (probe != null && (latest == null || probe.timestampUtc.isAfter(latest.timestampUtc))) {
              latestFix = probe;
              health?.onFix();
              cheapFixes++;
              await apply(policy.onFix(probe, DateTime.now()), probe);
            }
          }

          final decision = policy.onTick(latestFix, DateTime.now());
          if (decision.needFreshFix) {
            if (decision.switchTo != null) await apply(TrackingDecision(switchTo: decision.switchTo), null);
            final cached = await cheapFix();
            if (cached != null) cheapFixes++;
            final current = cached != null ? Ok<LocationFix, String>(cached) : await _fixNow(fixRequest);
            if (cached == null && current is Ok) activeFixes++;
            if (current case Ok(value: final fix)) {
              latestFix = fix;
              health?.onFix();
              await apply(policy.onFreshFix(fix, DateTime.now()), fix);
            } else if (current case Err(value: final err)) {
              if (!controller.isClosed) controller.add(Err('No location available: $err'));
            }
            return;
          }
          await apply(decision, latestFix);
        }));
      });

      await for (final result in controller.stream) {
        yield result;
      }
    } catch (e, s) {
      if (kDebugMode) {
        debugPrint('[LocationStream] Timer error: $e\n$s');
      }
      yield Err('Location stream error: $e');
    } finally {
      timer?.cancel();
      await locationSub?.cancel();
    }
  }
}
