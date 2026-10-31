import 'dart:async';

enum RestoreOutcome {
  /// Le tracking automatique est désactivé : rien à faire.
  disabled,

  /// Service relancé car il ne tournait plus.
  started,

  /// Relance refusée (permission, GPS…). Le réglage reste activé.
  startFailed,

  /// Service présent mais sans réponse au contrôle de santé : on n'y touche pas (un service
  /// qui enregistre des points est sain ; l'arrêter ferait perdre du suivi).
  unresponsive,

  /// Service vivant mais suivi en panne : relance du suivi demandée.
  restartedTracking,

  /// Service vivant, en attente de sa session/base (il réessaie seul).
  waitingForInit,

  /// Tout va bien.
  healthy,
}

/// Décide à l'ouverture de l'app ce qu'il faut faire du service de fond.
/// Ne modifie jamais le réglage « tracking auto » : il n'a aucun accès en écriture.
final class TrackingServiceRestorer {
  TrackingServiceRestorer({
    required this.readAutomaticTracking,
    required this.isRunning,
    required this.startService,
    required this.pingHealth,
    required this.restartTracking,
    required this.log,
  });

  final Future<bool> Function() readAutomaticTracking;
  final Future<bool> Function() isRunning;

  /// `null` si démarré, sinon le message d'échec.
  final Future<String?> Function() startService;

  /// Instantané de santé du service de fond, ou `null` s'il ne répond pas.
  final Future<Map<String, Object?>?> Function() pingHealth;
  final Future<void> Function() restartTracking;
  final void Function(String message) log;

  Future<RestoreOutcome> restore() async {
    if (!await readAutomaticTracking()) return RestoreOutcome.disabled;

    if (!await isRunning()) {
      final failure = await startService();
      if (failure != null) {
        log('Relance à l\'ouverture refusée : $failure (réglage conservé)');
        return RestoreOutcome.startFailed;
      }
      log('Relance à l\'ouverture : service redémarré');
      return RestoreOutcome.started;
    }

    final health = await pingHealth();
    if (health == null) {
      // Jamais d'arrêt sur un simple silence : le journal de terrain montre un service qui
      // enregistrait ses points pendant que le contrôle restait sans réponse, et un arrêt
      // suivi d'une relance interrompue (app refermée) a coûté 24 min de suivi.
      log('Service présent, pas de réponse au contrôle de santé : laissé tel quel');
      return RestoreOutcome.unresponsive;
    }

    if (health['tracking'] != true) {
      log('Service vivant, suivi pas encore démarré (${health['error'] ?? 'initialisation en cours'})');
      return RestoreOutcome.waitingForInit;
    }

    final issue = health['issue'];
    if (issue != null) {
      log('Suivi en panne ($issue) : relance demandée');
      await restartTracking();
      return RestoreOutcome.restartedTracking;
    }

    return RestoreOutcome.healthy;
  }

  /// Contrôle périodique depuis la tâche de fond (WorkManager), app fermée.
  /// Android peut tuer le service sans prévenir ; son superviseur meurt avec lui et,
  /// sur le terrain, plus rien ne le relançait avant l'ouverture de l'app (jusqu'à
  /// 11 h de suivi perdues). Ne relance qu'un service mort : un service vivant a son
  /// propre superviseur, et l'isolate de la tâche ne peut pas l'interroger.
  Future<RestoreOutcome> reviveIfDead() async {
    if (!await readAutomaticTracking()) return RestoreOutcome.disabled;
    if (await isRunning()) return RestoreOutcome.healthy;

    final failure = await startService();
    if (failure != null) {
      log('Relance par la tâche de fond refusée : $failure (réglage conservé)');
      return RestoreOutcome.startFailed;
    }
    log('Service retrouvé arrêté : relancé par la tâche de fond');
    return RestoreOutcome.started;
  }
}
