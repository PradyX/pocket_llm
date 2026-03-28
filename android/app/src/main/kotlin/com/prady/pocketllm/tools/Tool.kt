package com.prady.pocketllm.tools

import android.content.Context
import org.json.JSONObject

interface Tool {
    val name: String
    fun execute(context: Context, args: JSONObject): String
}
