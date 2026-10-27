import 'package:dawarich/features/app_update/app_update.dart';
import 'package:flutter_test/flutter_test.dart';

const _hex = 'a3f1c2d4e5b6978812345678901234567890abcdefabcdefabcdef0123456789';

Map<String, dynamic> _release(String tag, {List<Map<String, dynamic>>? assets}) => {
      'tag_name': tag,
      'assets': assets ??
          [
            {
              'browser_download_url': 'https://example.org/LieluFind-0.19.2.120.apk',
              'digest': 'sha256:$_hex',
            },
          ],
    };

void main() {
  group('sha256FromAssetDigest', () {
    test('extracts the lowercase hex of a sha256 digest', () {
      expect(sha256FromAssetDigest('sha256:${_hex.toUpperCase()}'), _hex);
    });

    test('rejects missing, other algorithms and malformed values', () {
      expect(sha256FromAssetDigest(null), isNull);
      expect(sha256FromAssetDigest(42), isNull);
      expect(sha256FromAssetDigest('sha512:$_hex'), isNull);
      expect(sha256FromAssetDigest('sha256:abc'), isNull);
    });
  });

  group('updateFromRelease', () {
    test('offers a newer build with its checksum', () {
      final update = updateFromRelease(_release('v0.19.2.120'), 119);
      expect(update?.versionName, 'v0.19.2.120');
      expect(update?.apkUrl, endsWith('.apk'));
      expect(update?.sha256, _hex);
    });

    test('offers nothing for the same or an older build', () {
      expect(updateFromRelease(_release('v0.19.2.120'), 120), isNull);
      expect(updateFromRelease(_release('v0.19.2.120'), 130), isNull);
    });

    test('offers nothing without an installed build or a readable tag', () {
      expect(updateFromRelease(_release('v0.19.2.120'), null), isNull);
      expect(updateFromRelease(_release('latest'), 1), isNull);
    });

    test('ignores non-APK assets and keeps a release without digest', () {
      final update = updateFromRelease(
        _release('v0.19.2.120', assets: [
          {'browser_download_url': 'https://example.org/notes.txt'},
          {'browser_download_url': 'https://example.org/app.apk'},
        ]),
        1,
      );
      expect(update?.apkUrl, 'https://example.org/app.apk');
      expect(update?.sha256, isNull);
    });
  });
}
