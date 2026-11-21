package com.geminihd.studio

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import org.mozilla.geckoview.GeckoRuntime
import org.mozilla.geckoview.GeckoRuntimeSettings
import org.mozilla.geckoview.GeckoSession
import org.mozilla.geckoview.GeckoSessionSettings
import org.mozilla.geckoview.WebExtension

/**
 * Built-in Firefox engine (GeckoView) used only for the Gemini sign-in.
 *
 * Google refuses sign-in inside Android WebView, but GeckoView is a
 * full browser engine (the one inside Firefox for Android). Its
 * profile lives in the app's private data, so after one sign-in the
 * session stays there and the Gemini cookies can be read again
 * later - silently.
 *
 * The cookies are read by a tiny built-in WebExtension
 * (assets/ais_cookies) that only returns the Google session cookies
 * gemini.google.com uses. Adapted for this app from the AI Image
 * Studio source the user provided.
 */
object GeckoBridge {
    const val GEMINI_URL = "https://gemini.google.com/app"
    const val SIGN_IN_URL =
        "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fgemini.google.com%2Fapp"

    private const val EXT_URI = "resource://android/assets/ais_cookies/"
    private const val EXT_ID = "ghs-cookies@geminihd"

    private val main = Handler(Looper.getMainLooper())
    private var runtime: GeckoRuntime? = null
    private var port: WebExtension.Port? = null
    private val waitingForPort = mutableListOf<() -> Unit>()
    private var nextId = 1
    private val pending = mutableMapOf<Int, (JSONObject?) -> Unit>()

    /** Channel to the Flutter app (set by MainActivity). */
    var channel: MethodChannel? = null

    /** Result of the running sign-in screen (one at a time). */
    private var signInResult: MethodChannel.Result? = null

    /** Last basket from the app, re-sent when the extension (re)connects. */
    private var lastBasket: JSONObject? = null

    /** v121 — session fields the sign-in screen read from the
     * Gemini page it loaded (see readSessionPage). Set by
     * GeckoSignInActivity just before it closes; consumed once by
     * signInFinished, then cleared. */
    var lastSessionPage: JSONObject? = null

    /** The Image Search browser tab; kept while the app runs so the
     * page survives leaving / reopening the browser screen. */
    private var browserSession: GeckoSession? = null
    var browserActivity: GeckoBrowserActivity? = null

    /** Last real page the browser tab showed. If the tab's renderer
     * process dies while the app is in the background, the kept tab
     * comes back stuck on about:blank; this is the page the healed
     * tab reloads. */
    @Volatile var lastBrowserUrl: String? = null

    /** Drops the cached browser tab (renderer crashed / killed);
     * the next browserSession() call creates a fresh one. */
    fun invalidateBrowserSession() {
        try {
            browserSession?.close()
        } catch (_: Exception) {
        }
        browserSession = null
    }

    fun runtime(context: Context): GeckoRuntime {
        runtime?.let { return it }
        val settings = GeckoRuntimeSettings.Builder()
            .consoleOutput(false)
            .aboutConfigEnabled(false)
            .build()
        val rt = GeckoRuntime.create(context.applicationContext, settings)
        runtime = rt
        installExtension(rt)
        return rt
    }

    private fun installExtension(rt: GeckoRuntime) {
        rt.webExtensionController.ensureBuiltIn(EXT_URI, EXT_ID).accept({ ext ->
            ext?.setMessageDelegate(object : WebExtension.MessageDelegate {
                override fun onConnect(p: WebExtension.Port) {
                    port = p
                    p.setDelegate(object : WebExtension.PortDelegate {
                        override fun onPortMessage(message: Any, p2: WebExtension.Port) {
                            onMessage(message)
                        }

                        override fun onDisconnect(p2: WebExtension.Port) {
                            if (port === p2) port = null
                        }
                    })
                    lastBasket?.let { b -> post(b) }
                    val w = waitingForPort.toList()
                    waitingForPort.clear()
                    w.forEach { it() }
                }
            }, "ais")
        }, { _ -> })
    }

    private fun onMessage(message: Any) {
        val o = message as? JSONObject ?: return
        if (o.optString("type") == "q") {
            // Picture requests from the page overlay -> app.
            channel?.invokeMethod("browserRequest", o.toString())
            return
        }
        if (!o.has("id")) return
        val cb = pending.remove(o.optInt("id")) ?: return
        cb(o)
    }

    private fun post(o: JSONObject): Boolean {
        val p = port ?: return false
        return try {
            p.postMessage(o)
            true
        } catch (e: Exception) {
            false
        }
    }

