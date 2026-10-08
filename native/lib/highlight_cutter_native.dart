import 'package:flutter/services.dart';

import 'models.dart';

export 'models.dart';

class HighlightCutterNative {
  /// Имя метода, которым нативная сторона шлёт прогресс анализа.
  /// На Android и iOS это MethodChannel с вручную реализованным
  /// протоколом event channel: нативник отвечает на `listen`/`cancel`
  /// и вызывает `invokeMethod(progressMethod, progress)`, поэтому
  /// подписка идёт через setMethodCallHandler, а не через поток.
  static const String progressMethod = 'analyzeFrames';

  HighlightCutterNative({
    MethodChannel? channel,
    MethodChannel? progressChannel,
  })  : _channel = channel ?? const MethodChannel('highlight_cutter/video'),
        _progressChannel = progressChannel ??
            const MethodChannel('highlight_cutter/video_progress');

  final MethodChannel _channel;
  final MethodChannel _progressChannel;

  Future<Map<Object?, Object?>> readMeta(String path) async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'readMeta',
      {'path': path},
    );
    if (result == null) {
      throw StateError('Не удалось прочитать метаданные видео');
    }
    return result;
  }

  Future<FrameAnalysis> analyzeFrames(
    String path, {
    double sampleFps = 2.0,
    void Function(double progress)? onProgress,
  }) async {
    if (onProgress == null) {
      return _decodeAnalysis(await _invokeAnalysis(path, sampleFps));
    }

    _progressChannel.setMethodCallHandler((call) async {
      if (call.method == progressMethod && call.arguments is num) {
        onProgress((call.arguments as num).toDouble());
      }
      return null;
    });

    try {
      return _decodeAnalysis(await _invokeAnalysis(path, sampleFps));
    } finally {
      _progressChannel.setMethodCallHandler(null);
    }
  }

  Future<Map<Object?, Object?>> _invokeAnalysis(
    String path,
    double sampleFps,
  ) async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'analyzeFrames',
      {
        'path': path,
        'sampleFps': sampleFps,
        'progressMethod': progressMethod,
      },
    );
    if (result == null) throw StateError('Анализ кадров не вернул результат');
    return result;
  }

  FrameAnalysis _decodeAnalysis(Map<Object?, Object?> result) {
    final metrics = result['metrics'] as Uint8List? ?? Uint8List(0);
    final histograms = result['histograms'] as Uint8List? ?? Uint8List(0);

    // Uint8List из MethodChannel — не самостоятельный буфер, а view внутрь
    // сообщения: StandardMessageCodec отдаёт
    // data.buffer.asUint8List(offset, length), где offset зависит от того,
    // что уже записано в сообщение. Для ответа analyzeFrames он не кратен 8,
    // и asFloat64List(offset, ...) падает с
    // «RangeError: Offset (N) must be a multiple of BYTES_PER_ELEMENT (8)».
    // Копия в свой буфер даёт offsetInBytes == 0.
    //
    // Порядок байт little-endian: Kotlin пишет ByteBuffer с nativeOrder(),
    // Swift копирует [Double] как есть, Android/iOS — little-endian,
    // строки Float64List читаются в порядке хоста.
    final aligned = Uint8List.fromList(metrics);
    // Первый аргумент asFloat64List — это смещение, а не длина, поэтому
    // передаём оба явно.
    final view = aligned.buffer.asFloat64List(0, aligned.lengthInBytes ~/ 8);

    final frames = <FrameSample>[];
    final count = aligned.lengthInBytes ~/ (kMetricsPerFrame * 8);
    for (var i = 0; i < count; i++) {
      final base = i * kMetricsPerFrame;
      frames.add(
        FrameSample(
          timeUs: view[base + kTimeUs].round(),
          sharpness: view[base + kSharpness],
          lumaMean: view[base + kLumaMean],
          lumaStd: view[base + kLumaStd],
          clippedLow: view[base + kClippedLow],
          clippedHigh: view[base + kClippedHigh],
          colorfulness: view[base + kColorfulness],
          faces: view[base + kFaces].round(),
          motion: view[base + kMotion],
          shotLengthSec: view[base + kShotLengthSec],
        ),
      );
    }

    return FrameAnalysis(
      frames: frames,
      histograms: histograms,
      sampleIntervalUs: (result['sampleIntervalUs'] as num?)?.toInt() ?? 0,
    );
  }

  Future<String> exportClip({
    required String sourcePath,
    required int startUs,
    required int endUs,
    required String outputPath,
    int width = 0,
    int height = 0,
    int bitrate = 6000000,
    int fps = 0,
  }) async {
    final result = await _channel.invokeMethod<String>('exportClip', {
      'sourcePath': sourcePath,
      'startUs': startUs,
      'endUs': endUs,
      'outputPath': outputPath,
      'width': width,
      'height': height,
      'bitrate': bitrate,
      'fps': fps,
    });
    if (result == null || result.isEmpty) throw StateError('Экспорт не удался');
    return result;
  }

  Future<String> exportTrailer({
    required String sourcePath,
    required List<List<int>> ranges,
    required String outputPath,
    int width = 0,
    int height = 0,
    int bitrate = 8000000,
    int fps = 0,
  }) async {
    final result = await _channel.invokeMethod<String>('exportTrailer', {
      'sourcePath': sourcePath,
      'ranges': ranges,
      'outputPath': outputPath,
      'width': width,
      'height': height,
      'bitrate': bitrate,
      'fps': fps,
    });
    if (result == null || result.isEmpty) {
      throw StateError('Сборка трейлера не удалась');
    }
    return result;
  }

  Future<String> thumbnail(String path, int timeUs) async {
    final result = await _channel.invokeMethod<String>('thumbnail', {
      'path': path,
      'timeUs': timeUs,
    });
    return result ?? '';
  }

  Future<void> cancel() => _channel.invokeMethod<void>('cancel', null);
}
