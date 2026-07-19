package com.example.metaserver_client

import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val preferences = getSharedPreferences(
            "metaserver_trading_local_storage",
            Context.MODE_PRIVATE
        )
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "metaserver/trading_local_storage"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "loadAll" -> {
                    val values = mutableMapOf<String, String>()
                    for ((key, value) in preferences.all) {
                        if (value is String) {
                            values[key] = value
                        }
                    }
                    result.success(values)
                }
                "save" -> {
                    val key = call.argument<String>("key")
                    val value = call.argument<String>("value")
                    if (key.isNullOrBlank() || value == null) {
                        result.error(
                            "invalid_arguments",
                            "Storage key and value are required.",
                            null
                        )
                        return@setMethodCallHandler
                    }
                    val saved = preferences.edit().putString(key, value).commit()
                    if (saved) {
                        result.success(null)
                    } else {
                        result.error(
                            "save_failed",
                            "Failed to persist trading storage value.",
                            null
                        )
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
