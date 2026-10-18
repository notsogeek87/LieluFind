import 'package:dawarich/features/tracking/application/services/adaptive_tracking_policy.dart';
import 'package:dawarich/features/tracking/domain/models/location_fix.dart';
import 'package:flutter_test/flutter_test.dart';

/// Positions sur une ligne : `x` en mètres depuis l'origine.
LocationFix fixAt(double x, DateTime t) => LocationFix(
      latitude: x,
      longitude: 0,
      timestampUtc: t,
      hAccuracyMeters: 10,
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
    test('la gigue Wi-Fi (< 25 m) ne déclenche ni point ni position active', () {
      start();
      for (var i = 0; i < 20; i++) {
        at(const Duration(seconds: 10));
        final jitter = fixAt(i.isEven ? 15 : -12, t);
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
    test('un déplacement de 25 m passe en mouvement et enregistre', () {
      start();
      at(const Duration(seconds: 30));
      final d = p.onFix(fixAt(40, t), t);
      expect(d.record, isTrue);
      expect(d.switchTo, MotionMode.moving);
    });

    test('en mouvement : au plus un point par intervalle', () {
      start();
      at(const Duration(seconds: 30));
      final f = fixAt(40, t);
      p.onFix(f, t);
      p.switched(MotionMode.moving, t);
      p.recorded(f, t);

      at(const Duration(seconds: 5));
      expect(p.onFix(fixAt(80, t), t).record, isFalse, reason: 'moins de 10 s');
      at(const Duration(seconds: 5));
      expect(p.onFix(fixAt(120, t), t).record, isTrue);
    });

    test('retour en immobile après 3 min sans déplacement', () {
      start();
      at(const Duration(seconds: 30));
      final f = fixAt(40, t);
      p.onFix(f, t);
      p.switched(MotionMode.moving, t);
      p.recorded(f, t);

      at(const Duration(minutes: 2, seconds: 50));
      expect(p.onTick(fixAt(45, t), t).switchTo, isNull);
      at(const Duration(seconds: 10));
      expect(p.onTick(fixAt(45, t), t).switchTo, MotionMode.still);
    });

    test('un téléphone immobile qui démarre est détecté par la position active', () {
      start();
      at(const Duration(minutes: 5));
      final d = p.onFreshFix(fixAt(300, t), t);
      expect(d.record, isTrue);
      expect(d.switchTo, MotionMode.moving);
    });
  });
}
