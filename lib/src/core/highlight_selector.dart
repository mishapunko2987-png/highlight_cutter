import 'dart:math' as math;
import 'dart:typed_data';

import 'package:highlight_cutter_native/highlight_cutter_native.dart';

import '../models/moment.dart';

class HighlightSelector {
  const HighlightSelector();

  static const int smoothRadius = 2;

  List<Moment> select(FrameAnalysis analysis, HighlightSettings settings) {
    if (analysis.frames.length < 2) return const [];

    final scenes = _detectScenes(analysis, settings.minSceneSec);
    final raw = _scoreFrames(analysis, settings);
    final smoothed = _smooth(raw, analysis.frames.length);
    return _pickMoments(
      analysis: analysis,
      raw: raw,
      smoothed: smoothed,
      scenes: scenes,
      settings: settings,
    );
  }

  List<int> _detectScenes(FrameAnalysis analysis, double minSceneSec) {
    final frames = analysis.frames;
    final minSceneUs = (minSceneSec * 1e6).round();
    final boundaries = <int>[0];

    for (var i = 1; i < frames.length; i++) {
      final prev = analysis.histogramAt(i - 1);
      final curr = analysis.histogramAt(i);
      if (_histogramDistance(prev, curr) <= 0.45) continue;

      final lastBoundaryUs = frames[boundaries.last].timeUs;
      if (frames[i].timeUs - lastBoundaryUs < minSceneUs) continue;
      boundaries.add(i);
    }

    boundaries.add(frames.length);
    return boundaries;
  }

  /// Total variation distance между нормализованными гистограммами: 0 — совпадение, 1 — полностью разные.
  double _histogramDistance(Uint8List a, Uint8List b) {
    if (a.isEmpty || b.isEmpty || a.length != b.length) return 0;
    var total = 0;
    for (var i = 0; i < a.length; i++) {
      total += (a[i] - b[i]).abs();
    }
    return (total / 510.0).clamp(0.0, 1.0);
  }

  List<double> _scoreFrames(
      FrameAnalysis analysis, HighlightSettings settings) {
    final frames = analysis.frames;
    final sharpness = _robustNormalize(frames.map((f) => f.sharpness).toList());
    final exposure = _robustNormalize(
      frames.map((f) => _exposureScore(f)).toList(),
    );
    final contrast = _robustNormalize(
      frames.map((f) => _contrastScore(f)).toList(),
    );
    final color = _robustNormalize(
      frames.map((f) => f.colorfulness).toList(),
    );
    final faces = _robustNormalize(
      frames.map((f) => math.min(f.faces / 3.0, 1.0)).toList(),
    );
    final motion = _robustNormalize(frames.map((f) => f.motion).toList());
    final activity = _activityScores(frames);

    final w = settings.weights;
    return List<double>.generate(frames.length, (i) {
      var sum = 0.0;
      var weightSum = 0.0;
      void add(String key, double value) {
        final weight = w[key] ?? 0;
        if (weight == 0) return;
        sum += weight * value;
        weightSum += weight;
      }

      add('sharpness', sharpness[i]);
      add('exposure', exposure[i]);
      add('contrast', contrast[i]);
      add('colorfulness', color[i]);
      add('faces', faces[i]);
      add('motion', motion[i]);

      if (weightSum == 0) return 0;
      var score = sum / weightSum;
      if (frames[i].shotLengthSec < 1.0) score *= 0.6;
      // Качество картинки само по себе не делает момент интересным: неподвижный
      // красивый кадр набирает полный балл по резкости, цвету и экспозиции.
      // Движение и люди в кадре — признак того, что что-то происходит,
      // поэтому они домножают оценку, а не просто суммируются с ней.
      return score * activity[i];
    });
  }

  /// Насколько в кадре что-то происходит: движение или присутствие людей.
  /// Возвращает коэффициент от [activityFloor] до 1, который домножается к
  /// оценке кадра.
  List<double> _activityScores(List<FrameSample> frames) {
    return frames.map((f) {
      final byMotion = (f.motion / activityMotionFull).clamp(0.0, 1.0);
      final byPeople = math.min(f.faces / 1.0, 1.0);
      final level = math.max(byMotion, byPeople);
      return activityFloor + (1.0 - activityFloor) * level;
    }).toList();
  }

  /// Нижняя граница коэффициента: полностью неподвижный кадр без людей теряет
  /// 30% оценки, но не выпадает из отбора совсем.
  static const double activityFloor = 0.7;

  /// Движение, при котором кадр считается «живым» целиком.
  static const double activityMotionFull = 0.3;

