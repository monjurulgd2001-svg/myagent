package com.geminihd.studio

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorFilter
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.graphics.drawable.ShapeDrawable
import android.graphics.drawable.shapes.OvalShape
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.ProgressBar
import org.mozilla.geckoview.AllowOrDeny
import org.mozilla.geckoview.GeckoResult
import org.mozilla.geckoview.GeckoSession
import org.mozilla.geckoview.GeckoView

/**
 * Image to Prompt browser for Android: the built-in Firefox engine with the
 * same picture overlay as the Windows app ("Select pictures" -> tap
 * pictures -> "Generate prompts"). Prompts are made by the app in the
 * background; the back arrow returns to the app's prompt list.
 */
class GeckoBrowserActivity : Activity() {
    private lateinit var view: GeckoView
    private lateinit var urlField: EditText
    private lateinit var progress: ProgressBar
    private lateinit var reload: ImageButton
    private var session: GeckoSession? = null
    private var mainSession: GeckoSession? = null

    /** Popup windows (window.open), e.g. "Continue with Google" on
     *  Pinterest. They stay linked to their opener page so the sign-in can
     *  post its result back and close itself, like in a desktop browser. */
    private val popups = ArrayList<GeckoSession>()
    private val backable = HashMap<GeckoSession, Boolean>()
    private var loading = false
    private var density = 1f

    /** Last location reported for the main tab, and the page this
     * screen was asked to show. Used by the blank-tab self-heal:
     * when the kept tab's renderer process dies while the app is in
     * the background, the tab reopens stuck on about:blank and
     * silently ignores loads (seen on device 2026-11-09: Pinterest
     * opened once, every reopen after Back was a blank page). */
    private var curUrl: String = ""
    private var wantedUrl: String? = null

    /** Load watchdog (v39): every explicit main-tab load must be
     * answered by the renderer with onPageStart within a few
     * seconds. A tab whose renderer was reaped while the app was
     * away accepts loadUri calls but never starts loading — and
     * the v19 blank check missed it twice over: it only ran on
     * onCreate (reopening a still-alive screen goes through
     * onNewIntent), and it trusted curUrl, which a dead tab can
     * still report from its remembered history while painting
     * nothing (on device 2026-11-11: Pinterest opens once, every
     * reopen after Back stays blank). The watchdog rebuilds the
     * tab when the start signal never comes. */
    private val mainHandler =
        android.os.Handler(android.os.Looper.getMainLooper())
    private var loadWatchdog: Runnable? = null
    private var loadStarted = false
    private var watchdogRebuilds = 0

    private fun dp(v: Int) = (v * density).toInt()

    /** Round icon button with a ripple, drawn with the app's own glyphs. */
    private fun iconButton(glyph: Glyph.Kind, desc: String, onTap: () -> Unit): ImageButton {
        val b = ImageButton(this)
        b.setImageDrawable(Glyph(glyph, Color.parseColor("#E6E6F0")))
        b.scaleType = android.widget.ImageView.ScaleType.FIT_CENTER
        b.setPadding(dp(11), dp(11), dp(11), dp(11))
        b.background = RippleDrawable(
            ColorStateList.valueOf(Color.parseColor("#33FFFFFF")), null,
            ShapeDrawable(OvalShape()))
        b.contentDescription = desc
        if (Build.VERSION.SDK_INT >= 26) b.tooltipText = desc
        b.setOnClickListener { onTap() }
        return b
    }

