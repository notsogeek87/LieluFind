import 'package:dawarich/features/tracking/domain/models/location_fix.dart';

/// Immobile : le fournisseur de position ne calcule qu'au ralenti.
/// En mouvement : cadence normale.
enum MotionMode { still, moving }

/// Ce que le flux doit faire après un événement.
final class TrackingDecision {
  const TrackingDecision({this.record = false, this.needFreshFix = false, this.switchTo});

  /// Enregistrer la position fournie (ou la dernière connue).
  final bool record;

  /// Aucune position assez récente : en demander une active (`getCurrent`).
  final bool needFreshFix;

  /// Changer la requête de localisation (cadence, filtre de distance).
  final MotionMode? switchTo;

  static const none = TrackingDecision();

  @override
  String toString() => 'TrackingDecision(record: $record, needFreshFix: $needFreshFix, switchTo: $switchTo)';
}

/// Décide quand enregistrer un point et quand changer de cadence, pour que le
/// GPS travaille le moins possible quand le téléphone ne bouge pas.
///
/// Logique pure (horloge et distance injectées) : testable sans appareil.
final class AdaptiveTrackingPolicy {
  AdaptiveTrackingPolicy({
    required this.distance,
    this.stillRadiusMeters = 50,
    this.stillHeartbeat = const Duration(minutes: 15),
    this.stillAfter = const Duration(minutes: 3),
    this.movingInterval = const Duration(seconds: 10),
    this.maxFixAge = const Duration(seconds: 60),
    this.freshFixRetry = const Duration(seconds: 60),
    this.deliverySlack = const Duration(seconds: 30),
    this.stillFallbackGrace = const Duration(seconds: 90),
    this.maxHeartbeatsWithoutFix = 3,
    this.maxQuietHeartbeats = 3,
    this.maxMovementThresholdMeters = 150,
    this.nightHeartbeat,
    this.isNight,
  });

  /// Immobile, la nuit : période du point « toujours là » (null = comme le jour).
  final Duration? nightHeartbeat;

  /// Dit si [now] tombe dans la nuit (null = jamais).
  final bool Function(DateTime now)? isNight;

  Duration _heartbeat(DateTime now) {
    final night = nightHeartbeat;
    return night != null && (isNight?.call(now) ?? false) ? night : stillHeartbeat;
  }

  /// Distance en mètres entre deux positions.
  final double Function(LocationFix a, LocationFix b) distance;

  /// En deçà, un écart est de la gigue (Wi-Fi, antennes), pas un déplacement.
  final double stillRadiusMeters;

  /// Immobile : un point « toujours là » par période.
  final Duration stillHeartbeat;

  /// En mouvement depuis plus longtemps que ça sans bouger : retour en immobile.
  final Duration stillAfter;

  /// En mouvement : au plus un point par intervalle.
  final Duration movingInterval;

  /// Une position plus vieille n'est pas réutilisée pour un point.
  final Duration maxFixAge;

  /// Délai minimal entre deux demandes de position active.
  final Duration freshFixRetry;

  /// Immobile : le fournisseur livre une position toutes les [stillHeartbeat] ;
  /// une livraison un peu en avance compte quand même comme point dû.
  final Duration deliverySlack;

  /// Immobile : si le fournisseur n'a rien livré [stillHeartbeat] + ce délai après
  /// le dernier point, on demande une position active (secours).
  final Duration stillFallbackGrace;

  /// Immobile : nombre maximal de points « toujours là » consécutifs enregistrés avec la
  /// dernière position connue quand aucune position n'est obtenable (téléphone posé,
  /// veille profonde). Au-delà, on s'arrête plutôt que d'afficher une position périmée.
  final int maxHeartbeatsWithoutFix;

  /// Immobile avec le capteur de mouvement : nombre maximal de points « toujours là »
  /// consécutifs repris sans aucune recherche de position (le capteur n'a rien vu bouger).
  /// Le suivant est une vraie position, qui borne l'erreur si le capteur a manqué un départ.
  final int maxQuietHeartbeats;

  /// Plafond du seuil de déplacement adaptatif (voir [_moved]).
  final double maxMovementThresholdMeters;

  /// Un écart n'est un déplacement que s'il dépasse l'incertitude des deux positions
  /// (la position réseau saute de plusieurs dizaines de mètres sans que l'on bouge).
  /// Seuil : au moins [stillRadiusMeters], au plus [maxMovementThresholdMeters].
  bool _moved(LocationFix a, LocationFix b) {
    final uncertainty = a.hAccuracyMeters + b.hAccuracyMeters;
    final threshold = uncertainty.clamp(stillRadiusMeters, maxMovementThresholdMeters).toDouble();
    return distance(a, b) >= threshold;
  }

  MotionMode mode = MotionMode.still;
  LocationFix? _lastRecordedFix;
  DateTime? _lastRecordedAt;
  DateTime? _lastMoveAt;
  DateTime? _lastFreshFixRequestAt;
  int _heartbeatsWithoutFix = 0;
  int _quietStreak = 0;

  /// Une vraie position est exigée avant le prochain point sans recherche : au
  /// démarrage, après un mouvement détecté et à chaque changement de mode.
  bool _needRealFix = true;

  DateTime? get lastRecordedAt => _lastRecordedAt;
  LocationFix? get lastRecordedFix => _lastRecordedFix;
  int get heartbeatsWithoutFix => _heartbeatsWithoutFix;

