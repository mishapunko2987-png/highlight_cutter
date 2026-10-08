package com.example.highlight_cutter

import android.graphics.SurfaceTexture
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt.EGL_RECORDABLE_ANDROID
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.view.Surface
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.max
import kotlin.math.min

internal data class ExportRequest(
    val sourcePath: String,
    val outputPath: String,
    val ranges: List<Pair<Long, Long>>,
    val width: Int,
    val height: Int,
    val bitrate: Int,
    val fps: Int,
)

internal data class EncodedSample(
    val presentationTimeUs: Long,
    val data: ByteArray,
    val flags: Int,
)

private class MuxState {
    var videoTrack = -1
    var audioTrack = -1
    var started = false
    var videoOffsetUs = 0L

    /// Последний записанный таймкод видеодорожки. MediaMuxer требует
    /// строго возрастающих таймкодов, повторы и откаты приводят к
    /// повреждению дорожки, поэтому такие сэмплы отбрасываются.
    var lastVideoPtsUs = Long.MIN_VALUE
}

internal class VideoExporter(private val request: ExportRequest) {

    private companion object {
        const val TIMEOUT_US = 10_000L
        const val MAX_WIDTH = 1920
        const val COLOR_FORMAT_SURFACE = 0x7F000789
        const val IDLE_ROUNDS = 30
    }

