import 'dart:async';
import 'package:dawarich/core/constants/notification.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:option_result/option_result.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:dawarich/core/di/providers/core_providers.dart';
import 'package:dawarich/core/di/providers/session_providers.dart';
import 'package:dawarich/core/di/providers/usecase_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'background_tracking_entrypoint.dart';
import 'package:dawarich/features/tracking/application/usecases/system_settings/check_system_settings_usecase.dart';
import 'tracking_log.dart';
import 'tracking_service_restorer.dart';
import 'tracking_supervisor.dart';
import 'package:dawarich/features/tracking/application/usecases/get_batch_point_count_usecase.dart';
import 'package:dawarich/features/tracking/application/usecases/get_last_point_usecase.dart';



class BackgroundTrackingEntry {
  static ProviderContainer? _container;

  static Future<ProviderContainer> _ensureContainer() async {
    final existing = _container;
    if (existing != null) return existing;

    final container = ProviderContainer();
    // Ensure core deps are ready in background isolate.
    await container.read(coreProvider.future);
    _container = container;
    return container;
  }

  /// Mis à vrai par [shutdown] : interrompt la boucle d'initialisation.
  static bool _stopRequested = false;

  /// Au-delà, une session toujours introuvable est considérée comme une
  /// déconnexion volontaire : le service s'arrête.
  static const Duration _noSessionGiveUp = Duration(minutes: 30);

  static Future<void> checkBackgroundTracking(ServiceInstance backgroundService) async {
    _stopRequested = false;
    if (kDebugMode) {
      debugPrint('[Background] Injecting background thread dependencies...');
    }
    await TrackingLog.add('Service de fond démarré');

    // Une base verrouillée ou une session pas encore lisible sont transitoires.
    // On réessaie (délais progressifs) au lieu d'appeler stopSelf(), qui
    // marquerait « arrêt manuel » et désarmerait le watchdog du plugin.
    final startedAt = DateTime.now();
    final boot = await retryUntilAvailable<_Boot>(
      (attempt) async {
        if (attempt > 1) {
          _container?.dispose();
          _container = null;
        }

        final container = await _ensureContainer();
        final session = await container.read(sessionBoxProvider.future);
        final user = await session.refreshSession();

        if (user == null) {
          if (DateTime.now().difference(startedAt) > _noSessionGiveUp) {
            return _Boot(container, null, false);
          }
          return null;
        }

        session.setUserId(user.id);
        final getSettings = await container.read(getTrackerSettingsUseCaseProvider.future);
        final settings = await getSettings(user.id);
        await TrackingLog.add('Réglage tracking auto = ${settings.automaticTracking}');
        return _Boot(container, user.id, settings.automaticTracking);
      },
      sleep: (d) => Future<void>.delayed(d),
      shouldStop: () => _stopRequested,
      onFailure: (attempt, error) {
        unawaited(TrackingLog.add(error == null
            ? 'Pas de session utilisateur (essai $attempt), nouvel essai'
            : 'Initialisation impossible (essai $attempt) : $error, nouvel essai'));
      },
    );

    if (boot == null) return; // arrêt demandé pendant l'attente

    if (boot.userId == null) {
      await shutdown(backgroundService, 'No user session');
      return;
    }

    if (!boot.automaticTracking) {
      if (kDebugMode) {
        debugPrint('[Background] Auto tracking OFF → shutting down.');
      }
      await shutdown(backgroundService, 'Auto tracking OFF');
      return;
    }

    await _startBackgroundTracking(backgroundService, boot.container, boot.userId!);
  }

  /// État des réglages Android qui décident de la survie du suivi écran éteint.
  static Future<void> _logEnvironment() async {
    try {
      final battery = await Permission.ignoreBatteryOptimizations.status;
      final always = await Permission.locationAlways.status;
      final notif = await Permission.notification.status;
      await TrackingLog.add('Environnement : batterie sans restriction=${battery.isGranted}, '
          'localisation toujours=${always.isGranted}, notifications=${notif.isGranted}');
      if (!battery.isGranted) {
        await TrackingLog.add('⚠ Optimisation de batterie ACTIVE : Android peut suspendre le réseau '
            'écran éteint (Doze). Réglage à passer sur « Sans restriction ».');
      }
    } catch (e) {
      await TrackingLog.add('Environnement illisible : $e');
    }
  }

