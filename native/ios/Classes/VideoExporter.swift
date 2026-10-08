import AVFoundation
import Foundation

final class VideoExporter {
  private let request: ExportRequest

  init(request: ExportRequest) {
    self.request = request
  }

  func run() throws -> String {
    let source = AVURLAsset(url: URL(fileURLWithPath: request.sourcePath))
    let outputURL = URL(fileURLWithPath: request.outputPath)

    let directory = outputURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    if FileManager.default.fileExists(atPath: outputURL.path) {
      try FileManager.default.removeItem(at: outputURL)
    }

    let composition = AVMutableComposition()
    guard let sourceVideoTrack = source.tracks(withMediaType: .video).first else {
      throw NSError(
        domain: "highlight_cutter",
        code: 10,
        userInfo: [NSLocalizedDescriptionKey: "В файле нет видеодорожки"]
      )
    }

    let sourceDurationUs = Int(CMTimeGetSeconds(source.duration) * 1_000_000)
    guard sourceDurationUs > 0 else {
      throw NSError(
        domain: "highlight_cutter",
        code: 11,
        userInfo: [NSLocalizedDescriptionKey: "Пустое видео"]
      )
    }

    let preferred = sourceVideoTrack.naturalSize.applying(sourceVideoTrack.preferredTransform)
    let baseWidth = abs(Int(preferred.width))
    let baseHeight = abs(Int(preferred.height))
    let (targetWidth, targetHeight) = resolveSize(width: baseWidth, height: baseHeight)
    let needsScale = targetWidth != baseWidth || targetHeight != baseHeight
    let renderSize = needsScale ? CGSize(width: targetWidth, height: targetHeight) : .zero
    let outputDurationUs = request.ranges.reduce(0) { $0 + max(0, $1.1 - $1.0) }
    if outputDurationUs <= 0 {
      throw NSError(
        domain: "highlight_cutter",
        code: 17,
        userInfo: [NSLocalizedDescriptionKey: "Пустой диапазон"]
      )
    }

    let fps = resolveFps(track: sourceVideoTrack)
    guard let videoTrack = composition.addMutableTrack(
      withMediaType: .video,
      preferredTrackID: kCMPersistentTrackID_Invalid
    ) else {
      throw NSError(
        domain: "highlight_cutter",
        code: 12,
        userInfo: [NSLocalizedDescriptionKey: "Не удалось создать видеодорожку"]
      )
    }

    let sourceAudioTrack = source.tracks(withMediaType: .audio).first
    let audioTrack: AVMutableCompositionTrack? = sourceAudioTrack.flatMap { _ in
      composition.addMutableTrack(
        withMediaType: .audio,
        preferredTrackID: kCMPersistentTrackID_Invalid
      )
    }

    var cursorUs = 0
    for range in request.ranges {
      let startUs = max(0, min(range.0, sourceDurationUs - 1))
      let endUs = max(startUs + 1, min(range.1, sourceDurationUs))
      let durationUs = endUs - startUs

      let startTime = CMTime(value: startUs, timescale: 1_000_000)
      let durationTime = CMTime(value: durationUs, timescale: 1_000_000)
      let insertionTime = CMTime(value: cursorUs, timescale: 1_000_000)

      try videoTrack.insertTimeRange(
        CMTimeRange(start: startTime, duration: durationTime),
        of: sourceVideoTrack,
        at: insertionTime
      )

      if let sourceAudioTrack, let audioTrack {
        try? audioTrack.insertTimeRange(
          CMTimeRange(start: startTime, duration: durationTime),
          of: sourceAudioTrack,
          at: insertionTime
        )
      }

      cursorUs += durationUs
    }

    videoTrack.preferredTransform = preferredTransform(
      for: sourceVideoTrack,
      renderSize: renderSize
    )

    let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)
    guard let exporter else {
      throw NSError(
        domain: "highlight_cutter",
        code: 14,
        userInfo: [NSLocalizedDescriptionKey: "Не удалось создать экспортёр"]
      )
    }

    exporter.outputURL = outputURL
    exporter.outputFileType = .mp4
    exporter.shouldOptimizeForNetworkUse = true
    exporter.videoComposition = makeVideoComposition(
      track: videoTrack,
      renderSize: renderSize,
      durationUs: outputDurationUs,
      fps: fps
    )

    let semaphore = DispatchSemaphore(value: 0)
    exporter.exportAsynchronously { semaphore.signal() }
    semaphore.wait()

    switch exporter.status {
    case .completed:
      return outputURL.path
    case .cancelled:
      throw NSError(
        domain: "highlight_cutter",
        code: 15,
        userInfo: [NSLocalizedDescriptionKey: "Экспорт отменён"]
      )
    default:
      throw exporter.error ?? NSError(
        domain: "highlight_cutter",
        code: 16,
        userInfo: [NSLocalizedDescriptionKey: "Экспорт не удался"]
      )
    }
  }

  private func preferredTransform(
    for track: AVAssetTrack,
    renderSize: CGSize
  ) -> CGAffineTransform {
    let transform = track.preferredTransform
    guard renderSize != .zero else { return transform }

    let transformed = track.naturalSize.applying(transform)
    let displayWidth = abs(transformed.width)
    let displayHeight = abs(transformed.height)
    guard displayWidth > 0, displayHeight > 0 else { return transform }

    return transform.concatenating(
      CGAffineTransform(
        scaleX: renderSize.width / displayWidth,
        y: renderSize.height / displayHeight
      )
    )
  }

  private func makeVideoComposition(
    track: AVAssetTrack,
    renderSize: CGSize,
    durationUs: Int,
    fps: Int
  ) -> AVVideoComposition? {
    guard renderSize != .zero else { return nil }

    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(
      start: .zero,
      duration: CMTime(value: CMTimeValue(durationUs), timescale: 1_000_000)
    )

    let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
    layer.setTransform(track.preferredTransform, at: .zero)
    instruction.layerInstructions = [layer]

    let videoComposition = AVMutableVideoComposition()
    videoComposition.renderSize = renderSize
    videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
    videoComposition.instructions = [instruction]
    return videoComposition
  }

  private func resolveSize(width: Int, height: Int) -> (Int, Int) {
    let maxWidth = 1920
    var targetWidth = request.width > 0 ? request.width : width
    var targetHeight = request.height > 0 ? request.height : height

    if request.width <= 0 || request.height <= 0 {
      if targetWidth > maxWidth {
        let ratio = Double(maxWidth) / Double(targetWidth)
        targetWidth = maxWidth
        targetHeight = max(2, Int(Double(targetHeight) * ratio))
      }
      return (targetWidth, targetHeight)
    }

    if targetWidth > maxWidth {
      let ratio = Double(maxWidth) / Double(targetWidth)
      targetWidth = maxWidth
      targetHeight = max(2, Int(Double(targetHeight) * ratio))
    }
    return (max(2, targetWidth / 2 * 2), max(2, targetHeight / 2 * 2))
  }

  private func resolveFps(track: AVAssetTrack) -> Int {
    if request.fps > 0 { return request.fps }
    let nominal = track.nominalFrameRate
    return nominal > 0 ? min(max(Int(nominal), 15), 60) : 30
  }
}
