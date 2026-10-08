import 'dart:math' as math;
import 'dart:typed_data';

const int kMetricsPerFrame = 10;
const int kHistogramBins = 64;

const int kTimeUs = 0;
const int kSharpness = 1;
const int kLumaMean = 2;
const int kLumaStd = 3;
const int kClippedLow = 4;
const int kClippedHigh = 5;
const int kColorfulness = 6;
const int kFaces = 7;
const int kMotion = 8;
const int kShotLengthSec = 9;

class VideoMeta {
  const VideoMeta({
    required this.path,
    required this.durationUs,
    required this.width,
    required this.height,
    required this.fps,
    this.rotationDegrees = 0,
  });

  final String path;
  final int durationUs;
  final int width;
  final int height;
  final double fps;
  final int rotationDegrees;

  Duration get duration => Duration(microseconds: durationUs);

  bool get isPortrait => height > width;

  factory VideoMeta.fromMap(Map<Object?, Object?> map) {
    return VideoMeta(
      path: map['path']! as String,
      durationUs: (map['durationUs'] as num?)?.toInt() ?? 0,
      width: (map['width'] as num?)?.toInt() ?? 0,
      height: (map['height'] as num?)?.toInt() ?? 0,
      fps: (map['fps'] as num?)?.toDouble() ?? 30.0,
      rotationDegrees: (map['rotationDegrees'] as num?)?.toInt() ?? 0,
    );
  }
}

class FrameSample {
  const FrameSample({
    required this.timeUs,
    required this.sharpness,
    required this.lumaMean,
    required this.lumaStd,
    required this.clippedLow,
    required this.clippedHigh,
    required this.colorfulness,
    required this.faces,
    required this.motion,
    required this.shotLengthSec,
  });

  final int timeUs;
  final double sharpness;
  final double lumaMean;
  final double lumaStd;
  final double clippedLow;
  final double clippedHigh;
  final double colorfulness;
  final int faces;
  final double motion;
  final double shotLengthSec;

  Duration get time => Duration(microseconds: timeUs);
}

class FrameAnalysis {
  const FrameAnalysis({
    required this.frames,
    required this.histograms,
    this.sampleIntervalUs = 0,
  });

  final List<FrameSample> frames;
  final Uint8List histograms;
  final int sampleIntervalUs;

  bool get isEmpty => frames.isEmpty;

  Uint8List histogramAt(int index) {
    final offset = index * kHistogramBins;
    final end = math.min(offset + kHistogramBins, histograms.length);
    if (offset >= histograms.length) return Uint8List(kHistogramBins);
    return Uint8List.sublistView(histograms, offset, end);
  }
}
