/// Pourquoi le téléphone a réveillé le suivi.
enum DeviceWake { alarm, motion }

/// Veille profonde à l'arrêt : le suivi laisse dormir le téléphone et se fait
/// réveiller par une alarme (point « toujours là ») ou par le capteur de
/// mouvement significatif (départ).
abstract interface class IDevicePower {
  /// Relâche le wakelock permanent du service de fond. Retourne le nombre de
  /// références relâchées (-1 si indisponible).
  Future<int> releaseServiceWakeLock();

  /// Programme (ou remplace) le prochain réveil. Retourne vrai si l'alarme est exacte.
  Future<bool> scheduleWake(Duration delay);

  Future<void> cancelWake();

  /// Arme le capteur de mouvement (un seul déclenchement) ou le désarme.
  /// Retourne faux si le téléphone n'en a pas.
  Future<bool> watchMotion(bool enabled);

  Stream<DeviceWake> get wakes;
}
