package com.geminihd.studio

import android.app.Activity
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import org.mozilla.geckoview.GeckoSession
import org.mozilla.geckoview.GeckoSessionSettings
import org.mozilla.geckoview.GeckoView

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
    private var currentUrl = ""

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
                close()
            }

            override fun onKill(session: GeckoSession) {
                close()
            }
        }
        s.open(GeckoBridge.runtime(this))
        view.setSession(s)
        session = s
        s.loadUri(intent.getStringExtra("url") ?: GeckoBridge.SIGN_IN_URL)
    }

    /** After each page load: signed in and back on Gemini -> close. */
    private fun checkSignedIn() {
        if (closing) return
        if (!currentUrl.startsWith("https://gemini.google.com")) return
        GeckoBridge.readCookies(this, 4000) { json ->
            if (!closing && GeckoBridge.hasPsid(json)) close()
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
        closing = true
        finish()
    }

    override fun onDestroy() {
        try {
            session?.close()
        } catch (_: Exception) {
        }
        session = null
        GeckoBridge.signInFinished(applicationContext)
        super.onDestroy()
    }
}
