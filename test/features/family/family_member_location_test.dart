import 'package:dawarich/features/family/domain/models/family_member_location.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses a member from /api/v1/families/locations', () {
    final m = FamilyMemberLocation.tryFromJson({
      'user_id': 7,
      'email': 'wife@example.com',
      'name': 'Wife',
      'email_initial': 'W',
      'latitude': 46.2,
      'longitude': 6.1,
      'timestamp': 1760000000,
      'battery': 80,
      'battery_status': 'unplugged',
    });

    expect(m, isNotNull);
    expect(m!.userId, 7);
    expect(m.name, 'Wife');
    expect(m.initial, 'W');
    expect(m.position.latitude, 46.2);
    expect(m.battery, 80);
  });

  test('ignores entries without coordinates', () {
    expect(
      FamilyMemberLocation.tryFromJson({'user_id': 1, 'name': 'x'}),
      isNull,
    );
    expect(FamilyMemberLocation.tryFromJson('nope'), isNull);
  });
}
