package com.example.highlight_cutter

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** Сколько значений double приходится на один кадр в дорожке метрик. */
internal const val METRICS_PER_FRAME = 10

/** Сколько бинов в нормализованной гистограмме. */
internal const val HIST_BINS = 64

/**
 * Порядок байт метрик. Dart читает их через ByteData с Endian.little,
 * поэтому со стороны Kotlin порядок задан явно, а не через nativeOrder():
 * так контракт не зависит от архитектуры машины, на которой собрано.
 */
internal val METRICS_BYTE_ORDER: ByteOrder = ByteOrder.LITTLE_ENDIAN

internal object FrameMetrics {

    /**
     * Нормализует счётчики бинов к сумме 255.
     *
     * Значения 128..255 в Kotlin Byte хранятся как -128..-1 — это не ошибка
     * записи, а особенность типа: Dart получает те же байты как Uint8List и
     * видит 128..255. Поэтому читать гистограмму обратно нужно беззнаково,
     * см. [binValue].
     */
    fun normalizeBins(binCounts: IntArray): ByteArray {
        var total = 0
        for (count in binCounts) total += count
        val out = ByteArray(binCounts.size)
        if (total <= 0) return out
        for (i in binCounts.indices) {
            val scaled = Math.round(binCounts[i].toDouble() * 255.0 / total)
            out[i] = scaled.coerceIn(0, 255).toByte()
        }
        return out
    }

    /** Значение бина как 0..255, независимо от знаковости [Byte]. */
    fun binValue(bin: Byte): Int = bin.toInt() and 0xFF

    /**
     * Total variation расстояние между гистограммами: 0 — совпадение,
     * 1 — полностью разные. Сравнение беззнаковое, иначе яркие бины
     * (хранящиеся отрицательными) считались бы неверно и порог смены
     * сцены срабатывал бы не там.
     */
    fun histogramDistance(a: ByteArray, b: ByteArray): Double {
        if (a.isEmpty() || b.isEmpty() || a.size != b.size) return 0.0
        var total = 0
        for (i in a.indices) {
            total += abs(binValue(a[i]) - binValue(b[i]))
        }
        return min(1.0, total / 510.0)
    }
}

/**
 * Плотная упаковка метрик и гистограмм.
 *
 * Обе дорожки обязаны расти синхронно. Если кадр не удалось получить
 * (getFrameAtTime вернул null), его нужно просто пропустить: тогда в
 * дорожках не остаётся дыр и i-я позиция всегда описывает один и тот же
 * кадр. Ключевой момент — позиция записи считается по счётчику принятых
 * кадров, а не по индексу в цикле опроса.
 */
internal class AnalysisWriter(maxFrames: Int) {

    private val metrics = ByteBuffer
        .allocateDirect(max(0, maxFrames) * METRICS_PER_FRAME * 8)
        .order(METRICS_BYTE_ORDER)
    private val histograms = ByteArray(max(0, maxFrames) * HIST_BINS)

    /** Сколько кадров реально принято (без пропусков). */
    var written = 0
        private set

    fun add(values: DoubleArray, histogram: ByteArray) {
        require(values.size == METRICS_PER_FRAME) {
            "ожидалось $METRICS_PER_FRAME метрик, получено ${values.size}"
        }
        require(histogram.size >= HIST_BINS) {
            "ожидалось минимум $HIST_BINS бинов, получено ${histogram.size}"
        }
        require(written < histograms.size / HIST_BINS) {
            "переполнение: $written кадров при вместимости ${histograms.size / HIST_BINS}"
        }
        for (value in values) metrics.putDouble(value)
        System.arraycopy(histogram, 0, histograms, written * HIST_BINS, HIST_BINS)
        written += 1
    }

    /** Первые [written] кадров метрик в порядке [METRICS_BYTE_ORDER]. */
    fun metricsBytes(): ByteArray {
        val out = ByteArray(written * METRICS_PER_FRAME * 8)
        if (out.isNotEmpty()) {
            metrics.duplicate().apply { flip() }.get(out)
        }
        return out
    }

    /** Первые [written] гистограмм, ровно по [HIST_BINS] байт на кадр. */
    fun histogramBytes(): ByteArray = histograms.copyOfRange(0, written * HIST_BINS)
}