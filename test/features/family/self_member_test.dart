import 'package:dawarich/features/family/domain/models/family_member_location.dart';
import 'package:dawarich/features/family/domain/self_member.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

void main() {
  final now = DateTime(2026, 10, 29, 10, 25);
  const here = LatLng(43.6, 3.9);

  FamilyMemberLocation member(int id, String name) => FamilyMemberLocation(
        userId: id,
        name: name,
        initial: name[0].toUpperCase(),
        position: const LatLng(43.8, 4.3),
        updatedAt: now,
      );

  FamilyMemberLocation me({int? serverId}) => selfMember(
        serverUserId: serverId,
        localUserId: 1,
        email: 'david.test@x.fr',
        position: here,
        updatedAt: now,
      );

  test('uses the server id when known and a name from the email', () {
    final m = me(serverId: 7);
    expect(m.userId, 7);
    expect(m.shortName, 'David');
    expect(m.position, here);
  });

  test('falls back to a negative id that cannot match a server member', () {
    expect(me().userId, isNegative);
  });

  test('adds me next to the family', () {
    final all = withSelf([member(2, 'Deborah')], me(serverId: 7));
    expect(all.map((m) => m.userId), [2, 7]);
  });

  test('replaces my stale server entry with the phone position', () {
    final all = withSelf(
        [member(7, 'David'), member(2, 'Deborah')], me(serverId: 7));
    expect(all.map((m) => m.userId), [2, 7]);
    expect(all.last.position, here);
  });

  test('without a fix the family is unchanged', () {
    final family = [member(2, 'Deborah')];
    expect(withSelf(family, null), family);
  });
}
