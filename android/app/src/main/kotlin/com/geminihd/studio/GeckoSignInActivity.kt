package com.geminihd.studio

import android.app.Activity
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Gravity
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import org.mozilla.geckoview.GeckoResult
import org.mozilla.geckoview.GeckoSession
import org.mozilla.geckoview.GeckoSessionSettings
import org.mozilla.geckoview.GeckoView
import org.mozilla.geckoview.StorageController

/**
 * Full-screen built-in browser (Firefox engine) on the Google sign-in
 * page. Closes itself as soon as Gemini is open signed in; "Done"
 * closes it too. Adapted for this app from the AI Image Studio
 * source the user provided; the bar is restyled to the app's dark
 * dashboard colours.
 */
class GeckoSignInActivity : Activity() {
    private var session: GeckoSession? = null
    private var closing = false
    // v107 — a settle is pending (see checkSignedIn): ignore further
    // page-stops until it fires, or the close would be scheduled twice.
    private var settlePending = false
    private var currentUrl = ""
    private val mainHandler = Handler(Looper.getMainLooper())
    // v124 — a sign-in check is already running; the poll (below)
    // must not pile another one on top of it.
    private var checkInFlight = false
    // v124 — the profile wipe ran once this visit (stale jar only).
    private var wipedOnce = false
    private var statusView: TextView? = null
    private var waitStartedAt = 0L
    private var slowHintShown = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val density = resources.displayMetrics.density
        fun dp(v: Int) = (v * density).toInt()

        val root = LinearLayout(this)
        root.orientation = LinearLayout.VERTICAL
        root.setBackgroundColor(Color.parseColor("#070A14"))
        root.fitsSystemWindows = true

