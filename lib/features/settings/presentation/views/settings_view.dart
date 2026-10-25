import 'package:auto_route/annotations.dart';
import 'package:dawarich/core/di/providers/core_providers.dart';
import 'package:dawarich/core/di/providers/session_providers.dart';
import 'package:dawarich/core/network/secondary_account.dart';
import 'package:dawarich/features/family/presentation/family_layer.dart';
import 'package:dawarich/features/family/presentation/family_visibility.dart';
import 'package:dawarich/core/di/providers/settings_providers.dart';
import 'package:dawarich/core/shell/drawer/drawer.dart';
import 'package:dawarich/features/app_update/app_update.dart';
import 'package:dawarich/features/app_update/app_update_installer.dart';
import 'package:dawarich/features/settings/application/usecases/check_biometric_availability_usecase.dart';
import 'package:dawarich/features/tracking/application/services/tracking_log.dart';
import 'package:dawarich/shared/widgets/app_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

@RoutePage()
class SettingsView extends ConsumerStatefulWidget {
  const SettingsView({super.key});

  @override
  ConsumerState<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends ConsumerState<SettingsView> {
  bool _lockEnabled = false;
  int _lockTimeoutSeconds = 0;
  ThemeMode _themeMode = ThemeMode.system;
  DeviceLockAvailability _availability = const DeviceLockAvailability(
    hasBiometrics: false,
    hasDeviceLock: false,
  );
  bool _loading = true;

  static const _timeoutOptions = <int, String>{
    0: 'Immediately',
    30: '30 seconds',
    60: '1 minute',
    300: '5 minutes',
    600: '10 minutes',
  };

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final isEnabled =
        await ref.read(isBiometricLockEnabledUseCaseProvider.future);
    final getTimeout =
        await ref.read(getLockTimeoutUseCaseProvider.future);
    final getTheme =
        await ref.read(getThemeModeUseCaseProvider.future);
    final checkAvailability =
        ref.read(checkBiometricAvailabilityUseCaseProvider);
    final userId = ref.read(currentUserIdProvider);

    final enabled = await isEnabled(userId);
    final timeout = await getTimeout(userId);
    final themeStr = await getTheme(userId);
    final availability = await checkAvailability();

    if (mounted) {
      setState(() {
        _lockEnabled = enabled;
        _lockTimeoutSeconds = timeout;
        _themeMode = themeModeFromString(themeStr);
        _availability = availability;
        _loading = false;
      });
    }
  }

