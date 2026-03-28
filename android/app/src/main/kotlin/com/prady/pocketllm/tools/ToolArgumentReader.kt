package com.prady.pocketllm.tools

import org.json.JSONObject

internal object ToolArgumentReader {
    fun requireInt(
        args: JSONObject,
        key: String,
        clarificationMessage: String,
        validRange: IntRange? = null,
    ): Int {
        val value = args.opt(key)
            ?.takeUnless { it == JSONObject.NULL }
            ?.toString()
            ?.trim()
            ?.toIntOrNull()
            ?: throw ToolExecutionException(clarificationMessage)

        if (validRange != null && value !in validRange) {
            throw ToolExecutionException(clarificationMessage)
        }

        return value
    }

    fun requireString(
        args: JSONObject,
        key: String,
        clarificationMessage: String,
    ): String {
        val value = args.opt(key)
            ?.takeUnless { it == JSONObject.NULL }
            ?.toString()
            ?.trim()
            .orEmpty()

        if (value.isEmpty()) {
            throw ToolExecutionException(clarificationMessage)
        }

        return value
    }
}
