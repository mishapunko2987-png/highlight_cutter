import AVFoundation
import CoreImage
import Flutter
import UIKit

public class VideoPlugin: NSObject, FlutterPlugin {
  private static let channelName = "highlight_cutter/video"
  private static let progressChannelName = "highlight_cutter/video_progress"

  static let metricsPerFrame = 10
  static let histBins = 64
  static let analysisWidth = 192
  static let maxAnalysisFrames = 6000
  static let sharpNorm = 0.00012
  static let colorNorm = 110.0
  static let motionNorm = 0.18
  static let sceneThreshold = 0.45

  private var channel: FlutterMethodChannel?
  private var progressChannel: FlutterMethodChannel?
  private var cancelled = false
  private let workQueue = DispatchQueue(label: "highlight_cutter.work", qos: .userInitiated)

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: VideoPlugin.channelName,
      binaryMessenger: registrar.messenger()
    )
    let instance = VideoPlugin()
    instance.channel = channel
    instance.progressChannel = FlutterMethodChannel(
      name: VideoPlugin.progressChannelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.addMethodCallDelegate(ProgressHandler(), channel: instance.progressChannel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    cancelled = false
    let args = call.arguments as? [String: Any] ?? [:]

    switch call.method {
    case "readMeta":
      result(readMeta(path: args["path"] as? String, errorResult: result))
    case "analyzeFrames":
      guard let path = args["path"] as? String else {
        result(FlutterError(code: "bad_args", message: "path is required", details: nil))
        return
      }
      let fps = args["sampleFps"] as? Double ?? 2.0
      let method = call.method
      workQueue.async { [weak self] in
        guard let self else { return }
        do {
          let analysis = try self.analyze(path: path, sampleFps: fps, method: method)
          if !self.cancelled {
            DispatchQueue.main.async { result(analysis) }
          }
        } catch {
          if !self.cancelled {
            DispatchQueue.main.async {
              result(FlutterError(code: "analyze_failed", message: error.localizedDescription, details: nil))
            }
          }
        }
      }
    case "exportClip":
      guard let source = args["sourcePath"] as? String,
            let output = args["outputPath"] as? String,
            let startUs = args["startUs"] as? Int,
            let endUs = args["endUs"] as? Int,
            endUs > startUs
      else {
        result(FlutterError(code: "bad_args", message: "invalid clip range", details: nil))
        return
      }
      let request = ExportRequest(
        sourcePath: source,
        outputPath: output,
        ranges: [(startUs, endUs)],
        width: args["width"] as? Int ?? 0,
        height: args["height"] as? Int ?? 0,
        bitrate: args["bitrate"] as? Int ?? 6_000_000,
        fps: args["fps"] as? Int ?? 0
      )
      workQueue.async { [weak self] in
        guard let self else { return }
        do {
          let path = try VideoExporter(request: request).run()
          DispatchQueue.main.async { result(path) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "export_failed", message: error.localizedDescription, details: nil))
          }
        }
      }
    case "exportTrailer":
      guard let source = args["sourcePath"] as? String,
            let output = args["outputPath"] as? String,
            let rawRanges = args["ranges"] as? [[Int]]
      else {
        result(FlutterError(code: "bad_args", message: "invalid trailer request", details: nil))
        return
      }
      let ranges = rawRanges.compactMap { pair -> (Int, Int)? in
        guard pair.count >= 2, pair[1] > pair[0] else { return nil }
        return (pair[0], pair[1])
      }
      guard !ranges.isEmpty else {
        result(FlutterError(code: "bad_args", message: "empty ranges", details: nil))
        return
      }
      let request = ExportRequest(
        sourcePath: source,
        outputPath: output,
        ranges: ranges,
        width: args["width"] as? Int ?? 0,
        height: args["height"] as? Int ?? 0,
        bitrate: args["bitrate"] as? Int ?? 8_000_000,
        fps: args["fps"] as? Int ?? 0
      )
      workQueue.async { [weak self] in
        guard let self else { return }
        do {
          let path = try VideoExporter(request: request).run()
          DispatchQueue.main.async { result(path) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "export_failed", message: error.localizedDescription, details: nil))
          }
        }
      }
    case "thumbnail":
      guard let path = args["path"] as? String else {
        result(FlutterError(code: "bad_args", message: "path is required", details: nil))
        return
      }
      let timeUs = args["timeUs"] as? Int ?? 0
      workQueue.async {
        let out = Self.writeThumbnail(path: path, timeUs: timeUs)
        DispatchQueue.main.async { result(out ?? "") }
      }
    case "cancel":
      cancelled = true
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func readMeta(path: String?, errorResult: FlutterResult) -> Any? {
    guard let path, !path.isEmpty else {
      errorResult(FlutterError(code: "bad_args", message: "path is required", details: nil))
      return nil
    }
    let url = URL(fileURLWithPath: path)
    let asset = AVURLAsset(url: url)
    let duration = CMTimeGetSeconds(asset.duration)
    guard let track = asset.tracks(withMediaType: .video).first else {
      errorResult(FlutterError(code: "meta_failed", message: "Нет видеодорожки", details: nil))
      return nil
    }
    let size = track.naturalSize.applying(track.preferredTransform)
    let fps = track.nominalFrameRate > 0 ? track.nominalFrameRate : 30
    return [
      "path": path,
      "durationUs": Int(duration * 1_000_000),
      "width": Int(abs(size.width)),
      "height": Int(abs(size.height)),
      "fps": Double(fps),
      "rotationDegrees": 0,
    ]
  }

  private func analyze(path: String, sampleFps: Double, method: String) throws -> [String: Any] {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let durationUs = Int(CMTimeGetSeconds(asset.duration) * 1_000_000)
    guard durationUs > 0 else { throw NSError(domain: "hc", code: 1, userInfo: [NSLocalizedDescriptionKey: "Пустое видео"]) }

    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: VideoPlugin.analysisWidth, height: VideoPlugin.analysisWidth)
    generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 6)
    generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 6)

    var stepUs = max(1000, Int(1_000_000 / max(0.2, min(10, sampleFps))))
    var totalFrames = durationUs / stepUs + 1
    if totalFrames > VideoPlugin.maxAnalysisFrames {
      totalFrames = VideoPlugin.maxAnalysisFrames
      stepUs = durationUs / VideoPlugin.maxAnalysisFrames
    }

    var metrics: [Double] = []
    var histograms: [UInt8] = []
    var previous: FrameData?
    var lastBoundaryUs = 0
    metrics.reserveCapacity(totalFrames * VideoPlugin.metricsPerFrame)
    histograms.reserveCapacity(totalFrames * VideoPlugin.histBins)

    for index in 0..<max(totalFrames, 1) {
      if cancelled { throw NSError(domain: "hc", code: 2, userInfo: [NSLocalizedDescriptionKey: "cancelled"]) }
      let timeUs = index * stepUs
      if timeUs >= durationUs { break }

      var actual = CMTime.zero
      guard let cgImage = try? generator.copyCGImage(
        at: CMTime(value: timeUs, timescale: 1_000_000),
        actualTime: &actual
      ) else { continue }

      var current: FrameData
      do {
        current = try FrameData(cgImage: cgImage)
      } catch {
        continue
      }

      var shotLengthSec = Double(timeUs - lastBoundaryUs) / 1_000_000
      if shotLengthSec >= 0.4, current.histogramDistance(previous) > VideoPlugin.sceneThreshold {
        lastBoundaryUs = timeUs
        shotLengthSec = 0
      }

      metrics.append(contentsOf: [
        Double(timeUs),
        current.sharpness,
        current.lumaMean,
        current.lumaStd,
        current.clippedLow,
        current.clippedHigh,
        current.colorfulness,
        Double(current.faces),
        current.motion(previous),
        shotLengthSec,
      ])
      histograms.append(contentsOf: current.histogram)
      previous = current

      if index % 5 == 0 {
        let progress = Double(index) / Double(max(totalFrames, 1))
        DispatchQueue.main.async { [weak self] in
          self?.progressChannel?.invokeMethod(method, arguments: progress)
        }
      }
    }

    guard !metrics.isEmpty else {
      throw NSError(domain: "hc", code: 3, userInfo: [NSLocalizedDescriptionKey: "Не удалось извлечь кадры"])
    }

    DispatchQueue.main.async { [weak self] in
      self?.progressChannel?.invokeMethod(method, arguments: 1.0)
    }

    var metricsData = Data(count: metrics.count * MemoryLayout<Double>.size)
    metrics.withUnsafeBufferPointer { pointer in
      metricsData.withUnsafeMutableBytes { destination in
        destination.copyBytes(from: pointer.baseAddress!, byteCount: metrics.count * 8)
      }
    }

    return [
      "metrics": FlutterStandardTypedData(bytes: metricsData),
      "histograms": FlutterStandardTypedData(bytes: Data(histograms)),
      "sampleIntervalUs": stepUs,
    ]
  }

  private static func writeThumbnail(path: String, timeUs: Int) -> String? {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 480, height: 480)
    guard let cgImage = try? generator.copyCGImage(
      at: CMTime(value: timeUs, timescale: 1_000_000),
      actualTime: nil
    ) else { return nil }
    let image = UIImage(cgImage: cgImage)
    guard let data = image.jpegData(compressionQuality: 0.85) else { return nil }
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("thumb_\(UUID().uuidString).jpg")
    try? data.write(to: url)
    return url.path
  }
}

