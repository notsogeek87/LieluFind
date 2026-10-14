import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dawarich/core/di/providers/core_providers.dart';
import 'package:dawarich/features/family/domain/models/family_member_location.dart';
import 'package:dawarich/features/family/presentation/family_photos.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:option_result/option_result.dart';
import 'package:url_launcher/url_launcher.dart';

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

/// Reverse-geocodes a member's position (OpenStreetMap Nominatim).
final memberAddressProvider =
    FutureProvider.autoDispose.family<String?, LatLng>((ref, pos) async {
  try {
    final res = await Dio().get<Map<String, dynamic>>(
      'https://nominatim.openstreetmap.org/reverse',
      queryParameters: {
        'format': 'jsonv2',
        'lat': pos.latitude,
        'lon': pos.longitude,
        'zoom': 18,
      },
      options: Options(
        headers: {'User-Agent': 'LieluFind'},
        receiveTimeout: const Duration(seconds: 10),
      ),
    );
    return res.data?['display_name'] as String?;
  } catch (_) {
    return null;
  }
});

Future<void> _openNavigation(LatLng p, String name) async {
  final geo = Uri.parse(
      'geo:${p.latitude},${p.longitude}?q=${p.latitude},${p.longitude}(${Uri.encodeComponent(name)})');
  if (await launchUrl(geo, mode: LaunchMode.externalApplication)) return;
  await launchUrl(
    Uri.parse(
        'https://www.google.com/maps/dir/?api=1&destination=${p.latitude},${p.longitude}'),
    mode: LaunchMode.externalApplication,
  );
}

/// Distance from the phone's last known fix to [p], or null without a fix.
final memberDistanceProvider =
    FutureProvider.autoDispose.family<double?, LatLng>((ref, p) async {
  try {
    final me = await Geolocator.getLastKnownPosition();
    if (me == null) return null;
    return Geolocator.distanceBetween(
        me.latitude, me.longitude, p.latitude, p.longitude);
  } catch (_) {
    return null;
  }
});

String _distance(double m) =>
    m < 1000 ? '${m.round()} m' : '${(m / 1000).toStringAsFixed(1)} km';

bool _isStale(FamilyMemberLocation m) =>
    DateTime.now().difference(m.updatedAt).inMinutes >= 60;

bool _isLowBattery(FamilyMemberLocation m) => (m.battery ?? 100) < 15;

/// flutter_map layer showing the last known position of each family member.
const _palette = <Color>[
  Color(0xFFE65100), // orange
  Color(0xFF00897B), // teal
  Color(0xFF6A1B9A), // purple
  Color(0xFFC62828), // red
  Color(0xFF2E7D32), // green
];

final class FamilyLayer extends ConsumerWidget {
  const FamilyLayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final members = ref.watch(familyLocationsProvider).value ?? const [];
    if (members.isEmpty) return const SizedBox.shrink();
    final photos = ref.watch(familyPhotosProvider);
    final mapController = MapController.maybeOf(context);

    // Colour comes from the user id so a person keeps the same colour
    // whoever else is online.
    return MarkerLayer(
      markers: [
        for (final m in members)
          Marker(
            point: m.position,
            width: 120,
            height: _avatarSize + 34,
            alignment: Alignment.topCenter,
            child: GestureDetector(
              onTap: () => _showMemberSheet(context, m, mapController),
              child: _MemberMarker(
                member: m,
                photo: photos[m.userId],
                color: _palette[m.userId.abs() % _palette.length],
              ),
            ),
          ),
      ],
    );
  }
}

/// Large on purpose: the whole point is to see at a glance who is who.
const double _avatarSize = 76;

final class _MemberMarker extends StatelessWidget {
  final FamilyMemberLocation member;
  final File? photo;
  final Color color;

  const _MemberMarker({required this.member, this.photo, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Opacity(
          opacity: _isStale(member) ? 0.5 : 1,
          child: _Avatar(
              member: member, photo: photo, color: color, size: _avatarSize),
        ),
        const SizedBox(height: 3),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '${_isLowBattery(member) ? '🪫 ' : ''}'
            '${member.shortName} · ${_ago(member.updatedAt)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.black87),
          ),
        ),
      ],
    );
  }
}