    fun run(): String {
        val outputFile = File(request.outputPath)
        outputFile.parentFile?.mkdirs()
        if (outputFile.exists()) outputFile.delete()

        val extractor = MediaExtractor()
        extractor.setDataSource(request.sourcePath)
        val muxer = MediaMuxer(request.outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

        var encoder: MediaCodec? = null
        var decoder: MediaCodec? = null
        var decoderSurface: Surface? = null
        var egl: EglBridge? = null
        val audio = AudioPipeline(request.sourcePath)
        val state = MuxState()

        try {
            val videoTrack = extractor.firstVideoTrack()
            if (videoTrack < 0) throw IllegalStateException("В файле нет видеодорожки")

            val sourceFormat = extractor.getTrackFormat(videoTrack)
            val mime = sourceFormat.getString(MediaFormat.KEY_MIME)
                ?: throw IllegalStateException("Неизвестный видеокодек")
            val (width, height) = targetSize(sourceFormat)
            val fps = resolveFps(sourceFormat)

            val encoderFormat = MediaFormat.createVideoFormat(
                MediaFormat.MIMETYPE_VIDEO_AVC,
                width,
                height,
            )
            encoderFormat.setInteger(MediaFormat.KEY_COLOR_FORMAT, COLOR_FORMAT_SURFACE)
            encoderFormat.setInteger(MediaFormat.KEY_BIT_RATE, request.bitrate)
            encoderFormat.setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            encoderFormat.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)

            encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            // Порядок обязателен: createInputSurface() допустим только в
            // состоянии Configured. До configure() кодек в Uninitialized, и
            // Android бросает «setInputSurface() is valid only at Configured
            // state; currently at Uninitialized state».
            encoder.configure(encoderFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val encoderSurface = encoder.createInputSurface()
            encoder.start()

            egl = EglBridge(encoderSurface)
            egl.makeCurrent()

            decoderSurface = egl.createDecoderSurface(width, height)

            decoder = MediaCodec.createDecoderByType(mime)
            decoder.configure(sourceFormat, decoderSurface, null, 0)
            decoder.start()

            extractor.selectTrack(videoTrack)

            // Аудио кодируется заранее: MediaMuxer требует все дорожки до start().
            val audioByRange = mutableListOf<List<EncodedSample>>()
            var audioOffsetUs = 0L
            for (range in request.ranges) {
                val samples = audio.encodeRange(range, audioOffsetUs)
                audioByRange.add(samples)
                audioOffsetUs += (range.second - range.first)
            }
            val allAudio = audioByRange.flatten()
            if (allAudio.isNotEmpty()) {
                state.audioTrack = muxer.addTrack(audio.encoderFormat ?: buildAacFormat())
            }

            for ((index, range) in request.ranges.withIndex()) {
                if (index > 0) {
                    // Сначала выбираем всё, что энкодер уже закодировал, иначе
                    // flush() инвалидирует неотданные выходные буферы.
                    drainEncoder(encoder, muxer, state)
                    encoder.flush()
                    state.videoOffsetUs =
                        request.ranges.take(index).sumOf { it.second - it.first }
                }
                decoder.flush()
                extractor.seekTo(range.first, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)

                transcodeRange(
                    extractor = extractor,
                    decoder = decoder,
                    encoder = encoder,
                    egl = egl,
                    muxer = muxer,
                    state = state,
                    range = range,
                )
            }

            if (request.ranges.isNotEmpty()) {
                encoder.signalEndOfInputStream()
            }

            drainToEnd(encoder, muxer, state)
            writeAudio(muxer, state, allAudio)

            if (!state.started) throw IllegalStateException("Не удалось закодировать видео")
        } finally {
            runCatching { decoder?.stop() }
            runCatching { decoder?.release() }
            runCatching { encoder?.stop() }
            runCatching { encoder?.release() }
            // Surface освобождаем до EglBridge: мост владеет SurfaceTexture
            // и освобождает его у себя.
            runCatching { decoderSurface?.release() }
            egl?.release()
            if (state.started) runCatching { muxer.stop() }
            runCatching { muxer.release() }
            extractor.release()
            audio.release()
        }

        return outputFile.absolutePath
    }

    private fun transcodeRange(
        extractor: MediaExtractor,
        decoder: MediaCodec,
        encoder: MediaCodec,
        egl: EglBridge,
        muxer: MediaMuxer,
        state: MuxState,
        range: Pair<Long, Long>,
    ) {
        val decoderInfo = MediaCodec.BufferInfo()
        var inputDone = false
        var decoderFinished = false
        var idleRounds = 0

        while (!decoderFinished) {
            if (!inputDone) {
                val inputIndex = decoder.dequeueInputBuffer(TIMEOUT_US)
                if (inputIndex >= 0) {
                    val buffer = decoder.getInputBuffer(inputIndex)
                    val size = if (buffer == null) -1 else extractor.readSampleData(buffer, 0)
                    val time = extractor.sampleTime
                    if (size < 0 || time >= range.second) {
                        decoder.queueInputBuffer(
                            inputIndex,
                            0,
                            0,
                            0,
                            MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                        )
                        if (size >= 0) extractor.advance()
                        inputDone = true
                    } else {
                        decoder.queueInputBuffer(inputIndex, 0, size, time, 0)
                        extractor.advance()
                    }
                }
            }

            val outputIndex = decoder.dequeueOutputBuffer(decoderInfo, TIMEOUT_US)
            if (outputIndex >= 0) {
                val hasFrame = decoderInfo.size > 0
                // seekTo(SEEK_TO_PREVIOUS_SYNC) встаёт на ключевой кадр перед
                // началом диапазона, и декодеру эти кадры скормить нужно. Но
                // в клип они попадать не должны.
                //
                // Раньше они рендерились с обрезанным временем
                // max(0, t - range.first + offset), то есть все получали
                // ОДИН И ТОТ ЖЕ таймкод. На дорожке появлялся кластер
                // сэмплов с одинаковым временем, и проигрыватель
                // показывал застывший кадр — в трейлере это выглядело как
                // «первый момент повторён 5 раз».
                val inRange = !hasFrame || decoderInfo.presentationTimeUs >= range.first
                if (hasFrame && inRange) {
                    decoder.releaseOutputBuffer(outputIndex, true)
                    val pts = decoderInfo.presentationTimeUs - range.first + state.videoOffsetUs
                    egl.setPresentationTime(pts)
                    egl.swapAndDraw()
                } else {
                    decoder.releaseOutputBuffer(outputIndex, false)
                }
                if (decoderInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                    decoderFinished = true
                }
                idleRounds = 0
            } else if (outputIndex == MediaCodec.INFO_TRY_AGAIN_LATER) {
                idleRounds++
                if (idleRounds > IDLE_ROUNDS && inputDone) break
            }

            drainEncoder(encoder, muxer, state)
        }

        drainEncoder(encoder, muxer, state)
    }

    private fun writeAudio(muxer: MediaMuxer, state: MuxState, samples: List<EncodedSample>) {
        if (!state.started || state.audioTrack < 0) return
        val info = MediaCodec.BufferInfo()
        for (sample in samples) {
            info.presentationTimeUs = sample.presentationTimeUs
            info.size = sample.data.size
            info.flags = sample.flags
            muxer.writeSampleData(state.audioTrack, ByteBuffer.wrap(sample.data), info)
        }
    }

    private fun drainEncoder(
        encoder: MediaCodec,
        muxer: MediaMuxer,
        state: MuxState,
    ) {
        val info = MediaCodec.BufferInfo()
        while (true) {
            val index = encoder.dequeueOutputBuffer(info, TIMEOUT_US)
            when {
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    if (state.videoTrack >= 0) {
                        throw IllegalStateException("Формат изменился дважды")
                    }
                    state.videoTrack = muxer.addTrack(encoder.outputFormat)
                    muxer.start()
                    state.started = true
                }
                index >= 0 -> {
                    val buffer = encoder.getOutputBuffer(index)
                    if (info.size > 0 && buffer != null && state.started &&
                        info.presentationTimeUs > state.lastVideoPtsUs
                    ) {
                        state.lastVideoPtsUs = info.presentationTimeUs
                        buffer.position(info.offset)
                        buffer.limit(info.offset + info.size)
                        muxer.writeSampleData(state.videoTrack, buffer, info)
                    }
                    encoder.releaseOutputBuffer(index, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                }
                index == MediaCodec.INFO_TRY_AGAIN_LATER -> return
            }
        }
    }

    private fun drainToEnd(encoder: MediaCodec, muxer: MediaMuxer, state: MuxState) {
        val info = MediaCodec.BufferInfo()
        while (true) {
            val index = encoder.dequeueOutputBuffer(info, TIMEOUT_US)
            when {
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    if (state.videoTrack < 0) {
                        state.videoTrack = muxer.addTrack(encoder.outputFormat)
                        muxer.start()
                        state.started = true
                    }
                }
                index >= 0 -> {
                    val buffer = encoder.getOutputBuffer(index)
                    if (info.size > 0 && buffer != null && state.started &&
                        info.presentationTimeUs > state.lastVideoPtsUs
                    ) {
                        state.lastVideoPtsUs = info.presentationTimeUs
                        buffer.position(info.offset)
                        buffer.limit(info.offset + info.size)
                        muxer.writeSampleData(state.videoTrack, buffer, info)
                    }
                    encoder.releaseOutputBuffer(index, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                }
            }
        }
    }

    private fun buildAacFormat(): MediaFormat {
        val format = MediaFormat.createAudioFormat(
            MediaFormat.MIMETYPE_AUDIO_AAC,
            44100,
            2,
        )
        format.setInteger(
            MediaFormat.KEY_AAC_PROFILE,
            MediaCodecInfo.CodecProfileLevel.AACObjectLC,
        )
        return format
    }

    private fun targetSize(format: MediaFormat): Pair<Int, Int> {
        var width = if (request.width > 0) {
            request.width
        } else {
            format.getInteger(MediaFormat.KEY_WIDTH)
        }
        var height = if (request.height > 0) {
            request.height
        } else {
            format.getInteger(MediaFormat.KEY_HEIGHT)
        }
        if (width > MAX_WIDTH) {
            val ratio = MAX_WIDTH.toDouble() / width
            width = MAX_WIDTH
            height = max(2, (height * ratio).toInt())
        }
        return (width / 2 * 2).coerceAtLeast(2) to (height / 2 * 2).coerceAtLeast(2)
    }

    private fun resolveFps(format: MediaFormat): Int {
        if (request.fps > 0) return request.fps
        val raw = try {
            format.getInteger(MediaFormat.KEY_FRAME_RATE)
        } catch (e: Exception) {
            30
        }
        return raw.coerceIn(15, 60)
    }
}

internal class AudioPipeline(private val sourcePath: String) {

