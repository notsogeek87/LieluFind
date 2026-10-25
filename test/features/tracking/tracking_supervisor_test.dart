import 'dart:async';

import 'package:dawarich/features/tracking/application/services/tracking_supervisor.dart';
import 'package:flutter_test/flutter_test.dart';

/// Horloge et dépendances contrôlées : aucun délai réel dans ces tests.
class _Harness {
  DateTime clock = DateTime.utc(2026, 1, 1, 12);
  int starts = 0;
  int stops = 0;
  String? blocked;
  Object? startError;
  Completer<void>? startGate;
  final logs = <String>[];

  late final TrackingSupervisor sup = TrackingSupervisor(
    startStream: () async {
      starts++;
      if (startError != null) throw startError!;
      await startGate?.future;
    },
    stopStream: () async => stops++,
    blockedReason: () async => blocked,
    log: logs.add,
    now: () => clock,
  );

  void advance(Duration d) => clock = clock.add(d);

  /// Simule un suivi sain pendant [d] : un tick toutes les 10 s, un point toutes les 5 min.
  void healthyFor(Duration d) {
    var elapsed = Duration.zero;
    while (elapsed < d) {
      advance(const Duration(seconds: 10));
      elapsed += const Duration(seconds: 10);
      sup.onTick();
      if (elapsed.inSeconds % 300 == 0) sup.onPoint();
    }
  }
}

