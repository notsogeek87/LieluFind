import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:dawarich/core/di/providers/core_providers.dart';
import 'package:dawarich/core/network/secondary_account.dart';
import 'package:dawarich/features/family/domain/models/family_locations.dart';
import 'package:dawarich/core/di/providers/session_providers.dart';
import 'package:dawarich/features/family/domain/models/family_member_location.dart';
import 'package:dawarich/features/family/domain/self_member.dart';
import 'package:dawarich/features/family/presentation/family_photos.dart';
import 'package:dawarich/features/family/presentation/family_visibility.dart';
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
/// as it opens, with no tap needed. A failed refresh keeps the last members
/// and flags the outage (see [FamilyLocations]) instead of emptying the map.
final familyLocationsProvider =
    StreamProvider.autoDispose<FamilyLocations>((ref) async* {
  final dio = await ref.watch(dioClientProvider.future);

  /// Null when the server could not be reached (see [isFamilyOutage]).
  Future<List<FamilyMemberLocation>?> fetch() async {
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
      Err(value: final e) => isFamilyOutage(e.statusCode) ? null : const [],
    };
  }

  final cfg = await ref.watch(apiConfigManagerProvider.future);
  final secondary = SecondaryAccount();
  int? secondarySelfId;
  String? secondarySelfKey;

  /// Second account's family (optional). Any failure just yields nothing, so
  /// the primary family is never affected.
  Future<List<FamilyMemberLocation>> fetchSecondary() async {
    final key = await secondary.readKey();
    final host = cfg.apiConfig?.host;
    if (key == null || host == null || host.isEmpty) return const [];

    // The second account is "me" too: hide it, the phone already shows me.
    if (secondarySelfKey != key || secondarySelfId == null) {
      secondarySelfKey = key;
      secondarySelfId = await secondary.fetchUserId(host, key);
    }
    final raw = await secondary.fetchFamilyLocations(host, key);
    return raw
        .map(FamilyMemberLocation.tryFromJson)
        .whereType<FamilyMemberLocation>()
        .where((m) => m.userId != secondarySelfId)
        .toList();
  }

  Future<List<FamilyMemberLocation>?> fetchAll() async {
    final List<FamilyMemberLocation>? primary;
    try {
      primary = await fetch();
    } catch (_) {
      return null; // an exception must never end the polling loop
    }
    if (primary == null) return null;
    List<FamilyMemberLocation> extra;
    try {
      extra = await fetchSecondary();
    } catch (_) {
      extra = const [];
    }
    if (extra.isEmpty) return primary;
    final seen = primary.map((m) => m.userId).toSet();
    return [...primary, ...extra.where((m) => seen.add(m.userId))];
  }

  FamilyLocations? latest;
  Future<FamilyLocations> refresh() async =>
      latest = FamilyLocations.next(latest, await fetchAll(), DateTime.now());

  // Ne jamais interroger le serveur quand la carte n'est pas à l'écran : le
  // service de suivi garde le processus vivant (et le CPU éveillé), donc une
  // simple boucle tournerait jour et nuit dès que l'app reste en arrière-plan.
  var resumed = Completer<void>();
  final lifecycle = AppLifecycleListener(onResume: () {
    if (!resumed.isCompleted) resumed.complete();
  });
  ref.onDispose(lifecycle.dispose);
  bool inForeground() =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  yield await refresh();
  while (true) {
    if (inForeground()) {
      await Future<void>.delayed(_refreshInterval);
    } else {
      await resumed.future; // en pause jusqu'au retour à l'écran
      resumed = Completer<void>();
    }
    if (!inForeground()) continue;
    yield await refresh();
  }
});

