import 'dart:async';

/// Délais de réessai : rapides au début, puis plafonnés. Jamais d'abandon
/// définitif : une permission, le GPS ou la session peuvent revenir.
const List<Duration> kRecoveryBackoff = [
  Duration(seconds: 5),
  Duration(seconds: 15),
  Duration(seconds: 45),
  Duration(minutes: 2),
  Duration(minutes: 5),
];

/// Au-delà de [kRecoveryBackoff], on réessaie à ce rythme lent.
const Duration kSlowRecoveryDelay = Duration(minutes: 10);

Duration recoveryDelay(int attempt, {List<Duration> steps = kRecoveryBackoff, Duration slow = kSlowRecoveryDelay}) {
  if (attempt <= 0) return Duration.zero;
  if (attempt <= steps.length) return steps[attempt - 1];
  return slow;
}

/// Ce que le flux de localisation signale au superviseur.
abstract interface class TrackingHealthSink {
  /// Une position a été reçue du flux ou de `getCurrent`.
  void onFix();

  /// Le minuteur du flux a tourné (même si aucun point n'a été créé :
  /// un téléphone immobile n'émet rien, ce n'est pas une panne).
  void onTick();

  /// Un point a été créé puis enregistré localement.
  void onPoint();

  /// Erreur du fournisseur de localisation (GPS coupé, permission retirée…).
  void onStreamError(Object error);

  /// Le flux s'est terminé alors qu'il ne devrait jamais le faire.
  void onStreamDone();
}

/// Pourquoi le superviseur juge le suivi en panne.
enum HealthIssue { streamDone, streamError, timerSilent, noPoint, neverStarted }

/// Surveille la santé *réelle* du suivi (flux, minuteur, points) et le relance
/// avec temporisation progressive. Une seule récupération à la fois.
final class TrackingSupervisor implements TrackingHealthSink {
  TrackingSupervisor({
    required this.startStream,
    required this.stopStream,
    required this.blockedReason,
    required this.log,
    this.now = DateTime.now,
    this.tickInterval = const Duration(seconds: 10),
    this.maxPointGap = const Duration(minutes: 22),
    this.startupGrace = const Duration(seconds: 90),
    this.stableAfter = const Duration(minutes: 2),
  });

  /// (Ré)abonne le flux de localisation.
  final Future<void> Function() startStream;

  /// Annule le flux courant, sans lever d'exception.
  final Future<void> Function() stopStream;

  /// `null` si le suivi est possible ; sinon la raison (permission, GPS, session).
  final Future<String?> Function() blockedReason;

  final void Function(String message) log;
  final DateTime Function() now;

  /// Cadence du minuteur du flux (réglage de fréquence).
  final Duration tickInterval;

  /// Silence maximal tolérable sans point : le rythme « immobile » est un point
  /// toutes les 15 min, plus le temps d'une position active ratée.
  final Duration maxPointGap;

  /// Délai laissé à un flux fraîchement (ré)abonné pour produire un premier signe de vie.
  final Duration startupGrace;

  /// Durée de bonne santé après laquelle les tentatives repartent de zéro.
  final Duration stableAfter;

  DateTime? _startedAt;
  DateTime? _lastTick;
  DateTime? _lastPoint;
  DateTime? _lastFix;
  DateTime? _nextAttemptAt;
  Object? _pendingError;
  bool _streamDone = false;
  bool _recovering = false;
  String? _lastBlocked;
  int _attempts = 0;

  int get attempts => _attempts;
  bool get recovering => _recovering;
  DateTime? get lastPointAt => _lastPoint;
  DateTime? get lastFixAt => _lastFix;

  /// À appeler dès que le flux vient d'être (ré)abonné.
  void markStarted() {
    final t = now();
    _startedAt = t;
    _lastTick = null;
    _streamDone = false;
    _pendingError = null;
  }

  @override
  void onFix() => _lastFix = now();

  @override
  void onTick() => _lastTick = now();

  @override
  void onPoint() {
    _lastPoint = now();
    _lastTick = _lastPoint;
  }

  @override
  void onStreamError(Object error) => _pendingError = error;

  @override
  void onStreamDone() => _streamDone = true;

