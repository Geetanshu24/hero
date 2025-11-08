package com.example.hero

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity: FlutterActivity() {
    private val CHANNEL = "app.channel.shared/files"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "sendEmailWithAttachments" -> {
                    val args = call.arguments as? Map<String, Any?>
                    if (args == null) {
                        result.error("invalid_args", "No args provided", null)
                        return@setMethodCallHandler
                    }

                    val toList = (args["to"] as? List<*>)?.filterIsInstance<String>() ?: emptyList()
                    val subject = args["subject"] as? String ?: ""
                    val body = args["body"] as? String ?: ""
                    val paths = (args["paths"] as? List<*>)?.filterIsInstance<String>() ?: emptyList()

                    try {
                        val uris = ArrayList<Uri>()
                        for (p in paths) {
                            val file = File(p)
                            if (!file.exists()) continue
                            val uri = FileProvider.getUriForFile(this, "${applicationContext.packageName}.fileprovider", file)
                            uris.add(uri)
                        }

                        if (uris.isEmpty()) {
                            result.error("no_files", "No valid files to attach", null)
                            return@setMethodCallHandler
                        }

                        val intent = Intent().apply {
                            action = Intent.ACTION_SEND_MULTIPLE
                            type = "application/pdf"
                            putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
                            putExtra(Intent.EXTRA_SUBJECT, subject)
                            putExtra(Intent.EXTRA_TEXT, body)
                            if (toList.isNotEmpty()) {
                                putExtra(Intent.EXTRA_EMAIL, toList.toTypedArray())
                            }
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }

                        val chooser = Intent.createChooser(intent, "Send email")
                        // Ensure there's at least one app to handle it
                        val resInfo = packageManager.queryIntentActivities(intent, 0)
                        if (resInfo.isEmpty()) {
                            result.error("no_activity", "No app found to handle intent", null)
                            return@setMethodCallHandler
                        }

                        startActivity(chooser)
                        result.success(true)
                    } catch (ae: ActivityNotFoundException) {
                        result.error("not_found", "No activity found to handle intent", ae.localizedMessage)
                    } catch (e: Exception) {
                        result.error("error", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}