  double _exposureScore(FrameSample f) {
    final under = f.clippedLow;
    final over = f.clippedHigh;
    final idealCenter =
        1.0 - ((f.lumaMean - 0.45).abs() / 0.45).clamp(0.0, 1.0);
    final clipped = 1.0 - (under + over).clamp(0.0, 1.0) * 4.0;
    return (idealCenter * 0.6 + clipped * 0.4).clamp(0.0, 1.0);
  }

  double _contrastScore(FrameSample f) {
    return (f.lumaStd / 0.28).clamp(0.0, 1.0);
  }

  List<double> _robustNormalize(List<double> values) {
    if (values.isEmpty) return values;
    final sorted = List<double>.from(values)..sort();
    final median = _percentile(sorted, 0.5);
    final deviations = values.map((v) => (v - median).abs()).toList()..sort();
    final mad = _percentile(deviations, 0.5);
    final scale = mad > 1e-6 ? mad * 1.4826 : 1e-6;

    return values.map((v) => ((v - median) / scale).clamp(-3.0, 3.0)).map((v) {
      final shifted = (v + 3.0) / 6.0;
      return shifted.clamp(0.0, 1.0);
    }).toList();
  }

  double _percentile(List<double> sorted, double q) {
    if (sorted.isEmpty) return 0;
    final pos = q * (sorted.length - 1);
    final low = pos.floor();
    final high = pos.ceil();
    if (low == high) return sorted[low];
    final frac = pos - low;
    return sorted[low] * (1 - frac) + sorted[high] * frac;
  }

  List<double> _smooth(List<double> scores, int length) {
    final result = List<double>.filled(length, 0);
    for (var i = 0; i < length; i++) {
      var sum = 0.0;
      var count = 0;
      for (var d = -smoothRadius; d <= smoothRadius; d++) {
        final idx = i + d;
        if (idx < 0 || idx >= length) continue;
        sum += scores[idx];
        count++;
      }
      result[i] = sum / count;
    }
    return result;
  }

  List<Moment> _pickMoments({
    required FrameAnalysis analysis,
    required List<double> raw,
    required List<double> smoothed,
    required List<int> scenes,
    required HighlightSettings settings,
  }) {
    final frames = analysis.frames;
    final totalUs = frames.last.timeUs;
    final clipUs = (settings.clipDurationSec * 1e6).round();
    final gapUs = (settings.minGapSec * 1e6).round();
    final minUs = (settings.minClipDurationSec * 1e6).round();

    // Кандидаты ранжируются не по одному кадру, а по окну клипа: среднее по
    // сглаженному скору внутри окна плюс сам пик. Один яркий кадр посреди
    // скучного фильма больше не обгоняет ровный участок, который целиком
    // интересный — раньше сортировка шла только по пиковому кадру.
    final windowScore = _windowScores(smoothed, frames, clipUs);

    final candidates = List<int>.generate(frames.length, (i) => i)
      ..sort((a, b) {
        final byWindow = _rankScore(smoothed, windowScore, a)
            .compareTo(_rankScore(smoothed, windowScore, b));
        if (byWindow != 0) return byWindow;
        final byScore = smoothed[b].compareTo(smoothed[a]);
        if (byScore != 0) return byScore;
        return raw[b].compareTo(raw[a]);
      });

    final chosen = <Moment>[];
    final takenRanges = <List<int>>[];

    for (final candidateIndex in candidates) {
      if (chosen.length >= settings.maxClips) break;

      final peakIndex = _refinePeak(candidateIndex, raw, smoothed);
      final peakUs = frames[peakIndex].timeUs;
      var startUs = peakUs - (clipUs * 0.4).round();
      var endUs = startUs + clipUs;
      if (startUs < 0) startUs = 0;
      if (endUs > totalUs) {
        endUs = totalUs;
        startUs = math.max(0, endUs - clipUs);
      }

      // Клип не выходит за границы сцены: монтаж в середине плана ломает кадр.
      final sceneRange = _sceneRangeFor(scenes, peakIndex, frames);
      startUs = math.max(startUs, sceneRange.$1);
      endUs = math.min(endUs, sceneRange.$2);
      if (endUs - startUs < minUs) continue;

      // Дедупликация. Момент отбрасывается, если он пересекается с уже
      // взятым или отстоит от него меньше чем на gapUs (зазор считается от
      // конца предыдущего клипа до начала следующего).
      //
      // Проверка на пересечение сама по себе не спасала от «одного эпизода
      // 15 раз»: лучшие пики яркого отрезка идут подряд с шагом в пару
      // секунд, при зазоре в 2 с все они проходили. Именно зазор разводит
      // моменты по фильму.
      final tooClose = takenRanges.any(
        (r) => startUs < r[1] + gapUs && endUs > r[0] - gapUs,
      );
      if (tooClose) continue;

      takenRanges.add([startUs, endUs]);
      chosen.add(
        Moment(
          startUs: startUs,
          endUs: endUs,
          peakUs: peakUs,
          score: raw[peakIndex],
          metrics: _windowMetrics(analysis, startUs, endUs),
          reasons: _reasonsFor(analysis, peakIndex),
        ),
      );
    }

    chosen.sort((a, b) => a.startUs.compareTo(b.startUs));
    return chosen;
  }

