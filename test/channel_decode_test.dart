import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:highlight_cutter_native/highlight_cutter_native.dart';

const MethodChannel _channel = MethodChannel('highlight_cutter/video');

/// Упаковывает метрики так же, как нативная сторона: плотный массив
/// float64 без заголовка, little-endian.
Uint8List encodeMetrics(List<List<double>> frames) {
  final data = Float64List(frames.length * kMetricsPerFrame);
  for (var f = 0; f < frames.length; f++) {
    for (var m = 0; m < kMetricsPerFrame; m++) {
      data[f * kMetricsPerFrame + m] = frames[f][m];
    }
  }
  return Uint8List.fromList(
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
  );
}

void mockAnalysis(Uint8List metrics, {Uint8List? histograms}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (MethodCall call) async {
    expect(call.method, 'analyzeFrames');
    return <Object?, Object?>{
      'metrics': metrics,
      'histograms': histograms ?? Uint8List(0),
      'sampleIntervalUs': 500000,
    };
  });
}

List<double> frame(double timeUs, double sharpness, double faces) {
  return [timeUs, sharpness, 0.45, 0.15, 0.0, 0.0, 0.3, faces, 0.1, 4.0];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  // Регрессия: StandardMessageCodec отдаёт byte[] как view внутрь буфера
  // сообщения (data.buffer.asUint8List(offset, length)), а offset там не
  // кратен8. Чтение как asFloat64List(offset, ...) падало с
  // «RangeError: Offset (18) must be a multiple of BYTES_PER_ELEMENT (8)».
  test('метрики декодируются из невыровненного Uint8List кокода', () async {
    final metrics = encodeMetrics([
      frame(1000, 0.5, 2),
      frame(1500, 0.7, 1),
    ]);
    final histograms = Uint8List(kHistogramBins * 2);
    mockAnalysis(metrics, histograms: histograms);

    final analysis = await HighlightCutterNative().analyzeFrames('/tmp/a.mp4');

    expect(analysis.frames, hasLength(2));
    expect(analysis.frames[0].timeUs, 1000);
    expect(analysis.frames[0].sharpness, 0.5);
    expect(analysis.frames[0].faces, 2);
    expect(analysis.frames[0].shotLengthSec, 4.0);
    expect(analysis.frames[1].timeUs, 1500);
    expect(analysis.frames[1].sharpness, 0.7);
    expect(analysis.histograms, histograms);
    expect(analysis.sampleIntervalUs, 500000);
  });

  // Размер метрик неоднозначен по длине varint в кокоде, поэтому длина
  // сообщения меняет смещение — проверяем кадры разного количества.
  test('кадры любого количества декодируются', () async {
    for (final count in [1, 3, 16, 17, 100, 1000]) {
      final frames = [
        for (var i = 0; i < count; i++) frame(i * 500000, i / count, i % 5),
      ];
      mockAnalysis(encodeMetrics(frames));

      final analysis = await HighlightCutterNative().analyzeFrames('/tmp/a.mp4');

      expect(analysis.frames, hasLength(count));
      expect(analysis.frames.last.timeUs, (count - 1) * 500000);
      expect(analysis.frames.last.faces, (count - 1) % 5);
    }
  });

  test('пустой ответ не падает и даёт ноль кадров', () async {
    mockAnalysis(Uint8List(0));

    final analysis = await HighlightCutterNative().analyzeFrames('/tmp/a.mp4');

    expect(analysis.frames, isEmpty);
    expect(analysis.isEmpty, isTrue);
  });
}