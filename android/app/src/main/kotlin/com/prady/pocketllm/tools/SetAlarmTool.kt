package com.prady.pocketllm.tools

import android.content.Context
import android.content.Intent
import android.provider.AlarmClock
import java.time.LocalTime
import java.time.format.DateTimeFormatter
import java.util.Locale
import org.json.JSONObject

class SetAlarmTool : Tool {
    override val name: String = "set_alarm"

    override fun execute(context: Context, args: JSONObject): String {
        val hour = ToolArgumentReader.requireInt(
            args = args,
            key = "hour",
            clarificationMessage = "I need the alarm hour to set that alarm.",
            validRange = 0..23,
        )
        val minute = ToolArgumentReader.requireInt(
            args = args,
            key = "minute",
            clarificationMessage = "I need the alarm minute to set that alarm.",
            validRange = 0..59,
        )

        val intent = Intent(AlarmClock.ACTION_SET_ALARM).apply {
            putExtra(AlarmClock.EXTRA_HOUR, hour)
            putExtra(AlarmClock.EXTRA_MINUTES, minute)
        }

        IntentLauncher.launch(
            context = context,
            intent = intent,
            unavailableMessage = "No alarm app is available on this Android device.",
        )

        return "Opening the alarm app for ${formatTime(hour, minute)}."
    }

    private fun formatTime(hour: Int, minute: Int): String = LocalTime.of(hour, minute)
        .format(DateTimeFormatter.ofPattern("h:mm a", Locale.getDefault()))
}
