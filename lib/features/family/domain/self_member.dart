import 'package:dawarich/features/family/domain/models/family_member_location.dart';
import 'package:latlong2/latlong.dart';

/// The user as a map member, built from the phone itself.
///
/// The server never lists the signed-in user in `/families/locations`, so the
/// only way to see "me" with a name and a photo used to be the optional second
/// account, which made me vanish whenever that account failed. The phone's own
/// position is always known, so it is the source of truth.
///
/// [serverUserId] is the user's id on the Dawarich server when known. Without
/// it a negative id is used, which can never collide with a real member.
FamilyMemberLocation selfMember({
  required int? serverUserId,
  required int localUserId,
  required String email,
  required LatLng position,
  required DateTime updatedAt,
}) =>
    FamilyMemberLocation(
      userId: serverUserId ?? -localUserId - 1,
      name: email,
      initial: email.isEmpty ? '?' : email[0].toUpperCase(),
      position: position,
      updatedAt: updatedAt,
    );

/// [members] with [me] added. A server entry for the same user (reachable
/// through the second account) is replaced, since the phone is fresher.
List<FamilyMemberLocation> withSelf(
  List<FamilyMemberLocation> members,
  FamilyMemberLocation? me,
) {
  if (me == null) return members;
  return [...members.where((m) => m.userId != me.userId), me];
}