void main() {
  late _Harness h;

  setUp(() {
    h = _Harness();
    h.sup.markStarted();
  });

  group('santé', () {
    test('un téléphone immobile (ticks, pas de position) n\'est pas une panne', () async {
      h.healthyFor(const Duration(minutes: 11));
      expect(h.sup.evaluate(), isNull);
      await h.sup.check();
      expect(h.starts, 0);
    });

    test('flux terminé : relance', () async {
      h.healthyFor(const Duration(minutes: 1));
      h.sup.onStreamDone();
      expect(h.sup.evaluate(), HealthIssue.streamDone);

      await h.sup.check();

      expect(h.stops, 1);
      expect(h.starts, 1);
      expect(h.sup.evaluate(), isNull, reason: 'markStarted remet le flux à zéro');
    });

    test('flux muet depuis le démarrage (service geolocator non lié) : relance après le délai de grâce', () async {
      h.advance(const Duration(seconds: 60));
      await h.sup.check();
      expect(h.starts, 0, reason: 'encore dans le délai de grâce');

      h.advance(const Duration(seconds: 40));
      expect(h.sup.evaluate(), HealthIssue.neverStarted);
      await h.sup.check();
      expect(h.starts, 1);
    });

    test('minuteur silencieux (isolate gelé) : relance', () async {
      h.healthyFor(const Duration(minutes: 1));
      h.advance(const Duration(minutes: 2));
      expect(h.sup.evaluate(), HealthIssue.timerSilent);
      await h.sup.check();
      expect(h.starts, 1);
    });

    test('ticks vivants mais aucun point depuis trop longtemps : relance', () async {
      for (var i = 0; i < 80; i++) {
        h.advance(const Duration(seconds: 10));
        h.sup.onTick();
      }
      h.advance(const Duration(minutes: 12));
      h.sup.onTick();
      expect(h.sup.evaluate(), HealthIssue.noPoint);
      await h.sup.check();
      expect(h.starts, 1);
    });

    test('erreur temporaire du fournisseur : relance puis état sain', () async {
      h.healthyFor(const Duration(minutes: 1));
      h.sup.onStreamError(StateError('provider disabled'));
      await h.sup.check();
      expect(h.starts, 1);
      expect(h.sup.evaluate(), isNull);
    });
  });

  group('veille profonde à l\'arrêt', () {
    test('téléphone endormi : un minuteur muet n\'est pas une panne', () async {
      h.healthyFor(const Duration(minutes: 1));
      h.sup.onPoint();
      h.sup.onSleepAllowed(true);
      h.advance(const Duration(minutes: 14));
      expect(h.sup.evaluate(), isNull);
      await h.sup.check();
      expect(h.starts, 0);
    });

    test('téléphone endormi : une alarme repoussée par Android est tolérée', () {
      h.sup.onPoint();
      h.sup.onSleepAllowed(true);
      h.advance(const Duration(minutes: 30));
      expect(h.sup.evaluate(), isNull, reason: '22 min + 15 min de marge');
    });

    test('téléphone endormi : aucun point bien au-delà de la marge reste une panne', () {
      h.sup.onPoint();
      h.sup.onSleepAllowed(true);
      h.advance(const Duration(minutes: 38));
      expect(h.sup.evaluate(), HealthIssue.noPoint);
    });

    test('réveillé (en mouvement) : le minuteur muet redevient une panne', () {
      h.healthyFor(const Duration(minutes: 1));
      h.sup.onSleepAllowed(true);
      h.sup.onSleepAllowed(false);
      h.advance(const Duration(minutes: 2));
      expect(h.sup.evaluate(), HealthIssue.timerSilent);
    });
  });

  group('permissions, GPS, session', () {
    test('permission manquante : pas de relance, puis reprise quand elle revient', () async {
      h.sup.onStreamDone();
      h.blocked = 'permission de localisation « toujours » absente';

      await h.sup.check();
      expect(h.starts, 0);
      expect(h.sup.attempts, 0, reason: 'un blocage n\'épuise pas les tentatives');
      expect(h.logs.single, contains('bloqué'));

      h.advance(const Duration(seconds: 31));
      await h.sup.check();
      expect(h.starts, 0);
      expect(h.logs.length, 1, reason: 'même blocage : pas de journal en boucle');

      h.blocked = null;
      h.advance(const Duration(seconds: 31));
      await h.sup.check();
      expect(h.starts, 1);
      expect(h.logs.any((l) => l.contains('Blocage levé')), isTrue);
    });
  });

  group('temporisation et limite', () {
    test('délais progressifs puis rythme lent, sans abandon', () {
      expect(recoveryDelay(1), const Duration(seconds: 5));
      expect(recoveryDelay(2), const Duration(seconds: 15));
      expect(recoveryDelay(5), const Duration(minutes: 5));
      expect(recoveryDelay(6), kSlowRecoveryDelay);
      expect(recoveryDelay(50), kSlowRecoveryDelay);
    });

    test('une panne persistante est relancée de plus en plus lentement', () async {
      h.startError = StateError('toujours en panne');
      h.sup.onStreamDone();

      var restarts = 0;
      for (var i = 0; i < 12; i++) {
        final before = h.starts;
        await h.sup.check();
        if (h.starts > before) restarts++;
        h.sup.onStreamDone(); // markStarted n'a pas été appelé : la panne persiste
        h.advance(recoveryDelay(h.sup.attempts) + const Duration(seconds: 1));
      }
      expect(restarts, 12);
      expect(h.sup.attempts, 12);
      expect(h.logs.any((l) => l.contains('rythme lent')), isTrue);
      expect(h.logs.any((l) => l.contains('Relance échouée')), isTrue);
    });

    test('pas de relance avant la fin de la temporisation', () async {
      h.sup.onStreamDone();
      await h.sup.check();
      expect(h.starts, 1);

      h.sup.onStreamDone();
      h.advance(const Duration(seconds: 2));
      await h.sup.check();
      expect(h.starts, 1, reason: 'attendre 5 s');

      h.advance(const Duration(seconds: 4));
      await h.sup.check();
      expect(h.starts, 2);
    });

    test('après une période stable avec des points, les tentatives repartent de zéro', () async {
      h.sup.onStreamDone();
      await h.sup.check();
      expect(h.sup.attempts, 1);

      h.healthyFor(const Duration(minutes: 3));
      await h.sup.check();
      expect(h.sup.attempts, 0);
    });
  });

  group('concurrence', () {
    test('plusieurs contrôles simultanés ne lancent qu\'une seule récupération', () async {
      h.startGate = Completer<void>();
      h.sup.onStreamDone();

      final first = h.sup.check();
      final second = h.sup.check();
      final third = h.sup.check();
      await Future.wait([second, third]);
      expect(h.sup.recovering, isTrue);

      h.startGate!.complete();
      await first;

      expect(h.stops, 1);
      expect(h.starts, 1);
      expect(h.sup.recovering, isFalse);
    });
  });

  group('SingleFlightGuard (écriture locale / envoi)', () {
    test('une tâche en cours bloque la suivante', () async {
      final guard = SingleFlightGuard(stuckAfter: const Duration(seconds: 45));
      final gate = Completer<void>();
      final running = guard.run(() => gate.future);

      expect(await guard.run(() async {}), isFalse);

      gate.complete();
      await running;
      expect(await guard.run(() async {}), isTrue);
    });

    test('un échec d\'écriture libère la garde', () async {
      final guard = SingleFlightGuard(stuckAfter: const Duration(seconds: 45));
      await expectLater(guard.run(() async => throw StateError('disque plein')), throwsStateError);
      expect(guard.busy, isFalse);
      expect(await guard.run(() async {}), isTrue);
    });

    test('une tâche bloquée est libérée au bout du délai', () async {
      var now = DateTime.utc(2026);
      final guard = SingleFlightGuard(stuckAfter: const Duration(seconds: 45), now: () => now);
      final hung = Completer<void>();
      unawaited(guard.run(() => hung.future).catchError((_) => true));

      now = now.add(const Duration(seconds: 30));
      expect(await guard.run(() async {}), isFalse);

      now = now.add(const Duration(seconds: 30));
      final stuck = <String>[];
      expect(await guard.run(() async {}, onStuck: stuck.add), isTrue);
      expect(stuck, hasLength(1));
    });
  });

  group('retryUntilAvailable (session expirée, base verrouillée)', () {
    test('réessaie avec les délais progressifs jusqu\'à obtenir la session', () async {
      final sleeps = <Duration>[];
      var calls = 0;
      final result = await retryUntilAvailable<String>(
        (attempt) async {
          calls++;
          if (attempt == 1) throw StateError('database is locked');
          if (attempt < 4) return null; // session pas encore lisible
          return 'user-1';
        },
        sleep: (d) async => sleeps.add(d),
      );

      expect(result, 'user-1');
      expect(calls, 4);
      expect(sleeps, [
        const Duration(seconds: 5),
        const Duration(seconds: 15),
        const Duration(seconds: 45),
      ]);
    });

    test('s\'arrête quand l\'arrêt est demandé', () async {
      var stop = false;
      final result = await retryUntilAvailable<String>(
        (attempt) async => null,
        sleep: (d) async => stop = true,
        shouldStop: () => stop,
      );
      expect(result, isNull);
    });
  });
}
