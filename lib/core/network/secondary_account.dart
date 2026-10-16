import 'package:dawarich/core/data/backup/backup_secrets_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Optional second Dawarich account on the same server (e.g. to belong to a
/// second family). It is purely additive: when no key is stored, nothing in
/// the app behaves differently.
///
/// * the map also shows the family of the second account;
/// * every uploaded point batch is mirrored to the second account.
final class SecondaryAccount {
  static const _storageKey = 'apiKey2';
  static const _ios =
      IOSOptions(accessibility: KeychainAccessibility.first_unlock);

  final FlutterSecureStorage _secure = const FlutterSecureStorage();
  final BackupSecretsStore _backup = const BackupSecretsStore();

  SecondaryAccount();

  Future<String?> readKey() async {
    try {
      var key = await _secure.read(key: _storageKey, iOptions: _ios);
      key ??= await _backup.read(_storageKey);
      key = key?.trim();
      return (key == null || key.isEmpty) ? null : key;
    } catch (e) {
      if (kDebugMode) debugPrint('[SecondaryAccount] read failed: $e');
      return null;
    }
  }

  Future<void> writeKey(String? key) async {
    final clean = key?.trim();
    if (clean == null || clean.isEmpty) {
      await _secure.delete(key: _storageKey, iOptions: _ios);
      await _backup.write(_storageKey, null);
      return;
    }
    await _secure.write(key: _storageKey, value: clean, iOptions: _ios);
    await _backup.write(_storageKey, clean);
  }

  Dio _dio(String host, String key) => Dio(BaseOptions(
        baseUrl: host,
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 20),
        headers: {'Authorization': 'Bearer $key'},
      ));

  /// Server user id of the second account, or null if the key is rejected.
  Future<int?> fetchUserId(String host, String key) async {
    try {
      final res =
          await _dio(host, key).get<dynamic>('/api/v1/users/me');
      final data = res.data;
      final user = data is Map ? data['user'] : null;
      final id = user is Map ? user['id'] : null;
      return id is num ? id.toInt() : null;
    } catch (_) {
      return null;
    }
  }

  /// Checks the key against the server. Returns null when it is accepted,
  /// otherwise a short reason to show the user.
  Future<String?> checkKey(String host, String key) async {
    try {
      final res = await _dio(host, key).get<dynamic>('/api/v1/users/me');
      return res.statusCode == 200 ? null : 'HTTP ${res.statusCode}';
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 401 || code == 403) return 'wrong API key (HTTP $code)';
      return code != null ? 'HTTP $code' : 'network error: ${e.type.name}';
    } catch (e) {
      return e.toString();
    }
  }

  /// Raw `locations` list of the second account's family. Never throws.
  Future<List<dynamic>> fetchFamilyLocations(String host, String key) async {
    try {
      final res = await _dio(host, key)
          .get<dynamic>('/api/v1/families/locations');
      final data = res.data;
      final raw = data is Map ? data['locations'] : null;
      return raw is List ? raw : const [];
    } catch (_) {
      return const [];
    }
  }

  /// Sends the same batch to the second account. Best effort: never throws
  /// and never affects the primary upload.
  Future<void> mirrorBatch(
      String host, String key, Map<String, dynamic> batchJson) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await _dio(host, key).post<void>(
          '/api/v1/points',
          data: batchJson,
          options: Options(headers: {'Content-Type': 'application/json'}),
        );
        return;
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[SecondaryAccount] mirror attempt $attempt failed: $e');
        }
      }
    }
  }
}