  Future<void> _onLockToggled(bool value) async {
    final setEnabled =
        await ref.read(setBiometricLockEnabledUseCaseProvider.future);
    final authenticate = ref.read(authenticateBiometricUseCaseProvider);
    final userId = ref.read(currentUserIdProvider);

    if (value) {
      if (!_availability.isAvailable) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  'No screen lock is configured on this device.'),
            ),
          );
        }
        return;
      }

      final success = await authenticate(
        reason: 'Verify your identity to enable app lock',
      );

      if (!success) return;
    }

    await setEnabled(userId, enabled: value);
    if (mounted) {
      setState(() => _lockEnabled = value);
    }
  }

  Future<void> _onTimeoutChanged(int seconds) async {
    final setTimeout =
        await ref.read(setLockTimeoutUseCaseProvider.future);
    final userId = ref.read(currentUserIdProvider);

    await setTimeout(userId, seconds: seconds);
    if (mounted) {
      setState(() => _lockTimeoutSeconds = seconds);
    }
  }

  Future<void> _onThemeChanged(ThemeMode mode) async {
    final setTheme =
        await ref.read(setThemeModeUseCaseProvider.future);
    final userId = ref.read(currentUserIdProvider);

    await setTheme(userId, mode: themeModeToString(mode));
    ref.read(themeModeProvider.notifier).set(mode);
    if (mounted) {
      setState(() => _themeMode = mode);
    }
  }

  String get _lockTitle {
    if (_availability.hasBiometrics) return 'Biometric / Screen Lock';
    if (_availability.hasDeviceLock) return 'Screen Lock (PIN / Pattern)';
    return 'App Lock';
  }

  String get _lockSubtitle {
    if (!_availability.isAvailable) {
      return 'No screen lock is configured on this device';
    }
    if (_availability.hasBiometrics) {
      return 'Use fingerprint, face, or screen lock to open the app';
    }
    return 'Use your PIN or pattern to open the app';
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Settings',
      titleFontSize: 40,
      drawer: const CustomDrawer(),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _buildSettings(context),
    );
  }

  Widget _buildSettings(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      children: [
        // ── General ──
        const _SectionHeader(title: 'General', icon: Icons.tune_outlined),
        const SizedBox(height: 8),
        _SettingsCard(
          children: [
            _PickerTile(
              icon: Icons.palette_outlined,
              title: 'Theme',
              value: themeModeLabel(_themeMode),
              onTap: () => _showThemePicker(context),
            ),
          ],
        ),

        const SizedBox(height: 24),

        // ── Map ──
        const _SectionHeader(title: 'Map', icon: Icons.map_outlined),
        const SizedBox(height: 8),
        const _SettingsCard(children: [_PeopleOnMapTile()]),

        const SizedBox(height: 24),

        // ── Second account ──
        const _SectionHeader(
            title: 'Second account', icon: Icons.group_add_outlined),
        const SizedBox(height: 8),
        const _SettingsCard(children: [_SecondaryAccountTile()]),

        const SizedBox(height: 24),

        // ── Security ──
        const _SectionHeader(title: 'Security', icon: Icons.shield_outlined),
        const SizedBox(height: 8),
        _SettingsCard(
          children: [
            _ToggleTile(
              icon: _availability.hasBiometrics
                  ? Icons.fingerprint
                  : Icons.lock_outline,
              title: _lockTitle,
              subtitle: _lockSubtitle,
              value: _lockEnabled,
              enabled: _availability.isAvailable,
              onChanged: _onLockToggled,
            ),
            if (_lockEnabled) ...[
              _PickerTile(
                icon: Icons.timer_outlined,
                title: 'Lock after',
                value: _timeoutOptions[_lockTimeoutSeconds] ?? 'Immediately',
                onTap: () => _showTimeoutPicker(context),
              ),
            ],
          ],
        ),

        const SizedBox(height: 24),

        // ── Updates ──
        const _SectionHeader(title: 'About', icon: Icons.info_outline),
        const SizedBox(height: 8),
        _SettingsCard(
          children: [
            ListTile(
              leading: _checkingUpdate
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.system_update_outlined),
              title: const Text('Check for updates'),
              subtitle: Text(_updateStatus ?? 'Tap to check for a new version'),
              onTap: _checkingUpdate ? null : _checkForUpdates,
            ),
            ListTile(
              leading: const Icon(Icons.bug_report_outlined),
              title: const Text('Journal du tracking'),
              subtitle: const Text('Démarrages, arrêts et erreurs du service'),
              onTap: _showTrackingLog,
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _showTrackingLog() async {
    final text = await TrackingLog.read();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Journal du tracking'),
        content: SingleChildScrollView(
          reverse: true,
          child: SelectableText(
            text.isEmpty ? 'Journal vide.' : text,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await TrackingLog.clear();
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Effacer'),
          ),
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: text)),
            child: const Text('Copier'),
          ),
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
  }

  bool _checkingUpdate = false;
  String? _updateStatus;

  Future<void> _checkForUpdates() async {
    setState(() => _checkingUpdate = true);
    final r = await runUpdateCheck();
    if (!mounted) return;

    final installed = 'Installed: ${r.installedVersion}';
    setState(() {
      _checkingUpdate = false;
      _updateStatus = r.error != null
          ? 'Check failed. $installed'
          : r.update != null
              ? 'Update available: ${r.update!.versionName}'
              : 'Up to date. $installed';
    });

    final update = r.update;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(update != null
            ? 'Update available'
            : r.error != null
                ? 'Update check failed'
                : 'You are up to date'),
        content: Text([
          installed,
          if (r.latestTag != null) 'Latest release: ${r.latestTag}',
          if (r.error != null) r.error!,
        ].join('\n')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          if (update != null)
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                downloadAndInstallUpdate(context, update);
              },
              child: const Text('Update'),
            ),
        ],
      ),
    );
  }

  void _showTimeoutPicker(BuildContext context) {
    showModalBottomSheet<int>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: Text(
                  'Lock after',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              ..._timeoutOptions.entries.map((e) {
                final isSelected = e.key == _lockTimeoutSeconds;
                return ListTile(
                  title: Text(e.value),
                  trailing:
                      isSelected ? Icon(Icons.check, color: theme.colorScheme.primary) : null,
                  onTap: () => Navigator.pop(ctx, e.key),
                );
              }),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    ).then((selected) {
      if (selected != null) {
        _onTimeoutChanged(selected);
      }
    });
  }

  void _showThemePicker(BuildContext context) {
    showModalBottomSheet<ThemeMode>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: Text(
                  'Theme',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              for (final mode in ThemeMode.values)
                ListTile(
                  leading: Icon(_themeIcon(mode),
                      color: mode == _themeMode
                          ? theme.colorScheme.primary
                          : null),
                  title: Text(themeModeLabel(mode)),
                  trailing: mode == _themeMode
                      ? Icon(Icons.check, color: theme.colorScheme.primary)
                      : null,
                  onTap: () => Navigator.pop(ctx, mode),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    ).then((selected) {
      if (selected != null) {
        _onThemeChanged(selected);
      }
    });
  }

  IconData _themeIcon(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return Icons.light_mode_outlined;
      case ThemeMode.dark:
        return Icons.dark_mode_outlined;
      case ThemeMode.system:
        return Icons.brightness_auto_outlined;
    }
  }
}

