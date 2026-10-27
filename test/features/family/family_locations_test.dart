import 'package:dawarich/features/family/domain/models/family_locations.dart';
import 'package:dawarich/features/family/domain/models/family_member_location.dart';
import 'package:dawarich/features/family/presentation/family_offline_banner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

FamilyMemberLocation _member(int id) => FamilyMemberLocation(
      userId: id,
      name: 'member$id@example.org',
      initial: 'M',
      position: const LatLng(48.85, 2.35),
      updatedAt: DateTime.utc(2026, 1, 1),
    );

void main() {
  final t0 = DateTime(2026, 1, 1, 14, 5);
  final t1 = t0.add(const Duration(seconds: 30));
  final t2 = t0.add(const Duration(minutes: 1));

  group('FamilyLocations.next', () {
    test('a successful refresh shows the members and is reachable', () {
      final s = FamilyLocations.next(null, [_member(1)], t0);
      expect(s.members.map((m) => m.userId), [1]);
      expect(s.lastSuccessAt, t0);
      expect(s.isUnreachable, isFalse);
    });

    test('a failed refresh keeps the last members and flags the outage', () {
      final ok = FamilyLocations.next(null, [_member(1), _member(2)], t0);
      final failed = FamilyLocations.next(ok, null, t1);
      expect(failed.members.map((m) => m.userId), [1, 2]);
      expect(failed.lastSuccessAt, t0);
      expect(failed.unreachableSince, t1);
    });

    test('the outage start is kept across repeated failures', () {
      final ok = FamilyLocations.next(null, [_member(1)], t0);
      final f1 = FamilyLocations.next(ok, null, t1);
      final f2 = FamilyLocations.next(f1, null, t2);
      expect(f2.unreachableSince, t1);
      expect(f2.members, hasLength(1));
    });

    test('recovering replaces the members and clears the outage', () {
      final failed = FamilyLocations.next(
          FamilyLocations.next(null, [_member(1)], t0), null, t1);
      final back = FamilyLocations.next(failed, [_member(3)], t2);
      expect(back.members.map((m) => m.userId), [3]);
      expect(back.isUnreachable, isFalse);
      expect(back.lastSuccessAt, t2);
    });

    test('an empty answer from the server is not an outage', () {
      final s = FamilyLocations.next(
          FamilyLocations.next(null, [_member(1)], t0), const [], t1);
      expect(s.members, isEmpty);
      expect(s.isUnreachable, isFalse);
    });

    test('a first refresh that fails is flagged with no members', () {
      final s = FamilyLocations.next(null, null, t0);
      expect(s.members, isEmpty);
      expect(s.lastSuccessAt, isNull);
      expect(s.unreachableSince, t0);
    });
  });

  group('isFamilyOutage', () {
    test('network failures, timeouts and server errors are outages', () {
      for (final code in [null, 408, 429, 500, 502, 503]) {
        expect(isFamilyOutage(code), isTrue, reason: '$code');
      }
    });

    test('other client errors are an answer, not an outage', () {
      for (final code in [400, 401, 403, 404, 422]) {
        expect(isFamilyOutage(code), isFalse, reason: '$code');
      }
    });
  });

  group('familyOfflineLabel', () {
    test('no banner while the server is reachable', () {
      expect(familyOfflineLabel(FamilyLocations.next(null, const [], t0)),
          isNull);
    });

    test('tells how old the shown positions are', () {
      final failed = FamilyLocations.next(
          FamilyLocations.next(null, [_member(1)], t0), null, t1);
      expect(familyOfflineLabel(failed), contains('14:05'));
    });

    test('says nothing was loaded when no refresh ever succeeded', () {
      expect(familyOfflineLabel(FamilyLocations.next(null, null, t0)),
          contains('not loaded'));
    });
  });
}
