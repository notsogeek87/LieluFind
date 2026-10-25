import 'package:flutter/services.dart';

/// Pourquoi le téléphone vient de réveiller l'app.
enum LieluWakeReason { alarm, motion }

/// Accès au plugin natif (Android). Sur les autres plateformes, chaque appel lève
/// une [MissingPluginException] : à l'appelant de prévoir un repli.
final class LieluPower {
  const LieluPower();

  static const MethodChannel _methods = MethodChannel('lielu_power');
  static const EventChannel _events = EventChannel('lielu_power/events');

  /// Relâche le wakelock permanent de flutter_background_service.
  /// Retourne le nombre de références relâchées (-1 : champ introuvable).
  Future<int> releaseServiceWakeLock() async =>
      await _methods.invokeMethod<int>('releaseServiceWakeLock') ?? 0;

  /// Programme (ou remplace) l'alarme de réveil. Retourne vrai si elle est exacte.
  Future<bool> scheduleWake(Duration delay) async =>
      await _methods.invokeMethod<bool>('scheduleWake', {'delayMs': delay.inMilliseconds}) ?? false;

  Future<void> cancelWake() => _methods.invokeMethod<void>('cancelWake');

  /// Arme (ou désarme) le capteur de mouvement significatif, à déclenchement unique.
  /// Retourne faux si le téléphone n'en a pas.
  Future<bool> watchMotion(bool enabled) async =>
      await _methods.invokeMethod<bool>('watchMotion', {'enabled': enabled}) ?? false;

  /// Relâche plus tôt le wakelock court pris au réveil.
  Future<void> releaseWake() => _methods.invokeMethod<void>('releaseWake');

  /// Réveils : alarme ou mouvement.
  Stream<LieluWakeReason> get wakes => _events.receiveBroadcastStream().map(
        (e) => e == 'motion' ? LieluWakeReason.motion : LieluWakeReason.alarm,
      );
}
