/// La nuit, un téléphone immobile n'a pas besoin d'un point toutes les 15 min :
/// le point « toujours là » passe à [heartbeat], ce qui divise par deux les
/// réveils de la radio. En mouvement, rien ne change.
///
/// Logique pure : l'heure est celle de la [DateTime] fournie (locale en production).
final class NightSchedule {
  const NightSchedule({
    this.startHour = 23,
    this.endHour = 7,
    this.heartbeat = const Duration(minutes: 30),
    this.maxPointGap = const Duration(minutes: 37),
  });

  /// Début de la nuit (inclus), en heures.
  final int startHour;

  /// Fin de la nuit (exclue), en heures.
  final int endHour;

  /// Immobile, la nuit : un point « toujours là » par période.
  final Duration heartbeat;

  /// Silence maximal toléré sans point la nuit (le superviseur ne doit pas
  /// relancer le suivi entre deux points espacés de [heartbeat]).
  final Duration maxPointGap;

  bool isNight(DateTime t) => t.hour >= startHour || t.hour < endHour;
}
