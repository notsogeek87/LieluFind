import 'package:dawarich/features/tracking/application/services/adaptive_tracking_policy.dart';
import 'package:dawarich/features/tracking/application/services/night_schedule.dart';
import 'package:dawarich/features/tracking/application/services/tracking_supervisor.dart';
import 'package:dawarich/features/tracking/domain/models/location_fix.dart';
import 'package:flutter_test/flutter_test.dart';

LocationFix _fix(DateTime t) => LocationFix(
      latitude: 0,
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
  const night = NightSchedule();

  group('NightSchedule.isNight', () {
    test('de 23 h (inclus) à 7 h (exclu)', () {
      expect(night.isNight(DateTime(2026, 1, 1, 22, 59)), isFalse);
      expect(night.isNight(DateTime(2026, 1, 1, 23)), isTrue);
      expect(night.isNight(DateTime(2026, 1, 2, 0, 0)), isTrue);
      expect(night.isNight(DateTime(2026, 1, 2, 6, 59)), isTrue);
      expect(night.isNight(DateTime(2026, 1, 2, 7)), isFalse);
      expect(night.isNight(DateTime(2026, 1, 2, 12)), isFalse);
    });
  });

  group('point « toujours là » la nuit', () {
    AdaptiveTrackingPolicy policy({bool withNight = true}) => AdaptiveTrackingPolicy(
          distance: (a, b) => (a.latitude - b.latitude).abs(),
          nightHeartbeat: withNight ? night.heartbeat : null,
          isNight: withNight ? night.isNight : null,
        );

    test('la nuit : pas de point à 16 min, un point à 30 min', () {
      final p = policy();
      final t0 = DateTime(2026, 1, 2, 2);
      p.recorded(_fix(t0), t0);

      final t16 = t0.add(const Duration(minutes: 16));
      expect(p.onFix(_fix(t16), t16).record, isFalse);

      final t30 = t0.add(const Duration(minutes: 30));
      expect(p.onFix(_fix(t30), t30).record, isTrue);
    });

    test('la nuit : le minuteur ne demande pas de position de secours avant 30 min', () {
      final p = policy();
      final t0 = DateTime(2026, 1, 2, 2);
      p.recorded(_fix(t0), t0);

      final t20 = t0.add(const Duration(minutes: 20));
      final d = p.onTick(_fix(t0), t20);
      expect(d.record || d.needFreshFix, isFalse);
    });

    test('le jour : toujours un point toutes les 15 min', () {
      final p = policy();
      final t0 = DateTime(2026, 1, 2, 12);
      p.recorded(_fix(t0), t0);

      final t15 = t0.add(const Duration(minutes: 15));
      expect(p.onFix(_fix(t15), t15).record, isTrue);
    });

    test('sans horaire de nuit : comportement inchangé', () {
      final p = policy(withNight: false);
      final t0 = DateTime(2026, 1, 2, 2);
      p.recorded(_fix(t0), t0);

      final t15 = t0.add(const Duration(minutes: 15));
      expect(p.onFix(_fix(t15), t15).record, isTrue);
    });
  });

  group('superviseur et cadence de nuit', () {
    late DateTime clock;
    late TrackingSupervisor sup;

    void startAt(DateTime start) {
      clock = start;
      sup = TrackingSupervisor(
        startStream: () async {},
        stopStream: () async {},
        blockedReason: () async => null,
        log: (_) {},
        now: () => clock,
        isNight: night.isNight,
        nightMaxPointGap: night.maxPointGap,
      );
      sup.markStarted();
    }

    void tickAndPointAt(DateTime t) {
      clock = t;
      sup.onPoint();
    }

    test('la nuit : 30 min sans point n\'est pas une panne', () {
      startAt(DateTime(2026, 1, 2, 1));
      tickAndPointAt(DateTime(2026, 1, 2, 1, 0, 1));
      clock = DateTime(2026, 1, 2, 1, 30);
      sup.onTick();
      expect(sup.evaluate(), isNull);
    });

    test('la nuit : plus de 37 min sans point est une panne', () {
      startAt(DateTime(2026, 1, 2, 1));
      tickAndPointAt(DateTime(2026, 1, 2, 1, 0, 1));
      clock = DateTime(2026, 1, 2, 1, 40);
      sup.onTick();
      expect(sup.evaluate(), HealthIssue.noPoint);
    });

    test('au matin : un point de 6 h 45 laisse jusqu\'à 7 h 22, sans fausse relance à 7 h', () {
      startAt(DateTime(2026, 1, 2, 6, 40));
      tickAndPointAt(DateTime(2026, 1, 2, 6, 45));
      clock = DateTime(2026, 1, 2, 7, 15);
      sup.onTick();
      expect(sup.evaluate(), isNull);
    });

    test('le jour : 25 min sans point reste une panne', () {
      startAt(DateTime(2026, 1, 2, 12));
      tickAndPointAt(DateTime(2026, 1, 2, 12, 0, 1));
      clock = DateTime(2026, 1, 2, 12, 25);
      sup.onTick();
      expect(sup.evaluate(), HealthIssue.noPoint);
    });
  });
}
