import 'dart:async';

enum RestoreOutcome {
  /// Le tracking automatique est désactivé : rien à faire.
  disabled,

  /// Service relancé car il ne tournait plus.
  started,

  /// Relance refusée (permission, GPS…). Le réglage reste activé.
  startFailed,

  /// Service présent mais isolate de fond muet : arrêté puis relancé.
  restartedUnresponsive,

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
    required this.stopService,
    required this.pingHealth,
    required this.restartTracking,
    required this.log,
    this.settleDelay = const Duration(seconds: 1),
  });

  final Future<bool> Function() readAutomaticTracking;
  final Future<bool> Function() isRunning;

  /// `null` si démarré, sinon le message d'échec.
  final Future<String?> Function() startService;
  final Future<void> Function() stopService;

  /// Instantané de santé du service de fond, ou `null` s'il ne répond pas.
  final Future<Map<String, Object?>?> Function() pingHealth;
  final Future<void> Function() restartTracking;
  final void Function(String message) log;
  final Duration settleDelay;

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
      log('Service présent mais sans réponse : arrêt puis relance');
      await stopService();
      await Future<void>.delayed(settleDelay);
      final failure = await startService();
      if (failure != null) {
        log('Relance après blocage refusée : $failure (réglage conservé)');
        return RestoreOutcome.startFailed;
      }
      return RestoreOutcome.restartedUnresponsive;
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
}
