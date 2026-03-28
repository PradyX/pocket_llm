package com.prady.pocketllm.tools

import android.content.Context
import android.util.Log
import org.json.JSONException
import org.json.JSONObject

class ToolExecutor(
    private val registry: ToolRegistry = ToolRegistry.default(),
) {
    fun execute(context: Context, payload: String): String {
        var toolName: String? = null

        return try {
            val request = JSONObject(payload)
            val type = request.optString("type").trim()
            if (type != "tool_call") {
                return ToolJsonResult.error("Unsupported tool payload type: ${if (type.isEmpty()) "unknown" else type}.")
            }

            toolName = request.optString("tool").trim()
            if (toolName.isNullOrEmpty()) {
                return ToolJsonResult.error("I need to know which tool to use.")
            }

            val args = request.optJSONObject("arguments") ?: JSONObject()
            val tool = registry.findTool(toolName!!)
                ?: return ToolJsonResult.error(
                    message = "Unknown tool: $toolName.",
                    toolName = toolName,
                )

            val message = tool.execute(context, args)
            ToolJsonResult.success(toolName!!, message)
        } catch (e: JSONException) {
            ToolJsonResult.error("Invalid tool payload.", toolName)
        } catch (e: ToolExecutionException) {
            ToolJsonResult.error(
                message = e.message ?: "I need a bit more information to do that.",
                toolName = toolName,
            )
        } catch (e: Exception) {
            Log.e("PocketLlmToolExecutor", "Tool execution failed", e)
            ToolJsonResult.error(
                message = "I couldn't complete that Android action.",
                toolName = toolName,
            )
        }
    }
}