    private fun setLoading(v: Boolean) {
        if (loading == v) return
        loading = v
        reload.setImageDrawable(Glyph(
            if (v) Glyph.Kind.CLOSE else Glyph.Kind.RELOAD,
            Color.parseColor("#E6E6F0")))
        reload.contentDescription = if (v) "Stop loading" else "Reload"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        GeckoBridge.browserActivity = this
        density = resources.displayMetrics.density
        val barColor = Color.parseColor("#15161D")
        if (Build.VERSION.SDK_INT >= 21) {
            window.statusBarColor = barColor
            window.navigationBarColor = Color.parseColor("#0E0F14")
        }

        val root = LinearLayout(this)
        root.orientation = LinearLayout.VERTICAL
        root.setBackgroundColor(Color.parseColor("#0E0F14"))
        root.fitsSystemWindows = true

        val bar = LinearLayout(this)
        bar.orientation = LinearLayout.HORIZONTAL
        bar.gravity = Gravity.CENTER_VERTICAL
        bar.setPadding(dp(6), dp(8), dp(6), dp(8))
        bar.setBackgroundColor(barColor)

        val close = iconButton(Glyph.Kind.CLOSE, "Back to Zedge Studio") {
            if (popups.isNotEmpty()) closePopup(popups.last()) else finish()
        }
        bar.addView(close, LinearLayout.LayoutParams(dp(44), dp(44)))

        urlField = EditText(this)
        urlField.setSingleLine(true)
        urlField.hint = "Search images or type a website"
        urlField.setTextColor(Color.parseColor("#F2F2F7"))
        urlField.setHintTextColor(Color.parseColor("#8B8CA3"))
        urlField.textSize = 14.5f
        urlField.imeOptions = EditorInfo.IME_ACTION_GO
        urlField.inputType = android.text.InputType.TYPE_CLASS_TEXT or
            android.text.InputType.TYPE_TEXT_VARIATION_URI
        urlField.setSelectAllOnFocus(true)
        urlField.background = GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = dp(22).toFloat()
            setColor(Color.parseColor("#24252F"))
            setStroke(dp(1), Color.parseColor("#33344A"))
        }
        urlField.setPadding(dp(14), 0, dp(14), 0)
        val search = Glyph(Glyph.Kind.SEARCH, Color.parseColor("#8B8CA3"))
        search.setBounds(0, 0, dp(18), dp(18))
        urlField.setCompoundDrawables(search, null, null, null)
        urlField.compoundDrawablePadding = dp(10)
        urlField.setOnEditorActionListener { _, actionId, ev ->
            if (actionId == EditorInfo.IME_ACTION_GO ||
                (ev != null && ev.keyCode == KeyEvent.KEYCODE_ENTER)) {
                load(urlField.text.toString())
                true
            } else false
        }
        val urlLp = LinearLayout.LayoutParams(0, dp(44), 1f)
        urlLp.setMargins(dp(4), 0, dp(4), 0)
        bar.addView(urlField, urlLp)

        reload = iconButton(Glyph.Kind.RELOAD, "Reload") {
            if (loading) session?.stop() else session?.reload()
        }
        bar.addView(reload, LinearLayout.LayoutParams(dp(44), dp(44)))