    /** Sends [cmd] to the extension and waits for its answer. */
    private fun request(context: Context, cmd: JSONObject, timeoutMs: Long,
                        done: (JSONObject?) -> Unit) {
        runtime(context)
        var finished = false
        val finish: (JSONObject?) -> Unit = { v ->
            if (!finished) {
                finished = true
                done(v)
            }
        }
        main.postDelayed({ finish(null) }, timeoutMs)
        val ask: () -> Unit = {
            val id = nextId++
            pending[id] = { v -> finish(v) }
            if (!post(cmd.put("id", id))) {
                pending.remove(id)
                finish(null)
            }
        }
        if (port != null) ask() else waitingForPort.add(ask)
    }

    /** Gemini session cookies as a JSON array string (null = none/timeout). */
    fun readCookies(context: Context, timeoutMs: Long = 8000, done: (String?) -> Unit) {
        request(context, JSONObject().put("cmd", "get"), timeoutMs) { o ->
            done(o?.optJSONArray("cookies")?.toString())
        }
    }

    /** v121 — session token + account fields, read by the
     * extension from the Gemini page the browser itself loaded.
     * Null when no Gemini tab answered or the page carries no
     * token; the caller then falls back to the Dart HTTP verify.
     * Only a reply carrying a real SNlM0e token is handed over. */
    fun readSessionPage(context: Context, timeoutMs: Long = 8000, done: (JSONObject?) -> Unit) {
        request(context, JSONObject().put("cmd", "sessionPage"), timeoutMs) { o ->
            if (o != null && o.optString("at").isNotEmpty()) done(o) else done(null)
        }
    }

    fun hasPsid(json: String?): Boolean {
        if (json == null) return false
        return try {
            val a = JSONArray(json)
            (0 until a.length()).any {
                val c = a.getJSONObject(it)
                c.optString("name") == "__Secure-1PSID" && c.optString("value").isNotEmpty()
            }
        } catch (e: Exception) {
            false
        }
    }

    // ------------------------------------------------------------ sign-in
    fun signIn(activity: Activity, url: String?, result: MethodChannel.Result) {
        signInResult?.success(null)
        signInResult = result
        // v121 — a stale session page from an earlier sign-in must
        // never leak into this one; the activity re-reads it.
        lastSessionPage = null
        runtime(activity)
        val i = Intent(activity, GeckoSignInActivity::class.java)
        i.putExtra("url", url ?: SIGN_IN_URL)
        activity.startActivity(i)
    }

    /** Merges the harvested cookies with the in-browser session
     * page (v121) into the one payload Dart parses: {"cookies":
     * [...], "session": {...}} — or null when the profile holds no
     * signed-in session. Dart accepts this shape and the old bare
     * cookie-array string. */
    private fun mergedSignInPayload(json: String?, page: JSONObject?): String? {
        if (!hasPsid(json)) return null
        val out = JSONObject()
        out.put("cookies", JSONArray(json ?: "[]"))
        if (page != null) out.put("session", page)
        return out.toString()
    }

    /** Called by [GeckoSignInActivity] when it closes. */
    fun signInFinished(context: Context) {
        val r = signInResult ?: return
        signInResult = null
        readCookies(context) { json ->
            r.success(mergedSignInPayload(json, lastSessionPage))
            lastSessionPage = null
        }
    }

    // ------------------------------------------------------- silent refresh
    /**
     * Opens Gemini in an invisible tab of the signed-in profile so
     * the engine renews the Google session itself, then returns the
     * cookies.
     */
    fun refresh(context: Context, result: MethodChannel.Result) {
        val rt = runtime(context)
        var answered = false
        val session = GeckoSession(
            GeckoSessionSettings.Builder()
                .usePrivateMode(false)
                .useTrackingProtection(false)
                .build()
        )
        val reply: () -> Unit = reply@{
            if (answered) return@reply
            answered = true
            // v121 — read the session token from the headless page
            // itself (same bot-check reason as sign-in) BEFORE
            // closing the session, then hand cookies + token to
            // Dart as one payload. Either read may time out to
            // null; the merged payload still works without it.
            readSessionPage(context, 8000) { page ->
                readCookies(context) { json ->
                    try {
                        session.close()
                    } catch (_: Exception) {
                    }
                    result.success(mergedSignInPayload(json, page))
                }
            }
        }
        session.progressDelegate = object : GeckoSession.ProgressDelegate {
            override fun onPageStop(session: GeckoSession, success: Boolean) {
                // Give the page a moment for its own cookie rotation.
                main.postDelayed({ reply() }, 4000)
            }
        }
        session.open(rt)
        session.setActive(true)
        session.loadUri(GEMINI_URL)
        main.postDelayed({ reply() }, 30000)
    }