private class ProgressHandler: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {}

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "listen", "cancel":
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

struct ExportRequest {
  let sourcePath: String
  let outputPath: String
  let ranges: [(Int, Int)]
  let width: Int
  let height: Int
  let bitrate: Int
  let fps: Int
}

struct FrameData {
  let sharpness: Double
  let lumaMean: Double
  let lumaStd: Double
  let clippedLow: Double
  let clippedHigh: Double
  let colorfulness: Double
  let faces: Int
  let histogram: [UInt8]
  private let luma: [Double]
  private let lumaWidth: Int
  private let lumaHeight: Int

  init(cgImage: CGImage) throws {
    let width = cgImage.width
    let height = cgImage.height
    let pixels = try cgImage.toLumaArray()
    if pixels.isEmpty {
      throw NSError(
        domain: "highlight_cutter",
        code: 20,
        userInfo: [NSLocalizedDescriptionKey: "Не удалось прочитать пиксели кадра"]
      )
    }

    var luma = [Double](repeating: 0, count: width * height)
    var binCounts = [Int](repeating: 0, count: VideoPlugin.histBins)
    var sum = 0.0
    var clippedLow = 0
    var clippedHigh = 0
    var rgMean = 0.0
    var ybMean = 0.0
    var rgSq = 0.0
    var ybSq = 0.0

    for index in pixels.indices {
      let (y, r, g, b) = pixels[index]
      luma[index] = y
      sum += y
      if y <= 0.02 { clippedLow += 1 }
      if y >= 0.98 { clippedHigh += 1 }
      let bin = min(63, max(0, Int(y * 63)))
      binCounts[bin] += 1

      let rg = r - g
      let yb = 0.5 * (r + g) - b
      rgMean += rg
      ybMean += yb
      rgSq += rg * rg
      ybSq += yb * yb
    }

    let count = Double(max(pixels.count, 1))
    let mean = sum / count
    var variance = 0.0
    for value in luma {
      let d = value - mean
      variance += d * d
    }
    variance /= count

    let rgStd = sqrt(max(0, rgSq / count - pow(rgMean / count, 2)))
    let ybStd = sqrt(max(0, ybSq / count - pow(ybMean / count, 2)))
    let magnitude = sqrt(pow(rgMean / count, 2) + pow(ybMean / count, 2))
    let colorfulness = sqrt(rgStd * rgStd + ybStd * ybStd) + 0.3 * magnitude

    self.luma = luma
    self.lumaWidth = width
    self.lumaHeight = height
    self.histogram = Self.normalize(binCounts: binCounts)
    self.lumaMean = mean
    self.lumaStd = sqrt(variance)
    self.clippedLow = Double(clippedLow) / count
    self.clippedHigh = Double(clippedHigh) / count
    self.colorfulness = min(1, colorfulness / VideoPlugin.colorNorm)
    self.sharpness = min(1, luma.laplacianVariance(width: width, height: height) / VideoPlugin.sharpNorm)
    self.faces = cgImage.detectFaces()
  }