  static Future<void> _startBackgroundTracking(
    ServiceInstance backgroundService,
    ProviderContainer container,
    int userId,
  ) async {
    if (kDebugMode) {
      debugPrint('[Background] Starting background tracking...');
    }

    final automation = await container.read(pointAutomationServiceProvider.future);
    await automation.startTracking(userId);
    await TrackingLog.add('Tracking démarré (user $userId)');
    unawaited(_logEnvironment());

    try {
      final getLastPoint = await container.read(getLastPointUseCaseProvider.future);
      final getBatchCount = await container.read(getBatchPointCountUseCaseProvider.future);
      await setInitialForegroundNotification(getLastPoint, getBatchCount, backgroundService, userId);
    } catch (_) {
      // ignore
    }
  }

  static void registerListeners(ServiceInstance backgroundService) {
    backgroundService.on('stopService').listen((event) async {
      final requestId = event?['requestId'];
      try {
        final container = _container;
        if (container != null) {
          final automation = await container.read(pointAutomationServiceProvider.future);
          await automation.stopTracking();
        }
      } catch (e, s) {
        debugPrint('[Background] Error stopping tracking: $e\n$s');
      } finally {
        backgroundService.invoke('stopped', {'requestId': requestId});
        await shutdown(backgroundService, 'stopService event');
      }
    });

    backgroundService.on('healthPing').listen((event) async {
      final snapshot = <String, dynamic>{'alive': true, 'tracking': false};
      try {
        final container = _container;
        if (container != null) {
          // Ne jamais bloquer la réponse : une réponse « lente » vaut mieux qu'un silence
          // que l'interface prendrait pour un service mort.
          final automation = await container
              .read(pointAutomationServiceProvider.future)
              .timeout(const Duration(seconds: 15));
          snapshot.addAll(automation.healthSnapshot());
        } else {
          snapshot['error'] = 'initialisation en cours';
        }
      } catch (e) {
        snapshot['error'] = '$e';
      }
      backgroundService.invoke('healthPong', snapshot);
    });

    backgroundService.on('restartTracking').listen((event) async {
      debugPrint('[Background] *** restartTracking event received ***');
      try {
        final container = _container;
        if (container != null) {
          final automation = await container.read(pointAutomationServiceProvider.future);
          await automation.restartTracking();
          debugPrint('[Background] Tracking restarted successfully');
        } else {
          debugPrint('[Background] Container is null, cannot restart tracking');
        }
      } catch (e, s) {
        debugPrint('[Background] Error restarting tracking: $e\n$s');
      }
    });
  }

  static Future<void> shutdown(ServiceInstance svc, String reason) async {
    _stopRequested = true;
    await TrackingLog.add('ARRÊT du service : $reason');
    if (kDebugMode) {
      debugPrint('[Background] Shutting down: $reason');
    }
    try {
      _container?.dispose();
    } catch (_) {}
    _container = null;
    svc.stopSelf();
  }

  static Future<void> setInitialForegroundNotification(
    GetLastPointUseCase getLastPoint,
    GetBatchPointCountUseCase getBatchPointsCount,
    ServiceInstance backgroundService,
    int userId,
  ) async {
    final lastPointResult = await getLastPoint(userId);
    final batchPointCount = await getBatchPointsCount(userId);

    if (backgroundService is AndroidServiceInstance) {
      if (lastPointResult case Some(value: final lp)) {
        await backgroundService.setForegroundNotificationInfo(
          title: 'LieluFind Tracking',
          content: 'Last updated at: ${lp.timestamp.toLocal()}, $batchPointCount points in batch.',
        );
      } else {
        await backgroundService.setForegroundNotificationInfo(
          title: 'LieluFind Tracking',
          content: 'Tracking in the background, no points recorded yet.',
        );
      }
    }
  }

}

@pragma('vm:entry-point')
final class BackgroundTrackingService {

  static bool _configured = false;
  static Completer<void>? _starting;
  static bool _isStopping = false;


  static Future<void> ensureNotificationChannelExists() async {
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      NotificationConstants.channelId,
      NotificationConstants.channelName,
      description: NotificationConstants.channelDescription,
      importance: Importance.min,
    );

    final FlutterLocalNotificationsPlugin plugin = FlutterLocalNotificationsPlugin();

