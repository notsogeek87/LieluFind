import 'package:dawarich/features/app_update/app_update.dart';
import 'package:dawarich/features/app_update/app_update_installer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Shows a card when a newer APK is available. Tapping "Update" downloads
/// it in the app; Android then installs it over the current app
/// (same signing key). Renders nothing when up to date.
final class AppUpdateBanner extends ConsumerStatefulWidget {
  const AppUpdateBanner({super.key});

  @override
  ConsumerState<AppUpdateBanner> createState() => _AppUpdateBannerState();
}

class _AppUpdateBannerState extends ConsumerState<AppUpdateBanner> {
  bool _dismissed = false;

  /// The launch prompt is shown once per app run, whichever screen hosts
  /// the banner.
  static bool _prompted = false;

  void _promptOnce(AppUpdate update) {
    if (_prompted) return;
    _prompted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final accept = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Update available'),
          content: Text('Version ${update.versionName} is ready to install.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Later'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Update'),
            ),
          ],
        ),
      );
      if (accept == true && mounted) {
        await downloadAndInstallUpdate(context, update);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(appUpdateProvider, (_, next) {
      final update = next.asData?.value;
      if (update != null) _promptOnce(update);
    });
    final current = ref.read(appUpdateProvider).asData?.value;
    if (current != null) _promptOnce(current);

    if (_dismissed) return const SizedBox.shrink();

    final update = ref.watch(appUpdateProvider).asData?.value;
    if (update == null) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            Icon(Icons.system_update, color: scheme.onPrimaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Update available: ${update.versionName}',
                style: TextStyle(color: scheme.onPrimaryContainer),
              ),
            ),
            TextButton(
              onPressed: () => downloadAndInstallUpdate(context, update),
              child: const Text('Update'),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              color: scheme.onPrimaryContainer,
              onPressed: () => setState(() => _dismissed = true),
            ),
          ],
        ),
      ),
    );
  }
}
