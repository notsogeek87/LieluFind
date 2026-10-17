import 'dart:async';
import 'package:dawarich/core/data/repositories/local_point_repository_interfaces.dart';
import 'package:dawarich/features/batch/application/usecases/batch_upload_workflow_usecase.dart';
import 'package:dawarich/features/batch/application/usecases/get_current_batch_usecase.dart';
import 'package:dawarich/features/tracking/application/usecases/get_batch_point_count_usecase.dart';
import 'package:dawarich/features/tracking/application/usecases/notifications/show_tracker_notification_usecase.dart';
import 'package:dawarich/features/tracking/application/usecases/point_creation/create_point_from_location_stream_workflow.dart';
import 'package:dawarich/features/tracking/application/usecases/point_creation/store_point_usecase.dart';
import 'package:dawarich/features/tracking/application/usecases/settings/watch_tracker_settings_usecase.dart';
import 'package:dawarich/features/tracking/domain/models/tracker_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'tracking_log.dart';
import 'tracking_supervisor.dart';
import 'package:option_result/option_result.dart';

final class PointAutomationService {
  bool _isTracking = false;
  /// Écriture locale / envoi : une tâche à la fois, mais jamais bloqué pour toujours.
  final SingleFlightGuard _writeGuard = SingleFlightGuard(stuckAfter: const Duration(seconds: 45));
  final SingleFlightGuard _uploadGuard = SingleFlightGuard(stuckAfter: const Duration(minutes: 3));
  TrackingSupervisor? _supervisor;
  Timer? _watchdogTimer;
  DateTime? _lastUploadAttemptAt;
  DateTime? _lastUploadOkAt;
  int? _currentUserId;
  StreamSubscription<Result<dynamic, String>>? _locationStreamSub;
  StreamSubscription<TrackerSettings>? _settingsWatchSub;
  StreamSubscription<int>? _batchCountSub;
  TrackerSettings? _currentSettings;
  Timer? _heartbeatTimer;
  DateTime? _lastPointTime;
  int _lastKnownBatchCount = 0;

  /// Heartbeat interval for re-posting the notification so aggressive OEMs
  /// (Xiaomi, Huawei, Samsung) don't kill the foreground service.
  /// Uses the cached batch count — no DB query.
  static const _heartbeatInterval = Duration(seconds: 60);

  /// Fréquence d'évaluation de la santé du suivi.
  static const _watchdogPeriod = Duration(seconds: 30);

  final CreatePointFromLocationStreamWorkflow _createPointFromLocationStream;
  final StorePointUseCase _storePoint;
  final GetBatchPointCountUseCase _getBatchPointCount;
  final ShowTrackerNotificationUseCase _showTrackerNotification;
  final GetCurrentBatchUseCase _getCurrentBatch;
  final BatchUploadWorkflowUseCase _batchUploadWorkflow;
  final WatchTrackerSettingsUseCase _watchTrackerSettings;
  final IPointLocalRepository _localPointRepository;
  final Future<String?> Function() _blockedReason;

  PointAutomationService(
    this._createPointFromLocationStream,
    this._storePoint,
    this._getBatchPointCount,
    this._showTrackerNotification,
    this._getCurrentBatch,
    this._batchUploadWorkflow,
    this._watchTrackerSettings,
    this._localPointRepository, {
    Future<String?> Function()? blockedReason,
  }) : _blockedReason = blockedReason ?? defaultBlockedReason;

