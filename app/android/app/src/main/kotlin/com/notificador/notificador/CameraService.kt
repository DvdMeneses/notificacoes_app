package com.notificador.notificador

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/// Serviço em primeiro plano que mantém a câmera ativa, mesmo com o app fechado.
/// O Android exige a notificação fixa enquanto a câmera estiver em uso, e ela
/// tem o botão "Parar câmera" para desligar a qualquer momento.
class CameraService : Service() {

    private var title = ""
    private var textTemplate = ""

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> startCamera(intent)
            ACTION_STOP -> stopCamera()
            ACTION_SWITCH -> session?.switchCamera()
        }
        // Não reinicia sozinho se o sistema matar o serviço: quem liga é o usuário.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        session?.stop()
        session = null
        running = false
        super.onDestroy()
    }

    private fun startCamera(intent: Intent) {
        val groupCode = intent.getStringExtra(EXTRA_GROUP) ?: return stopSelf()
        val deviceId = intent.getStringExtra(EXTRA_DEVICE) ?: return stopSelf()
        val facing = intent.getStringExtra(EXTRA_FACING) ?: "environment"
        title = intent.getStringExtra(EXTRA_TITLE) ?: "Câmera em uso"
        textTemplate = intent.getStringExtra(EXTRA_TEXT) ?: ""

        createChannel()
        ServiceCompat.startForeground(
            this,
            NOTIFICATION_ID,
            buildNotification(facing),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
        )

        session?.stop()
        session = CameraSession(applicationContext, groupCode, deviceId) { newFacing ->
            prefs().edit().putString(PREF_FACING, newFacing).apply()
            getSystemService(NotificationManager::class.java)
                .notify(NOTIFICATION_ID, buildNotification(newFacing))
        }
        try {
            session?.start(facing)
            running = true
            prefs().edit().putBoolean(PREF_CAMERA_MODE, true).apply()
        } catch (e: Exception) {
            // Sem câmera ou sem permissão: não deixa a notificação de "ativa" parada.
            stopCamera()
        }
    }

    private fun stopCamera() {
        session?.stop()
        session = null
        running = false
        prefs().edit().putBoolean(PREF_CAMERA_MODE, false).apply()
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun buildNotification(facing: String): Notification {
        val label = if (facing == "user") "frontal" else "traseira"
        val stopIntent = Intent(this, CameraService::class.java).setAction(ACTION_STOP)
        val stopPending = PendingIntent.getService(
            this, 0, stopIntent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val openPending = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(this, 1, it, PendingIntent.FLAG_IMMUTABLE)
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setContentTitle(title)
            .setContentText(textTemplate.replace("{facing}", label))
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(openPending)
            .build()
    }

    private fun createChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID, "Câmera ativa", NotificationManager.IMPORTANCE_LOW
        ).apply { description = "Aviso fixo enquanto a câmera está sendo coletada." }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun prefs() = getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)

    companion object {
        const val ACTION_START = "com.notificador.notificador.camera.START"
        const val ACTION_STOP = "com.notificador.notificador.camera.STOP"
        const val ACTION_SWITCH = "com.notificador.notificador.camera.SWITCH"

        const val EXTRA_GROUP = "groupCode"
        const val EXTRA_DEVICE = "deviceId"
        const val EXTRA_FACING = "facing"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"

        // Mesmo arquivo e prefixo que o shared_preferences do Flutter usa.
        const val PREFS_FILE = "FlutterSharedPreferences"
        const val PREF_CAMERA_MODE = "flutter.cameraMode"
        const val PREF_FACING = "flutter.cameraFacing"

        const val CHANNEL_ID = "camera_monitor"
        const val NOTIFICATION_ID = 512

        @Volatile
        var running = false

        var session: CameraSession? = null
    }
}