  /// Verdict de santé, sans effet de bord.
  HealthIssue? evaluate() {
    final t = now();
    final started = _startedAt;
    if (started == null) return null;

    if (_streamDone) return HealthIssue.streamDone;
    if (_pendingError != null) return HealthIssue.streamError;

    final lastSign = _lastTick ?? _lastPoint;
    if (lastSign == null) {
      return t.difference(started) > startupGrace ? HealthIssue.neverStarted : null;
    }
    if (t.difference(lastSign) > tickInterval * 3 + const Duration(seconds: 30)) {
      return HealthIssue.timerSilent;
    }

    final lastPointOrStart = _lastPoint ?? started;
    if (t.difference(lastPointOrStart) > maxPointGap) return HealthIssue.noPoint;

    return null;
  }

  /// Une évaluation du watchdog : sans effet si tout va bien ou si une
  /// récupération est déjà en cours.
  Future<void> check() async {
    if (_recovering) return;

    final issue = evaluate();
    final t = now();

    if (issue == null) {
      // Le compteur ne repart de zéro qu'après une période stable (minuteur
      // vivant, aucune erreur) : un flux instable ne doit pas être relancé en
      // boucle serrée. Un téléphone immobile ne produit un point que toutes les 5 min.
      final started = _startedAt;
      if (_attempts > 0 && started != null && _lastTick != null && t.difference(started) > stableAfter) {
        _attempts = 0;
      }
      return;
    }

    final next = _nextAttemptAt;
    if (next != null && t.isBefore(next)) return;

    _recovering = true;
    try {
      final blocked = await blockedReason();
      if (blocked != null) {
        if (blocked != _lastBlocked) log('Suivi bloqué ($blocked), nouvel essai dans 30 s');
        _lastBlocked = blocked;
        _nextAttemptAt = now().add(const Duration(seconds: 30));
        return;
      }
      if (_lastBlocked != null) {
        log('Blocage levé ($_lastBlocked)');
        _lastBlocked = null;
      }

      _attempts++;
      final delay = recoveryDelay(_attempts);
      log('Panne détectée : ${issue.name} → relance #$_attempts'
          '${_attempts > kRecoveryBackoff.length ? ' (rythme lent)' : ''}');

      try {
        await stopStream();
        await startStream();
        markStarted();
      } catch (e) {
        log('Relance échouée : $e');
      }
      _nextAttemptAt = now().add(delay);
    } finally {
      _recovering = false;
    }
  }
}

/// Exécute une tâche à la fois. Une tâche bloquée plus de [stuckAfter] est
/// abandonnée pour que la suivante puisse passer (écriture locale ou envoi qui ne revient jamais).
final class SingleFlightGuard {
  SingleFlightGuard({required this.stuckAfter, DateTime Function()? now}) : _now = now ?? DateTime.now;

  final Duration stuckAfter;
  final DateTime Function() _now;
  DateTime? _busySince;
  int _generation = 0;

  bool get busy => _busySince != null;

  /// Retourne `false` si une autre tâche tourne encore (et n'est pas bloquée).
  Future<bool> run(Future<void> Function() job, {void Function(String)? onStuck}) async {
    final since = _busySince;
    if (since != null) {
      if (_now().difference(since) <= stuckAfter) return false;
      onStuck?.call('tâche bloquée depuis ${_now().difference(since).inSeconds} s, libérée');
    }

    final gen = ++_generation;
    _busySince = _now();
    try {
      await job().timeout(stuckAfter);
    } finally {
      if (gen == _generation) _busySince = null;
    }
    return true;
  }
}

/// Réessaie [attempt] jusqu'à obtenir une valeur non nulle, avec [recoveryDelay]
/// entre chaque essai. S'arrête si [shouldStop] devient vrai.
Future<T?> retryUntilAvailable<T>(
  Future<T?> Function(int attempt) attempt, {
  required Future<void> Function(Duration) sleep,
  bool Function()? shouldStop,
  void Function(int attempt, Object? error)? onFailure,
}) async {
  var n = 0;
  while (true) {
    if (shouldStop?.call() ?? false) return null;
    n++;
    try {
      final value = await attempt(n);
      if (value != null) return value;
      onFailure?.call(n, null);
    } catch (e) {
      onFailure?.call(n, e);
    }
    await sleep(recoveryDelay(n));
  }
}