  /// Raison pour laquelle le suivi ne peut pas (re)démarrer maintenant, ou `null`.
  static Future<String?> defaultBlockedReason() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return 'localisation du téléphone désactivée';
    }
    if (!(await Permission.locationAlways.status).isGranted) {
      return 'permission de localisation « toujours » absente';
    }
    return null;
  }

  /// Instantané de santé, renvoyé à l'interface via le service de fond.
  Map<String, Object?> healthSnapshot() {
    final sup = _supervisor;
    return {
      'tracking': _isTracking,
      'lastPointAt': sup?.lastPointAt?.toIso8601String(),
      'lastFixAt': sup?.lastFixAt?.toIso8601String(),
      'issue': sup?.evaluate()?.name,
      'recoveryAttempts': sup?.attempts ?? 0,
      'pendingPoints': _lastKnownBatchCount,
      'lastUploadOkAt': _lastUploadOkAt?.toIso8601String(),
    };
  }

  /// Whether automatic tracking is currently active
  bool get isTracking => _isTracking;

  Future<void> startTracking(int userId) async {
    if (_isTracking) return;

    if (kDebugMode) {
      debugPrint("[PointAutomation] Starting automatic tracking with location stream...");
    }

    _isTracking = true;
    _currentUserId = userId;
    _lastPointTime = null;

    await _refreshNotification(userId);

    _startHeartbeatTimer();
    _startSettingsWatch(userId);
    _startSupervisor(userId);
    _startLocationStream(userId);
    _supervisor?.markStarted();
    _startBatchCountWatch(userId);
  }

  void _startSupervisor(int userId) {
    _watchdogTimer?.cancel();
    final sup = TrackingSupervisor(
      startStream: () async => _startLocationStream(userId),
      stopStream: _stopLocationStream,
      blockedReason: _blockedReason,
      log: (m) => unawaited(TrackingLog.add(m)),
      tickInterval: Duration(seconds: _currentSettings?.trackingFrequency ?? 10),
    );
    _supervisor = sup;
    _watchdogTimer = Timer.periodic(_watchdogPeriod, (_) {
      if (!_isTracking) return;
      _retryPendingUpload(userId);
      unawaited(sup.check().catchError((Object e) {
        unawaited(TrackingLog.add('Erreur du watchdog : $e'));
      }));
    });
  }

  /// Des points sont en attente et aucun envoi n'a été tenté depuis un moment
  /// (réseau suspendu par Doze, serveur injoignable) : on réessaie sans attendre
  /// qu'un nouveau point arrive.
  void _retryPendingUpload(int userId) {
    if (_lastKnownBatchCount <= 0) return;
    final last = _lastUploadAttemptAt;
    if (last != null && DateTime.now().difference(last) < const Duration(seconds: 60)) return;
    unawaited(_uploadCurrentBatch(userId));
  }

  Future<void> _stopLocationStream() async {
    final sub = _locationStreamSub;
    _locationStreamSub = null;
    try {
      await sub?.cancel();
    } catch (e) {
      unawaited(TrackingLog.add('Annulation du flux : $e'));
    }
  }

  // ── Heartbeat (OEM keep-alive) ─────────────────────────────────────────

  /// Re-posts the notification periodically using cached data (no DB query)
  /// so aggressive Android OEMs don't kill the foreground service for being
  /// "idle". This is purely a keep-alive signal.
  void _startHeartbeatTimer() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      _heartbeatInterval,
      (_) {
        _refreshNotificationWithCount(_lastKnownBatchCount);
        // Retry anything left over from a failed upload (offline, server down).
        final userId = _currentUserId;
        if (_lastKnownBatchCount > 0 && userId != null) {
          unawaited(_uploadCurrentBatch(userId));
        }
      },
    );
  }

  // ── Notification ───────────────────────────────────────────────────────

  /// Refreshes the notification. Called reactively when the batch count
  /// changes or after an upload — not on a timer.
  Future<void> _refreshNotification(int userId) async {
    try {
      final batchCount = await _getBatchPointCount(userId);
      _refreshNotificationWithCount(batchCount);
    } catch (e, s) {
      debugPrint("[PointAutomation] Notification refresh error: $e\n$s");
    }
  }

  /// Updates the notification using an already-known batch count,
  /// avoiding an extra DB query.
  void _refreshNotificationWithCount(int batchCount) {
    try {
      String body;
      if (_lastPointTime != null) {
        final lastTime = _lastPointTime!.toLocal();
        final lastTimeStr = '${lastTime.hour.toString().padLeft(2, '0')}:'
            '${lastTime.minute.toString().padLeft(2, '0')}:'
            '${lastTime.second.toString().padLeft(2, '0')}';
        body = 'Last point: $lastTimeStr • $batchCount in batch';
      } else {
        body = 'Waiting for location... • $batchCount in batch';
      }

      _showTrackerNotification(
        title: 'Tracking active',
        body: body,
      );
    } catch (e, s) {
      debugPrint("[PointAutomation] Notification refresh error: $e\n$s");
    }
  }

  // ── Reactive batch count → threshold upload ────────────────────────────

  /// Watches the un-uploaded point count via a Drift reactive stream.
  /// Every time the count changes (point stored, upload completed, etc.)
  /// we check if the threshold is met and upload. Also refreshes the
  /// notification so the user always sees the current batch count.
  void _startBatchCountWatch(int userId) {
    _batchCountSub?.cancel();

    final stream = _localPointRepository.watchBatchPointCount(userId);

    _batchCountSub = stream.listen(
      (count) async {
        // Cache for the heartbeat timer.
        _lastKnownBatchCount = count;

        // Update notification reactively — only when the count actually changes.
        _refreshNotificationWithCount(count);

        // Family needs fresh positions: send as soon as a point is stored.
        if (count > 0) {
          if (kDebugMode) {
            debugPrint('[PointAutomation] $count pending point(s) — uploading');
          }
          await _uploadCurrentBatch(userId);
        }
      },
      onError: (e) {
        debugPrint('[PointAutomation] Batch count watch error: $e');
      },
    );
  }

  // ── Upload helper ──────────────────────────────────────────────────────

  /// Fetches the current un-uploaded batch and uploads it.
  /// Guarded by [_uploadGuard] to prevent overlapping uploads.
  Future<void> _uploadCurrentBatch(int userId) async {
    try {
      await _uploadGuard.run(() async {
        final batch = await _getCurrentBatch(userId);
        if (batch.isEmpty) return;

        _lastUploadAttemptAt = DateTime.now();
        final sw = Stopwatch()..start();
        final result = await _batchUploadWorkflow(batch, userId);
        if (result case Ok()) {
          _lastUploadOkAt = DateTime.now();
          unawaited(TrackingLog.addThrottled('upload-ok', 'Envoi OK : ${batch.length} point(s) en ${sw.elapsedMilliseconds} ms', every: const Duration(minutes: 10)));
          if (kDebugMode) {
            debugPrint('[PointAutomation] Batch upload successful.');
          }
        } else if (result case Err(value: final err)) {
          debugPrint('[PointAutomation] Batch upload failed: $err');
          unawaited(TrackingLog.addThrottled('upload', 'Envoi des points échoué (conservés localement, ${batch.length} en attente) : $err'));
        }
      }, onStuck: (m) => unawaited(TrackingLog.add('Envoi : $m')));
    } catch (e, s) {
      debugPrint('[PointAutomation] Upload error: $e\n$s');
      unawaited(TrackingLog.addThrottled('upload', 'Erreur d\'envoi (points conservés) : $e'));
    }
  }

  // ── Settings watch ─────────────────────────────────────────────────────

  void _startSettingsWatch(int userId) {
    _settingsWatchSub?.cancel();

    if (kDebugMode) {
      debugPrint("[PointAutomation] Starting settings watch for userId: $userId");
    }

    _settingsWatchSub = _watchTrackerSettings(userId).listen(
      (settings) async {
        final old = _currentSettings;
        _currentSettings = settings;

        if (old != null && _settingsRequireRestart(old, settings)) {
          if (kDebugMode) {
            debugPrint("[PointAutomation] Settings changed (${old.trackingFrequency}s -> ${settings.trackingFrequency}s), restarting location stream...");
          }
          await _restartLocationStream(userId);
        }
      },
      onError: (e) {
        debugPrint("[PointAutomation] Settings watch error: $e");
      },
    );
  }

  bool _settingsRequireRestart(TrackerSettings old, TrackerSettings current) {
    return old.trackingFrequency != current.trackingFrequency ||
           old.locationPrecision != current.locationPrecision ||
           old.minimumPointDistance != current.minimumPointDistance;
  }

  // ── Location stream ────────────────────────────────────────────────────

  void _startLocationStream(int userId) {
    _locationStreamSub?.cancel();

    final pointStream = _createPointFromLocationStream.getPointStream(userId, health: _supervisor);

    _locationStreamSub = pointStream.listen(
      (result) async {
        await _handleLocationUpdate(result, userId);
      },
      onError: (error, stackTrace) {
        debugPrint("[PointAutomation] Stream error: $error\n$stackTrace");
        _supervisor?.onStreamError(error);
        unawaited(TrackingLog.addThrottled('stream', 'Erreur du flux de localisation : $error'));
      },
      onDone: () {
        _supervisor?.onStreamDone();
        unawaited(TrackingLog.add('Flux de localisation terminé'));
        if (kDebugMode) {
          debugPrint("[PointAutomation] Location stream completed");
        }
      },
      cancelOnError: false,
    );
  }

  Future<void> _restartLocationStream(int userId) async {
    try {
      final oldSub = _locationStreamSub;
      _locationStreamSub = null;

      if (oldSub != null) {
        unawaited(oldSub.cancel().catchError((e) {
          debugPrint("[PointAutomation] Cancel error (ignored): $e");
        }));
      }

      _startLocationStream(userId);

      if (kDebugMode) {
        debugPrint("[PointAutomation] Location stream restarted");
      }
    } catch (e, s) {
      debugPrint("[PointAutomation] ERROR in _restartLocationStream: $e\n$s");
    }
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────

  Future<void> stopTracking() async {
    if (!_isTracking) return;
    unawaited(TrackingLog.add('stopTracking appelé'));

    if (kDebugMode) {
      debugPrint("[PointAutomation] Stopping automatic tracking...");
    }

    _isTracking = false;
    _currentUserId = null;
    _currentSettings = null;
    _lastPointTime = null;
    _lastKnownBatchCount = 0;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _supervisor = null;
    await _batchCountSub?.cancel();
    _batchCountSub = null;
    await _settingsWatchSub?.cancel();
    _settingsWatchSub = null;
    await _locationStreamSub?.cancel();
    _locationStreamSub = null;
  }

  Future<void> restartTracking() async {
    if (!_isTracking || _currentUserId == null) return;

    final userId = _currentUserId!;

    if (kDebugMode) {
      debugPrint("[PointAutomation] Restarting tracking to apply new settings...");
    }

    await stopTracking();
    await startTracking(userId);
  }

  // ── Location update handler (store only) ───────────────────────────────

  /// Handles location updates from the stream.
  /// Only stores the point locally. The reactive [_batchCountSub] stream
  /// picks up the count change and triggers the upload when the threshold
  /// is met.
  Future<void> _handleLocationUpdate(Result<dynamic, String> result, int userId) async {
    try {
      final ran = await _writeGuard.run(() async {
        if (result case Ok(value: final point)) {
          if (kDebugMode) {
            debugPrint("[PointAutomation] Storing point from location stream");
          }

          final storeResult = await _storePoint(point);

          if (storeResult case Ok()) {
            _lastPointTime = DateTime.now();
            _supervisor?.onPoint();
            // Envoi immédiat, sans dépendre du flux réactif de la base.
            unawaited(_uploadCurrentBatch(userId));
            unawaited(TrackingLog.addThrottled('point', 'Point enregistré', every: const Duration(minutes: 10)));
          } else if (storeResult case Err(value: final err)) {
            debugPrint("[PointAutomation] Failed to store point: $err");
            unawaited(TrackingLog.addThrottled('store', 'Point non enregistré : $err'));
          }
        } else if (result case Err(value: final err)) {
          debugPrint("[PointAutomation] Point creation error: $err");
          unawaited(TrackingLog.addThrottled('create', 'Position introuvable : $err'));
        }
      }, onStuck: (m) => unawaited(TrackingLog.add('Écriture locale : $m')));

      if (!ran && kDebugMode) {
        debugPrint("[PointAutomation] Skipping location update, write busy.");
      }
    } catch (e, s) {
      debugPrint("[PointAutomation] Error handling location update: $e\n$s");
      unawaited(TrackingLog.addThrottled('store', 'Échec d\'écriture locale : $e'));
    }
  }
}
