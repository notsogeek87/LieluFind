import 'package:dawarich/features/tracking/application/services/adaptive_tracking_policy.dart';
import 'package:dawarich/features/tracking/domain/models/location_fix.dart';
import 'package:flutter_test/flutter_test.dart';

/// Positions sur une ligne : `x` en mètres depuis l'origine.
LocationFix fixAt(double x, DateTime t, {double accuracy = 10}) => LocationFix(
      latitude: x,
      longitude: 0,
      timestampUtc: t,
      hAccuracyMeters: accuracy,
      altitudeMeters: 0,
      altitudeAccuracyMeters: 0,
      speedMps: 0,
      speedAccuracyMps: 0,
      headingDegrees: 0,
      headingAccuracyDegrees: 0,
    );

void main() {
  late DateTime t;
  late AdaptiveTrackingPolicy p;

  void at(Duration d) => t = t.add(d);

  setUp(() {
    t = DateTime.utc(2026, 1, 1, 12);
    p = AdaptiveTrackingPolicy(distance: (a, b) => (a.latitude - b.latitude).abs());
  });

  void start() {
    final f = fixAt(0, t);
    expect(p.onFix(f, t).record, isTrue, reason: 'premier point');
    p.recorded(f, t);
  }

  group('immobile', () {
    test('la gigue Wi-Fi (< 50 m) ne déclenche ni point ni position active', () {
      start();
      for (var i = 0; i < 20; i++) {
        at(const Duration(seconds: 10));
        final jitter = fixAt(i.isEven ? 30 : -25, t);
        expect(p.onFix(jitter, t).record, isFalse, reason: 'avant 5 min : rien');
        final tick = p.onTick(jitter, t);
        expect(tick.record || tick.needFreshFix, isFalse);
      }
      expect(p.mode, MotionMode.still);
    });

    test('la livraison du fournisseur toutes les 5 min est le point « toujours là »', () {
      start();
      at(const Duration(minutes: 4));
      expect(p.onFix(fixAt(3, t), t).record, isFalse, reason: 'trop tôt');
      at(const Duration(seconds: 40));
      expect(p.onFix(fixAt(3, t), t).record, isTrue, reason: 'livraison un peu en avance acceptée');
    });

    test('le minuteur ne demande pas de position active tant que le fournisseur peut encore livrer', () {
      start();
      at(const Duration(minutes: 5));
      final d = p.onTick(fixAt(0, t.subtract(const Duration(minutes: 5))), t);
      expect(d.record || d.needFreshFix, isFalse);
    });

    test('rien livré : une seule demande active de secours, pas une par tick', () {
      start();
      at(const Duration(minutes: 6, seconds: 30));
      final stale = fixAt(0, t.subtract(const Duration(minutes: 6)));
      expect(p.onTick(stale, t).needFreshFix, isTrue);
      at(const Duration(seconds: 20));
      expect(p.onTick(stale, t).needFreshFix, isFalse, reason: 'attendre 60 s avant de redemander');
      at(const Duration(seconds: 40));
      expect(p.onTick(stale, t).needFreshFix, isTrue);
    });

    test('la position active obtenue est enregistrée (point dû)', () {
      start();
      at(const Duration(minutes: 5));
      expect(p.onFreshFix(fixAt(2, t), t).record, isTrue);
      expect(p.mode, MotionMode.still);
    });
  });

  group('changement de mode', () {
    test('un déplacement de 50 m passe en mouvement et enregistre', () {
      start();
      at(const Duration(seconds: 30));
      final d = p.onFix(fixAt(70, t), t);
      expect(d.record, isTrue);
      expect(d.switchTo, MotionMode.moving);
    });

    test('en mouvement : au plus un point par intervalle', () {
      start();
      at(const Duration(seconds: 30));
      final f = fixAt(70, t);
      p.onFix(f, t);
      p.switched(MotionMode.moving, t);
      p.recorded(f, t);

      at(const Duration(seconds: 5));
      expect(p.onFix(fixAt(140, t), t).record, isFalse, reason: 'moins de 10 s');
      at(const Duration(seconds: 5));
      expect(p.onFix(fixAt(210, t), t).record, isTrue);
    });

    test('retour en immobile après 3 min sans déplacement', () {
      start();
      at(const Duration(seconds: 30));
      final f = fixAt(70, t);
      p.onFix(f, t);
      p.switched(MotionMode.moving, t);
      p.recorded(f, t);

      at(const Duration(minutes: 2, seconds: 50));
      expect(p.onTick(fixAt(75, t), t).switchTo, isNull);
      at(const Duration(seconds: 10));
      expect(p.onTick(fixAt(75, t), t).switchTo, MotionMode.still);
    });

    test('un téléphone immobile qui démarre est détecté par la position active', () {
      start();
      at(const Duration(minutes: 5));
      final d = p.onFreshFix(fixAt(300, t), t);
      expect(d.record, isTrue);
      expect(d.switchTo, MotionMode.moving);
    });
  });

  group('point toutes les 15 min (réglage utilisé par l\'app)', () {
    test('sans livraison du fournisseur, le minuteur demande le point pile à 15 min', () {
      p = AdaptiveTrackingPolicy(
        distance: (a, b) => (a.latitude - b.latitude).abs(),
        stillHeartbeat: const Duration(minutes: 15),
        stillFallbackGrace: Duration.zero,
      );
      start();
      at(const Duration(minutes: 14, seconds: 50));
      final early = p.onTick(fixAt(0, t.subtract(const Duration(minutes: 10))), t);
      expect(early.record || early.needFreshFix, isFalse);
      at(const Duration(seconds: 10));
      expect(p.onTick(fixAt(0, t.subtract(const Duration(minutes: 10))), t).needFreshFix, isTrue);
    });

    test('une position gratuite qui montre un départ passe en mouvement sans attendre 15 min', () {
      p = AdaptiveTrackingPolicy(
        distance: (a, b) => (a.latitude - b.latitude).abs(),
        stillHeartbeat: const Duration(minutes: 15),
        stillFallbackGrace: Duration.zero,
      );
      start();
      at(const Duration(minutes: 5));
      final d = p.onFix(fixAt(200, t), t);
      expect(d.record, isTrue);
      expect(d.switchTo, MotionMode.moving);
    });
  });

  group('aucune position obtenable (téléphone posé, veille profonde)', () {
    test('immobile : 3 points de repli avec la dernière position, puis arrêt', () {
      start();
      for (var i = 1; i <= 3; i++) {
        at(const Duration(minutes: 15));
        final d = p.onFreshFixFailed();
        expect(d.record, isTrue, reason: 'repli $i/3');
        p.recorded(p.lastRecordedFix!, t, withoutFix: true);
      }
      expect(p.heartbeatsWithoutFix, 3);
      expect(p.onFreshFixFailed().record, isFalse, reason: 'au-delà de 45 min : on ne ment plus');
    });

    test('une vraie position remet le compteur à zéro', () {
      start();
      at(const Duration(minutes: 15));
      p.recorded(p.lastRecordedFix!, t, withoutFix: true);
      expect(p.heartbeatsWithoutFix, 1);
      at(const Duration(minutes: 15));
      p.recorded(fixAt(3, t), t);
      expect(p.heartbeatsWithoutFix, 0);
    });

    test('en mouvement ou sans point précédent : pas de repli', () {
      expect(p.onFreshFixFailed().record, isFalse, reason: 'aucun point enregistré');
      start();
      p.switched(MotionMode.moving, t);
      expect(p.onFreshFixFailed().record, isFalse, reason: 'on a peut-être bougé');
    });

    test('le point de repli reporte la prochaine échéance de 15 min (plus de recherche à la minute)', () {
      p = AdaptiveTrackingPolicy(
        distance: (a, b) => (a.latitude - b.latitude).abs(),
        stillHeartbeat: const Duration(minutes: 15),
        stillFallbackGrace: Duration.zero,
      );
      start();
      at(const Duration(minutes: 15));
      final stale = fixAt(0, t.subtract(const Duration(minutes: 15)));
      expect(p.onTick(stale, t).needFreshFix, isTrue);
      p.recorded(p.lastRecordedFix!, t, withoutFix: true);
      at(const Duration(minutes: 1));
      final next = p.onTick(stale, t);
      expect(next.needFreshFix || next.record, isFalse);
    });
  });

  group('seuil de déplacement adaptatif (gigue de la position réseau)', () {
    test('un saut de 100 m avec 50 m d\'incertitude de chaque côté n\'est pas un départ', () {
      final f0 = fixAt(0, t, accuracy: 50);
      p.onFix(f0, t);
      p.recorded(f0, t);
      at(const Duration(minutes: 1));
      final d = p.onFix(fixAt(100, t, accuracy: 50), t);
      expect(d.switchTo, isNull);
      expect(d.record, isFalse);
    });

    test('un saut de 60 m avec une bonne précision est un départ', () {
      final f0 = fixAt(0, t, accuracy: 5);
      p.onFix(f0, t);
      p.recorded(f0, t);
      at(const Duration(minutes: 1));
      expect(p.onFix(fixAt(60, t, accuracy: 5), t).switchTo, MotionMode.moving);
    });

    test('le seuil est plafonné à 150 m même avec une très mauvaise précision', () {
      final f0 = fixAt(0, t, accuracy: 1000);
      p.onFix(f0, t);
      p.recorded(f0, t);
      at(const Duration(minutes: 1));
      expect(p.onFix(fixAt(120, t, accuracy: 1000), t).switchTo, isNull);
      expect(p.onFix(fixAt(200, t, accuracy: 1000), t).switchTo, MotionMode.moving);
    });
  });
}
