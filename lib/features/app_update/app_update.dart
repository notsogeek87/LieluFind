import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

const _latestReleaseUrl =
    'https://api.github.com/repos/notsogeek87/LieluFind/releases/latest';

/// A newer APK published as a GitHub release.
final class AppUpdate {
  final String versionName;
  final String apkUrl;

  /// Hex SHA-256 GitHub computed for the asset, checked before installing.
  final String? sha256;
  const AppUpdate({required this.versionName, required this.apkUrl, this.sha256});
}

/// GitHub exposes each release asset's checksum as `digest: "sha256:<hex>"`.
/// Returns the hex part, or null when absent or malformed.
String? sha256FromAssetDigest(Object? digest) {
  if (digest is! String) return null;
  final match = RegExp(r'^sha256:([0-9a-fA-F]{64})$').firstMatch(digest.trim());
  return match?.group(1)?.toLowerCase();
}

/// The update offered by a `releases/latest` payload, if its build is newer
/// than [installedBuild] and it carries an APK asset.
AppUpdate? updateFromRelease(Map<String, dynamic> data, int? installedBuild) {
  final tag = data['tag_name'] as String? ?? '';
  final latest = _buildFromTag(tag);
  if (installedBuild == null || latest == null || latest <= installedBuild) {
    return null;
  }
  for (final asset in (data['assets'] as List?) ?? const []) {
    if (asset is! Map) continue;
    final url = asset['browser_download_url'] as String?;
    if (url != null && url.endsWith('.apk')) {
      return AppUpdate(
        versionName: tag,
        apkUrl: url,
        sha256: sha256FromAssetDigest(asset['digest']),
      );
    }
  }
  return null;
}

/// Release tags are `v<pubspec version>.<run_number>` and the installed
/// versionCode is the run number (see android-build.yml), so the last tag
/// segment is directly comparable with the installed build number.
int? _buildFromTag(String tag) {
  final parts = tag.replaceFirst(RegExp(r'^v'), '').split('.');
  return parts.length < 2 ? null : int.tryParse(parts.last);
}

/// Outcome of an update check, with enough detail to explain itself.
final class UpdateCheck {
  final String installedVersion;
  final int? installedBuild;
  final String? latestTag;
  final AppUpdate? update;
  final String? error;
  const UpdateCheck({
    required this.installedVersion,
    this.installedBuild,
    this.latestTag,
    this.update,
    this.error,
  });
}

/// Checks GitHub for a release newer than the installed build. Never throws:
/// failures (offline, rate limit, no release) are reported in [UpdateCheck.error].
Future<UpdateCheck> runUpdateCheck() async {
  String version = '?';
  int? installed;
  try {
    final info = await PackageInfo.fromPlatform();
    version = '${info.version}+${info.buildNumber}';
    installed = int.tryParse(info.buildNumber);

    final resp = await Dio().get<Map<String, dynamic>>(
      _latestReleaseUrl,
      options: Options(
        headers: {'Accept': 'application/vnd.github+json'},
        receiveTimeout: const Duration(seconds: 10),
        sendTimeout: const Duration(seconds: 10),
      ),
    );
    final data = resp.data;
    final tag = data?['tag_name'] as String? ?? '';
    final latest = _buildFromTag(tag);
    if (data == null || latest == null) {
      return UpdateCheck(
          installedVersion: version,
          installedBuild: installed,
          latestTag: tag,
          error: 'Unreadable release tag "$tag"');
    }

    final update = updateFromRelease(data, installed);
    return UpdateCheck(
        installedVersion: version,
        installedBuild: installed,
        latestTag: tag,
        update: update);
  } catch (e) {
    return UpdateCheck(
        installedVersion: version, installedBuild: installed, error: '$e');
  }
}

Future<AppUpdate?> checkForAppUpdate() async => (await runUpdateCheck()).update;

/// Checked once per app launch.
final appUpdateProvider = FutureProvider<AppUpdate?>((ref) => checkForAppUpdate());
