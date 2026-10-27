import 'package:dawarich/features/family/domain/models/family_member_location.dart';

/// Whether a failed request means the server could not be reached (network,
/// timeout, server error), rather than a real answer such as "this account has
/// no family" (other 4xx), which simply shows nobody.
bool isFamilyOutage(int? statusCode) =>
    statusCode == null ||
    statusCode >= 500 ||
    statusCode == 408 ||
    statusCode == 429;

/// What the map shows of the family, including whether it is up to date.
///
/// A failed refresh never empties the map: the last members are kept and
/// [unreachableSince] says since when the server could not be reached, so
/// "nobody is there" and "no network" never look the same.
final class FamilyLocations {
  final List<FamilyMemberLocation> members;

  /// Time of the last successful refresh, null if none succeeded yet.
  final DateTime? lastSuccessAt;

  /// First failed refresh of the current outage, null when reachable.
  final DateTime? unreachableSince;

  const FamilyLocations({
    this.members = const [],
    this.lastSuccessAt,
    this.unreachableSince,
  });

  bool get isUnreachable => unreachableSince != null;

  /// State after a refresh: [fetched] is the server's answer, or null when
  /// the request failed.
  static FamilyLocations next(
    FamilyLocations? previous,
    List<FamilyMemberLocation>? fetched,
    DateTime now,
  ) {
    if (fetched != null) {
      return FamilyLocations(members: fetched, lastSuccessAt: now);
    }
    return FamilyLocations(
      members: previous?.members ?? const [],
      lastSuccessAt: previous?.lastSuccessAt,
      unreachableSince: previous?.unreachableSince ?? now,
    );
  }
}
