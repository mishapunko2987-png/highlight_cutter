import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:highlight_cutter/src/core/highlight_selector.dart';
import 'package:highlight_cutter/src/models/moment.dart';
import 'package:highlight_cutter_native/highlight_cutter_native.dart';

FrameSample frame({
  required int timeUs,
  double sharpness = 0.5,
  double lumaMean = 0.45,
  double lumaStd = 0.15,
  double clippedLow = 0,
  double clippedHigh = 0,
  double colorfulness = 0.4,
  int faces = 0,
  double motion = 0.2,
  double shotLengthSec = 5,
}) {
  return FrameSample(
    timeUs: timeUs,
    sharpness: sharpness,
    lumaMean: lumaMean,
    lumaStd: lumaStd,
    clippedLow: clippedLow,
    clippedHigh: clippedHigh,
    colorfulness: colorfulness,
    faces: faces,
    motion: motion,
    shotLengthSec: shotLengthSec,
  );
}

/// Гистограмма с одним пиком в бине [bin], нормированная к сумме 255.
Uint8List peakHistogram(int bin) {
  final bins = Uint8List(kHistogramBins);
  bins[bin] = 255;
  return bins;
}

FrameAnalysis analysisOf(
  List<FrameSample> frames, {
  List<Uint8List>? histograms,
}) {
  final bytes = <int>[];
  for (final h in histograms ??
      List.generate(
        frames.length,
        (_) => Uint8List(kHistogramBins),
      )) {
    bytes.addAll(h);
  }
  return FrameAnalysis(
    frames: frames,
    histograms: Uint8List.fromList(bytes),
  );
}

