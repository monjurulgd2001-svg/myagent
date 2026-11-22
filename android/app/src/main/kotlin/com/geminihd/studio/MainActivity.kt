package com.geminihd.studio

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Kotlin Android host (user requirement: Flutter + Kotlin).
//
// Two browser channels:
//  * "browser" — the Image Search screen's intent channel: its
//    browsing runs in a dedicated external browser process (Chrome
//    first, then Firefox, then the system default).
//  * "gecko" — the Gemini sign-in: a built-in Firefox engine
//    (GeckoView, see GeckoBridge) whose profile keeps the Google
//    session and hands its cookies back to the app after sign-in.
//    A separate browser's cookies are unreadable to any app, so the
//    sign-in could not hand the session over any other way.
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.geminihd.studio/browser"
        ).setMethodCallHandler { call, result ->
            if (call.method == "openExternal") {
                val url = call.argument<String>("url") ?: ""
                result.success(openExternal(url))
            } else {
                result.notImplemented()
            }
        }

        // "foreground" — background generation (v33): Dart starts
        // GenerationService while a generation runs so the work
        // survives the screen turning off / other apps coming to
        // the front; also answers the battery-exemption checks.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.geminihd.studio/foreground"
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "start" -> {
                        askNotificationPermission()
                        val intent = Intent(this, GenerationService::class.java)
                        intent.putExtra(
                            GenerationService.EXTRA_LABEL,
                            call.argument<String>("label")
                                ?: "Generating in the background")
                        if (Build.VERSION.SDK_INT >= 26) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(true)
                    }
                    "stop" -> {
                        stopService(Intent(this, GenerationService::class.java))
                        result.success(true)
                    }
                    "notifyDone" -> {
                        showDoneNotification(
                            call.argument<String>("title") ?: "Zedge Studio",
                            call.argument<String>("body")
                                ?: "Queue finished")
                        result.success(true)
                    }
                    "isBatteryExempt" -> {
                        val pm = getSystemService(Context.POWER_SERVICE)
                            as PowerManager
                        result.success(
                            pm.isIgnoringBatteryOptimizations(packageName))
                    }
                    "requestBatteryExemption" -> {
                        // v72: the direct request intent is blocked
                        // on some OEM skins (HiOS included) — fall
                        // back to the list screen where the user can
                        // flip this app to "Unrestricted" by hand.
                        result.success(try {
                            startActivity(
                                Intent(
                                    Settings
                                        .ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                    Uri.parse("package:$packageName")
                                )
                            )
                            true
                        } catch (e: Exception) {
                            try {
                                startActivity(
                                    Intent(
                                        Settings
                                            .ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS
                                    )
                                )
                                true
                            } catch (e2: Exception) {
                                false
                            }
                        })
                    }
                    // v72: the background-killer steps differ per
                    // maker (TECNO/Infinix/itel need Auto-start +
                    // Phone Master background allow on top of the
                    // stock exemption). v76: Auto-start lives
                    // inside the Phone Master app, not on the app
                    // settings page — see "openPhoneMaster" below.
                    "getManufacturer" -> {
                        result.success(Build.MANUFACTURER ?: "")
                    }
                    "openAppSettings" -> {
                        result.success(try {
                            startActivity(
                                Intent(
                                    Settings
                                        .ACTION_APPLICATION_DETAILS_SETTINGS,
                                    Uri.parse("package:$packageName")
                                )
                            )
                            true
                        } catch (e: Exception) {
                            false
                        })
                    }
                    // v77: open the Transsion Phone Master app,
                    // where HiOS keeps Auto-start management
                    // (package com.transsion.phonemaster). Falls
                    // back to the app settings page when Phone
                    // Master is not installed.
                    "openPhoneMaster" -> {
                        val pmIntent = packageManager
                            .getLaunchIntentForPackage(
                                "com.transsion.phonemaster")
                        if (pmIntent != null) {
                            pmIntent.addFlags(
                                Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(pmIntent)
                            result.success(true)
                        } else {
                            result.success(try {
                                startActivity(
                                    Intent(
                                        Settings
                                            .ACTION_APPLICATION_DETAILS_SETTINGS,
                                        Uri.parse("package:$packageName")
                                    )
                                )
                                true
                            } catch (e: Exception) {
                                false
                            })
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Throwable) {
                result.error("foreground", e.toString(), null)
            }
        }

        val geckoChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.geminihd.studio/gecko"
        )
        GeckoBridge.channel = geckoChannel
        geckoChannel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "signIn" -> GeckoBridge.signIn(
                        this, call.argument<String>("url"), result)
                    "refresh" -> GeckoBridge.refresh(
                        this, result, call.argument<String>("cookieHeader"))
                    "syncCookies" -> GeckoBridge.syncCookies(
                        this, call.argument<String>("cookieHeader") ?: ""
                    ) { result.success(it) }
                    "cookies" -> GeckoBridge.readCookies(this) {
                        result.success(it)
                    }
                    "browserOpen" -> {
                        GeckoBridge.browserOpen(
                            this, call.argument<String>("url"))
                        result.success(true)
                    }
                    "browserClose" -> {
                        GeckoBridge.browserClose()
                        result.success(true)
                    }
                    "browserBasket" -> {
                        GeckoBridge.browserBasket(call.arguments as String)
                        result.success(true)
                    }
                    "browserStatus" -> {
                        GeckoBridge.browserStatus(call.arguments as String)
                        result.success(true)
                    }
                    "browserToast" -> {
                        GeckoBridge.browserToast(call.arguments as String)
                        result.success(true)
                    }
                    "browserVideo" -> {
                        GeckoBridge.browserVideo(call.arguments as String)
                        result.success(true)
                    }
                    "browserVideoHeadless" -> {
                        // v150 — return posted-vs-queued so Dart can
                        // log a queued job instead of assuming it
                        // reached the page.
                        result.success(GeckoBridge.browserVideoHeadless(
                            this, call.arguments as String))
                    }
                    "backendFetch" -> GeckoBridge.backendFetch(
                        this, call.arguments as String) {
                        result.success(it)
                    }
                    "browserFetch" -> GeckoBridge.browserFetch(
                        this, call.arguments as String) {
                        result.success(it)
                    }
                    "browserCapture" -> GeckoBridge.browserCapture(
                        call.arguments as String) {
                        result.success(it)
                    }
                    "browserIsOpen" ->
                        result.success(GeckoBridge.hasBrowserSession())
                    else -> result.notImplemented()
                }
            } catch (e: Throwable) {
                result.error("gecko", e.toString(), null)
            }
        }
    }

    // v47: one-off completion notification for the overnight
    // queue. Uses the same "generation" channel the foreground
    // service creates (made here too if the service never ran).
    private fun showDoneNotification(title: String, body: String) {
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE)
                as NotificationManager
            if (Build.VERSION.SDK_INT >= 26 &&
                nm.getNotificationChannel("generation") == null) {
                nm.createNotificationChannel(
                    NotificationChannel(
                        "generation", "Background generation",
                        NotificationManager.IMPORTANCE_LOW))
            }
            val tapIntent = Intent(this, MainActivity::class.java)
            val flags = if (Build.VERSION.SDK_INT >= 23)
                PendingIntent.FLAG_UPDATE_CURRENT or
                    PendingIntent.FLAG_IMMUTABLE
            else PendingIntent.FLAG_UPDATE_CURRENT
            val tap = PendingIntent.getActivity(this, 0, tapIntent, flags)
            val builder = if (Build.VERSION.SDK_INT >= 26)
                Notification.Builder(this, "generation")
            else @Suppress("DEPRECATION") Notification.Builder(this)
            nm.notify(
                4212,
                builder
                    .setContentTitle(title)
                    .setContentText(body)
                    .setSmallIcon(applicationInfo.icon)
                    .setAutoCancel(true)
                    .setContentIntent(tap)
                    .build())
        } catch (e: Throwable) {
            // A missed notification must never break a queue run.
        }
    }

    private fun askNotificationPermission() {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(
                arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                7331)
        }
    }

    private fun openExternal(url: String): Boolean {
        if (url.isEmpty()) return false
        val uri = Uri.parse(url)
        for (pkg in listOf("com.android.chrome", "org.mozilla.firefox")) {
            try {
                startActivity(Intent(Intent.ACTION_VIEW, uri).apply {
                    setPackage(pkg)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                })
                return true
            } catch (e: Exception) {
                // Browser not installed — try the next one.
            }
        }
        return try {
            startActivity(Intent(Intent.ACTION_VIEW, uri).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            })
            true
        } catch (e: Exception) {
            false
        }
    }
}
