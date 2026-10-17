import 'dart:async';
import 'package:dawarich/core/domain/models/point/local/local_point.dart';
import 'package:dawarich/features/tracking/application/repositories/location_provider_interface.dart';
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
  static const Duration _stillHeartbeat = Duration(minutes: 5);

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

  /// Timer mode: emit points at fixed intervals using cached location.
  Stream<Result<LocalPoint, String>> _getTimerPointStream(
    int userId,
    LocationPrecision precision,
    int frequencySeconds,
    TrackingHealthSink? health,
  ) async* {
    LocationFix? latestFix;
    LocationFix? lastRecordedFix;
    DateTime? lastRecordedAt;
    StreamSubscription<LocationFix>? locationSub;

    // Battery: the stream only wakes the GPS/network provider when the phone
    // moved _streamDistanceMeters, and at most once per tracking interval.
    // A still phone therefore costs (almost) nothing between heartbeats.
    final request = LocationRequest(
      precision: precision,
      distanceFilterMeters: _streamDistanceMeters,
      timeLimit: null,
      intervalDuration: Duration(seconds: frequencySeconds),
    );
    final fixRequest = LocationRequest(
      precision: precision,
      distanceFilterMeters: 0,
      timeLimit: null,
      intervalDuration: Duration(seconds: frequencySeconds),
    );
    Timer? timer;

    try {
      final locationStream = _locationProvider.getLocationStream(request);
      locationSub = locationStream.listen(
        (fix) {
          latestFix = fix;
          health?.onFix();
          if (kDebugMode) {
            debugPrint('[LocationStream] Cache updated: ${fix.latitude}, ${fix.longitude}');
          }
        },
        onError: (e) {
          health?.onStreamError(e);
          if (kDebugMode) {
            debugPrint('[LocationStream] Stream error: $e');
          }
        },
        onDone: () => health?.onStreamDone(),
      );

      final controller = StreamController<Result<LocalPoint, String>>();
      // Stop the timer and the location stream as soon as the consumer goes
      // away (stop / settings restart); otherwise they keep running forever.
      controller.onCancel = () async {
        timer?.cancel();
        await locationSub?.cancel();
      };

      final initialResult = await _fixNow(fixRequest);
      if (initialResult case Ok(value: final fix)) {
        latestFix = fix;
        health?.onFix();
        final timestamp = DateTime.now().toUtc();
        final pointResult = await _createPointFromLocationFix(fix, timestamp, userId)
            .timeout(_createPointTimeout);
        if (pointResult case Ok(value: final point)) {
          lastRecordedFix = fix;
          lastRecordedAt = DateTime.now();
          yield Ok(point);
        }
      }

      final timerDuration = Duration(seconds: frequencySeconds);
      bool tickBusy = false;

      if (kDebugMode) {
        debugPrint('[LocationStream] Timer mode: interval = ${frequencySeconds}s');
      }

      Future<void> onTick() async {
        LocationFix? fixToUse = latestFix;

        // The distance-filtered stream stays silent while the phone is still,
        // so an unchanged cache + a recent point means "still here": skip
        // without waking the GPS.
        final recordedFix = lastRecordedFix;
        final recordedAt = lastRecordedAt;
        if (fixToUse != null &&
            identical(fixToUse, recordedFix) &&
            recordedAt != null &&
            DateTime.now().difference(recordedAt) < _stillHeartbeat) {
          return;
        }

        if (fixToUse == null ||
            DateTime.now().difference(fixToUse.timestampUtc).inSeconds > 30) {
          if (kDebugMode) {
            debugPrint('[LocationStream] Cache stale, fetching current position');
          }
          final currentResult = await _fixNow(fixRequest);
          if (currentResult case Ok(value: final fix)) {
            fixToUse = fix;
            latestFix = fix;
            health?.onFix();
          }
        }

        if (fixToUse == null) {
          controller.add(Err('No location available'));
          return;
        }

        // Still and recently recorded: skip, the family map is already right.
        final lastFix = lastRecordedFix;
        final lastAt = lastRecordedAt;
        if (lastFix != null && lastAt != null) {
          final moved = Geolocator.distanceBetween(lastFix.latitude,
              lastFix.longitude, fixToUse.latitude, fixToUse.longitude);
          if (moved < _stillRadiusMeters &&
              DateTime.now().difference(lastAt) < _stillHeartbeat) {
            return;
          }
        }

        try {
          final timestamp = DateTime.now().toUtc();
          final pointResult = await _createPointFromLocationFix(fixToUse, timestamp, userId)
              .timeout(_createPointTimeout);

          if (pointResult case Ok(value: final point)) {
            lastRecordedFix = fixToUse;
            lastRecordedAt = DateTime.now();
            controller.add(Ok(point));
          } else if (pointResult case Err(value: final err)) {
            if (kDebugMode) {
              debugPrint('[LocationStream] Point validation failed: $err');
            }
            controller.add(Err('Failed to create point: $err'));
          }
        } catch (e) {
          if (kDebugMode) {
            debugPrint('[LocationStream] Error creating point: $e');
          }
          controller.add(Err('Failed to create point: $e'));
        }
      }

      timer = Timer.periodic(timerDuration, (t) async {
        if (controller.isClosed) {
          t.cancel();
          return;
        }
        health?.onTick();

        // Un tick à la fois : un `getCurrent` lent ne doit pas empiler les appels.
        if (tickBusy) return;
        tickBusy = true;
        try {
          await onTick();
        } finally {
          tickBusy = false;
        }
      });

      await for (final result in controller.stream) {
        yield result;
      }

      await locationSub.cancel();
    } catch (e, s) {
      if (kDebugMode) {
        debugPrint('[LocationStream] Timer error: $e\n$s');
      }
      yield Err('Location stream error: $e');
      await locationSub?.cancel();
    }
  }
}
