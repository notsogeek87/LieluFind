import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

/// Photos chosen on this phone for each family member (including the user).
/// Purely local: nothing is sent to the server, so each person decides what
/// picture they see for everybody.
///
/// Files are stored as `family_photos/<userId>_<timestamp>.jpg`. A fresh name
/// is used on every change so Flutter's image cache never shows a stale photo.
final familyPhotosProvider =
    NotifierProvider<FamilyPhotosNotifier, Map<int, File>>(
        FamilyPhotosNotifier.new);

final class FamilyPhotosNotifier extends Notifier<Map<int, File>> {
  @override
  Map<int, File> build() {
    _load();
    return const {};
  }

  Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/family_photos');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static int? _userIdOf(File f) {
    final name = f.uri.pathSegments.last;
    return int.tryParse(name.split('_').first);
  }

  Future<void> _load() async {
    try {
      final dir = await _dir();
      final newest = <int, File>{};
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final id = _userIdOf(e);
        if (id == null) continue;
        final current = newest[id];
        if (current == null ||
            e.path.compareTo(current.path) > 0) {
          newest[id] = e;
        }
      }
      state = newest;
    } catch (_) {
      // Photos are optional; fall back to initials.
    }
  }

  /// Opens the system photo picker and stores a small square-ish copy.
  /// Returns false if the user cancelled or something went wrong.
  Future<bool> pick(int userId, {ImageSource source = ImageSource.gallery}) async {
    try {
      final picked = await ImagePicker().pickImage(
        source: source,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 85,
      );
      if (picked == null) return false;

      final dir = await _dir();
      final target = File(
          '${dir.path}/${userId}_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await File(picked.path).copy(target.path);

      final old = state[userId];
      state = {...state, userId: target};
      if (old != null && await old.exists()) await old.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> remove(int userId) async {
    final old = state[userId];
    state = {...state}..remove(userId);
    try {
      if (old != null && await old.exists()) await old.delete();
    } catch (_) {}
  }
}
