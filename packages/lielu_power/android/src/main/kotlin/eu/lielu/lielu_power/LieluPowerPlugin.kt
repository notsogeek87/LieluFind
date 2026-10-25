package eu.lielu.lielu_power

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.hardware.Sensor
import android.hardware.SensorManager
import android.hardware.TriggerEvent
import android.hardware.TriggerEventListener
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Laisse le téléphone dormir quand il ne bouge pas, comme Traccar :
 * - une alarme réveille l'app pour le point « toujours là » ;
 * - le capteur de mouvement significatif (matériel, sans services Google) signale un départ ;
 * - chaque réveil tient le CPU au plus [WAKE_HOLD_MS], le temps d'une position et d'un envoi.
 *
 * Le plugin est attaché à chaque moteur Flutter (interface et service de fond) ;
 * les événements partent vers tous ceux qui écoutent.
 */
class LieluPowerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private lateinit var context: Context
    private var methods: MethodChannel? = null
    private var events: EventChannel? = null
    private var sink: EventChannel.EventSink? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "lielu_power").also { it.setMethodCallHandler(this) }
        events = EventChannel(binding.binaryMessenger, "lielu_power/events").also { it.setStreamHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods?.setMethodCallHandler(null)
        events?.setStreamHandler(null)
        methods = null
        events = null
        onCancel(null)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        synchronized(listeners) { listeners.add(this) }
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        synchronized(listeners) { listeners.remove(this) }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "releaseServiceWakeLock" -> result.success(releaseServiceWakeLock())
                "scheduleWake" -> {
                    val delayMs = (call.argument<Number>("delayMs") ?: 0).toLong()
                    result.success(scheduleWake(context, delayMs))
                }
                "cancelWake" -> {
                    cancelWake(context)
                    result.success(null)
                }
                "watchMotion" -> result.success(watchMotion(context, call.argument<Boolean>("enabled") == true))
                "releaseWake" -> {
                    releaseWake()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("lielu_power", e.toString(), null)
        }
    }

    internal companion object {
        private const val TAG = "LieluPower"
        private const val WAKE_HOLD_MS = 60_000L
        private const val ALARM_REQUEST_CODE = 0x4C46

        private val listeners = mutableSetOf<LieluPowerPlugin>()
        private val mainHandler = Handler(Looper.getMainLooper())
        private var wakeLock: PowerManager.WakeLock? = null
        @Volatile private var motionListener: TriggerEventListener? = null

        /** Réveil (alarme ou mouvement) : CPU tenu un court instant, puis signal au Dart. */
        fun wake(context: Context, reason: String) {
            acquireWake(context)
            mainHandler.post {
                val targets = synchronized(listeners) { listeners.toList() }
                targets.forEach { it.sink?.success(reason) }
            }
        }

        @Synchronized
        private fun acquireWake(context: Context) {
            val lock = wakeLock ?: (context.applicationContext.getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "lielufind:wake")
                .also {
                    it.setReferenceCounted(false)
                    wakeLock = it
                }
            lock.acquire(WAKE_HOLD_MS)
        }

        @Synchronized
        private fun releaseWake() {
            wakeLock?.let { if (it.isHeld) it.release() }
        }

        /**
         * flutter_background_service prend un wakelock sans délai au démarrage du service et ne le
         * relâche jamais : le téléphone ne peut plus dormir. On le relâche (compté par référence).
         * Retourne le nombre de références relâchées, ou -1 si le champ est introuvable.
         */
        private fun releaseServiceWakeLock(): Int {
            val lock = try {
                Class.forName("id.flutter.flutter_background_service.BackgroundService")
                    .getField("lockStatic")
                    .get(null) as? PowerManager.WakeLock
            } catch (e: Exception) {
                Log.w(TAG, "Wakelock du service introuvable : $e")
                return -1
            } ?: return 0
            var released = 0
            synchronized(lock) {
                while (lock.isHeld && released < 64) {
                    lock.release()
                    released++
                }
            }
            return released
        }

        /** Retourne vrai si l'alarme est exacte (sinon Android peut la retarder un peu). */
        private fun scheduleWake(context: Context, delayMs: Long): Boolean {
            val alarms = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val at = SystemClock.elapsedRealtime() + delayMs.coerceAtLeast(0)
            val exact = Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarms.canScheduleExactAlarms()
            if (exact) {
                alarms.setExactAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, alarmIntent(context))
            } else {
                alarms.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, alarmIntent(context))
            }
            return exact
        }

        private fun cancelWake(context: Context) {
            val alarms = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            alarms.cancel(alarmIntent(context))
        }

        private fun alarmIntent(context: Context): PendingIntent = PendingIntent.getBroadcast(
            context.applicationContext,
            ALARM_REQUEST_CODE,
            Intent(context.applicationContext, WakeAlarmReceiver::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        /**
         * Capteur à déclenchement unique : réarmé à chaque appel avec [enabled] vrai.
         * Retourne faux si le téléphone n'en a pas.
         */
        @Synchronized
        private fun watchMotion(context: Context, enabled: Boolean): Boolean {
            val sensors = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
            val sensor = sensors.getDefaultSensor(Sensor.TYPE_SIGNIFICANT_MOTION) ?: return false
            motionListener?.let { sensors.cancelTriggerSensor(it, sensor) }
            motionListener = null
            if (!enabled) return true
            val appContext = context.applicationContext
            val listener = object : TriggerEventListener() {
                override fun onTrigger(event: TriggerEvent?) {
                    if (motionListener === this) motionListener = null
                    wake(appContext, "motion")
                }
            }
            if (!sensors.requestTriggerSensor(listener, sensor)) return false
            motionListener = listener
            return true
        }
    }
}

class WakeAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        LieluPowerPlugin.wake(context, "alarm")
    }
}