    private val extractor = MediaExtractor()
    private val trackIndex: Int
    private val sourceFormat: MediaFormat?
    private var disabled = false

    var encoderFormat: MediaFormat? = null
        private set

    init {
        var found = -1
        var format: MediaFormat? = null
        try {
            extractor.setDataSource(sourcePath)
            val index = extractor.firstAudioTrack()
            if (index >= 0) {
                found = index
                runCatching { format = extractor.getTrackFormat(index) }
            }
        } catch (e: Exception) {
            found = -1
        }
        trackIndex = found
        sourceFormat = format
    }

    private val isAac: Boolean
        get() = sourceFormat?.getString(MediaFormat.KEY_MIME) == MediaFormat.MIMETYPE_AUDIO_AAC

    fun encodeRange(range: Pair<Long, Long>, offsetUs: Long): List<EncodedSample> {
        if (disabled || trackIndex < 0) return emptyList()
        return try {
            if (isAac) passthrough(range, offsetUs) else reencode(range, offsetUs)
        } catch (e: Exception) {
            disabled = true
            emptyList()
        }
    }

    private fun passthrough(range: Pair<Long, Long>, offsetUs: Long): List<EncodedSample> {
        encoderFormat = sourceFormat
        val samples = mutableListOf<EncodedSample>()
        val buffer = ByteBuffer.allocate(256 * 1024)
        extractor.selectTrack(trackIndex)
        extractor.seekTo(range.first, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        while (true) {
            buffer.clear()
            val size = extractor.readSampleData(buffer, 0)
            val time = extractor.sampleTime
            if (size < 0 || time >= range.second) break
            if (time < range.first) {
                extractor.advance()
                continue
            }
            val copy = ByteArray(size)
            buffer.position(0)
            buffer.get(copy)
            samples.add(
                EncodedSample(
                    presentationTimeUs = time - range.first + offsetUs,
                    data = copy,
                    flags = MediaCodec.BUFFER_FLAG_KEY_FRAME,
                )
            )
            extractor.advance()
        }
        return samples
    }

    private fun reencode(range: Pair<Long, Long>, offsetUs: Long): List<EncodedSample> {
        val source = sourceFormat ?: return emptyList()
        val mime = source.getString(MediaFormat.KEY_MIME) ?: return emptyList()
        val sampleRate = source.getInteger(MediaFormat.KEY_SAMPLE_RATE).coerceAtLeast(8000)
        val channels = source.getInteger(MediaFormat.KEY_CHANNEL_COUNT).coerceAtLeast(1)

        val target = MediaFormat.createAudioFormat(
            MediaFormat.MIMETYPE_AUDIO_AAC,
            sampleRate,
            channels,
        )
        target.setInteger(MediaFormat.KEY_BIT_RATE, AAC_BITRATE)
        target.setInteger(
            MediaFormat.KEY_AAC_PROFILE,
            MediaCodecInfo.CodecProfileLevel.AACObjectLC,
        )
        encoderFormat = target

        val decoder = MediaCodec.createDecoderByType(mime)
        val encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        val samples = mutableListOf<EncodedSample>()

        try {
            decoder.configure(source, null, null, 0)
            decoder.start()
            encoder.configure(target, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            encoder.start()

            extractor.selectTrack(trackIndex)
            extractor.seekTo(range.first, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)

            val decoderInfo = MediaCodec.BufferInfo()
            val encoderInfo = MediaCodec.BufferInfo()
            var inputDone = false
            var decoderDone = false
            var encoderDone = false

            while (!encoderDone) {
                if (!inputDone) {
                    val index = decoder.dequeueInputBuffer(TIMEOUT_US)
                    if (index >= 0) {
                        val buffer = decoder.getInputBuffer(index)
                        val size = if (buffer == null) -1 else extractor.readSampleData(buffer, 0)
                        val time = extractor.sampleTime
                        if (size < 0 || time >= range.second) {
                            decoder.queueInputBuffer(
                                index,
                                0,
                                0,
                                0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            if (size >= 0) extractor.advance()
                            inputDone = true
                        } else {
                            decoder.queueInputBuffer(index, 0, size, time, 0)
                            extractor.advance()
                        }
                    }
                }

                if (!decoderDone) {
                    val index = decoder.dequeueOutputBuffer(decoderInfo, TIMEOUT_US)
                    if (index >= 0) {
                        val buffer = decoder.getOutputBuffer(index)
                        if (decoderInfo.size > 0 && buffer != null) {
                            val outIndex = encoder.dequeueInputBuffer(TIMEOUT_US)
                            if (outIndex >= 0) {
                                val outBuffer = encoder.getInputBuffer(outIndex)
                                if (outBuffer != null) {
                                    outBuffer.clear()
                                    buffer.position(decoderInfo.offset)
                                    buffer.limit(decoderInfo.offset + decoderInfo.size)
                                    val chunk = ByteArray(min(decoderInfo.size, outBuffer.remaining()))
                                    buffer.get(chunk)
                                    outBuffer.put(chunk)
                                    encoder.queueInputBuffer(
                                        outIndex,
                                        0,
                                        chunk.size,
                                        decoderInfo.presentationTimeUs,
                                        0,
                                    )
                                }
                            }
                        }
                        decoder.releaseOutputBuffer(index, false)
                        if (decoderInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            decoderDone = true
                            encoder.signalEndOfInputStream()
                        }
                    }
                }

                val index = encoder.dequeueOutputBuffer(encoderInfo, TIMEOUT_US)
                if (index >= 0) {
                    val buffer = encoder.getOutputBuffer(index)
                    if (encoderInfo.size > 0 && buffer != null) {
                        val copy = ByteArray(encoderInfo.size)
                        buffer.position(encoderInfo.offset)
                        buffer.limit(encoderInfo.offset + encoderInfo.size)
                        buffer.get(copy)
                        samples.add(
                            EncodedSample(
                                presentationTimeUs = max(
                                    0,
                                    encoderInfo.presentationTimeUs - range.first,
                                ) + offsetUs,
                                data = copy,
                                flags = MediaCodec.BUFFER_FLAG_KEY_FRAME,
                            )
                        )
                    }
                    encoder.releaseOutputBuffer(index, false)
                    if (encoderInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        encoderDone = true
                    }
                }
            }

            samples.sortBy { it.presentationTimeUs }
            return samples
        } finally {
            runCatching { decoder.stop() }
            runCatching { decoder.release() }
            runCatching { encoder.stop() }
            runCatching { encoder.release() }
        }
    }

    fun release() {
        runCatching { extractor.release() }
    }

    private companion object {
        const val AAC_BITRATE = 128000
        const val TIMEOUT_US = 10000L
    }
}

internal fun MediaExtractor.firstVideoTrack(): Int {
    for (i in 0 until trackCount) {
        val mime = getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
        if (mime.startsWith("video/")) return i
    }
    return -1
}

internal fun MediaExtractor.firstAudioTrack(): Int {
    for (i in 0 until trackCount) {
        val mime = getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
        if (mime.startsWith("audio/")) return i
    }
    return -1
}

internal class EglBridge(private val surface: Surface) {
    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var context: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var presentationTimeUs = 0L

    // SurfaceTexture, в который декодер кладёт кадры. Пока из него не взят
    // кадр через updateTexImage(), текстура пустая.
    private var frameTexture: SurfaceTexture? = null

    // glVertexAttribPointer не копирует данные, поэтому буферы вершин
    // нужно удерживать — иначе GC освободит память под ними.
    private var positionBuffer: ByteBuffer? = null
    private var texCoordBuffer: ByteBuffer? = null

    var textureId = 0
        private set

    /**
     * Декодер рендерит в SurfaceTexture, потребитель забирает кадр через
     * updateTexImage() и рисует его в поверхность энкодера. Без
     * updateTexImage() текстура остаётся незаполненной, шейдер рисует
     * константу, и в ролике оказывается один и тот же кадр.
     */
    fun createDecoderSurface(width: Int, height: Int): Surface {
        frameTexture = SurfaceTexture(textureId).also {
            it.setDefaultBufferSize(width, height)
        }
        return Surface(frameTexture!!)
    }

    fun makeCurrent() {
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        val version = IntArray(2)
        EGL14.eglInitialize(display, version, 0, version, 1)
        EGL14.eglBindAPI(EGL14.EGL_OPENGL_ES_API)

        val attributes = intArrayOf(
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL_RECORDABLE_ANDROID, 1,
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val numConfigs = IntArray(1)
        EGL14.eglChooseConfig(display, attributes, 0, configs, 0, 1, numConfigs, 0)
        val config = configs[0] ?: throw IllegalStateException("EGL config не найден")

        context = EGL14.eglCreateContext(
            display,
            config,
            EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE),
            0,
        )
        eglSurface = EGL14.eglCreateWindowSurface(
            display,
            config,
            surface,
            intArrayOf(EGL14.EGL_NONE),
            0,
        )
        EGL14.eglMakeCurrent(display, eglSurface, eglSurface, context)
        buildPipeline()
    }

    fun setPresentationTime(us: Long) {
        presentationTimeUs = us
    }

    fun swapAndDraw() {
        // Забираем очередной кадр из SurfaceTexture. Пропуск этого вызова —
        // причина, по которой весь ролик состоял из одного кадра.
        frameTexture?.updateTexImage()
        EGLExt.eglPresentationTimeANDROID(display, eglSurface, presentationTimeUs)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        EGL14.eglSwapBuffers(display, eglSurface)
    }

    fun release() {
        frameTexture?.release()
        frameTexture = null
        if (display != EGL14.EGL_NO_DISPLAY) {
            EGL14.eglMakeCurrent(
                display,
                EGL14.EGL_NO_SURFACE,
                EGL14.EGL_NO_SURFACE,
                EGL14.EGL_NO_CONTEXT,
            )
            if (eglSurface != EGL14.EGL_NO_SURFACE) {
                EGL14.eglDestroySurface(display, eglSurface)
            }
            if (context != EGL14.EGL_NO_CONTEXT) {
                EGL14.eglDestroyContext(display, context)
            }
            EGL14.eglReleaseThread()
            EGL14.eglTerminate(display)
        }
        display = EGL14.EGL_NO_DISPLAY
        context = EGL14.EGL_NO_CONTEXT
        eglSurface = EGL14.EGL_NO_SURFACE
    }

    private fun buildPipeline() {
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        textureId = textures[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_MIN_FILTER,
            GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_MAG_FILTER,
            GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_WRAP_S,
            GLES20.GL_CLAMP_TO_EDGE,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_WRAP_T,
            GLES20.GL_CLAMP_TO_EDGE,
        )

        val program = GLES20.glCreateProgram()
        GLES20.glAttachShader(
            program,
            compileShader(
                GLES20.GL_VERTEX_SHADER,
                """
                attribute vec4 aPosition;
                attribute vec2 aTexCoord;
                varying vec2 vTexCoord;
                void main() {
                    gl_Position = aPosition;
                    vTexCoord = aTexCoord;
                }
                """.trimIndent(),
            ),
        )
        GLES20.glAttachShader(
            program,
            compileShader(
                GLES20.GL_FRAGMENT_SHADER,
                """
                #extension GL_OES_EGL_image_external : require
                precision mediump float;
                varying vec2 vTexCoord;
                uniform samplerExternalOES sTexture;
                void main() {
                    gl_FragColor = texture2D(sTexture, vTexCoord);
                }
                """.trimIndent(),
            ),
        )
        GLES20.glLinkProgram(program)
        GLES20.glUseProgram(program)

        val positionHandle = GLES20.glGetAttribLocation(program, "aPosition")
        GLES20.glEnableVertexAttribArray(positionHandle)
        positionBuffer = directFloatBuffer(floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f))
        GLES20.glVertexAttribPointer(
            positionHandle,
            2,
            GLES20.GL_FLOAT,
            false,
            0,
            positionBuffer,
        )

        val texCoordHandle = GLES20.glGetAttribLocation(program, "aTexCoord")
        GLES20.glEnableVertexAttribArray(texCoordHandle)
        texCoordBuffer = directFloatBuffer(floatArrayOf(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f))
        GLES20.glVertexAttribPointer(
            texCoordHandle,
            2,
            GLES20.GL_FLOAT,
            false,
            0,
            texCoordBuffer,
        )
    }

    private fun directFloatBuffer(values: FloatArray): ByteBuffer {
        val buffer = ByteBuffer
            .allocateDirect(values.size * 4)
            .order(ByteOrder.nativeOrder())
        for (value in values) {
            buffer.putFloat(value)
        }
        buffer.position(0)
        return buffer
    }

    private fun compileShader(type: Int, source: String): Int {
        val shader = GLES20.glCreateShader(type)
        GLES20.glShaderSource(shader, source)
        GLES20.glCompileShader(shader)
        return shader
    }
}
