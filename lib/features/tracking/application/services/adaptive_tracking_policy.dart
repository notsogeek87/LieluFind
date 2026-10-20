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
    // Augmenté à 50m pour réduire les faux départs dus à la gigue réseau (Wi-Fi/antennes).
    this.stillRadiusMeters = 50,
    this.stillHeartbeat = const Duration(minutes: 5),
    this.stillAfter = const Duration(minutes: 3),
    this.movingInterval = const Duration(seconds: 10),
    this.maxFixAge = const Duration(seconds: 60),
    this.freshFixRetry = const Duration(seconds: 60),
    this.deliverySlack = const Duration(seconds: 30),
    this.stillFallbackGrace = const Duration(seconds: 90),
    this.maxHeartbeatsWithoutFix = 3,
    this.maxMovementThresholdMeters = 150,
  });

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
          final due = lastAt == null || now.difference(lastAt) >= stillHeartbeat - deliverySlack;
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
        : stillHeartbeat + stillFallbackGrace;
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

  /// Le point a bien été créé. [withoutFix] : point de repli sans nouvelle position.
  void recorded(LocationFix fix, DateTime now, {bool withoutFix = false}) {
    _lastRecordedFix = fix;
    _lastRecordedAt = now;
    _heartbeatsWithoutFix = withoutFix ? _heartbeatsWithoutFix + 1 : 0;
  }

  void switched(MotionMode to, DateTime now) {
    mode = to;
    if (to == MotionMode.moving) _lastMoveAt = now;
  }
}
