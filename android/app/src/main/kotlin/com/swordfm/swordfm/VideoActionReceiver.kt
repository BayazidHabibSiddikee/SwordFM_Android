package com.swordfm.swordfm

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class VideoActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != null) {
            MainActivity.videoActionChannel?.invokeMethod("onVideoAction", action)
            
            if (action == VideoForegroundService.ACTION_STOP) {
                val stopIntent = Intent(context, VideoForegroundService::class.java).apply {
                    this.action = VideoForegroundService.ACTION_STOP
                }
                context.startService(stopIntent)
            }
        }
    }
}