  /// Position livrée par le flux (filtrée par distance côté fournisseur).
  TrackingDecision onFix(LocationFix fix, DateTime now) {
    final last = _lastRecordedFix;
    if (last == null) return const TrackingDecision(record: true);

    final moved = _moved(last, fix);

    switch (mode) {
      case MotionMode.still:
        if (!moved) {
          // Livraison périodique du fournisseur : c'est le point « toujours là ».
          final lastAt = _lastRecordedAt;
          final due = lastAt == null || now.difference(lastAt) >= _heartbeat(now) - deliverySlack;
          return TrackingDecision(record: due);
        }
        _lastMoveAt = now;
        return const TrackingDecision(record: true, switchTo: MotionMode.moving);
      case MotionMode.moving:
        if (moved) _lastMoveAt = now;
        final lastAt = _lastRecordedAt;
        final due = lastAt == null || now.difference(lastAt) >= movingInterval;
        return TrackingDecision(record: moved && due);
    }
  }

  /// Tick du minuteur, avec la dernière position connue du flux.
  TrackingDecision onTick(LocationFix? latest, DateTime now) {
    MotionMode? switchTo;
    if (mode == MotionMode.moving) {
      final lastMove = _lastMoveAt ?? _lastRecordedAt;
      if (lastMove != null && now.difference(lastMove) >= stillAfter) {
        switchTo = MotionMode.still;
      }
    }

    final lastAt = _lastRecordedAt;
    // Immobile : le point dû arrive normalement par le fournisseur ; le minuteur
    // n'est qu'un secours s'il n'a rien livré.
    final period = mode == MotionMode.moving && switchTo == null
        ? stillAfter
        : _heartbeat(now) + stillFallbackGrace;
    final due = lastAt == null || now.difference(lastAt) >= period;
    if (!due) return TrackingDecision(switchTo: switchTo);

    if (latest != null && now.difference(latest.timestampUtc) <= maxFixAge) {
      return TrackingDecision(record: true, switchTo: switchTo);
    }

    final lastRequest = _lastFreshFixRequestAt;
    if (lastRequest != null && now.difference(lastRequest) < freshFixRetry) {
      return TrackingDecision(switchTo: switchTo);
    }
    _lastFreshFixRequestAt = now;
    return TrackingDecision(needFreshFix: true, switchTo: switchTo);
  }

  /// Position obtenue après [TrackingDecision.needFreshFix] : c'est un point dû.
  TrackingDecision onFreshFix(LocationFix fix, DateTime now) {
    final last = _lastRecordedFix;
    if (mode == MotionMode.still && last != null && _moved(last, fix)) {
      _lastMoveAt = now;
      return const TrackingDecision(record: true, switchTo: MotionMode.moving);
    }
    return const TrackingDecision(record: true);
  }

  /// La position active a échoué. Immobile, on enregistre quand même un point avec la
  /// dernière position connue (le téléphone n'a pas bougé) : plus de trou sur la carte,
  /// et plus de nouvelle recherche active avant la prochaine échéance.
  TrackingDecision onFreshFixFailed() {
    if (mode != MotionMode.still ||
        _lastRecordedFix == null ||
        _heartbeatsWithoutFix >= maxHeartbeatsWithoutFix) {
      return TrackingDecision.none;
    }
    return const TrackingDecision(record: true);
  }

  /// Le capteur de mouvement significatif s'est déclenché à l'arrêt : on repart en
  /// mouvement sans attendre de position. Fausse alerte : retour en immobile après
  /// [stillAfter] sans déplacement, comme d'habitude.
  TrackingDecision onMotion(DateTime now) {
    _needRealFix = true;
    if (mode == MotionMode.moving) return TrackingDecision.none;
    _lastMoveAt = now;
    return const TrackingDecision(switchTo: MotionMode.moving);
  }

  /// Immobile : temps restant avant le prochain point « toujours là », pour
  /// programmer l'alarme qui réveillera le téléphone. Zéro s'il est déjà dû.
  Duration untilHeartbeatDue(DateTime now) {
    final lastAt = _lastRecordedAt;
    if (lastAt == null) return Duration.zero;
    final left = lastAt.add(_heartbeat(now) + stillFallbackGrace).difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  int get quietStreak => _quietStreak;

  /// Immobile : le point « toujours là » dû peut-il reprendre la dernière position
  /// enregistrée, sans rien demander au téléphone ? Oui si le capteur de mouvement
  /// ([motionWatched]) veille et n'a rien signalé depuis la dernière vraie position,
  /// dans la limite de [maxQuietHeartbeats] points d'affilée.
  bool quietHeartbeatAllowed({required bool motionWatched}) =>
      motionWatched &&
      mode == MotionMode.still &&
      _lastRecordedFix != null &&
      !_needRealFix &&
      _quietStreak < maxQuietHeartbeats;

  /// Le point a bien été créé. [withoutFix] : point de repli sans nouvelle position.
  /// [quiet] : point repris sans recherche (voir [quietHeartbeatAllowed]).
  void recorded(LocationFix fix, DateTime now, {bool withoutFix = false, bool quiet = false}) {
    if (quiet) {
      _quietStreak++;
    } else if (!withoutFix) {
      _quietStreak = 0;
      _needRealFix = false;
    }
    _lastRecordedFix = fix;
    _lastRecordedAt = now;
    _heartbeatsWithoutFix = withoutFix ? _heartbeatsWithoutFix + 1 : 0;
  }

  void switched(MotionMode to, DateTime now) {
    mode = to;
    _needRealFix = true;
    if (to == MotionMode.moving) _lastMoveAt = now;
  }
}
