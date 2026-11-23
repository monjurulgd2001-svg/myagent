package com.geminihd.studio

import android.content.Context
import android.view.View
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import org.mozilla.geckoview.GeckoSession
import org.mozilla.geckoview.GeckoSessionSettings
import org.mozilla.geckoview.GeckoView

/**
 * v156 — the in-app browser engine (GeckoView) embedded inside the
 * phone-mockup preview, for MP4s the phone's hardware decoder
 * rejects.
 *
 * Live 2026-11-22: the finished animation failed the in-frame
 * video_player with "MediaCodecVideoRenderer error" on TECNO CAMON
 * 30S, while the same file plays in Chrome — Gecko bundles its own
 * software decoders, so it plays what MediaCodec cannot. The
 * preview must happen ON THE DEVICE, inside the phone mockup, so
 * this view sits in the mockup's screen area (Dart:
 * lib/widgets/gecko_video_view.dart) instead of opening the
 * separate-activity browser.
 *
 * One FRESH GeckoSession per view, on the shared GeckoRuntime
 * (same settings as GeckoBridge.browserSession) — never the shared
 * browser tab session, so this view cannot steal or disturb the
 * Gemini tab. The session is closed with the view.
 *
 * v159 second pass — the URL this view loads is the WRAPPER page
 * (lib/widgets/video_preview_wrapper.dart: a minimal HTML page
 * with a cover-fit <video>, written next to the MP4 and handed
 * over as its file:// URL), NOT the raw MP4 URL: loading the raw
 * file showed Gecko's built-in media viewer with its own chrome
 * and a contain-fit with black bars instead of filling the mockup
 * screen. The factory itself stays generic — it loads whatever
 * URL it is given; the raw MP4 URL only arrives when the wrapper
 * could not be written (old behaviour, kept as the fallback).
 *
 * Registered in MainActivity.configureFlutterEngine as
 * "com.geminihd.studio/gecko_video".
 */
class GeckoVideoViewFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val url = (args as? Map<*, *>)?.get("url") as? String
        return GeckoVideoView(context, url)
    }
}

class GeckoVideoView(context: Context, url: String?) : PlatformView {
    private val view = GeckoView(context)
    private val session: GeckoSession

    init {
        session = GeckoSession(
            GeckoSessionSettings.Builder()
                .usePrivateMode(false)
                .useTrackingProtection(true)
                .build()
        )
        session.open(GeckoBridge.runtime(context))
        view.setSession(session)
        if (url != null) session.loadUri(url)
    }

    override fun getView(): View = view

    override fun dispose() {
        try {
            view.releaseSession()
        } catch (_: Exception) {
        }
        try {
            session.close()
        } catch (_: Exception) {
        }
    }
}
