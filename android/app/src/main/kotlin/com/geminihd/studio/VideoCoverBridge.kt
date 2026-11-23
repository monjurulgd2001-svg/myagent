package com.geminihd.studio

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.YuvImage
import android.media.Image
import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
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
// v167 — the recipe is now the panel's, exactly: the file is
// copied to a temp file WITH its real extension so the
// extractor can sniff the container, the duration is read and
// the points are coerced inside it, and a 0ms grab is the last
// resort when every point misses. The old code called
// setDataSource() on the original path directly — the one
// difference from the proven panel capture on this device.
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
    private const val TAG = "VideoCoverBridge"

    // v168 — a frame whose average luma is below this counts as
    // BLACK (same threshold as the Dart gate, kCoverMinLuminance).
    private const val BLACK_LUMA = 10.0

    // v168 — hard stop for one software-decode pass.
    private const val SOFT_TIMEOUT_MS = 90_000L

    fun captureCoverFrames(
        context: Context,
        path: String,
        pointsMs: List<Long>,
        result: MethodChannel.Result,
    ) {
        Thread {
            val frames = try {
                capture(context, path, pointsMs)
            } catch (_: Exception) {
                emptyList<ByteArray?>()
            }
            Handler(Looper.getMainLooper()).post { result.success(frames) }
        }.start()
    }

    private fun capture(
        context: Context,
        path: String,
        pointsMs: List<Long>,
    ): List<ByteArray?> {
        val src = java.io.File(path)
        if (!src.exists()) return List(pointsMs.size) { null }
        // v167 — the panel's recipe, exactly
        // (VideoUtils.captureFrames in the Zedge Content Studio
        // panel): copy to a temp file WITH the real extension so
        // the extractor can sniff the container, read the
        // duration and coerce the points inside it. The old code
        // called setDataSource() on the original path directly —
        // the one difference from the proven panel capture on
        // this device (live 2026-11-23: all five v166 picker
        // candidates black for a bright video).
        val ext = Regex("\\.[A-Za-z0-9]{2,4}$")
            .find(src.name.lowercase())?.value ?: ".mp4"
        val tmp = java.io.File.createTempFile("vid", ext, context.cacheDir)
        val mr = MediaMetadataRetriever()
        try {
            tmp.writeBytes(src.readBytes())
            mr.setDataSource(tmp.absolutePath)
            val duration = mr.extractMetadata(
                MediaMetadataRetriever.METADATA_KEY_DURATION
            )?.toLongOrNull() ?: 0L
            val points: List<Long> = if (duration > 0L) {
                pointsMs.map {
                    it.coerceIn(0L, (duration - 40L).coerceAtLeast(0L))
                }
            } else {
                pointsMs
            }
            val out = ArrayList<ByteArray?>(points.size)
            for (atMs in points) {
                val bmp = grabFrame(mr, atMs)
                if (bmp == null) {
                    out.add(null)
                    continue
                }
                // v168 — the phone's HARDWARE decoder returns a
                // BLACK bitmap (not null) for Gemini's H.264 High
                // @ 5.2 1620x2880@60fps files (live 2026-11-23:
                // every picker candidate black for a bright
                // video). A black frame is treated as "no frame"
                // here so the software decoder below gets it.
                if (isBlack(bmp)) {
                    Log.w(TAG, "retriever frame at ${atMs}ms is black")
                    try {
                        bmp.recycle()
                    } catch (_: Exception) {
                    }
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
            // v168 — software decode for every slot the retriever
            // missed or returned black: MediaCodec on Android's own
            // software AVC decoder (c2.android.avc.decoder), which
            // does not depend on the phone's hardware decoder.
            val missing = out.indices.filter { out[it] == null }
            if (missing.isNotEmpty()) {
                try {
                    val soft = softwareCaptureFrames(
                        tmp.absolutePath, missing.map { points[it] })
                    for ((k, idx) in missing.withIndex()) {
                        if (k < soft.size && soft[k] != null) out[idx] = soft[k]
                    }
                } catch (e: Throwable) {
                    Log.w(TAG, "software capture failed: $e")
                }
            }
            // Panel fallback: when every point missed, one grab
            // at 0ms — a file with decodable frames usually
            // yields its first frame even when the percentage
            // points miss.
            if (out.isNotEmpty() && out.all { it == null }) {
                val bmp0 = grabFrame(mr, 0L)
                if (bmp0 != null && !isBlack(bmp0)) {
                    try {
                        out[0] = toPortraitJpeg(bmp0)
                    } catch (_: Exception) {
                    } finally {
                        try {
                            bmp0.recycle()
                        } catch (_: Exception) {
                        }
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
            try {
                tmp.delete()
            } catch (_: Exception) {
            }
        }
    }

    // ---------------------------------------------------------------
    // v168 — black-frame check + software decode
    // ---------------------------------------------------------------

    private fun isBlack(bmp: Bitmap): Boolean {
        return try {
            val small = Bitmap.createScaledBitmap(bmp, 16, 16, true)
            val px = IntArray(256)
            small.getPixels(px, 0, 16, 0, 0, 16, 16)
            if (small !== bmp) small.recycle()
            var sum = 0.0
            for (p in px) {
                sum += 0.2126 * ((p shr 16) and 0xFF) +
                    0.7152 * ((p shr 8) and 0xFF) +
                    0.0722 * (p and 0xFF)
            }
            sum / 256.0 < BLACK_LUMA
        } catch (_: Exception) {
            false
        }
    }

    // The software-only decoders for [mime] (c2.android.* /
    // OMX.google.*), never the vendor hardware one that returned
    // the black frames.
    private fun softwareDecoderNames(mime: String): List<String> {
        val out = ArrayList<String>()
        try {
            for (info in MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos) {
                if (info.isEncoder) continue
                if (!info.supportedTypes.any { it.equals(mime, ignoreCase = true) }) continue
                val soft = if (Build.VERSION.SDK_INT >= 29) {
                    info.isSoftwareOnly
                } else {
                    info.name.startsWith("OMX.google.") ||
                        info.name.startsWith("c2.android.")
                }
                if (soft) out.add(info.name)
            }
        } catch (e: Exception) {
            Log.w(TAG, "codec list failed: $e")
        }
        return out
    }

    private fun startSoftwareDecoder(mime: String, format: MediaFormat): MediaCodec? {
        for (name in softwareDecoderNames(mime)) {
            var c: MediaCodec? = null
            try {
                c = MediaCodec.createByCodecName(name)
                c.configure(format, null, null, 0)
                c.start()
                Log.i(TAG, "software decoder: $name")
                return c
            } catch (e: Exception) {
                Log.w(TAG, "decoder $name failed: $e")
                try {
                    c?.release()
                } catch (_: Exception) {
                }
            }
        }
        return null
    }

    /**
     * One software-decode pass over the first seconds of the video:
     * returns one portrait JPEG per entry of [pointsMs] (same
     * order; null = no frame). For each point the FIRST decoded
     * frame with presentation time >= the point is used, so the
     * whole 2-4s cover window costs a single pass. Frames that no
     * point wants are released without any conversion.
     */
    private fun softwareCaptureFrames(path: String, pointsMs: List<Long>): List<ByteArray?> {
        val results = arrayOfNulls<ByteArray>(pointsMs.size)
        if (pointsMs.isEmpty()) return results.toList()
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(path)
            var track = -1
            var format: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                val m = f.getString(MediaFormat.KEY_MIME) ?: ""
                if (m.startsWith("video/")) {
                    track = i
                    format = f
                    break
                }
            }
            if (track < 0 || format == null) return results.toList()
            extractor.selectTrack(track)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: return results.toList()
            val rotation = if (format.containsKey(MediaFormat.KEY_ROTATION)) {
                format.getInteger(MediaFormat.KEY_ROTATION)
            } else {
                0
            }
            val dec = startSoftwareDecoder(mime, format) ?: return results.toList()
            codec = dec

            val order = pointsMs.indices.sortedBy { pointsMs[it] }
            var next = 0
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            var lastJpeg: ByteArray? = null
            val deadline = System.currentTimeMillis() + SOFT_TIMEOUT_MS
            while (!outputDone && next < order.size &&
                System.currentTimeMillis() < deadline) {
                if (!inputDone) {
                    val inIdx = dec.dequeueInputBuffer(10_000L)
                    if (inIdx >= 0) {
                        val buf = dec.getInputBuffer(inIdx)
                        val size = if (buf != null) extractor.readSampleData(buf, 0) else -1
                        if (size < 0) {
                            dec.queueInputBuffer(inIdx, 0, 0, 0L,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            dec.queueInputBuffer(inIdx, 0, size,
                                extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val outIdx = dec.dequeueOutputBuffer(info, 10_000L)
                if (outIdx >= 0) {
                    val ptsMs = info.presentationTimeUs / 1000L
                    val eos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                    val due = next < order.size && ptsMs >= pointsMs[order[next]]
                    if ((due || eos) && info.size > 0) {
                        var jpeg: ByteArray? = null
                        var image: Image? = null
                        try {
                            image = dec.getOutputImage(outIdx)
                            if (image != null) jpeg = imageToPortraitJpeg(image, rotation)
                        } catch (e: Throwable) {
                            Log.w(TAG, "frame convert failed: $e")
                        } finally {
                            try {
                                image?.close()
                            } catch (_: Exception) {
                            }
                        }
                        if (jpeg != null) {
                            lastJpeg = jpeg
                            while (next < order.size &&
                                ptsMs >= pointsMs[order[next]]) {
                                results[order[next]] = jpeg
                                next++
                            }
                        }
                    }
                    if (eos) {
                        // The clip ended before the later points:
                        // they get the last frame that was decoded.
                        while (next < order.size) {
                            if (lastJpeg != null) results[order[next]] = lastJpeg
                            next++
                        }
                        outputDone = true
                    }
                    dec.releaseOutputBuffer(outIdx, false)
                }
            }
        } finally {
            try {
                codec?.stop()
            } catch (_: Exception) {
            }
            try {
                codec?.release()
            } catch (_: Exception) {
            }
            try {
                extractor.release()
            } catch (_: Exception) {
            }
        }
        return results.toList()
    }

    // YUV_420_888 (cropped, any stride) -> NV21 -> bitmap ->
    // rotated -> the same portrait JPEG as every other path.
    private fun imageToPortraitJpeg(image: Image, rotation: Int): ByteArray? {
        val crop = image.cropRect
        val w = crop.width() and 1.inv()
        val h = crop.height() and 1.inv()
        val nv21 = yuv420ToNv21(image, crop, w, h) ?: return null
        val yuv = YuvImage(nv21, ImageFormat.NV21, w, h, null)
        val bos = ByteArrayOutputStream()
        if (!yuv.compressToJpeg(Rect(0, 0, w, h), 95, bos)) return null
        val jb = bos.toByteArray()
        var bmp = BitmapFactory.decodeByteArray(jb, 0, jb.size) ?: return null
        if (rotation != 0) {
            val m = Matrix()
            m.postRotate(rotation.toFloat())
            val r = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, m, true)
            if (r !== bmp) {
                bmp.recycle()
                bmp = r
            }
        }
        try {
            return toPortraitJpeg(bmp)
        } finally {
            bmp.recycle()
        }
    }

    private fun yuv420ToNv21(image: Image, crop: Rect, w: Int, h: Int): ByteArray? {
        if (w <= 0 || h <= 0) return null
        val planes = image.planes
        if (planes.size < 3) return null
        val out = ByteArray(w * h * 3 / 2)
        val yb = planes[0].buffer.duplicate()
        val yRow = planes[0].rowStride
        val yPix = planes[0].pixelStride
        var pos = 0
        for (row in 0 until h) {
            val base = (row + crop.top) * yRow + crop.left * yPix
            if (yPix == 1) {
                yb.position(base)
                yb.get(out, pos, w)
                pos += w
            } else {
                for (col in 0 until w) {
                    out[pos++] = yb.get(base + col * yPix)
                }
            }
        }
        val ub = planes[1].buffer.duplicate()
        val vb = planes[2].buffer.duplicate()
        val uRow = planes[1].rowStride
        val uPix = planes[1].pixelStride
        val vRow = planes[2].rowStride
        val vPix = planes[2].pixelStride
        for (row in 0 until h / 2) {
            val cy = row + crop.top / 2
            for (col in 0 until w / 2) {
                val cx = col + crop.left / 2
                out[pos++] = vb.get(cy * vRow + cx * vPix)
                out[pos++] = ub.get(cy * uRow + cx * uPix)
            }
        }
        return out
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
