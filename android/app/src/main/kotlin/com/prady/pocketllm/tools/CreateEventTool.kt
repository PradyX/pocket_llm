package com.prady.pocketllm.tools

import android.content.Context
import android.content.Intent
import android.provider.CalendarContract
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale
import org.json.JSONObject

class CreateEventTool : Tool {
    override val name: String = "create_event"

    override fun execute(context: Context, args: JSONObject): String {
        val title = ToolArgumentReader.requireString(
            args = args,
            key = "title",
            clarificationMessage = "I need an event title to create that calendar entry.",
        )
        val startTimeRaw = ToolArgumentReader.requireString(
            args = args,
            key = "start_time",
            clarificationMessage = "I need the event start time to create that calendar entry.",
        )
        val parsedStart = EventStartParser.parse(startTimeRaw)

        val intent = Intent(Intent.ACTION_INSERT).apply {
            data = CalendarContract.Events.CONTENT_URI
            putExtra(CalendarContract.Events.TITLE, title)
            putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, parsedStart.startMillis)
            if (parsedStart.isAllDay) {
                putExtra(CalendarContract.EXTRA_EVENT_ALL_DAY, true)
            }
        }

        IntentLauncher.launch(
            context = context,
            intent = intent,
            unavailableMessage = "No calendar app is available on this Android device.",
        )

        return if (parsedStart.isAllDay) {
            "Opening the calendar to create \"$title\" on ${parsedStart.readableTime}."
        } else {
            "Opening the calendar to create \"$title\" at ${parsedStart.readableTime}."
        }
    }
}

private data class ParsedEventStart(
    val startMillis: Long,
    val readableTime: String,
    val isAllDay: Boolean,
)

private object EventStartParser {
    private val deviceZone: ZoneId = ZoneId.systemDefault()

    fun parse(raw: String): ParsedEventStart {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) {
            throw ToolExecutionException("I need the event start time to create that calendar entry.")
        }

        parseDateOnly(trimmed)?.let { return it }
        parseInstant(trimmed)?.let { return it }
        parseZonedDateTime(trimmed)?.let { return it }
        parseLocalDateTime(trimmed)?.let { return it }

        throw ToolExecutionException(
            "I need a valid start time to create that calendar entry.",
        )
    }

    private fun parseDateOnly(raw: String): ParsedEventStart? {
        val date = runCatching { LocalDate.parse(raw, DateTimeFormatter.ISO_LOCAL_DATE) }
            .getOrNull() ?: return null
        val zonedDateTime = date.atStartOfDay(deviceZone)
        return ParsedEventStart(
            startMillis = zonedDateTime.toInstant().toEpochMilli(),
            readableTime = date.format(DateTimeFormatter.ofPattern("MMM d, yyyy", Locale.getDefault())),
            isAllDay = true,
        )
    }

    private fun parseInstant(raw: String): ParsedEventStart? {
        val instant = runCatching { Instant.parse(raw) }.getOrNull() ?: return null
        return fromZonedDateTime(instant.atZone(deviceZone))
    }

    private fun parseZonedDateTime(raw: String): ParsedEventStart? {
        val zonedDateTime = runCatching { ZonedDateTime.parse(raw) }.getOrNull() ?: return null
        return fromZonedDateTime(zonedDateTime.withZoneSameInstant(deviceZone))
    }

    private fun parseLocalDateTime(raw: String): ParsedEventStart? {
        val localDateTime = runCatching { LocalDateTime.parse(raw, DateTimeFormatter.ISO_LOCAL_DATE_TIME) }
            .getOrNull() ?: return null
        return fromZonedDateTime(localDateTime.atZone(deviceZone))
    }

    private fun fromZonedDateTime(dateTime: ZonedDateTime): ParsedEventStart = ParsedEventStart(
        startMillis = dateTime.toInstant().toEpochMilli(),
        readableTime = dateTime.format(
            DateTimeFormatter.ofPattern("MMM d, yyyy 'at' h:mm a", Locale.getDefault()),
        ),
        isAllDay = false,
    )
}
