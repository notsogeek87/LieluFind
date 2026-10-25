import 'package:dawarich/features/tracking/application/repositories/device_power_interface.dart';
import 'package:lielu_power/lielu_power.dart';

/// [IDevicePower] via le plugin natif lielu_power (Android).
final class DevicePower implements IDevicePower {
  const DevicePower([this._plugin = const LieluPower()]);

  final LieluPower _plugin;

  @override
  Future<int> releaseServiceWakeLock() => _plugin.releaseServiceWakeLock();

  @override
  Future<bool> scheduleWake(Duration delay) => _plugin.scheduleWake(delay);

  @override
  Future<void> cancelWake() => _plugin.cancelWake();

  @override
  Future<bool> watchMotion(bool enabled) => _plugin.watchMotion(enabled);

  @override
  Stream<DeviceWake> get wakes => _plugin.wakes.map(
        (w) => switch (w) {
          LieluWakeReason.alarm => DeviceWake.alarm,
          LieluWakeReason.motion => DeviceWake.motion,
        },
      );
}