        val bar = LinearLayout(this)
        bar.orientation = LinearLayout.HORIZONTAL
        bar.gravity = Gravity.CENTER_VERTICAL
        bar.setPadding(dp(16), dp(6), dp(8), dp(6))
        bar.setBackgroundColor(Color.parseColor("#0C1122"))
        val title = TextView(this)
        title.text = "Sign in to Google (Gemini)"
        title.setTextColor(Color.WHITE)
        title.textSize = 16f
        bar.addView(title, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        val done = Button(this)
        done.text = "Done"
        done.setOnClickListener { close() }
        bar.addView(done)
        root.addView(bar, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        // v124 — show where the browser is, so a slow load does not
        // look stuck (live 2026-11-21 the screen sat silent at
        // ~5 KB/s until the user closed it by hand).
        val status = TextView(this)
        status.text = "Loading Google sign-in…"
        status.setTextColor(Color.parseColor("#9AA0B5"))
        status.textSize = 13f
        status.setPadding(dp(16), dp(6), dp(16), dp(6))
        root.addView(status, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        statusView = status

        val view = GeckoView(this)
        root.addView(view, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        setContentView(root)

        val s = GeckoSession(
            GeckoSessionSettings.Builder()
                .usePrivateMode(false)
                .useTrackingProtection(false)
                .build()
        )
        s.navigationDelegate = object : GeckoSession.NavigationDelegate {
            override fun onLocationChange(
                session: GeckoSession,
                url: String?,
                perms: MutableList<GeckoSession.PermissionDelegate.ContentPermission>,
                hasUserGesture: Boolean
            ) {
                currentUrl = url ?: ""
                when {
                    currentUrl.contains("accounts.google.com") ->
                        setStatus("Sign in with Google…")
                    currentUrl.startsWith("https://gemini.google.com") ->
                        setStatus("Opening Gemini…")
                }
            }
        }
        s.progressDelegate = object : GeckoSession.ProgressDelegate {
            override fun onPageStop(session: GeckoSession, success: Boolean) {
                checkSignedIn()
            }
        }
        s.contentDelegate = object : GeckoSession.ContentDelegate {
            // Renderer crashed / was killed under memory pressure:
            // this screen's session is per-visit, so just close —
            // the app reports the attempt ended and the next Sign in
            // tap starts a brand-new session (no zombie blank page).
            override fun onCrash(session: GeckoSession) {
                closeAfterCrash()
            }

            override fun onKill(session: GeckoSession) {
                closeAfterCrash()
            }
        }
        s.open(GeckoBridge.runtime(this))
        view.setSession(s)
        session = s
        // v124 — no upfront wipe (see wipeProfileThenLoad): load
        // the sign-in page on top of whatever the profile holds.
        // A good profile login lands straight on /app and the poll
        // below closes with its token; a stale one is wiped only
        // after it proves tokenless.
        waitStartedAt = SystemClock.elapsedRealtime()
        session?.loadUri(intent.getStringExtra("url") ?: GeckoBridge.SIGN_IN_URL)
        mainHandler.postDelayed(pollRunnable, 5000)
    }

    private fun setStatus(text: String) {
        statusView?.text = text
    }

    // v124 — page-stop alone cannot be trusted on a slow network:
    // a heavy /app page can take minutes to finish at ~5 KB/s, so
    // onPageStop may never fire while the user waits — and the
    // screen used to sit there until the user closed it by hand.
    // The poll re-checks the signed-in state every 5s instead.
    private val pollRunnable = object : Runnable {
        override fun run() {
            if (closing) return
            if (!slowHintShown &&
                SystemClock.elapsedRealtime() - waitStartedAt > 30000
            ) {
                slowHintShown = true
                setStatus("Still loading — slow connection, please wait…")
            }
            checkSignedIn()
            mainHandler.postDelayed(this, 5000)
        }
    }

    // v124 — the v108 wipe, moved: it no longer runs before every
    // sign-in (live 2026-11-21 a failed sign-in wiped the profile
    // and left Refresh with nothing to recover, while the saved
    // login sat untouched in the app). It runs only here, once per
    // visit, when the loaded /app page is signed in but yields no
    // token twice — a proven-stale jar. SITE_DATA covers cookies +
    // DOM storages + caches. The load waits for the wipe (both
    // outcomes load the page).
    private fun wipeProfileThenLoad(url: String) {
        try {
            // v117 — explicitly-typed SAM listeners: bare lambdas
            // hit GeckoResult's flatMap overload and U stays
            // uninferred (the v116 `null as Void?` fix did not
            // fix it; the 09:25 run failed again the same way).
            GeckoBridge.runtime(this).storageController
                .clearData(StorageController.ClearFlags.SITE_DATA)
                .then(
                    GeckoResult.OnValueListener<Void, Void?> {
                        session?.loadUri(url)
                        null
                    },
                    GeckoResult.OnExceptionListener<Void?> {
                        session?.loadUri(url)
                        null
                    },
                )
        } catch (_: Exception) {
            session?.loadUri(url)
        }
    }

    /** After each page load (and every poll tick): signed in and back on Gemini -> close. */
    private fun checkSignedIn() {
        if (closing || settlePending || checkInFlight) return
        if (!currentUrl.startsWith("https://gemini.google.com")) return
        // v107 — only the app page counts: the landing / consent
        // pages live under the same host but carry no session.
        if (!currentUrl.contains("/app")) return
        checkInFlight = true
        GeckoBridge.readCookies(this, 8000) { json ->
            checkInFlight = false
            if (closing || settlePending) return@readCookies
            if (!GeckoBridge.hasPsid(json)) return@readCookies
            // v107 — the PSID is set the moment Google login
            // succeeds, but the Gemini session (SNlM0e + the full
            // cookie set) settles over the redirect chain after it.
            // Live 2026-11-20 the screen closed at the first
            // page-stop and handed Dart a half-settled jar, so the
            // verify fetch found no token ("Could not find Gemini
            // session token (SNlM0e)"). Wait 4s — the same settle
            // the silent refresh already uses — and re-confirm the
            // PSID is still there before closing.
            settlePending = true
            setStatus("Signed in — finishing…")
            mainHandler.postDelayed({
                if (closing) return@postDelayed
                GeckoBridge.readCookies(this, 8000) { json2 ->
                    if (closing) return@readCookies
                    if (!GeckoBridge.hasPsid(json2)) {
                        // PSID vanished mid-settle — let the poll
                        // try again instead of closing on nothing.
                        settlePending = false
                        return@readCookies
                    }
                    readSessionPageWithRetry(retriesLeft = 1)
                }
            }, 4000)
        }
    }

    /** v124 — reads the session token off the loaded /app page.
     * One retry: a single miss can mean the extension tab had
     * not connected yet, not a dead session. Two misses on a
     * signed-in /app page mean the jar is stale or mixed (the
     * v108 case) — wipe the profile once and show the fresh
     * sign-in form instead of handing Dart a tokenless page. */
    private fun readSessionPageWithRetry(retriesLeft: Int) {
        // v121 — read the session token from the page this
        // browser itself loaded, then close: Dart gets cookies +
        // token without any raw HTTP fetch (Google bot-checks
        // that fetch — live 2026-11-21).
        GeckoBridge.readSessionPage(this, 15000) { page ->
            if (closing) return@readSessionPage
            if (page != null) {
                GeckoBridge.lastSessionPage = page
                settlePending = false
                close()
                return@readSessionPage
            }
            if (retriesLeft > 0) {
                mainHandler.postDelayed({
                    if (!closing) readSessionPageWithRetry(retriesLeft - 1)
                }, 4000)
                return@readSessionPage
            }
            // Two misses on a signed-in page: stale / mixed jar.
            settlePending = false
            if (!wipedOnce) {
                wipedOnce = true
                setStatus("That login looks stale — starting a fresh sign-in…")
                wipeProfileThenLoad(GeckoBridge.SIGN_IN_URL)
            } else {
                setStatus("Loading Google sign-in…")
                session?.loadUri(GeckoBridge.SIGN_IN_URL)
            }
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        val s = session
        if (s != null && !currentUrl.startsWith("https://gemini.google.com")) {
            s.goBack()
            return
        }
        close()
    }

    private fun close() {
        if (closing) return
        // v124 — a settle is already reading the session token;
        // let it finish and close by itself instead of cutting
        // it off (a manual close mid-settle used to lose the
        // token and fall back to the bot-blocked Dart verify).
        if (settlePending) return
        closing = true
        finish()
    }

    /** The renderer died: no token can be read from a dead tab,
     * so do not wait a settle out — close at once. */
    private fun closeAfterCrash() {
        if (closing) return
        closing = true
        finish()
    }

    override fun onDestroy() {
        mainHandler.removeCallbacks(pollRunnable)
        try {
            session?.close()
        } catch (_: Exception) {
        }
        session = null
        GeckoBridge.signInFinished(applicationContext)
        super.onDestroy()
    }
}
