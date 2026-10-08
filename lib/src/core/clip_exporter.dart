import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/moment.dart';
import 'package:highlight_cutter_native/highlight_cutter_native.dart';

enum ExportMode { clips, trailer }

class ExportResult {
  const ExportResult({required this.files, required this.mode});

  final List<String> files;
  final ExportMode mode;
}

class ClipExporter {
  ClipExporter({required HighlightCutterNative engine}) : _engine = engine;

  final HighlightCutterNative _engine;

  Future<ExportResult> export({
    required String sourcePath,
    required List<Moment> moments,
    required ExportMode mode,
    void Function(double progress)? onProgress,
    int bitrate = 6000000,
    int width = 0,
    int height = 0,
    int fps = 0,
  }) async {
    if (moments.isEmpty) {
      throw StateError('Нет выбранных моментов для нарезки');
    }

    final dir = await _outputDirectory();
    final files = <String>[];

    if (mode == ExportMode.trailer) {
      final outputPath =
          '${dir.path}/trailer_${DateTime.now().millisecondsSinceEpoch}.mp4';
      final ranges = moments.map((m) => [m.startUs, m.endUs]).toList();
      final path = await _engine.exportTrailer(
        sourcePath: sourcePath,
        ranges: ranges,
        outputPath: outputPath,
        width: width,
        height: height,
        bitrate: bitrate,
        fps: fps,
      );
      return ExportResult(files: [path], mode: ExportMode.trailer);
    }

    for (var i = 0; i < moments.length; i++) {
      final moment = moments[i];
      final outputPath =
          '${dir.path}/clip_${i + 1}_${DateTime.now().millisecondsSinceEpoch}.mp4';
      final path = await _engine.exportClip(
        sourcePath: sourcePath,
        startUs: moment.startUs,
        endUs: moment.endUs,
        outputPath: outputPath,
        width: width,
        height: height,
        bitrate: bitrate,
        fps: fps,
      );
      files.add(path);
      onProgress?.call((i + 1) / moments.length);
    }

    return ExportResult(files: files, mode: ExportMode.clips);
  }

  Future<Directory> _outputDirectory() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/highlights');
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }
}
