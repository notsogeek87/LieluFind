import 'dart:io';

import 'package:dawarich/features/app_update/app_update.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

const _channel = MethodChannel('com.sunstep.travel/apk_installer');

/// Downloads [update]'s APK inside the app (progress reported in 0..1) and
/// returns the local file path.
Future<String> downloadUpdateApk(
  AppUpdate update, {
  required void Function(double progress) onProgress,
  CancelToken? cancelToken,
}) async {
  final cache = await getTemporaryDirectory();
  final dir = Directory('${cache.path}/apk_updates');
  if (await dir.exists()) await dir.delete(recursive: true);
  await dir.create(recursive: true);
  final path = '${dir.path}/update.apk';

  await Dio().download(
    update.apkUrl,
    path,
    cancelToken: cancelToken,
    onReceiveProgress: (received, total) {
      if (total > 0) onProgress(received / total);
    },
  );
  return path;
}

Future<bool> canInstallApks() async =>
    await _channel.invokeMethod<bool>('canInstall') ?? false;

Future<void> openInstallPermissionSettings() =>
    _channel.invokeMethod('openInstallSettings');

/// Checks the APK natively (checksum, package name, signing key). Returns
/// null when it is safe to install, otherwise the reason it is not.
Future<String?> verifyUpdateApk(String path, {String? sha256}) =>
    _channel.invokeMethod<String>('verify', {'path': path, 'sha256': sha256});

Future<void> installApk(String path) =>
    _channel.invokeMethod('install', {'path': path});

/// Full in-app flow: dialog with download progress, then hand-off to the
/// system installer (a single confirmation sheet, no browser involved).
Future<void> downloadAndInstallUpdate(
    BuildContext context, AppUpdate update) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _UpdateProgressDialog(update: update),
  );
}

class _UpdateProgressDialog extends StatefulWidget {
  final AppUpdate update;
  const _UpdateProgressDialog({required this.update});

  @override
  State<_UpdateProgressDialog> createState() => _UpdateProgressDialogState();
}

class _UpdateProgressDialogState extends State<_UpdateProgressDialog> {
  final _cancel = CancelToken();
  double _progress = 0;
  String? _error;
  String? _apkPath;
  bool _needsPermission = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    if (!_cancel.isCancelled) _cancel.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    setState(() {
      _error = null;
      _needsPermission = false;
      _progress = 0;
    });
    try {
      _apkPath ??= await downloadUpdateApk(
        widget.update,
        cancelToken: _cancel,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      final problem =
          await verifyUpdateApk(_apkPath!, sha256: widget.update.sha256);
      if (problem != null) {
        // Never keep a rejected file: the next retry downloads it again.
        final rejected = File(_apkPath!);
        _apkPath = null;
        if (await rejected.exists()) await rejected.delete();
        if (mounted) setState(() => _error = problem);
        return;
      }
      if (!mounted) return;
      if (!await canInstallApks()) {
        setState(() => _needsPermission = true);
        return;
      }
      await installApk(_apkPath!);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (!mounted || (e is DioException && CancelToken.isCancel(e))) return;
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final String body;
    if (_error != null) {
      body = _error!;
    } else if (_needsPermission) {
      body = 'Allow this app to install updates, then come back and retry.';
    } else {
      body = 'Downloading ${widget.update.versionName}… '
          '${(_progress * 100).round()}%';
    }

    return AlertDialog(
      title: const Text('Updating'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(body),
          if (_error == null && !_needsPermission) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(value: _progress > 0 ? _progress : null),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        if (_needsPermission)
          FilledButton(
            onPressed: () async {
              await openInstallPermissionSettings();
            },
            child: const Text('Open settings'),
          ),
        if (_needsPermission || _error != null)
          FilledButton(onPressed: _run, child: const Text('Retry')),
      ],
    );
  }
}
