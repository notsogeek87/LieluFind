import 'package:dawarich/core/data/backup/backup_secrets_store.dart';
import 'package:dawarich/core/network/configs/api_config.dart';
import 'package:dawarich/core/network/configs/api_config_manager_interfaces.dart';
import 'package:dawarich/core/shell/drawer/i_api_config_logout.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

final class ApiConfigManager implements IApiConfigManager, IApiConfigLogout {
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  final BackupSecretsStore _backup = const BackupSecretsStore();
  ApiConfig? _apiConfig;
  ApiConfigManager();
  static const _iOS    = IOSOptions(accessibility: KeychainAccessibility.first_unlock);

  @override
  bool get hasHost => _apiConfig?.hasHost == true;
  @override
  bool get isConfigured => _apiConfig?.isFullyConfigured == true;

  @override
  Future<void> load() async {
    String? host = await _secureStorage.read(key: 'host', iOptions: _iOS);
    String? apiKey = await _secureStorage.read(key: 'apiKey', iOptions: _iOS);

    // Après une restauration Android (nouveau téléphone), le Keystore est vide
    // mais le miroir de sauvegarde contient la configuration.
    if (host == null || host.trim().isEmpty) {
      final restoredHost = await _backup.read('host');
      if (restoredHost != null) {
        host = restoredHost;
        apiKey = await _backup.read('apiKey');
        await _secureStorage.write(key: 'host', value: host, iOptions: _iOS);
        if (apiKey != null) {
          await _secureStorage.write(key: 'apiKey', value: apiKey, iOptions: _iOS);
        }
      }
    }

    if (host != null && host.trim().isNotEmpty) {
      _apiConfig = ApiConfig(host: host.trim(), apiKey: apiKey?.trim());
    } else {
      _apiConfig = null;
    }
  }

  @override
  ApiConfig? get apiConfig => _apiConfig;

  @override
  void createConfig(String host) {
    _apiConfig = ApiConfig(host: host.trim());
  }

  @override
  void setApiKey(String apiKey) {
    final ApiConfig? cfg = _apiConfig;

    if (cfg == null) {
      if (kDebugMode) {
        debugPrint('[ApiConfigManager] Ignoring setApiKey: no config/host set');
      }
      return;
    }

    _apiConfig = cfg.copyWith(apiKey: apiKey.trim());
  }

  @override
  Future<void> storeApiConfig() async {
    final ApiConfig? cfg = _apiConfig;

    if (cfg == null || !cfg.isFullyConfigured) {
      throw Exception('Cannot store incomplete ApiConfigDTO');
    }

    await _secureStorage.write(
        key: 'host',
        value: cfg.host,
        iOptions: _iOS
    );
    await _secureStorage.write(
        key: 'apiKey',
        value: cfg.apiKey,
        iOptions: _iOS
    );
    await _backup.write('host', cfg.host);
    await _backup.write('apiKey', cfg.apiKey);
  }

  @override
  Future<void> clearConfiguration() async {
    await _secureStorage.delete(
        key: 'host',
        iOptions: _iOS
    );
    await _secureStorage.delete(
        key: 'apiKey',
        iOptions: _iOS
    );

    await _backup.write('host', null);
    await _backup.write('apiKey', null);

    _apiConfig = null;
  }

}
