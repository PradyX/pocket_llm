package com.prady.pocketllm.tools

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent

internal object IntentLauncher {
    fun launch(
        context: Context,
        intent: Intent,
        unavailableMessage: String,
    ) {
        if (context !is Activity) {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        try {
            context.startActivity(intent)
        } catch (_: ActivityNotFoundException) {
            throw ToolExecutionException(unavailableMessage)
        }
    }
}