// ---------------------------------------------------------------------------
// Reusable settings widgets
// ---------------------------------------------------------------------------

final class _SectionHeader extends StatelessWidget {
  final String title;
  final IconData icon;

  const _SectionHeader({required this.title, required this.icon});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            title.toUpperCase(),
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

final class _SettingsCard extends StatelessWidget {
  final List<Widget> children;

  const _SettingsCard({required this.children});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: (isDark ? Colors.white : Colors.black)
            .withValues(alpha: isDark ? 0.07 : 0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: (isDark ? Colors.white : Colors.black)
              .withValues(alpha: 0.06),
        ),
      ),
      child: Column(
        children: [
          for (int i = 0; i < children.length; i++) ...[
            children[i],
            if (i < children.length - 1)
              Divider(
                height: 1,
                indent: 56,
                color: (isDark ? Colors.white : Colors.black)
                    .withValues(alpha: 0.06),
              ),
          ],
        ],
      ),
    );
  }
}

final class _ToggleTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _ToggleTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Icon(
            icon,
            size: 24,
            color: enabled ? theme.colorScheme.primary : theme.disabledColor,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.textTheme.bodySmall?.color
                        ?.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch.adaptive(
            value: value,
            onChanged: enabled ? onChanged : null,
          ),
        ],
      ),
    );
  }
}

final class _PickerTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final VoidCallback onTap;

  const _PickerTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 24, color: theme.colorScheme.primary),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
            ),
            Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.chevron_right,
              size: 20,
              color: theme.iconTheme.color?.withValues(alpha: 0.3),
            ),
          ],
        ),
      ),
    );
  }
}


/// Optional second account on the same server: its family is shown on the map
/// and every uploaded point is copied to it.
final class _SecondaryAccountTile extends ConsumerStatefulWidget {
  const _SecondaryAccountTile();

  @override
  ConsumerState<_SecondaryAccountTile> createState() =>
      _SecondaryAccountTileState();
}

