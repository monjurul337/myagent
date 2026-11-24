package com.geminihd.studio

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import org.mozilla.gecko.GeckoThread

/**
 * Foreground service that keeps the app alive while a generation
 * runs (v33): the user can turn the screen off or switch to other
 * apps and the work continues in the background. The service does
 * no work itself — generation stays in the Flutter engine; the
 * service only holds foreground priority plus a partial wake
 * lock, and shows the ongoing notification Android requires.
 *
 * v72: also holds a Wi-Fi lock — on many phones Wi-Fi sleeps
 * when the screen locks, which drops the Gemini connection even
 * with the wake lock held.
 */
class GenerationService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    // v169 — keep Gecko running with the screen off. GeckoRuntime
    // listens to ProcessLifecycleOwner and, the moment the app is
    // no longer in the foreground (screen off / other app), calls
    // GeckoThread.onPause() — Gecko then runs in "application-
    // background" mode and stops watching the network, so the
    // headless Gemini page that renders the video stalls. While a
    // generation runs (this service), the pause is cancelled right
    // after it happens (GeckoThread.onResume()) and re-applied when
    // the app comes back, so Gecko's pause counter stays balanced.
    private val main = Handler(Looper.getMainLooper())
    private var geckoPauseCancelled = false
    private var lifecycleObserver: DefaultLifecycleObserver? = null

    private fun registerGeckoKeepRunning() {
        if (lifecycleObserver != null) return
        val obs = object : DefaultLifecycleObserver {
            override fun onPause(owner: LifecycleOwner) {
                main.post {
                    if (geckoPauseCancelled || !GeckoBridge.hasRuntime()) return@post
                    try {
                        GeckoThread.onResume()
                        geckoPauseCancelled = true
                        Log.i(TAG, "Gecko pause cancelled (generation running)")
                    } catch (e: Throwable) {
                        Log.w(TAG, "Gecko keep-running failed: $e")
                    }
                }
            }

            override fun onResume(owner: LifecycleOwner) {
                main.post { restoreGeckoPause() }
            }
        }
        lifecycleObserver = obs
        try {
            ProcessLifecycleOwner.get().lifecycle.addObserver(obs)
        } catch (e: Throwable) {
            Log.w(TAG, "lifecycle observer failed: $e")
            lifecycleObserver = null
        }
    }

    /** Re-applies the pause we cancelled so Gecko's counter is back
     *  to what its own lifecycle listener expects. */
    private fun restoreGeckoPause() {
        if (!geckoPauseCancelled) return
        geckoPauseCancelled = false
        try {
            GeckoThread.onPause()
        } catch (e: Throwable) {
            Log.w(TAG, "Gecko pause restore failed: $e")
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val label = intent?.getStringExtra(EXTRA_LABEL) ?: DEFAULT_LABEL
        val notification = buildNotification(label)
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                NOTIF_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(NOTIF_ID, notification)
        }
        holdWakeLock()
        holdWifiLock()
        registerGeckoKeepRunning()
        // Not sticky: the service lives only while Dart asks for
        // it; if the process dies, the service must not resurrect
        // a stale "generating" notification on its own.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        lifecycleObserver?.let {
            try {
                ProcessLifecycleOwner.get().lifecycle.removeObserver(it)
            } catch (_: Throwable) {
            }
        }
        lifecycleObserver = null
        // The generation is over: if the app is still in the
        // background, Gecko goes back to its normal paused state.
        restoreGeckoPause()
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        wifiLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
        super.onDestroy()
    }

    private fun holdWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK, "GeminiHDStudio:Generation"
        ).apply {
            setReferenceCounted(false)
            // Timed as a safety net: even if a stop call were ever
            // missed, the lock lets go on its own.
            acquire(MAX_WAKE_MS)
        }
    }

    private fun holdWifiLock() {
        if (wifiLock?.isHeld == true) return
        try {
            val wm = applicationContext
                .getSystemService(Context.WIFI_SERVICE) as WifiManager
            wifiLock = wm.createWifiLock(
                WifiManager.WIFI_MODE_FULL_LOW_LATENCY,
                "GeminiHDStudio:Generation"
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: Throwable) {
            // Wi-Fi lock is a best effort: mobile data or a
            // missing radio must never break the service.
            wifiLock = null
        }
    }

    private fun buildNotification(label: String): Notification {
        val nm =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26 &&
            nm.getNotificationChannel(CHANNEL_ID) == null
        ) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Background generation",
                    NotificationManager.IMPORTANCE_LOW
                )
            )
        }
        val launchIntent = Intent(this, MainActivity::class.java)
        val pending = PendingIntent.getActivity(
            this, 0, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("Zedge Studio")
            .setContentText(label)
            .setContentIntent(pending)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val TAG = "GenerationService"
        const val EXTRA_LABEL = "label"
        private const val DEFAULT_LABEL = "Generating in the background"
        private const val CHANNEL_ID = "generation"
        private const val NOTIF_ID = 4211
        private const val MAX_WAKE_MS = 12L * 60L * 60L * 1000L
    }
}
