package com.prady.pocketllm.tools

import android.content.Context
import android.content.Intent
import android.net.Uri
import org.json.JSONObject

class SendSmsTool : Tool {
    override val name: String = "send_sms"

    override fun execute(context: Context, args: JSONObject): String {
        val phone = ToolArgumentReader.requireString(
            args = args,
            key = "phone",
            clarificationMessage = "I need the phone number to send that SMS.",
        )
        val message = ToolArgumentReader.requireString(
            args = args,
            key = "message",
            clarificationMessage = "I need the SMS message text to send that SMS.",
        )

        val intent = Intent(Intent.ACTION_SENDTO).apply {
            data = Uri.parse("smsto:${Uri.encode(phone)}")
            putExtra("sms_body", message)
        }

        IntentLauncher.launch(
            context = context,
            intent = intent,
            unavailableMessage = "No SMS app is available on this Android device.",
        )

        return "Opening the SMS app for $phone."
    }
}