class _SecondaryAccountTileState extends ConsumerState<_SecondaryAccountTile> {
  final _store = SecondaryAccount();
  bool _loading = true;
  bool _configured = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final key = await _store.readKey();
    if (!mounted) return;
    setState(() {
      _configured = key != null;
      _loading = false;
    });
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _edit() async {
    final controller = TextEditingController();
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Second account'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'API key of your second account on the same server. Its '
                'family appears on the map and your position is sent to it too.'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'API key'),
            ),
          ],
        ),
        actions: [
          if (_configured)
            TextButton(
                onPressed: () => Navigator.pop(ctx, 'remove'),
                child: const Text('Remove')),
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'save'),
              child: const Text('Save')),
        ],
      ),
    );
    final key = controller.text.trim();
    controller.dispose();
    if (action == null || !mounted) return;

    if (action == 'remove') {
      await _store.writeKey(null);
    } else {
      if (key.isEmpty) return;
      final cfg = await ref.read(apiConfigManagerProvider.future);
      final host = cfg.apiConfig?.host;
      final error = host == null
          ? 'no server configured'
          : await _store.checkKey(host, key);
      if (!mounted) return;
      if (error != null) {
        _toast('Key rejected: $error');
        return;
      }
      await _store.writeKey(key);
    }
    ref.invalidate(familyLocationsProvider);
    await _refresh();
  }

  Future<void> _diagnose() async {
    final cfg = await ref.read(apiConfigManagerProvider.future);
    final host = cfg.apiConfig?.host;
    final key = await _store.readKey();
    String report;
    if (host == null || key == null) {
      report = 'No second account configured.';
    } else {
      final error = await _store.checkKey(host, key);
      if (error != null) {
        report = 'Key check failed: $error';
      } else {
        final selfId = await _store.fetchUserId(host, key);
        final raw = await _store.fetchFamilyLocations(host, key);
        final lines = <String>['Key OK (user id $selfId).'];
        if (raw.isEmpty) {
          lines.add('Server returned NO member with a position for this '
              'account\'s family. Check: member of the family, location '
              'sharing on, and at least one point received.');
        }
        for (final m in raw) {
          if (m is! Map) continue;
          final ts = (m['timestamp'] as num?)?.toInt();
          final when = ts == null
              ? 'unknown time'
              : DateTime.fromMillisecondsSinceEpoch(ts * 1000)
                  .toLocal()
                  .toString()
                  .split('.')
                  .first;
          final who = m['name'] ?? m['email'] ?? '?';
          final me = m['user_id'] == selfId ? ' (this account)' : '';
          lines.add('• $who$me — last point $when');
        }
        report = lines.join('\n');
      }
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Second account check'),
        content: SingleChildScrollView(child: Text(report)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.group_add_outlined),
      title: const Text('Second account'),
      subtitle: Text(_loading
          ? '…'
          : _configured
              ? 'Active: second family shown, positions mirrored'
              : 'Not set'),
      trailing: _configured
          ? IconButton(
              icon: const Icon(Icons.fact_check_outlined),
              tooltip: 'Check',
              onPressed: _diagnose,
            )
          : const Icon(Icons.chevron_right),
      onTap: _loading ? null : _edit,
    );
  }
}


/// Choose which people appear on the map. Lives in Settings (not on the map)
/// so nobody hides someone by accident. Everybody is shown by default.
final class _PeopleOnMapTile extends ConsumerWidget {
  const _PeopleOnMapTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hidden = ref.watch(hiddenFamilyIdsProvider);
    return ListTile(
      leading: const Icon(Icons.people_outline),
      title: const Text('People on the map'),
      subtitle: Text(
          hidden.isEmpty ? 'Everyone is shown' : '${hidden.length} hidden'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => const _PeopleOnMapDialog(),
      ),
    );
  }
}

final class _PeopleOnMapDialog extends ConsumerWidget {
  const _PeopleOnMapDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hidden = ref.watch(hiddenFamilyIdsProvider);
    final members = [...(ref.watch(familyLocationsProvider).value ?? const [])]
      ..sort((a, b) => a.shortName.compareTo(b.shortName));
    final notifier = ref.read(hiddenFamilyIdsProvider.notifier);

    return AlertDialog(
      title: const Text('People on the map'),
      content: SizedBox(
        width: double.maxFinite,
        child: members.isEmpty
            ? const Text('Nobody to show yet. People appear here once their '
                'position is known.')
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final m in members)
                    CheckboxListTile(
                      value: !hidden.contains(m.userId),
                      onChanged: (v) => notifier.setHidden(m.userId, v == false),
                      title: Text(m.shortName),
                      subtitle: Text(m.name),
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                ],
              ),
      ),
      actions: [
        if (hidden.isNotEmpty)
          TextButton(
              onPressed: notifier.showEveryone,
              child: const Text('Show everyone')),
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done')),
      ],
    );
  }
}
