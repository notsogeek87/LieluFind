import 'package:dawarich/features/tracking/application/services/tracking_service_restorer.dart';
import 'package:flutter_test/flutter_test.dart';

class _Fake {
  bool automaticTracking = true;
  bool running = false;
  String? startFailure;
  Map<String, Object?>? health = {'tracking': true, 'issue': null};
  int starts = 0, stops = 0, restarts = 0;
  final logs = <String>[];

  /// Le restaurateur n'a aucun accès en écriture au réglage : on vérifie
  /// quand même qu'il reste intact après chaque scénario d'échec.
  late final restorer = TrackingServiceRestorer(
    readAutomaticTracking: () async => automaticTracking,
    isRunning: () async => running,
    startService: () async {
      starts++;
      if (startFailure != null) return startFailure;
      running = true;
      return null;
    },
    stopService: () async {
      stops++;
      running = false;
    },
    pingHealth: () async => health,
    restartTracking: () async => restarts++,
    log: logs.add,
    settleDelay: Duration.zero,
  );
}

void main() {
  test('tracking désactivé : rien n\'est lancé', () async {
    final f = _Fake()..automaticTracking = false;
    expect(await f.restorer.restore(), RestoreOutcome.disabled);
    expect(f.starts, 0);
  });

  test('service mort après une mise à jour : relancé', () async {
    final f = _Fake();
    expect(await f.restorer.restore(), RestoreOutcome.started);
    expect(f.starts, 1);
    expect(f.automaticTracking, isTrue);
  });

  test('permission manquante : le réglage reste activé et l\'échec est journalisé', () async {
    final f = _Fake()..startFailure = 'Background location permission is required.';
    expect(await f.restorer.restore(), RestoreOutcome.startFailed);
    expect(f.automaticTracking, isTrue);
    expect(f.logs.single, contains('réglage conservé'));
  });

  test('service présent mais isolate muet : arrêt puis relance', () async {
    final f = _Fake()
      ..running = true
      ..health = null;
    expect(await f.restorer.restore(), RestoreOutcome.restartedUnresponsive);
    expect(f.stops, 1);
    expect(f.starts, 1);
  });

  test('relance refusée après blocage : le réglage reste activé', () async {
    final f = _Fake()
      ..running = true
      ..health = null
      ..startFailure = 'Notification permission is required.';
    expect(await f.restorer.restore(), RestoreOutcome.startFailed);
    expect(f.automaticTracking, isTrue);
  });

  test('suivi en panne dans un service vivant : relance du suivi', () async {
    final f = _Fake()
      ..running = true
      ..health = {'tracking': true, 'issue': 'streamDone'};
    expect(await f.restorer.restore(), RestoreOutcome.restartedTracking);
    expect(f.restarts, 1);
    expect(f.stops, 0, reason: 'inutile de tuer le service');
  });

  test('service en attente de sa session : on ne le dérange pas', () async {
    final f = _Fake()
      ..running = true
      ..health = {'tracking': false, 'error': 'initialisation en cours'};
    expect(await f.restorer.restore(), RestoreOutcome.waitingForInit);
    expect(f.starts + f.stops + f.restarts, 0);
  });

  test('tout va bien : aucune action', () async {
    final f = _Fake()..running = true;
    expect(await f.restorer.restore(), RestoreOutcome.healthy);
    expect(f.starts + f.stops + f.restarts, 0);
  });
}
