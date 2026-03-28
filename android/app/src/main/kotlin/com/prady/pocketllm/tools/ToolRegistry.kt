package com.prady.pocketllm.tools

class ToolRegistry(
    tools: List<Tool>,
) {
    private val toolsByName = tools.associateBy { it.name }

    fun findTool(name: String): Tool? = toolsByName[name]

    companion object {
        fun default(): ToolRegistry = ToolRegistry(
            listOf(
                SetAlarmTool(),
                CreateEventTool(),
                SendSmsTool(),
            ),
        )
    }
}
