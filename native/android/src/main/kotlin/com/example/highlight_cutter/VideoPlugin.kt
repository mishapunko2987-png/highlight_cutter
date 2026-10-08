package com.example.highlight_cutter

import android.graphics.Bitmap
import android.media.FaceDetector
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.os.Looper
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

class VideoPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private companion object {
        const val CHANNEL = "highlight_cutter/video"
        const val PROGRESS_CHANNEL = "highlight_cutter/video_progress"
        const val ANALYSIS_WIDTH = 192
        const val MAX_ANALYSIS_FRAMES = 6000
        const val SHARP_NORM = 0.00012
        const val COLOR_NORM = 110.0
        const val MOTION_NORM = 0.18
        const val SCENE_THRESHOLD = 0.45
        const val DEFAULT_WIDTH = 720
        const val DEFAULT_HEIGHT = 1280
        const val DEFAULT_BITRATE = 6_000_000
        const val KEY_FRAME_RATE = 30
        const val KEY_I_FRAME_INTERVAL = 1
        const val TIMEOUT_US = 10_000L
    }

    private var channel: MethodChannel? = null
    private var progressChannel: MethodChannel? = null
    private var cancelled = false
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        progressChannel = MethodChannel(binding.binaryMessenger, PROGRESS_CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "listen", "cancel" -> result.success(null)
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        progressChannel = null
    }

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: MethodChannel.Result) {
        cancelled = false
        when (call.method) {
            "readMeta" -> handleReadMeta(call, result)
            "analyzeFrames" -> handleAnalyze(call, result)
            "exportClip" -> handleExportClip(call, result)
            "exportTrailer" -> handleExportTrailer(call, result)
            "thumbnail" -> handleThumbnail(call, result)
            "cancel" -> {
                cancelled = true
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun handleReadMeta(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path.isNullOrBlank()) {
            result.error("bad_args", "path is required", null)
            return
        }
        try {
            val retriever = MediaMetadataRetriever()
            retriever.setDataSource(path)
            val durationMs = retriever.extractMetadata(
                MediaMetadataRetriever.METADATA_KEY_DURATION
            )?.toLongOrNull() ?: 0L
            val width = retriever.extractMetadata(
                MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH
            )?.toIntOrNull() ?: 0
            val height = retriever.extractMetadata(
                MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT
            )?.toIntOrNull() ?: 0
            val rotation = retriever.extractMetadata(
                MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION
            )?.toIntOrNull() ?: 0
            retriever.release()
            result.success(
                mapOf(
                    "path" to path,
                    "durationUs" to durationMs * 1000L,
                    "width" to width,
                    "height" to height,
                    "fps" to 30.0,
                    "rotationDegrees" to rotation,
                )
            )
        } catch (e: Exception) {
            result.error("meta_failed", e.message, null)
        }
    }

    private fun handleAnalyze(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path.isNullOrBlank()) {
            result.error("bad_args", "path is required", null)
            return
        }
        val sampleFps = (call.argument<Double>("sampleFps") ?: 2.0).coerceIn(0.2, 10.0)
        val progressMethod = call.argument<String>("progressMethod") ?: "analyzeFrames"

        Thread {
            try {
                val analysis = analyze(path, sampleFps, progressMethod)
                if (!cancelled) result.success(analysis)
            } catch (e: Exception) {
                if (!cancelled) result.error("analyze_failed", e.message, null)
            }
        }.start()
    }

    private fun analyze(path: String, sampleFps: Double, progressMethod: String): Map<String, Any> {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            val durationMs = retriever.extractMetadata(
                MediaMetadataRetriever.METADATA_KEY_DURATION
            )?.toLongOrNull() ?: 0L
            if (durationMs <= 0) throw IllegalStateException("Пустое видео")

            val stepUs = max(1000L, (1_000_000.0 / sampleFps).toLong())
            var totalFrames = (durationMs * 1000L / stepUs).toInt() + 1
            var effectiveStep = stepUs
            if (totalFrames > MAX_ANALYSIS_FRAMES) {
                totalFrames = MAX_ANALYSIS_FRAMES
                effectiveStep = durationMs * 1000L / MAX_ANALYSIS_FRAMES
            }

            val writer = AnalysisWriter(totalFrames)

            var previous: FrameData? = null
            var lastBoundaryUs = 0L

            for (index in 0 until totalFrames) {
                if (cancelled) throw IllegalStateException("cancelled")
                val timeUs = index.toLong() * effectiveStep
                if (timeUs >= durationMs * 1000L) break

                val bitmap = retriever.getFrameAtTime(
                    timeUs,
                    MediaMetadataRetriever.OPTION_CLOSEST
                )
                if (bitmap != null) {
                    val current = FrameData.from(bitmap)
                    val shotLengthSec = (timeUs - lastBoundaryUs) / 1_000_000.0
                    if (shotLengthSec >= 0.4 && (current.histogramDistance(previous) > SCENE_THRESHOLD)) {
                        lastBoundaryUs = timeUs
                    }

                    // AnalysisWriter пишет обе дорожки на позицию taken, то
                    // есть по счётчику принятых кадров. Пропущенный кадр
                    // (bitmap == null) просто не добавляется, и тогда i-я
                    // позиция в обеих дорожках описывает один и тот же кадр.
                    writer.add(
                        doubleArrayOf(
                            timeUs.toDouble(),
                            current.sharpness,
                            current.lumaMean,
                            current.lumaStd,
                            current.clippedLow,
                            current.clippedHigh,
                            current.colorfulness,
                            current.faces.toDouble(),
                            current.motion(previous),
                            shotLengthSec,
                        ),
                        current.histogram,
                    )
                    previous = current
                    bitmap.recycle()
                }

                if (index % 5 == 0) {
                    val progress = index.toDouble() / totalFrames
                    mainHandler.post {
                        progressChannel?.invokeMethod(progressMethod, progress)
                    }
                }
            }

            if (writer.written == 0) throw IllegalStateException("Не удалось извлечь кадры")

            mainHandler.post { progressChannel?.invokeMethod(progressMethod, 1.0) }

            return mapOf(
                "metrics" to writer.metricsBytes(),
                "histograms" to writer.histogramBytes(),
                "sampleIntervalUs" to effectiveStep,
            )
        } finally {
            retriever.release()
        }
    }

    private fun handleExportClip(call: MethodCall, result: MethodChannel.Result) {
        val source = call.argument<String>("sourcePath")
        val output = call.argument<String>("outputPath")
        val startUs = call.argument<Int>("startUs")
        val endUs = call.argument<Int>("endUs")
        if (source.isNullOrBlank() || output.isNullOrBlank() ||
            startUs == null || endUs == null || endUs <= startUs
        ) {
            result.error("bad_args", "invalid clip range", null)
            return
        }
        val request = ExportRequest(
            sourcePath = source,
            outputPath = output,
            ranges = listOf(startUs.toLong() to endUs.toLong()),
            width = call.argument<Int>("width") ?: 0,
            height = call.argument<Int>("height") ?: 0,
            bitrate = call.argument<Int>("bitrate") ?: DEFAULT_BITRATE,
            fps = call.argument<Int>("fps") ?: 0,
        )
        Thread {
            try {
                result.success(VideoExporter(request).run())
            } catch (e: Exception) {
                result.error("export_failed", e.message, null)
            }
        }.start()
    }

    private fun handleExportTrailer(call: MethodCall, result: MethodChannel.Result) {
        val source = call.argument<String>("sourcePath")
        val output = call.argument<String>("outputPath")
        val ranges = call.argument<List<List<Int>>>("ranges")
        if (source.isNullOrBlank() || output.isNullOrBlank() || ranges.isNullOrEmpty()) {
            result.error("bad_args", "invalid trailer request", null)
            return
        }
        val parsed = ranges.mapNotNull { pair ->
            if (pair.size < 2) null else pair[0].toLong() to pair[1].toLong()
        }.filter { it.second > it.first }
        if (parsed.isEmpty()) {
            result.error("bad_args", "empty ranges", null)
            return
        }
        val request = ExportRequest(
            sourcePath = source,
            outputPath = output,
            ranges = parsed,
            width = call.argument<Int>("width") ?: 0,
            height = call.argument<Int>("height") ?: 0,
            bitrate = call.argument<Int>("bitrate") ?: 6_000_000,
            fps = call.argument<Int>("fps") ?: 0,
        )
        Thread {
            try {
                result.success(VideoExporter(request).run())
            } catch (e: Exception) {
                result.error("export_failed", e.message, null)
            }
        }.start()
    }

    private fun handleThumbnail(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        val timeUs = call.argument<Int>("timeUs") ?: 0
        if (path.isNullOrBlank()) {
            result.error("bad_args", "path is required", null)
            return
        }
        Thread {
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(path)
                val bitmap = retriever.getFrameAtTime(
                    timeUs.toLong(),
                    MediaMetadataRetriever.OPTION_CLOSEST
                )
                if (bitmap == null) {
                    result.success("")
                    return@Thread
                }
                val output = File(System.getProperty("java.io.tmpdir")!!, "thumb_${System.nanoTime()}.jpg")
                output.outputStream().use { stream ->
                    bitmap.compress(Bitmap.CompressFormat.JPEG, 88, stream)
                }
                bitmap.recycle()
                result.success(output.absolutePath)
            } catch (e: Exception) {
                result.error("thumb_failed", e.message, null)
            } finally {
                retriever.release()
            }
        }.start()
    }

    private class FrameData(
        val sharpness: Double,
        val lumaMean: Double,
        val lumaStd: Double,
        val clippedLow: Double,
        val clippedHigh: Double,
        val colorfulness: Double,
        val faces: Int,
        val histogram: ByteArray,
        val luma: DoubleArray,
        val lumaWidth: Int,
        val lumaHeight: Int,
    ) {
        fun motion(previous: FrameData?): Double {
            if (previous == null || luma.isEmpty()) return 0.0
            val other = previous.luma
            if (other.size != luma.size) return 0.0
            var sum = 0.0
            for (i in luma.indices) {
                sum += abs(luma[i] - other[i])
            }
            return min(1.0, sum / luma.size / MOTION_NORM)
        }

        fun histogramDistance(other: FrameData?): Double {
            if (other == null) return 0.0
            return FrameMetrics.histogramDistance(histogram, other.histogram)
        }

        companion object {
            fun from(bitmap: Bitmap): FrameData {
                val scaled = Bitmap.createScaledBitmap(bitmap, ANALYSIS_WIDTH, -1, true)
                val w = scaled.width
                val h = scaled.height
                val pixels = IntArray(w * h)
                scaled.getPixels(pixels, 0, w, 0, 0, w, h)
                if (scaled !== bitmap) scaled.recycle()

                val luma = DoubleArray(w * h)
                val binCounts = IntArray(HIST_BINS)
                var sum = 0.0
                var clippedLow = 0
                var clippedHigh = 0
                var rgMean = 0.0
                var ybMean = 0.0
                var rgSq = 0.0
                var ybSq = 0.0

                for (i in pixels.indices) {
                    val pixel = pixels[i]
                    val r = (pixel shr 16) and 0xFF
                    val g = (pixel shr 8) and 0xFF
                    val b = pixel and 0xFF
                    val y = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
                    luma[i] = y
                    sum += y
                    if (y <= 0.02) clippedLow++
                    if (y >= 0.98) clippedHigh++

                    val bin = ((y * 63).toInt()).coerceIn(0, 63)
                    binCounts[bin]++

                    val rg = (r - g).toDouble()
                    val yb = 0.5 * (r + g) - b
                    rgMean += rg
                    ybMean += yb
                    rgSq += rg * rg
                    ybSq += yb * yb
                }

                val count = pixels.size.toDouble()
                val mean = sum / count
                var variance = 0.0
                for (i in luma.indices) {
                    val d = luma[i] - mean
                    variance += d * d
                }
                variance /= count

                val rgStd = sqrt(max(0.0, rgSq / count - (rgMean / count) * (rgMean / count)))
                val ybStd = sqrt(max(0.0, ybSq / count - (ybMean / count) * (ybMean / count)))
                val magnitude = sqrt(
                    (rgMean / count) * (rgMean / count) + (ybMean / count) * (ybMean / count)
                )
                val colorfulness =
                    sqrt(rgStd * rgStd + ybStd * ybStd) + 0.3 * magnitude

                val sharpness = laplacianVariance(luma, w, h)
                val faces = detectFaces(bitmap)

                return FrameData(
                    sharpness = min(1.0, sharpness / SHARP_NORM),
                    lumaMean = mean,
                    lumaStd = sqrt(variance),
                    clippedLow = clippedLow / count,
                    clippedHigh = clippedHigh / count,
                    colorfulness = min(1.0, colorfulness / COLOR_NORM),
                    faces = faces,
                    histogram = normalizeBins(binCounts),
                    luma = luma,
                    lumaWidth = w,
                    lumaHeight = h,
                )
            }

            private fun normalizeBins(binCounts: IntArray): ByteArray =
                FrameMetrics.normalizeBins(binCounts)

            private fun laplacianVariance(luma: DoubleArray, w: Int, h: Int): Double {
                if (w < 3 || h < 3) return 0.0
                var sum = 0.0
                var sumSq = 0.0
                var count = 0
                for (y in 1 until h - 1) {
                    val rowCenter = y * w
                    val rowUp = rowCenter - w
                    val rowDown = rowCenter + w
                    for (x in 1 until w - 1) {
                        val center = rowCenter + x
                        val value = -4.0 * luma[center] +
                            luma[rowUp + x] + luma[rowDown + x] +
                            luma[rowCenter + x - 1] + luma[rowCenter + x + 1]
                        sum += value
                        sumSq += value * value
                        count++
                    }
                }
                if (count == 0) return 0.0
                val mean = sum / count
                return sumSq / count - mean * mean
            }

            private fun detectFaces(bitmap: Bitmap): Int {
                return try {
                    val w = bitmap.width
                    val h = bitmap.height
                    val scale = min(1.0, 320.0 / max(w, h))
                    val fw = max(1, (w * scale).toInt())
                    val fh = max(1, (h * scale).toInt())
                    val small = Bitmap.createScaledBitmap(bitmap, fw, fh, true)
                    val rgb565 = small.copy(Bitmap.Config.RGB_565, false)
                    if (rgb565 != small) small.recycle()
                    val faces = arrayOfNulls<FaceDetector.Face>(8)
                    val detector = FaceDetector(fw, fh, 1)
                    val count = detector.findFaces(rgb565, faces)
                    rgb565.recycle()
                    count
                } catch (e: Throwable) {
                    0
                }
            }
        }
    }
}
