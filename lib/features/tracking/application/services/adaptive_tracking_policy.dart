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
    this.stillRadiusMeters = 25,
    this.stillHeartbeat = const Duration(minutes: 5),
    this.stillAfter = const Duration(minutes: 3),
    this.movingInterval = const Duration(seconds: 10),
    this.maxFixAge = const Duration(seconds: 60),
    this.freshFixRetry = const Duration(seconds: 60),
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

  MotionMode mode = MotionMode.still;
  LocationFix? _lastRecordedFix;
  DateTime? _lastRecordedAt;
  DateTime? _lastMoveAt;
  DateTime? _lastFreshFixRequestAt;

  DateTime? get lastRecordedAt => _lastRecordedAt;

  /// Position livrée par le flux (filtrée par distance côté fournisseur).
  TrackingDecision onFix(LocationFix fix, DateTime now) {
    final last = _lastRecordedFix;
    if (last == null) return const TrackingDecision(record: true);

    final moved = distance(last, fix) >= stillRadiusMeters;

    switch (mode) {
      case MotionMode.still:
        if (!moved) return TrackingDecision.none;
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
    final period = mode == MotionMode.moving && switchTo == null ? stillAfter : stillHeartbeat;
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
    if (mode == MotionMode.still && last != null && distance(last, fix) >= stillRadiusMeters) {
      _lastMoveAt = now;
      return const TrackingDecision(record: true, switchTo: MotionMode.moving);
    }
    return const TrackingDecision(record: true);
  }

  /// Le point a bien été créé.
  void recorded(LocationFix fix, DateTime now) {
    _lastRecordedFix = fix;
    _lastRecordedAt = now;
  }

  void switched(MotionMode to, DateTime now) {
    mode = to;
    if (to == MotionMode.moving) _lastMoveAt = now;
  }
}
