# Lu par réflexion (LieluPowerPlugin.releaseServiceWakeLock).
-keepclassmembers class id.flutter.flutter_background_service.BackgroundService {
    public static volatile android.os.PowerManager$WakeLock lockStatic;
}
