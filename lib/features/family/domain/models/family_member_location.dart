import 'package:latlong2/latlong.dart';

/// Last known position of a family member, as returned by
/// `GET /api/v1/families/locations`.
final class FamilyMemberLocation {
  final int userId;
  final String name;
  final String initial;
  final LatLng position;
  final DateTime updatedAt;
  final int? battery;

  const FamilyMemberLocation({
    required this.userId,
    required this.name,
    required this.initial,
    required this.position,
    required this.updatedAt,
    this.battery,
  });

  /// First name guessed from the display name or the email local part
  /// ("deborah.defranc@x.fr" -> "Deborah").
  String get shortName {
    final base = name.contains('@') ? name.split('@').first : name;
    final token = base
        .split(RegExp(r'[._\-\s\d]+'))
        .firstWhere((t) => t.isNotEmpty, orElse: () => base);
    if (token.isEmpty) return initial;
    return token[0].toUpperCase() + token.substring(1).toLowerCase();
  }

  /// Two letters ("De"), so members sharing a first initial stay distinct.
  String get badge {
    final n = shortName;
    return n.length >= 2 ? n.substring(0, 2) : n;
  }

  static FamilyMemberLocation? tryFromJson(Object? json) {
    if (json is! Map) return null;

    final lat = (json['latitude'] as num?)?.toDouble();
    final lon = (json['longitude'] as num?)?.toDouble();
    final userId = (json['user_id'] as num?)?.toInt();
    if (lat == null || lon == null || userId == null) return null;

    final name = (json['name'] ?? json['email'] ?? '').toString();
    final initial = (json['email_initial'] ?? (name.isEmpty ? '?' : name[0]))
        .toString()
        .toUpperCase();
    final ts = (json['timestamp'] as num?)?.toInt();

    return FamilyMemberLocation(
      userId: userId,
      name: name,
      initial: initial,
      position: LatLng(lat, lon),
      updatedAt: ts != null
          ? DateTime.fromMillisecondsSinceEpoch(ts * 1000)
          : DateTime.now(),
      battery: (json['battery'] as num?)?.toInt(),
    );
  }
}