  /// Средний сглаженный скор по окну длиной [clipUs] вокруг кадра [i].
  /// Скользящее окно двумя указателями: отсортированные по времени кадры
  /// позволяют не пересчитывать сумму на каждом шаге.
  List<double> _windowScores(
    List<double> smoothed,
    List<FrameSample> frames,
    int clipUs,
  ) {
    final n = frames.length;
    final halfUs = clipUs ~/ 2;
    final result = List<double>.filled(n, 0.0);
    var lo = 0;
    var hi = 0;
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      final center = frames[i].timeUs;
      while (hi < n && frames[hi].timeUs <= center + halfUs) {
        sum += smoothed[hi];
        hi++;
      }
      while (lo < hi && frames[lo].timeUs < center - halfUs) {
        sum -= smoothed[lo];
        lo++;
      }
      final count = hi - lo;
      result[i] = count == 0 ? 0.0 : sum / count;
    }
    return result;
  }

  /// Итоговая оценка кандидата: пик весит [windowPeakWeight], качество
  /// окна — остальное.
  double _rankScore(List<double> smoothed, List<double> windowScore, int i) {
    return windowPeakWeight * smoothed[i] +
        (1.0 - windowPeakWeight) * windowScore[i];
  }

  static const double windowPeakWeight = 0.6;

  int _refinePeak(int candidate, List<double> raw, List<double> smoothed) {
    var best = candidate;
    var bestRaw = raw[candidate];
    for (var d = -smoothRadius; d <= smoothRadius; d++) {
      final index = candidate + d;
      if (index < 0 || index >= raw.length) continue;
      if (raw[index] > bestRaw) {
        bestRaw = raw[index];
        best = index;
      }
    }
    return best;
  }

  (int, int) _sceneRangeFor(
    List<int> scenes,
    int frameIndex,
    List<FrameSample> frames,
  ) {
    var startIndex = 0;
    var endIndex = frames.length;

    for (var s = 0; s < scenes.length - 1; s++) {
      final lo = scenes[s];
      final hi = scenes[s + 1];
      if (frameIndex >= lo && frameIndex < hi) {
        startIndex = lo;
        endIndex = hi;
        break;
      }
    }

    final startUs = startIndex < frames.length ? frames[startIndex].timeUs : 0;
    final endUs = endIndex >= frames.length
        ? frames[frames.length - 1].timeUs
        : frames[endIndex].timeUs;
    return (startUs, math.max(startUs, endUs));
  }

  Map<String, double> _windowMetrics(
    FrameAnalysis analysis,
    int startUs,
    int endUs,
  ) {
    final frames = analysis.frames;
    var sharpness = 0.0;
    var color = 0.0;
    var luma = 0.0;
    var count = 0;
    for (final f in frames) {
      if (f.timeUs < startUs || f.timeUs > endUs) continue;
      sharpness += f.sharpness;
      color += f.colorfulness;
      luma += f.lumaMean;
      count++;
    }
    if (count == 0) {
      return const {'sharpness': 0, 'colorfulness': 0, 'exposure': 0};
    }
    return {
      'sharpness': sharpness / count,
      'colorfulness': color / count,
      'exposure': luma / count,
    };
  }

  List<String> _reasonsFor(FrameAnalysis analysis, int index) {
    final frame = analysis.frames[index];
    final reasons = <String>[];
    if (frame.sharpness > 0.5) reasons.add('Резкий кадр');
    if (frame.faces > 0) reasons.add('Люди в кадре');
    if (frame.colorfulness > 0.5) reasons.add('Насыщенные цвета');
    if (frame.lumaMean > 0.35 && frame.lumaMean < 0.65) {
      reasons.add('Хорошая экспозиция');
    }
    if (frame.motion > 0.4) reasons.add('Динамика');
    if (reasons.isEmpty) reasons.add('Сильная композиция');
    return reasons;
  }
}
