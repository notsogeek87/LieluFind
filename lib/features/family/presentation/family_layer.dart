import 'dart:async';

import 'package:dawarich/core/di/providers/core_providers.dart';
import 'package:dawarich/features/family/domain/models/family_member_location.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:option_result/option_result.dart';

const _refreshInterval = Duration(seconds: 30);

/// Polls the family locations endpoint so every member is on the map as soon
/// as it opens, with no tap needed.
final familyLocationsProvider =
    StreamProvider.autoDispose<List<FamilyMemberLocation>>((ref) async* {
  final dio = await ref.watch(dioClientProvider.future);

  Future<List<FamilyMemberLocation>> fetch() async {
    final result = await dio.getJson<List<FamilyMemberLocation>>(
      '/api/v1/families/locations',
      map: (json) {
        final raw = json is Map ? json['locations'] : null;
        if (raw is! List) return const [];
        return raw
            .map(FamilyMemberLocation.tryFromJson)
            .whereType<FamilyMemberLocation>()
            .toList();
      },
    );
    return switch (result) {
      Ok(value: final v) => v,
      Err() => const [],
    };
  }

  yield await fetch();
  await for (final _ in Stream<void>.periodic(_refreshInterval)) {
    yield await fetch();
  }
});

/// flutter_map layer showing the last known position of each family member.
final class FamilyLayer extends ConsumerWidget {
  const FamilyLayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final members = ref.watch(familyLocationsProvider).value ?? const [];
    if (members.isEmpty) return const SizedBox.shrink();

    return MarkerLayer(
      markers: [
        for (final m in members)
          Marker(
            point: m.position,
            width: 96,
            height: 64,
            alignment: Alignment.topCenter,
            child: _MemberMarker(member: m),
          ),
      ],
    );
  }
}

final class _MemberMarker extends StatelessWidget {
  final FamilyMemberLocation member;

  const _MemberMarker({required this.member});

  @override
  Widget build(BuildContext context) {
    final color = Colors.primaries[member.userId % Colors.primaries.length];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black38)],
          ),
          child: Text(
            member.initial,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
          ),
        ),
        const SizedBox(height: 2),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '${member.name} · ${_ago(member.updatedAt)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10, color: Colors.black87),
          ),
        ),
      ],
    );
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'now';
    if (d.inMinutes < 60) return '${d.inMinutes} min';
    if (d.inHours < 24) return '${d.inHours} h';
    return '${d.inDays} d';
  }
}
