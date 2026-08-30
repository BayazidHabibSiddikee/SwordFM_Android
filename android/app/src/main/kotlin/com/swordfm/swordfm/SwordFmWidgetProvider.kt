package com.swordfm.swordfm

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

class SwordFmWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (appWidgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.widget_recent).apply {
                setTextViewText(R.id.widget_title, "SwordFM")

                val prefs = context.getSharedPreferences("HomeWidgetPreferences", Context.MODE_PRIVATE)

                val recentCount = prefs.getString("recent_count", "0")?.toIntOrNull() ?: 0
                val bookmarkCount = prefs.getString("bookmark_count", "0")?.toIntOrNull() ?: 0

                val recentText = StringBuilder()
                for (i in 0 until recentCount) {
                    val data = prefs.getString("recent_$i", null) ?: continue
                    try {
                        val json = org.json.JSONObject(data)
                        val name = json.getString("name")
                        recentText.appendLine("  $name")
                    } catch (_: Exception) {}
                }
                setTextViewText(R.id.widget_recent_text,
                    if (recentText.isNotEmpty()) recentText.toString().trimEnd() else "No recent files")

                val bookmarkText = StringBuilder()
                for (i in 0 until bookmarkCount) {
                    val data = prefs.getString("bookmark_$i", null) ?: continue
                    try {
                        val json = org.json.JSONObject(data)
                        val name = json.getString("name")
                        bookmarkText.appendLine("  $name")
                    } catch (_: Exception) {}
                }
                setTextViewText(R.id.widget_bookmark_text,
                    if (bookmarkText.isNotEmpty()) bookmarkText.toString().trimEnd() else "No bookmarks")

                val intent = Intent(context, MainActivity::class.java).apply {
                    action = Intent.ACTION_MAIN
                    addCategory(Intent.CATEGORY_LAUNCHER)
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                }
                val pendingIntent = PendingIntent.getActivity(
                    context, 0, intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                setOnClickPendingIntent(R.id.widget_root, pendingIntent)
            }

            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }
}