    await plugin
        .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  static Future<void> installConfigurationOnce() async {

    if (_configured) {
      return;
    }

    await ensureNotificationChannelExists();

    await FlutterBackgroundService().configure(
      androidConfiguration: AndroidConfiguration(
        onStart: backgroundTrackingEntry,
        autoStartOnBoot: true,
        isForegroundMode: true,
        foregroundServiceTypes: [AndroidForegroundType.location],
        autoStart: false,
        foregroundServiceNotificationId: NotificationConstants.notificationId,
        notificationChannelId: NotificationConstants.channelId,
      ),
      iosConfiguration: IosConfiguration(
        onForeground: backgroundTrackingEntry,
        onBackground: (_) async => true,
      ),
    );

    _configured = true;
  }


  /// Start (if needed) and configure the background service.
  /// Safe/idempotent across concurrent callers
  static Future<void> configureService({bool force = false}) async {
    // coalesce concurrent calls
    if (_starting != null) {
      return _starting!.future;
    }

    _starting = Completer<void>();

    try {
      await installConfigurationOnce();

      final service = FlutterBackgroundService();

      if (!await service.isRunning()) {
        await service.startService();

        final ready = Completer<void>();
        final sub = service.on('ready').listen((_) {
          if (!ready.isCompleted) ready.complete();
        });
        await ready.future.timeout(const Duration(seconds: 5), onTimeout: () {});
        await sub.cancel();
      }


      _starting!.complete();
    } catch (e, s) {
      if (kDebugMode) debugPrint('[Tracker] configureService failed: $e\n$s');
      _starting!.completeError(e, s);
      rethrow;
    } finally {
      _starting = null;
    }
  }

  /// Relance le service si le tracking automatique est activé mais que le
  /// service ne tourne plus (mise à jour de l'APK, kill système, redémarrage).
  /// Ne touche jamais au réglage : un échec (permission manquante) laisse le
  /// bouton activé.
  static Future<void>? _restoring;

  static Future<void> restoreIfEnabled(ProviderContainer container, int userId) {
    // Démarrage + retour au premier plan peuvent se chevaucher : un seul contrôle à la fois.
    return _restoring ??= _restore(container, userId).whenComplete(() => _restoring = null);
  }

  static Future<void> _restore(ProviderContainer container, int userId) async {
    try {
      // Sans configure(), l'interface ne reçoit aucun message du service (pong, confirmations) :
      // le contrôle de santé resterait toujours sans réponse.
      await installConfigurationOnce();
      final restorer = TrackingServiceRestorer(
        readAutomaticTracking: () async {
          final getSettings = await container.read(getTrackerSettingsUseCaseProvider.future);
          final enabled = (await getSettings(userId)).automaticTracking;
          if (enabled && await CheckSystemSettingsUseCase()()) {
            unawaited(TrackingLog.addThrottled(
                'battery',
                '⚠ Optimisation de batterie ACTIVE pour LieluFind : écran éteint, Android peut suspendre '
                'le réseau (les positions ne partent qu\'à l\'ouverture de l\'app). Réglages Android → '
                'Applications → LieluFind → Batterie → Sans restriction.',
                every: const Duration(hours: 1)));
          }
          return enabled;
        },
        isRunning: () => FlutterBackgroundService().isRunning(),
        startService: () async {
          final result = await start();
          return switch (result) { Ok() => null, Err(value: final m) => m };
        },
        pingHealth: _pingHealth,
        restartTracking: restartTracking,
        log: (m) => unawaited(TrackingLog.add(m)),
      );
      final outcome = await restorer.restore();
      if (kDebugMode) debugPrint('[Tracker] restoreIfEnabled → $outcome');
    } catch (e, s) {
      if (kDebugMode) debugPrint('[Tracker] restoreIfEnabled failed: $e\n$s');
      unawaited(TrackingLog.add('Contrôle du service impossible : $e'));
    }
  }

  /// Appelé par la tâche WorkManager périodique, app fermée : relance le service
  /// s'il a été tué alors que le tracking automatique est activé.
  static Future<RestoreOutcome> reviveIfDead({required bool automaticTracking}) async {
    try {
      await installConfigurationOnce();
      return await TrackingServiceRestorer(
        readAutomaticTracking: () async => automaticTracking,
        isRunning: () => FlutterBackgroundService().isRunning(),
        startService: () async {
          // Android peut refuser un service de premier plan lancé depuis l'arrière-plan
          // (exception de plateforme) : on le journalise, la tâche suivante réessaiera.
          try {
            final result = await start();
            return switch (result) { Ok() => null, Err(value: final m) => m };
          } catch (e) {
            return '$e';
          }
        },
        pingHealth: () async => null,
        restartTracking: () async {},
        log: (m) => unawaited(TrackingLog.add(m)),
      ).reviveIfDead();
    } catch (e, s) {
      if (kDebugMode) debugPrint('[Tracker] reviveIfDead failed: $e\n$s');
      unawaited(TrackingLog.add('Contrôle du service par la tâche de fond impossible : $e'));
      return RestoreOutcome.startFailed;
    }
  }

