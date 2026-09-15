package com.swordfm.swordfm

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

class VideoForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "VideoPlaybackChannel"
        const val NOTIFICATION_ID = 1002
        const val ACTION_PLAY = "com.swordfm.swordfm.PLAY"
        const val ACTION_PAUSE = "com.swordfm.swordfm.PAUSE"
        const val ACTION_STOP = "com.swordfm.swordfm.STOP"
        
        var isPlaying = false
        var videoTitle = "Playing Video"
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        if (action == ACTION_STOP) {
            stopForeground(true)
            stopSelf()
            return START_NOT_STICKY
        }

        intent?.getStringExtra("title")?.let {
            videoTitle = it
        }
        isPlaying = intent?.getBooleanExtra("isPlaying", isPlaying) ?: isPlaying

        startForeground(NOTIFICATION_ID, buildNotification())

        return START_NOT_STICKY
    }

    private fun buildNotification(): Notification {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val playPauseAction = if (isPlaying) ACTION_PAUSE else ACTION_PLAY
        val playPauseTitle = if (isPlaying) "Pause" else "Play"
        
        val playPauseBroadcast = Intent(this, VideoActionReceiver::class.java).apply {
            action = playPauseAction
        }
        val playPausePending = PendingIntent.getBroadcast(
            this, 1, playPauseBroadcast, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        
        val stopBroadcast = Intent(this, VideoActionReceiver::class.java).apply {
            action = ACTION_STOP
        }
        val stopPending = PendingIntent.getBroadcast(
            this, 2, stopBroadcast, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(videoTitle)
            .setContentText("Video Playback")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentIntent(pendingIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(isPlaying)
            .addAction(if(isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play, playPauseTitle, playPausePending)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop", stopPending)
            .setStyle(androidx.media.app.NotificationCompat.MediaStyle().setShowActionsInCompactView(0, 1))

        return builder.build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Video Playback",
                NotificationManager.IMPORTANCE_LOW
            )
            channel.description = "Controls for background video playback"
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
