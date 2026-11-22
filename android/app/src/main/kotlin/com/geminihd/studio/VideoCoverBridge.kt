package com.geminihd.studio

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import kotlin.math.max

// v166 — native cover capture, the panel's recipe
// (VideoUtils.captureFrames in the Zedge Content Studio panel):
// MediaMetadataRetriever, frames at duration percentages
// 0.08/0.28/0.50/0.72/0.92, a 4-option fallback per timestamp
// (CLOSEST_SYNC -> CLOSEST -> PREVIOUS_SYNC -> NEXT_SYNC ->
// frameAtTime), cover-scale center-cropped to portrait
// 1620x2880, JPEG 85. The panel's own submitVideo proves this
// API decodes Gemini's H.264 High @ 5.2 1620x2880@60fps files on
// this phone — the video_thumbnail plugin's single-option call
// returns null for the same files, so this channel is the FIRST
// capture path now (the plugin stays as a later fallback).
//
// One channel call returns one frame per requested timestamp,
// in the same order (a null slot means that timestamp yielded
// no frame), so Dart can line the frames up with the picker's
// timestamps. The work runs on a background thread (retriever
// + decode must never block the UI thread); the result is
// posted back to the main thread.
object VideoCoverBridge {
    private const val TARGET_W = 1620
    private const val TARGET_H = 2880

    fun captureCoverFrames(
        path: String,
        pointsMs: List<Long>,
        result: MethodChannel.Result,
    ) {
        Thread {
            val frames = try {
                capture(path, pointsMs)
            } catch (_: Exception) {
                emptyList<ByteArray?>()
            }
            Handler(Looper.getMainLooper()).post { result.success(frames) }
        }.start()
    }

    private fun capture(path: String, pointsMs: List<Long>): List<ByteArray?> {
        val file = java.io.File(path)
        if (!file.exists()) return List(pointsMs.size) { null }
        val mr = MediaMetadataRetriever()
        try {
            mr.setDataSource(path)
            val out = ArrayList<ByteArray?>(pointsMs.size)
            for (atMs in pointsMs) {
                val bmp = grabFrame(mr, atMs)
                if (bmp == null) {
                    out.add(null)
                    continue
                }
                try {
                    out.add(toPortraitJpeg(bmp))
                } catch (_: Exception) {
                    // A frame that cannot be encoded is skipped;
                    // the other timestamps still get their chance.
                    out.add(null)
                } finally {
                    try {
                        bmp.recycle()
                    } catch (_: Exception) {
                    }
                }
            }
            return out
        } catch (_: Exception) {
            return List(pointsMs.size) { null }
        } finally {
            try {
                mr.release()
            } catch (_: Exception) {
            }
        }
    }

    private fun grabFrame(mr: MediaMetadataRetriever, atMs: Long): Bitmap? {
        val us = atMs * 1000L
        val options = intArrayOf(
            MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
            MediaMetadataRetriever.OPTION_CLOSEST,
            MediaMetadataRetriever.OPTION_PREVIOUS_SYNC,
            MediaMetadataRetriever.OPTION_NEXT_SYNC
        )
        for (opt in options) {
            val bmp = try {
                mr.getFrameAtTime(us, opt)
            } catch (_: Exception) {
                null
            }
            if (bmp != null) return bmp
        }
        return try {
            mr.frameAtTime
        } catch (_: Exception) {
            null
        }
    }

    // Same cover-scale center crop as the panel's
    // ImageUtils.resizeToPortrait (JPEG 85 here, matching the
    // Studio's other cover paths, instead of the panel's 92 —
    // a smaller thumb uploads faster on a ~30 KB/s network).
    private fun toPortraitJpeg(src: Bitmap): ByteArray {
        val scale = max(TARGET_W.toFloat() / src.width, TARGET_H.toFloat() / src.height)
        val nw = src.width * scale
        val nh = src.height * scale
        val dx = (TARGET_W - nw) / 2f
        val dy = (TARGET_H - nh) / 2f
        val outBmp = Bitmap.createBitmap(TARGET_W, TARGET_H, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(outBmp)
        val paint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
        canvas.drawBitmap(src, null, RectF(dx, dy, dx + nw, dy + nh), paint)
        val bos = ByteArrayOutputStream()
        outBmp.compress(Bitmap.CompressFormat.JPEG, 85, bos)
        outBmp.recycle()
        return bos.toByteArray()
    }
}
