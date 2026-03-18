package com.prady.pocketllm

import android.os.StatFs
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val storageChannel = "pocket_llm/storage_info"
    private val runtimePathsChannel = "pocket_llm/runtime_paths"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, storageChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getStorageInfo" -> {
                        try {
                            val stat = StatFs(filesDir.absolutePath)
                            val freeBytes = stat.availableBytes
                            val totalBytes = stat.totalBytes
                            result.success(
                                mapOf(
                                    "freeBytes" to freeBytes,
                                    "totalBytes" to totalBytes,
                                ),
                            )
                        } catch (e: Exception) {
                            result.error("storage_error", e.message, null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, runtimePathsChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getAndroidNativeLibraryDir" -> {
                        try {
                            result.success(applicationInfo.nativeLibraryDir)
                        } catch (e: Exception) {
                            result.error("runtime_paths_error", e.message, null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }
}