void main() {
  const selector = HighlightSelector();

  test('пустой анализ не даёт моментов', () {
    final result = selector.select(
      analysisOf(const []),
      const HighlightSettings(),
    );
    expect(result, isEmpty);
  });

  test('один кадр не даёт моментов', () {
    final result = selector.select(
      analysisOf([frame(timeUs: 0)]),
      const HighlightSettings(),
    );
    expect(result, isEmpty);
  });

  test('выбирает лучший кадр из серии', () {
    const step = 500000;
    final frames = <FrameSample>[];
    for (var i = 0; i < 200; i++) {
      final isPeak = i == 120;
      frames.add(
        frame(
          timeUs: i * step,
          sharpness: isPeak ? 0.98 : 0.25,
          lumaMean: isPeak ? 0.48 : 0.5,
          colorfulness: isPeak ? 0.9 : 0.2,
          faces: isPeak ? 3 : 0,
        ),
      );
    }

    final result = selector.select(
      analysisOf(frames),
      const HighlightSettings(maxClips: 1, clipDurationSec: 6),
    );

    expect(result, hasLength(1));
    expect(result.first.peakUs, 120 * step);
    expect(result.first.endUs - result.first.startUs, 6000000);
    expect(result.first.reasons, contains('Резкий кадр'));
    expect(result.first.reasons, contains('Люди в кадре'));
  });

  test('соблюдает лимит клипов и не пересекает моменты', () {
    const step = 400000;
    final frames = <FrameSample>[];
    for (var i = 0; i < 300; i++) {
      frames.add(
        frame(
          timeUs: i * step,
          sharpness: (i % 30).isEven ? 0.9 : 0.2,
        ),
      );
    }

    final result = selector.select(
      analysisOf(frames),
      const HighlightSettings(maxClips: 4, clipDurationSec: 5),
    );

    expect(result.length, lessThanOrEqualTo(4));
    for (var i = 1; i < result.length; i++) {
      expect(result[i].startUs, greaterThan(result[i - 1].endUs));
    }
  });

  // Регрессия: приложение выдавало 15 моментов из одного эпизода — все
  // лучшие пики яркого отрезка шли подряд, и зазора в пару секунд хватало,
  // чтобы все они прошли. Зазор в 30 с оставляет из эпизода один момент.
  test('соседние моменты разведены минимум на minGapSec', () {
    const step = 500000;
    final frames = <FrameSample>[];
    for (var i = 0; i < 600; i++) {
      // Один яркий отрезок: первые 60 кадров — максимум, дальше ровный фон
      // с отдельными всплесками.
      final sharp = i < 60
          ? 0.95
          : (i % 150 == 0 ? 0.8 : 0.2);
      frames.add(frame(timeUs: i * step, sharpness: sharp));
    }

    final result = selector.select(
      analysisOf(frames),
      const HighlightSettings(maxClips: 15, clipDurationSec: 8, minGapSec: 30),
    );

    for (var i = 1; i < result.length; i++) {
      final gapSec = (result[i].startUs - result[i - 1].endUs) / 1e6;
      expect(gapSec, greaterThanOrEqualTo(30.0));
    }
  });

  test('из одного яркого эпизода берётся один момент', () {
    const step = 500000;
    // Ровно один яркий отрезок длиной 30 с. Клип 8 с плюс зазор 30 с
    // занимают 38 с, поэтому второй момент в него не помещается в принципе.
    final frames = List.generate(60, (i) => frame(
          timeUs: i * step,
          sharpness: 0.9,
        ));

    final result = selector.select(
      analysisOf(frames),
      const HighlightSettings(maxClips: 15, clipDurationSec: 8, minGapSec: 30),
    );

    expect(result, hasLength(1));
  });

  test('нулевой зазор не ломает отбор, моменты просто не пересекаются', () {
    const step = 500000;
    final frames = List.generate(400, (i) => frame(
          timeUs: i * step,
          sharpness: i % 50 == 0 ? 0.95 : 0.2,
        ));

    final result = selector.select(
      analysisOf(frames),
      const HighlightSettings(maxClips: 5, minGapSec: 0),
    );

    expect(result, isNotEmpty);
    for (var i = 1; i < result.length; i++) {
      expect(result[i].startUs, greaterThanOrEqualTo(result[i - 1].endUs));
    }
  });

  test('моменты отсортированы по времени', () {
    const step = 500000;
    final frames = List.generate(
      400,
      (i) => frame(timeUs: i * step, sharpness: i % 40 == 0 ? 0.95 : 0.2),
    );

    final result = selector.select(
      analysisOf(frames),
      const HighlightSettings(maxClips: 5),
    );

    for (var i = 1; i < result.length; i++) {
      expect(result[i].startUs, greaterThanOrEqualTo(result[i - 1].startUs));
    }
  });

  test('нулевые веса дают нулевой скор', () {
    const step = 500000;
    final frames =
        List.generate(100, (i) => frame(timeUs: i * step, sharpness: 0.9));

    final result = selector.select(
      analysisOf(frames),
      const HighlightSettings(weights: {}),
    );

    expect(result, isNotEmpty);
    for (final moment in result) {
      expect(moment.score, 0);
    }
  });

  test('клип не выходит за границы видео', () {
    const step = 1000000;
    final frames =
        List.generate(20, (i) => frame(timeUs: i * step, sharpness: 0.9));

    final result = selector.select(
      analysisOf(frames),
      const HighlightSettings(
        maxClips: 3,
        clipDurationSec: 8,
        minClipDurationSec: 1,
      ),
    );

    expect(result, isNotEmpty);
    for (final moment in result) {
      expect(moment.startUs, greaterThanOrEqualTo(0));
      expect(moment.endUs, lessThanOrEqualTo(19 * step));
    }
  });

  test('смена сцены разрывает клип', () {
    const step = 500000;
    final frames = <FrameSample>[];
    final histograms = <Uint8List>[];

    for (var i = 0; i < 60; i++) {
      frames.add(frame(timeUs: i * step, sharpness: 0.5));
      histograms.add(peakHistogram(i < 30 ? 5 : 50));
    }

    final result = selector.select(
      analysisOf(frames, histograms: histograms),
      const HighlightSettings(maxClips: 1, clipDurationSec: 20),
    );

    expect(result, isNotEmpty);
    final moment = result.first;
    expect(moment.endUs, lessThanOrEqualTo(30 * step));
  });

  test('одинаковые гистограммы не создают границ сцены', () {
    const step = 500000;
    final frames =
        List.generate(60, (i) => frame(timeUs: i * step, sharpness: 0.5));
    final histograms = List.generate(60, (_) => peakHistogram(20));

    final result = selector.select(
      analysisOf(frames, histograms: histograms),
      const HighlightSettings(
        maxClips: 3,
        clipDurationSec: 6,
        minClipDurationSec: 3,
        // Тест проверяет границы сцен, а не зазор: зазор по умолчанию
        // 30 с не поместился бы в ролик длиной 30 с и дал один момент.
        minGapSec: 2,
      ),
    );

    expect(result, isNotEmpty);
    // Единственная сцена — весь ролик, поэтому пики в разных её частях доступны.
    expect(result.length, greaterThan(1));
    for (final moment in result) {
      expect(moment.startUs, greaterThanOrEqualTo(0));
      expect(moment.endUs, lessThanOrEqualTo(59 * step));
    }
  });

  // Регрессия к замечанию «красивый кадр ≠ интересный момент»: неподвижный
  // кадр набирал полный балл по резкости и цвету, хотя в нём ничего не
  // происходило. Домножитель активности отдаёт предпочтение движущему кадру.
  test('неподвижный красивый кадр проигрывает движущему', () {
    const step = 500000;
    final frames = <FrameSample>[];
    for (var i = 0; i < 120; i++) {
      if (i >= 10 && i < 30) {
        // Красиво, но статично: ни движения, ни людей.
        frames.add(frame(
          timeUs: i * step,
          sharpness: 0.95,
          colorfulness: 0.95,
          faces: 0,
          motion: 0.0,
        ));
      } else if (i >= 70 && i < 90) {
        // Чуть менее красиво, зато что-то происходит.
        frames.add(frame(
          timeUs: i * step,
          sharpness: 0.92,
          colorfulness: 0.88,
          faces: 3,
          motion: 0.6,
        ));
      } else {
        frames.add(frame(
          timeUs: i * step,
          sharpness: 0.3,
          colorfulness: 0.3,
          faces: 0,
          motion: 0.05,
        ));
      }
    }

    final result = selector.select(
      analysisOf(frames),
      const HighlightSettings(
        maxClips: 1,
        clipDurationSec: 8,
        minGapSec: 0,
      ),
    );

    expect(result, hasLength(1));
    expect(result.first.peakUs, greaterThanOrEqualTo(70 * step));
    expect(result.first.peakUs, lessThan(90 * step));
  });

  // Регрессия к ранжированию только по пиковому кадру: одиночный яркий кадр
  // посреди скучного фильма больше не обгоняет ровный участок, который
  // интересен целиком.
  test('окно лучше одиночного яркого кадра', () {
    const step = 500000;
    final frames = <FrameSample>[];
    for (var i = 0; i < 160; i++) {
      if (i == 30) {
        frames.add(frame(timeUs: i * step, sharpness: 0.99, colorfulness: 0.9));
      } else if (i >= 80 && i < 120) {
        frames.add(frame(timeUs: i * step, sharpness: 0.75, colorfulness: 0.6));
      } else {
        frames.add(frame(timeUs: i * step, sharpness: 0.25, colorfulness: 0.2));
      }
    }

    final result = selector.select(
      analysisOf(frames),
      const HighlightSettings(
        maxClips: 1,
        clipDurationSec: 8,
        minGapSec: 0,
      ),
    );

    expect(result, hasLength(1));
    expect(result.first.peakUs, greaterThanOrEqualTo(80 * step));
    expect(result.first.peakUs, lessThan(120 * step));
  });

  test('пустая гистограмма не роняет отбор', () {
    const step = 500000;
    final frames =
        List.generate(40, (i) => frame(timeUs: i * step, sharpness: 0.6));
    final histograms = <Uint8List>[
      Uint8List(kHistogramBins),
      for (var i = 1; i < 40; i++) peakHistogram(20),
    ];

    final result = selector.select(
      analysisOf(frames, histograms: histograms),
      const HighlightSettings(maxClips: 2, clipDurationSec: 6),
    );

    expect(result, isNotEmpty);
    for (final moment in result) {
      expect(moment.endUs - moment.startUs, greaterThan(0));
    }
  });

  test('частая смена кадров не ломает отбор', () {
    const step = 500000;
    final frames =
        List.generate(40, (i) => frame(timeUs: i * step, sharpness: 0.6));
    final histograms = <Uint8List>[
      for (var i = 0; i < 40; i++) peakHistogram(i % kHistogramBins),
    ];

    final result = selector.select(
      analysisOf(frames, histograms: histograms),
      const HighlightSettings(
        maxClips: 2,
        clipDurationSec: 4,
        minClipDurationSec: 0.5,
      ),
    );

    expect(result, isNotEmpty);
    for (final moment in result) {
      expect(moment.endUs, lessThanOrEqualTo(39 * step));
    }
  });
}
