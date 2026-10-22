import 'package:dawarich/features/tracking/data/repositories/location_provider.dart';
import 'package:dawarich/features/tracking/domain/enum/location_precision.dart';
import 'package:dawarich/features/tracking/domain/models/location_request.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LocationProvider.shouldKeepAwake', () {
    test('flux passif (immobile) : pas de wakelock', () {
      const request = LocationRequest(precision: LocationPrecision.balanced, passive: true);

      expect(LocationProvider.shouldKeepAwake(request), isFalse);
    });

    test('flux actif (en mouvement) : wakelock tenu', () {
      const request = LocationRequest(precision: LocationPrecision.balanced);

      expect(LocationProvider.shouldKeepAwake(request), isTrue);
    });
  });
}