        root.addView(bar, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        progress = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal)
        progress.max = 100
        progress.visibility = View.INVISIBLE
        if (Build.VERSION.SDK_INT >= 21) {
            progress.progressTintList = ColorStateList.valueOf(Color.parseColor("#8B7CF6"))
            progress.progressBackgroundTintList = ColorStateList.valueOf(barColor)
        }
        // INVISIBLE (not GONE) so the page does not jump when loading ends.
        val pLp = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(2))
        root.addView(progress, pLp)

        view = GeckoView(this)
        root.addView(view, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        setContentView(root)

        val s = GeckoBridge.browserSession(this)
        attach(s)
        view.setSession(s)
        session = s
        mainSession = s
        GeckoBridge.browserState()
        val url = intent.getStringExtra("url")
        wantedUrl = url
        if (url != null) load(url)
        // Blank-tab self-heal (see curUrl): if the kept tab lost its
        // renderer while the app was away, it is still sitting on
        // about:blank a moment after opening — rebuild it then.
        android.os.Handler(mainLooper).postDelayed({ healIfBlank() }, 2000)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.getStringExtra("url")?.let {
            wantedUrl = it
            load(it)
        }
        // Reopening a still-alive screen never hits onCreate, so
        // run the blank check here too (the load above also arms
        // the watchdog on its own).
        mainHandler.postDelayed({ healIfBlank() }, 2000)
    }

    private fun attach(s: GeckoSession) {
        s.navigationDelegate = object : GeckoSession.NavigationDelegate {
            override fun onLocationChange(
                session: GeckoSession,
                url: String?,
                perms: MutableList<GeckoSession.PermissionDelegate.ContentPermission>,
                hasUserGesture: Boolean
            ) {
                if (session === mainSession) {
                    curUrl = url ?: ""
                    if (!url.isNullOrEmpty() && url != "about:blank")
                        GeckoBridge.lastBrowserUrl = url
                }
                if (session === this@GeckoBrowserActivity.session && !urlField.hasFocus())
                    urlField.setText(url ?: "")
            }

            override fun onCanGoBack(session: GeckoSession, canGoBack: Boolean) {
                backable[session] = canGoBack
            }

            // New windows open as real popups (kept linked to the opener),
            // so OAuth / "Sign in with Google" can report back and close.
            override fun onNewSession(session: GeckoSession, uri: String): GeckoResult<GeckoSession>? {
                return GeckoResult.fromValue(openPopup(session))
            }

            override fun onLoadRequest(
                session: GeckoSession,
                request: GeckoSession.NavigationDelegate.LoadRequest
            ): GeckoResult<AllowOrDeny>? = null
        }
        s.contentDelegate = object : GeckoSession.ContentDelegate {
            // window.close() from a popup (sign-in finished).
            override fun onCloseRequest(session: GeckoSession) {
                if (popups.contains(session)) closePopup(session)
            }

            // The page's renderer process crashed: the session is
            // dead weight now — rebuild the tab (see recoverDead).
            override fun onCrash(session: GeckoSession) {
                recoverDead(session)
            }

            // The page's renderer process was killed (Android reaps
            // it under memory pressure while the app is away): same
            // zombie state as a crash — rebuild the tab.
            override fun onKill(session: GeckoSession) {
                recoverDead(session)
            }
        }
        s.progressDelegate = object : GeckoSession.ProgressDelegate {
            override fun onPageStart(session: GeckoSession, url: String) {
                if (session === mainSession) {
                    // Proof the renderer is alive (watchdog food).
                    loadStarted = true
                    watchdogRebuilds = 0
                }
                if (session !== this@GeckoBrowserActivity.session) return
                progress.visibility = View.VISIBLE
                progress.progress = 5
                setLoading(true)
            }

            override fun onProgressChange(session: GeckoSession, p: Int) {
                if (session !== this@GeckoBrowserActivity.session) return
                progress.progress = p
                progress.visibility = if (p >= 100) View.INVISIBLE else View.VISIBLE
            }

            override fun onPageStop(session: GeckoSession, success: Boolean) {
                if (session !== this@GeckoBrowserActivity.session) return
                progress.visibility = View.INVISIBLE
                setLoading(false)
            }
        }
    }

    /** Creates (not opens - Gecko opens it) the popup session and shows it. */
    private fun openPopup(opener: GeckoSession): GeckoSession {
        val p = GeckoSession(opener.settings)
        attach(p)
        popups.add(p)
        show(p)
        return p
    }

    private fun closePopup(p: GeckoSession) {
        val i = popups.indexOf(p)
        if (i < 0) return
        popups.removeAt(i)
        backable.remove(p)
        val next = if (popups.isNotEmpty()) popups.last() else mainSession
        if (session === p && next != null) show(next)
        try {
            p.navigationDelegate = null
            p.progressDelegate = null
            p.contentDelegate = null
            p.close()
        } catch (_: Exception) {
        }
    }

    private fun show(s: GeckoSession) {
        try {
            view.releaseSession()
        } catch (_: Exception) {
        }
        view.setSession(s)
        session = s
        progress.visibility = View.INVISIBLE
        setLoading(false)
        view.requestFocus()
    }

    /** One-shot check shortly after opening: a healthy tab has
     * committed SOME page by now (a load reports its location as
     * soon as it starts). Still blank means the kept tab is a
     * zombie — rebuild it and load what should be showing. */
    private fun healIfBlank() {
        if (isDestroyed || isFinishing) return
        if (session !== mainSession) return
        if (curUrl.isNotEmpty() && curUrl != "about:blank") return
        val target = wantedUrl ?: GeckoBridge.lastBrowserUrl
        if (target != null && target != "about:blank") {
            rebuildMainSession(target)
        } else if (wantedUrl == null && GeckoBridge.lastBrowserUrl == null) {
            // First-ever open with nothing to restore: never sit blank.
            load("https://www.google.com/imghp")
        }
    }

    /** A popup dying is unremarkable; the MAIN tab dying leaves the
     * browser unusable, so rebuild it on the spot. */
    private fun recoverDead(dead: GeckoSession) {
        if (isDestroyed || isFinishing) return
        if (popups.contains(dead)) {
            closePopup(dead)
            return
        }
        if (dead !== mainSession) return
        val target = wantedUrl ?: GeckoBridge.lastBrowserUrl
        rebuildMainSession(target ?: "https://www.google.com/imghp")
    }

    /** Throws the dead main tab away and opens a fresh one at
     * [target]. Runs on the main thread (GeckoView delegate
     * callbacks and the self-heal timer both live there). */
    private fun rebuildMainSession(target: String) {
        try {
            GeckoBridge.invalidateBrowserSession()
            val s = GeckoBridge.browserSession(this)
            attach(s)
            show(s)
            mainSession = s
            curUrl = ""
            load(target)
            GeckoBridge.browserState()
        } catch (_: Exception) {
        }
    }

    /** Renders the visible page and cuts out the area (shares 0..1 of the
     *  view). [done] gets base64 PNG or null, on the main thread. */
    fun capture(fx: Double, fy: Double, fw: Double, fh: Double, done: (String?) -> Unit) {
        val main = android.os.Handler(mainLooper)
        try {
            view.capturePixels().accept({ bmp ->
                if (bmp == null) {
                    main.post { done(null) }
                } else {
                    Thread {
                        val out = try {
                            val bw = bmp.width
                            val bh = bmp.height
                            val x = (fx * bw).toInt().coerceIn(0, bw - 1)
                            val y = (fy * bh).toInt().coerceIn(0, bh - 1)
                            val w = (fw * bw).toInt().coerceIn(1, bw - x)
                            val h = (fh * bh).toInt().coerceIn(1, bh - y)
                            val crop = android.graphics.Bitmap.createBitmap(bmp, x, y, w, h)
                            val bos = java.io.ByteArrayOutputStream()
                            crop.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, bos)
                            android.util.Base64.encodeToString(bos.toByteArray(), android.util.Base64.NO_WRAP)
                        } catch (e: Throwable) {
                            null
                        }
                        main.post { done(out) }
                    }.start()
                }
            }, { _ ->
                main.post { done(null) }
            })
        } catch (e: Throwable) {
            done(null)
        }
    }

    fun load(input: String) {
        val u = normalize(input)
        urlField.setText(u)
        urlField.clearFocus()
        (getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager)
            .hideSoftInputFromWindow(urlField.windowToken, 0)
        view.requestFocus()
        session?.loadUri(u)
        armLoadWatchdog(u)
    }

    /** After loadUri, a live renderer answers with onPageStart
     * almost immediately, however slow the network is; a dead
     * one never answers at all. No answer within 2.5 s therefore
     * means the kept tab is a zombie — rebuild it at the page
     * that was asked for. Capped at 2 rebuilds in a row so a
     * genuinely broken runtime cannot loop forever. */
    private fun armLoadWatchdog(target: String) {
        loadWatchdog?.let { mainHandler.removeCallbacks(it) }
        loadStarted = false
        val w = Runnable {
            loadWatchdog = null
            if (isDestroyed || isFinishing) return@Runnable
            if (session !== mainSession) return@Runnable
            if (loadStarted) return@Runnable
            if (watchdogRebuilds >= 2) return@Runnable
            watchdogRebuilds++
            rebuildMainSession(target)
        }
        loadWatchdog = w
        mainHandler.postDelayed(w, 2500)
    }

    private fun normalize(input: String): String {
        val t = input.trim()
        if (t.isEmpty()) return "https://www.google.com/imghp"
        if (Regex("^[a-zA-Z][a-zA-Z0-9+.-]*://").containsMatchIn(t)) return t
        if (!t.contains(' ') && t.contains('.')) return "https://$t"
        return "https://www.google.com/search?tbm=isch&q=" +
            java.net.URLEncoder.encode(t, "UTF-8")
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        val cur = session
        if (cur != null && backable[cur] == true) {
            cur.goBack()
            return
        }
        if (cur != null && popups.contains(cur)) {
            closePopup(cur)
            return
        }
        @Suppress("DEPRECATION")
        super.onBackPressed()
    }

    override fun onDestroy() {
        loadWatchdog?.let { mainHandler.removeCallbacks(it) }
        loadWatchdog = null
        // Keep the tab (and its page) alive for the next time; just detach.
        try {
            view.releaseSession()
        } catch (_: Exception) {
        }
        for (p in ArrayList(popups)) {
            try {
                p.close()
            } catch (_: Exception) {
            }
        }
        popups.clear()
        mainSession?.navigationDelegate = null
        mainSession?.progressDelegate = null
        mainSession?.contentDelegate = null
        if (GeckoBridge.browserActivity === this) GeckoBridge.browserActivity = null
        GeckoBridge.browserState()
        super.onDestroy()
    }
}

