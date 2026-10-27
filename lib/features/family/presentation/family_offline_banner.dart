import 'package:dawarich/features/family/domain/models/family_locations.dart';
import 'package:dawarich/features/family/presentation/family_layer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Text of the banner, or null when the server is reachable.
String? familyOfflineLabel(FamilyLocations family) {
  if (!family.isUnreachable) return null;
  final last = family.lastSuccessAt;
  if (last == null) return 'Server unreachable: family positions not loaded yet';
  final hh = last.hour.toString().padLeft(2, '0');
  final mm = last.minute.toString().padLeft(2, '0');
  return 'Server unreachable: family positions from $hh:$mm';
}

/// Shown over the map while family positions cannot be refreshed, so an
/// outage never looks like "nobody is there". The polling keeps retrying.
final class FamilyOfflineBanner extends ConsumerWidget {
  const FamilyOfflineBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final family = ref.watch(familyLocationsProvider).value;
    final label = family == null ? null : familyOfflineLabel(family);
    if (label == null) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Material(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
        elevation: 2,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.cloud_off, size: 20, color: scheme.onErrorContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(color: scheme.onErrorContainer, fontSize: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
