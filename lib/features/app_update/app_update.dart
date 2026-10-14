import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

const _latestReleaseUrl =
    'https://api.github.com/repos/notsogeek87/LieluFind/releases/latest';

/// A newer APK published as a GitHub release.
final class AppUpdate {
  final String versionName;
  final String apkUrl;
  const AppUpdate({required this.versionName, required this.apkUrl});
}

/// Release tags are `v<pubspec version>.<run_number>` and the installed
/// versionCode is the run number (see android-build.yml), so the last tag
/// segment is directly comparable with the installed build number.
int? _buildFromTag(String tag) {
  final parts = tag.replaceFirst(RegExp(r'^v'), '').split('.');
  return parts.length < 2 ? null : int.tryParse(parts.last);
}

/// Returns the latest release when it is newer than the installed build,
/// null otherwise. Any failure (offline, rate limit, private repo) is
/// treated as "no update" so the check never disturbs the app.
Future<AppUpdate?> checkForAppUpdate() async {
  try {
    final installed = int.tryParse((await PackageInfo.fromPlatform()).buildNumber);
    if (installed == null) return null;

    final resp = await Dio().get<Map<String, dynamic>>(
      _latestReleaseUrl,
      options: Options(
        headers: {'Accept': 'application/vnd.github+json'},
        receiveTimeout: const Duration(seconds: 10),
        sendTimeout: const Duration(seconds: 10),
      ),
    );
    final data = resp.data;
    if (data == null) return null;

    final tag = data['tag_name'] as String? ?? '';
    final latest = _buildFromTag(tag);
    if (latest == null || latest <= installed) return null;

    final assets = (data['assets'] as List?) ?? const [];
    for (final asset in assets) {
      final url = (asset as Map)['browser_download_url'] as String?;
      if (url != null && url.endsWith('.apk')) {
        return AppUpdate(versionName: tag, apkUrl: url);
      }
    }
  } catch (_) {}
  return null;
}

/// Checked once per app launch.
final appUpdateProvider = FutureProvider<AppUpdate?>((ref) => checkForAppUpdate());