/** Minimal line icons (24-unit grid) so the toolbar matches the app. */
class Glyph(private val kind: Kind, color: Int) : Drawable() {
    enum class Kind { CLOSE, RELOAD, SEARCH, BACK }

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        this.color = color
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        this.color = color
        style = Paint.Style.FILL
    }

    override fun getIntrinsicWidth() = 72
    override fun getIntrinsicHeight() = 72

    override fun draw(canvas: Canvas) {
        val b = bounds
        val size = minOf(b.width(), b.height()).toFloat()
        if (size <= 0f) return
        val k = size / 24f
        canvas.save()
        canvas.translate(b.left + (b.width() - size) / 2f, b.top + (b.height() - size) / 2f)
        canvas.scale(k, k)
        paint.strokeWidth = 2f
        when (kind) {
            Kind.CLOSE -> {
                canvas.drawLine(6f, 6f, 18f, 18f, paint)
                canvas.drawLine(18f, 6f, 6f, 18f, paint)
            }
            Kind.BACK -> {
                canvas.drawLine(19f, 12f, 5f, 12f, paint)
                val p = Path()
                p.moveTo(11f, 6f); p.lineTo(5f, 12f); p.lineTo(11f, 18f)
                canvas.drawPath(p, paint)
            }
            Kind.SEARCH -> {
                canvas.drawCircle(10.5f, 10.5f, 6f, paint)
                canvas.drawLine(15f, 15f, 20f, 20f, paint)
            }
            Kind.RELOAD -> {
                canvas.drawArc(RectF(5f, 5f, 19f, 19f), 20f, 290f, false, paint)
                // Arrow head at the end of the arc (310 deg, upper right).
                val a = Math.toRadians(310.0)
                val ex = (12 + 7 * Math.cos(a)).toFloat()
                val ey = (12 + 7 * Math.sin(a)).toFloat()
                val dx = (-Math.sin(a)).toFloat()
                val dy = Math.cos(a).toFloat()
                val p = Path()
                p.moveTo(ex + dx * 3.2f, ey + dy * 3.2f)
                p.lineTo(ex - dy * 3f, ey + dx * 3f)
                p.lineTo(ex + dy * 3f, ey - dx * 3f)
                p.close()
                canvas.drawPath(p, fill)
            }
        }
        canvas.restore()
    }

    override fun setAlpha(alpha: Int) {
        paint.alpha = alpha
        fill.alpha = alpha
    }

    override fun setColorFilter(colorFilter: ColorFilter?) {
        paint.colorFilter = colorFilter
        fill.colorFilter = colorFilter
    }

    @Deprecated("Deprecated in Java")
    override fun getOpacity(): Int = PixelFormat.TRANSLUCENT
}