/// The phone's own position, so "me" is always on the map with a name and a
/// photo whatever the server returns (it never lists the signed-in user).
final selfPositionProvider = StreamProvider.autoDispose<LatLng>((ref) async* {
  try {
    final last = await Geolocator.getLastKnownPosition();
    if (last != null) yield LatLng(last.latitude, last.longitude);
    yield* Geolocator.getPositionStream(
      locationSettings: const LocationSettings(distanceFilter: 25),
    ).map((p) => LatLng(p.latitude, p.longitude));
  } catch (_) {
    // No permission or no fix: the blue dot and the family still work.
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

/// Two avatars closer than this (in screen pixels) are fanned out.
const double _clusterPx = 70;

/// Distance from the avatar's centre to the marker anchor (label + gap +
/// half an avatar), used to draw the connector to the avatar's middle.
const double _anchorToAvatarCentre = _labelBlock + _avatarSize / 2;

const double _markerWidth = 130;

/// Gap + two-line label below the avatar.
const double _labelBlock = 3 + 44;

/// A group of members whose avatars would overlap at the current zoom.
final class _Cluster {
  final List<FamilyMemberLocation> members;
  Offset sum;

  _Cluster(FamilyMemberLocation m, Offset o)
      : members = [m],
        sum = o;

  Offset get centre => sum / members.length.toDouble();
}

/// True once the map has been framed on the family, so the timeline does not
/// pull the camera back to the first point of the day.
final familyFitDone = ValueNotifier<bool>(false);

final class FamilyLayer extends ConsumerStatefulWidget {
  const FamilyLayer({super.key});

  @override
  ConsumerState<FamilyLayer> createState() => _FamilyLayerState();
}

final class _FamilyLayerState extends ConsumerState<FamilyLayer> {
  bool _fitted = false;

  @override
  void dispose() {
    familyFitDone.value = false;
    super.dispose();
  }

  /// Zooms the map once, when the map opens, so everybody (and the phone
  /// itself, when a fix is known) is visible.
  Future<void> _fitEveryone(
      MapController? controller, List<FamilyMemberLocation> members) async {
    if (controller == null) return;

    final points = [for (final m in members) m.position];
    try {
      final me = await Geolocator.getLastKnownPosition();
      if (me != null) points.add(LatLng(me.latitude, me.longitude));
    } catch (_) {}
    // Let the timeline's own opening animation finish first.
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (!mounted || points.isEmpty) return;

    // maxZoom keeps a single point (or everyone at the same spot) readable.
    controller.fitCamera(CameraFit.coordinates(
      coordinates: points,
      padding: const EdgeInsets.fromLTRB(60, 140, 60, 260),
      maxZoom: 17,
    ));
    familyFitDone.value = true;
  }

  @override
  Widget build(BuildContext context) {
    final hidden = ref.watch(hiddenFamilyIdsProvider);
    final user = ref.watch(authenticatedUserProvider);
    final myPosition = ref.watch(selfPositionProvider).value;
    final me = user == null || myPosition == null
        ? null
        : selfMember(
            serverUserId: user.remoteId,
            localUserId: user.id,
            email: user.email,
            position: myPosition,
            updatedAt: DateTime.now(),
          );
    final members = withSelf(
            ref.watch(familyLocationsProvider).value?.members ??
                const <FamilyMemberLocation>[],
            me)
        .where((m) => !hidden.contains(m.userId))
        .toList();
    if (members.isEmpty) return const SizedBox.shrink();
    final photos = ref.watch(familyPhotosProvider);
    final mapController = MapController.maybeOf(context);
    final camera = MapCamera.of(context);

    // Wait for the family answer: framing on the phone alone would skip it.
    if (!_fitted && ref.watch(familyLocationsProvider).hasValue) {
      _fitted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fitEveryone(mapController, members);
      });
    }

    // Group members that overlap on screen. Working in pixels means groups
    // split by themselves as the user zooms in.
    final clusters = <_Cluster>[];
    for (final m in members) {
      final o = camera.latLngToScreenOffset(m.position);
      final hit = clusters
          .where((c) => (c.centre - o).distance < _clusterPx)
          .firstOrNull;
      if (hit == null) {
        clusters.add(_Cluster(m, o));
      } else {
        hit.members.add(m);
        hit.sum += o;
      }
    }

    final markers = <Marker>[];
    final lines = <Polyline>[];
    final dots = <CircleMarker>[];

    Marker markerAt(FamilyMemberLocation m, LatLng at) => Marker(
          point: at,
          width: _markerWidth,
          height: _avatarSize + _labelBlock,
          alignment: Alignment.topCenter,
          child: GestureDetector(
            onTap: () => _showMemberSheet(context, m, mapController),
            // Colour comes from the user id so a person keeps the same
            // colour whoever else is online.
            child: _MemberMarker(
              member: m,
              photo: photos[m.userId],
              color: _palette[m.userId.abs() % _palette.length],
            ),
          ),
        );

    for (final c in clusters) {
      if (c.members.length == 1) {
        markers.add(markerAt(c.members.first, c.members.first.position));
        continue;
      }

      // Fan the avatars out on a circle around the real spot, with a thin
      // line back to it so the shared location stays obvious.
      final group = [...c.members]..sort((a, b) => a.userId - b.userId);
      final n = group.length;
      final centre = c.centre;
      final centreLatLng = camera.screenOffsetToLatLng(centre);
      final radius = math.max(66.0, 64 / math.sin(math.pi / n));

      dots.add(CircleMarker(
        point: centreLatLng,
        radius: 6,
        color: Colors.black87,
        borderColor: Colors.white,
        borderStrokeWidth: 2,
      ));

      for (var i = 0; i < n; i++) {
        final angle = math.pi + 2 * math.pi * i / n; // 2 people: left/right
        final anchor = centre + Offset.fromDirection(angle, radius);
        final m = group[i];
        lines.add(Polyline(
          points: [
            centreLatLng,
            camera.screenOffsetToLatLng(
                anchor.translate(0, -_anchorToAvatarCentre)),
          ],
          strokeWidth: 3,
          color: _palette[m.userId.abs() % _palette.length],
        ));
        markers.add(markerAt(m, camera.screenOffsetToLatLng(anchor)));
      }
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        if (lines.isNotEmpty) PolylineLayer(polylines: lines),
        if (dots.isNotEmpty) CircleLayer(circles: dots),
        MarkerLayer(markers: markers),
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
          width: _markerWidth - 8,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(10),
          ),
          // Name and age on two lines: on one line the age was always cut.
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${_isLowBattery(member) ? '🪫 ' : ''}${member.shortName}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Colors.black87),
              ),
              Text(
                _ago(member.updatedAt),
                maxLines: 1,
                style: TextStyle(
                    fontSize: 12,
                    color: _isStale(member)
                        ? Colors.red.shade700
                        : Colors.black54),
              ),
            ],
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
    isScrollControlled: true,
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
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Avatar(
                member: member,
                photo: photo,
                color: _palette[member.userId.abs() % _palette.length],
                size: 96),
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