final class _Avatar extends StatelessWidget {
  final FamilyMemberLocation member;
  final File? photo;
  final Color color;
  final double size;

  const _Avatar({
    required this.member,
    required this.photo,
    required this.color,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(color: color, width: 4),
        boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black45)],
        image: photo == null
            ? null
            : DecorationImage(image: FileImage(photo!), fit: BoxFit.cover),
      ),
      child: photo == null
          ? Text(
              member.badge,
              style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: size * 0.38),
            )
          : null,
    );
  }
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'maintenant';
  if (d.inMinutes < 60) return 'il y a ${d.inMinutes} min';
  if (d.inHours < 24) return 'il y a ${d.inHours} h';
  return 'il y a ${d.inDays} j';
}

void _showMemberSheet(BuildContext context, FamilyMemberLocation member,
    MapController? mapController) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => _MemberSheet(member: member, mapController: mapController),
  );
}

final class _MemberSheet extends ConsumerWidget {
  final FamilyMemberLocation member;
  final MapController? mapController;

  const _MemberSheet({required this.member, this.mapController});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final photo = ref.watch(familyPhotosProvider)[member.userId];
    final notifier = ref.read(familyPhotosProvider.notifier);
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Avatar(
                member: member,
                photo: photo,
                color: _palette[member.userId.abs() % _palette.length],
                size: 140),
            const SizedBox(height: 12),
            Text(member.shortName, style: theme.textTheme.headlineSmall),
            const SizedBox(height: 4),
            Text(
              'Position mise à jour ${_ago(member.updatedAt)}'
              '${member.battery != null ? ' · batterie ${member.battery} %' : ''}',
              style: theme.textTheme.bodySmall,
            ),
            if (_isStale(member) || _isLowBattery(member))
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  [
                    if (_isStale(member)) 'Position ancienne',
                    if (_isLowBattery(member)) 'Batterie faible',
                  ].join(' · '),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ),
            ref.watch(memberDistanceProvider(member.position)).maybeWhen(
                  data: (d) => d == null
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text('À ${_distance(d)} de toi',
                              style: theme.textTheme.bodyMedium),
                        ),
                  orElse: () => const SizedBox.shrink(),
                ),
            const SizedBox(height: 12),
            ref.watch(memberAddressProvider(member.position)).when(
                  data: (a) => Text(
                    a ?? 'Adresse indisponible',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                  loading: () => const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  error: (_, __) => const SizedBox.shrink(),
                ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.navigation_outlined),
                label: const Text('Ouvrir dans une app de navigation'),
                onPressed: () =>
                    _openNavigation(member.position, member.shortName),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (mapController != null)
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.my_location),
                      label: const Text('Recentrer'),
                      onPressed: () {
                        mapController!.move(member.position, 16);
                        Navigator.of(context).pop();
                      },
                    ),
                  ),
                if (mapController != null) const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.share_outlined),
                    label: const Text('Copier le lien'),
                    onPressed: () async {
                      final p = member.position;
                      await Clipboard.setData(ClipboardData(
                          text:
                              'https://maps.google.com/?q=${p.latitude},${p.longitude}'));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Lien copié')));
                      }
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.photo_library_outlined),
                label: Text(photo == null
                    ? 'Choisir une photo'
                    : 'Changer la photo'),
                onPressed: () async {
                  final ok = await notifier.pick(member.userId);
                  if (ok && context.mounted) Navigator.of(context).pop();
                },
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.photo_camera_outlined),
                label: const Text('Prendre une photo'),
                onPressed: () async {
                  final ok =
                      await notifier.pick(member.userId, source: ImageSource.camera);
                  if (ok && context.mounted) Navigator.of(context).pop();
                },
              ),
            ),
            if (photo != null)
              TextButton(
                onPressed: () async {
                  await notifier.remove(member.userId);
                  if (context.mounted) Navigator.of(context).pop();
                },
                child: const Text('Retirer la photo'),
              ),
            const SizedBox(height: 4),
            Text(
              'Cette photo reste sur ton téléphone.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
