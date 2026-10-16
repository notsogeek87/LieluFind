import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _prefsKey = 'family_hidden_user_ids';

/// Members the user chose to hide from the map (server user ids).
/// Empty by default: everybody is shown. Changed from Settings only.
final hiddenFamilyIdsProvider =
    NotifierProvider<HiddenFamilyIdsNotifier, Set<int>>(
        HiddenFamilyIdsNotifier.new);

final class HiddenFamilyIdsNotifier extends Notifier<Set<int>> {
  @override
  Set<int> build() {
    _load();
    return const {};
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ids = (prefs.getStringList(_prefsKey) ?? const [])
          .map(int.tryParse)
          .whereType<int>()
          .toSet();
      if (ids.isNotEmpty) state = ids;
    } catch (_) {
      // Fall back to showing everybody.
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
          _prefsKey, state.map((e) => e.toString()).toList());
    } catch (_) {}
  }

  Future<void> setHidden(int userId, bool hidden) async {
    final next = {...state};
    hidden ? next.add(userId) : next.remove(userId);
    state = next;
    await _save();
  }

  Future<void> showEveryone() async {
    state = const {};
    await _save();
  }
}