    // ------------------------------------------------- Image Search browser
    fun browserSession(context: Context): GeckoSession {
        browserSession?.let { if (it.isOpen) return it }
        val s = GeckoSession(
            GeckoSessionSettings.Builder()
                .usePrivateMode(false)
                .useTrackingProtection(true)
                .build()
        )
        s.open(runtime(context))
        browserSession = s
        return s
    }

    fun hasBrowserSession(): Boolean = browserSession?.isOpen == true

    fun browserOpen(activity: Activity, url: String?) {
        val i = Intent(activity, GeckoBrowserActivity::class.java)
        if (url != null) i.putExtra("url", url)
        i.addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
        activity.startActivity(i)
    }

    fun browserClose() {
        browserActivity?.finish()
        try {
            browserSession?.close()
        } catch (_: Exception) {
        }
        browserSession = null
        lastBrowserUrl = null
        browserState()
    }

    /** Tells the app whether the browser screen / tab exists. */
    fun browserState() {
        val o = JSONObject()
            .put("open", hasBrowserSession())
            .put("visible", browserActivity != null)
        channel?.invokeMethod("browserState", o.toString())
    }

    fun browserBasket(json: String) {
        val o = JSONObject(json).put("cmd", "basket")
        lastBasket = o
        post(o)
    }

    fun browserStatus(json: String) {
        post(JSONObject(json).put("cmd", "status"))
    }

    fun browserToast(msg: String) {
        post(JSONObject().put("cmd", "toast").put("msg", msg))
    }

    /** v86: hands a video job to the in-page Gemini driver (the
     *  extension's content script on gemini.google.com). */
    fun browserVideo(json: String) {
        post(JSONObject(json).put("cmd", "video"))
    }

    // ------------------------------------------------- v98: page transport
    /**
     * Headless Gemini tab for the v98 page transport: the same
     * invisible-session pattern as [refresh] (no view, no Activity),
     * but kept alive while the app runs so the content script stays
     * connected and the backend's page fetches are instant after the
     * first load. The page's own fetch is what makes the request the
     * browser's own (its cookies, Origin, sec-fetch, HTTP/2, TLS).
     */
    private var backendSession: GeckoSession? = null

    fun ensureBackendSession(context: Context) {
        val s = backendSession
        if (s != null && s.isOpen) return
        val session = GeckoSession(
            GeckoSessionSettings.Builder()
                .usePrivateMode(false)
                .useTrackingProtection(false)
                .build()
        )
        session.open(runtime(context))
        session.setActive(true)
        session.loadUri(GEMINI_URL)
        backendSession = session
    }

    /** One backend exchange through the page: opens the headless
     * Gemini tab if needed, then sends the job to the extension
     * (background.js queues it until a Gemini tab connects) and
     * waits for the content script's reply. 120s: the page fetch
     * itself is fast, but on a slow network the tab may still be
     * loading when the first job arrives. Null = no answer in time
     * (Dart falls back to plain HTTP). */
    fun backendFetch(context: Context, json: String, done: (String?) -> Unit) {
        ensureBackendSession(context)
        val o = try {
            JSONObject(json)
        } catch (_: Exception) {
            done(null)
            return
        }
        // v101 — 60s (was 120s): the headless tab either answers
        // quickly or never attaches at all; waiting 2 min on a dead
        // tab just delays the Dart-HTTP fallback and the whole job.
        request(context, o.put("cmd", "backendFetch"), 60000) { reply ->
            done(reply?.toString())
        }
    }

    /** Screenshot of an area of the visible page (shares of the
     * viewport: {"x","y","w","h"} 0..1). Answers base64 PNG or null. */
    fun browserCapture(json: String, done: (String?) -> Unit) {
        val act = browserActivity
        if (act == null) {
            done(null)
            return
        }
        try {
            val o = JSONObject(json)
            act.capture(o.optDouble("x"), o.optDouble("y"),
                o.optDouble("w"), o.optDouble("h"), done)
        } catch (e: Exception) {
            done(null)
        }
    }

    /** Downloads a picture through the engine; answers a data: URL or null. */
    fun browserFetch(context: Context, src: String, done: (String?) -> Unit) {
        request(context, JSONObject().put("cmd", "fetch").put("src", src), 45000) { o ->
            done(o?.optString("data")?.takeIf { it.startsWith("data:") })
        }
    }
}