  /// Interroge l'isolate de fond ; `null` s'il ne répond pas dans les 5 s.
  static Future<Map<String, Object?>?> _pingHealth() async {
    final service = FlutterBackgroundService();
    final completer = Completer<Map<String, Object?>?>();
    final sub = service.on('healthPong').listen((event) {
      if (!completer.isCompleted) completer.complete(Map<String, Object?>.from(event ?? {}));
    });
    try {
      // Un isolate endormi (écran éteint) peut mettre quelques secondes à se réveiller :
      // deux essais avant de conclure qu'il est muet.
      for (var attempt = 1; attempt <= 2; attempt++) {
        service.invoke('healthPing', {});
        final pong = await completer.future.timeout(const Duration(seconds: 15), onTimeout: () => null);
        if (pong != null) return pong;
      }
      return null;
    } finally {
      await sub.cancel();
    }
  }

  static Future<Result<(), String>> start() async {

    if (!(await Permission.notification.isGranted)) {
      debugPrint('[BackgroundService] Notification permission missing.');
      await TrackingLog.add('Démarrage refusé : permission notification manquante');
      return Err("Notification permission is required.");
    }

    final locEnabled = await Geolocator.isLocationServiceEnabled();
    final always = await Permission.locationAlways.status;
    final hasBgPermission = always.isGranted;

    if (!locEnabled || !hasBgPermission) {
      await TrackingLog.add('Démarrage refusé : localisation ${locEnabled ? 'ok' : 'désactivée'}, permission « toujours » ${hasBgPermission ? 'ok' : 'manquante'}');
      return Err("Background location permission is required.");
    }

    await installConfigurationOnce();

    final isRunning = await FlutterBackgroundService().isRunning();
    if (isRunning) {
      debugPrint('[BackgroundService] Already running — skipping start.');
      await TrackingLog.add('Service déjà en cours : pas de relance');
      return Ok(());
    }

    final started = await FlutterBackgroundService().startService();
    await TrackingLog.add('startService → $started');
    return started
        ? Ok(())
        : Err("Failed to start background service.");
  }

  static Future<void> stop() async {
    final service = FlutterBackgroundService();

    final isRunning = await service.isRunning();
    if (!isRunning) {
      debugPrint('[BackgroundService] Stop skipped: service not running');
      return;
    }

    if (_isStopping) return;
    _isStopping = true;

    final requestId = DateTime.now().millisecondsSinceEpoch.toString();
    final stopCompleter = Completer<void>();

    final sub = service.on('stopped').listen((event) {
      final eventId = event?['requestId'];
      if (eventId == requestId) {
        debugPrint('[BackgroundService] Stop confirmed for requestId $requestId.');
        stopCompleter.complete();
      } else {
        debugPrint('[BackgroundService] Received unrelated stop event with requestId $eventId.');
      }
    });

    debugPrint('[BackgroundService] Sending stopService request with ID $requestId...');
    service.invoke('stopService', {'requestId': requestId});

    try {
      await stopCompleter.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          debugPrint('[BackgroundService] Stop confirmation timed out for requestId $requestId.');
        },
      );
    } catch (_) {
      debugPrint('[BackgroundService] Stop confirmation failed or timed out.');
    } finally {
      await sub.cancel();
      _isStopping = false;
    }
  }

  /// Restart tracking to apply new settings (e.g., frequency change)
  /// Sends event to background isolate to restart the tracking logic.
  static Future<void> restartTracking() async {
    final service = FlutterBackgroundService();

    final isRunning = await service.isRunning();
    if (!isRunning) {
      debugPrint('[BackgroundService] Restart skipped: service not running');
      return;
    }

    debugPrint('[BackgroundService] Sending restartTracking event to background isolate...');
    service.invoke('restartTracking', {});
  }

}

class _Boot {
  final ProviderContainer container;
  final int? userId;
  final bool automaticTracking;
  const _Boot(this.container, this.userId, this.automaticTracking);
}
