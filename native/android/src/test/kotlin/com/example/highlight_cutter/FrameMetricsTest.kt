package com.example.highlight_cutter

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class FrameMetricsTest {

    private fun histogram(peakBin: Int, value: Int = 255): ByteArray {
        val bins = ByteArray(HIST_BINS)
        bins[peakBin] = value.toByte()
        return bins
    }

    private fun frameMetrics(timeSec: Double): DoubleArray =
        DoubleArray(METRICS_PER_FRAME).also { it[0] = timeSec }

    private fun readDouble(bytes: ByteArray, frameIndex: Int): Double =
        ByteBuffer.wrap(bytes)
            .order(METRICS_BYTE_ORDER)
            .getDouble(frameIndex * METRICS_PER_FRAME * 8)

    private fun peakBin(histograms: ByteArray, frameIndex: Int): Int {
        val offset = frameIndex * HIST_BINS
        var best = 0
        for (i in 0 until HIST_BINS) {
            if (FrameMetrics.binValue(histograms[offset + i]) >
                FrameMetrics.binValue(histograms[offset + best])
            ) {
                best = i
            }
        }
        return best
    }

    // --- Знаковый Byte: 128..255 хранятся как -128..-1, но читать их надо
    //     беззнаково иначе расстояние между гистограммами занижается.

    @Test
    fun binValueReadsUnsigned() {
        assertEquals(200, FrameMetrics.binValue((-56).toByte()))
        assertEquals(255, FrameMetrics.binValue((-1).toByte()))
        assertEquals(128, FrameMetrics.binValue((-128).toByte()))
        assertEquals(0, FrameMetrics.binValue(0.toByte()))
        assertEquals(127, FrameMetrics.binValue(127.toByte()))
    }

    @Test
    fun normalizeBinsKeepsValuesAbove127() {
        val counts = IntArray(HIST_BINS)
        counts[3] = 200
        counts[4] = 55
        val bins = FrameMetrics.normalizeBins(counts)

        assertEquals(200, FrameMetrics.binValue(bins[3]))
        assertEquals(55, FrameMetrics.binValue(bins[4]))
    }

    @Test
    fun histogramDistanceIsComputedOnUnsignedValues() {
        // 200 лежит в байте как -56. Со знаковым чтением расстояние было бы
        // |(-56) - 10| = 66, то есть 66/510 = 0.129 вместо 190/510 = 0.373.
        val distance = FrameMetrics.histogramDistance(
            histogram(10, 200),
            histogram(10, 10),
        )

        assertEquals(190.0 / 510.0, distance, 1e-9)
    }

    @Test
    fun brightToDarkSceneChangePassesThreshold() {
        // Главный симптом бага: со знаковым чтением яркий бин против пустого
        // давал |(-1) - 0| = 1/510 = 0.002 и порог 0.45 не срабатывал —
        // смена сцены терялась.
        val distance = FrameMetrics.histogramDistance(
            histogram(10, 255),
            histogram(10, 0),
        )

        assertEquals(255.0 / 510.0, distance, 1e-9)
        assertTrue("смена сцены должна определяться", distance > 0.45)
    }

    @Test
    fun identicalHistogramsHaveZeroDistance() {
        assertEquals(0.0, FrameMetrics.histogramDistance(histogram(5), histogram(5)), 1e-9)
    }

    @Test
    fun differentSizedHistogramsHaveZeroDistance() {
        assertEquals(0.0, FrameMetrics.histogramDistance(ByteArray(4), ByteArray(8)), 1e-9)
        assertEquals(0.0, FrameMetrics.histogramDistance(ByteArray(0), ByteArray(8)), 1e-9)
    }

    @Test
    fun emptyHistogramNormalizesToZeros() {
        assertEquals(HIST_BINS, FrameMetrics.normalizeBins(IntArray(HIST_BINS)).size)
        assertEquals(0, FrameMetrics.binValue(FrameMetrics.normalizeBins(IntArray(HIST_BINS))[0]))
    }

    // --- Пропуск кадра: обе дорожки должны расти синхронно, без дыр.

    @Test
    fun skippedFrameLeavesNoHoles() {
        val writer = AnalysisWriter(maxFrames = 8)

        // Опрос: кадры 0 и 2 пришли, кадр 1 — нет.
        writer.add(frameMetrics(0.0), histogram(1))
        writer.add(frameMetrics(2.0), histogram(3))

        assertEquals(2, writer.written)
        assertEquals(2 * HIST_BINS, writer.histogramBytes().size)
        assertEquals(2 * METRICS_PER_FRAME * 8, writer.metricsBytes().size)
    }

    @Test
    fun bothTracksDescribeTheSameFramesAfterSkip() {
        val writer = AnalysisWriter(maxFrames = 8)
        writer.add(frameMetrics(0.0), histogram(1))
        writer.add(frameMetrics(2.0), histogram(3))
        writer.add(frameMetrics(4.0), histogram(5))

        val metrics = writer.metricsBytes()
        val histograms = writer.histogramBytes()

        // i-я позиция в обеих дорожках — один и тот же кадр. Раньше гистограмма
        // ложилась по индексу опроса, и после пропуска метрики и гистограммы
        // описывали разные кадры.
        assertEquals(0.0, readDouble(metrics, 0), 1e-9)
        assertEquals(1, peakBin(histograms, 0))
        assertEquals(2.0, readDouble(metrics, 1), 1e-9)
        assertEquals(3, peakBin(histograms, 1))
        assertEquals(4.0, readDouble(metrics, 2), 1e-9)
        assertEquals(5, peakBin(histograms, 2))
    }

    @Test
    fun noGapsInHistogramBytes() {
        val writer = AnalysisWriter(maxFrames = 8)
        for (i in 0 until 5) {
            writer.add(frameMetrics(i.toDouble()), histogram(i))
        }

        // Каждый кадр обязан занимать ровно HIST_BINS байт с ненулевым пиком;
        // дыра от пропуска дала бы нулевой слот посередине.
        val histograms = writer.histogramBytes()
        assertEquals(5 * HIST_BINS, histograms.size)
        for (i in 0 until 5) {
            assertEquals("кадр $i", i, peakBin(histograms, i))
        }
    }

    @Test
    fun emptyWriterProducesEmptyTracks() {
        val writer = AnalysisWriter(maxFrames = 4)
        assertEquals(0, writer.written)
        assertEquals(0, writer.metricsBytes().size)
        assertEquals(0, writer.histogramBytes().size)
    }

    @Test(expected = IllegalArgumentException::class)
    fun overflowIsRejected() {
        val writer = AnalysisWriter(maxFrames = 1)
        writer.add(frameMetrics(0.0), histogram(1))
        writer.add(frameMetrics(1.0), histogram(1))
    }

    @Test(expected = IllegalArgumentException::class)
    fun wrongMetricCountIsRejected() {
        AnalysisWriter(maxFrames = 2).add(DoubleArray(3), histogram(1))
    }

    @Test(expected = IllegalArgumentException::class)
    fun shortHistogramIsRejected() {
        AnalysisWriter(maxFrames = 2).add(frameMetrics(0.0), ByteArray(4))
    }

    // --- Порядок байт между Kotlin и Dart.

    @Test
    fun metricsAreWrittenLittleEndian() {
        assertEquals(ByteOrder.LITTLE_ENDIAN, METRICS_BYTE_ORDER)

        val writer = AnalysisWriter(maxFrames = 1)
        writer.add(
            doubleArrayOf(1.0, -2.5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0),
            histogram(2),
        )
        val bytes = writer.metricsBytes()

        // Dart читает эти байты через ByteData с Endian.little, поэтому
        // первый double должен лежать в порядке little-endian:
        // 1.0 = 00 00 00 00 00 00 F0 3F.
        val expected =
            ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putDouble(1.0).array()
        for (i in 0 until 8) {
            assertEquals("байт $i", expected[i], bytes[i])
        }
    }

    @Test
    fun writtenMetricsRoundTrip() {
        val writer = AnalysisWriter(maxFrames = 4)
        val frames = listOf(
            doubleArrayOf(1000.0, 0.5, 0.45, 0.15, 0.0, 0.0, 0.3, 2.0, 0.1, 4.0),
            doubleArrayOf(1500.0, 0.7, 0.50, 0.20, 0.0, 0.0, 0.4, 1.0, 0.2, 4.0),
        )
        for (f in frames) writer.add(f, histogram(4))

        val bytes = writer.metricsBytes()
        for (i in frames.indices) {
            for (m in 0 until METRICS_PER_FRAME) {
                assertEquals(
                    "кадр $i, метрика $m",
                    frames[i][m],
                    readDouble(bytes, i).let { _ ->
                        ByteBuffer.wrap(bytes)
                            .order(METRICS_BYTE_ORDER)
                            .getDouble(i * METRICS_PER_FRAME * 8 + m * 8)
                    },
                    1e-12,
                )
            }
        }
    }
}