  static func normalize(binCounts: [Int]) -> [UInt8] {
    let total = binCounts.reduce(0, +)
    guard total > 0 else { return [UInt8](repeating: 0, count: binCounts.count) }
    return binCounts.map { count in
      let scaled = Int((Double(count) * 255.0 / Double(total)).rounded())
      return UInt8(min(255, max(0, scaled)))
    }
  }

  func motion(_ previous: FrameData?) -> Double {
    guard let previous, !luma.isEmpty, previous.luma.count == luma.count else { return 0 }
    var sum = 0.0
    for index in luma.indices {
      sum += abs(luma[index] - previous.luma[index])
    }
    return min(1, sum / Double(luma.count) / VideoPlugin.motionNorm)
  }

  func histogramDistance(_ other: FrameData?) -> Double {
    guard let other, other.histogram.count == histogram.count else { return 0 }
    var total = 0
    for index in histogram.indices {
      total += abs(Int(histogram[index]) - Int(other.histogram[index]))
    }
    return min(1, Double(total) / 510.0)
  }
}

extension Array where Element == Double {
  func laplacianVariance(width: Int, height: Int) -> Double {
    guard width >= 3, height >= 3 else { return 0 }
    var sum = 0.0
    var sumSq = 0.0
    var count = 0
    for y in 1..<(height - 1) {
      let rowCenter = y * width
      let rowUp = rowCenter - width
      let rowDown = rowCenter + width
      for x in 1..<(width - 1) {
        let center = rowCenter + x
        let value = -4 * self[center]
          + self[rowUp + x] + self[rowDown + x]
          + self[rowCenter + x - 1] + self[rowCenter + x + 1]
        sum += value
        sumSq += value * value
        count += 1
      }
    }
    if count == 0 { return 0 }
    let mean = sum / Double(count)
    return sumSq / Double(count) - mean * mean
  }
}

extension CGImage {
  func toLumaArray() throws -> [(Double, Double, Double, Double)] {
    let width = self.width
    let height = self.height
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
      data: &buffer,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else {
      throw NSError(
        domain: "highlight_cutter",
        code: 21,
        userInfo: [NSLocalizedDescriptionKey: "Не удалось создать контекст"]
      )
    }
    context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))

    var result = [(Double, Double, Double, Double)]()
    result.reserveCapacity(width * height)
    for index in stride(from: 0, to: buffer.count, by: 4) {
      let b = Double(buffer[index])
      let g = Double(buffer[index + 1])
      let r = Double(buffer[index + 2])
      let y = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
      result.append((y, r, g, b))
    }
    return result
  }

  func detectFaces() -> Int {
    guard let detector = CIDetector(
      ofType: CIDetectorTypeFace,
      context: nil,
      options: [CIDetectorAccuracy: CIDetectorAccuracyLow]
    ) else { return 0 }
    let ciImage = CIImage(cgImage: self)
    let features = detector.features(in: ciImage)
    return features.count
  }
}
