package com.prady.pocketllm.tools

import org.json.JSONObject

internal object ToolJsonResult {
    fun success(toolName: String, message: String): String = JSONObject()
        .put("status", "success")
        .put("tool", toolName)
        .put("message", message)
        .toString()

    fun error(message: String, toolName: String? = null): String {
        val payload = JSONObject()
            .put("status", "error")
            .put("message", message)

        if (!toolName.isNullOrBlank()) {
            payload.put("tool", toolName)
        }

        return payload.toString()
    }
}
