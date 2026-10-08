class Moment {
  const Moment({
    required this.startUs,
    required this.endUs,
    required this.score,
    required this.peakUs,
    required this.metrics,
    required this.reasons,
  });

  final int startUs;
  final int endUs;
  final int peakUs;
  final double score;
  final Map<String, double> metrics;
  final List<String> reasons;

  Duration get start => Duration(microseconds: startUs);
  Duration get end => Duration(microseconds: endUs);
  Duration get peak => Duration(microseconds: peakUs);
  Duration get length => Duration(microseconds: endUs - startUs);

  String get id => '${startUs}_$endUs';
}

class HighlightSettings {
  const HighlightSettings({
    this.clipDurationSec = 8.0,
    this.maxClips = 5,
    this.minClipDurationSec = 3.0,
    this.weights = defaultWeights,
    this.minGapSec = 2.0,
    this.minSceneSec = 1.5,
  });

  final double clipDurationSec;
  final int maxClips;
  final double minClipDurationSec;
  final double minGapSec;

  /// Короткие «сцены» не считаются сменой сцены: кадры, резко отличающиеся
  /// яркостью в пределах одной сцены, не должны разрывать клип.
  final double minSceneSec;
  final Map<String, double> weights;

  static const defaultWeights = <String, double>{
    'sharpness': 1.0,
    'exposure': 0.9,
    'contrast': 0.6,
    'colorfulness': 0.8,
    'faces': 0.7,
    'motion': 0.5,
  };

  HighlightSettings copyWith({
    double? clipDurationSec,
    int? maxClips,
    double? minClipDurationSec,
    double? minGapSec,
    double? minSceneSec,
    Map<String, double>? weights,
  }) {
    return HighlightSettings(
      clipDurationSec: clipDurationSec ?? this.clipDurationSec,
      maxClips: maxClips ?? this.maxClips,
      minClipDurationSec: minClipDurationSec ?? this.minClipDurationSec,
      minGapSec: minGapSec ?? this.minGapSec,
      minSceneSec: minSceneSec ?? this.minSceneSec,
      weights: weights ?? this.weights,
    );
  }
}
