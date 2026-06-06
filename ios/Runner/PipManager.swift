import AVKit
import CoreImage
import UIKit

/// Renders teleprompter text line-by-line into a PiP floating window.
///
/// The native side independently scrolls through lines once started.
/// Flutter controls start/stop, speed, settings and line-position via
/// method channel commands.
@available(iOS 15.0, *)
final class PipManager: NSObject {
  // ── PiP primitives ────────────────────────────────────────────
  private var pipController: AVPictureInPictureController!
  private let displayLayer = AVSampleBufferDisplayLayer()

  // ── Render loop ───────────────────────────────────────────────
  private var displayLink: CADisplayLink?
  private var pixelBufferPool: CVPixelBufferPool?
  private let canvasWidth = 720
  private let canvasHeight = 400
  private var frameCount: Int64 = 0

  // ── Scrolling state ───────────────────────────────────────────
  private var lines: [String] = []
  private var lineIndex: Int = 0
  private var lineProgress: Double = 0.0  // 0..1 fractional progress within current line

  // ── Settings (set from Flutter) ────────────────────────────────
  var fontSize: CGFloat = 56
  var isMirrored = false
  /// Lines per second to advance (1 = one line per second ≈ 60 wpm)
  private var speed: Double = 0.33

  // MARK: - Setup

  func setup() {
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      print("[PipManager] PiP not supported on this device")
      return
    }

    displayLayer.videoGravity = .resizeAspectFill
    displayLayer.backgroundColor = UIColor.black.cgColor

    let contentSource = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: displayLayer,
      playbackDelegate: self
    )
    pipController = AVPictureInPictureController(contentSource: contentSource)
    pipController.canStartPictureInPictureAutomaticallyFromInline = true
    createPixelBufferPool()
  }

  // MARK: - Public API

  var isAvailable: Bool {
    AVPictureInPictureController.isPictureInPictureSupported()
  }

  var isActive: Bool {
    pipController?.isPictureInPictureActive ?? false
  }

  func start(
    text: String,
    speed: Double,
    fontSize: CGFloat,
    isMirrored: Bool,
    scrollOffset: Double
  ) {
    self.lines = text
      .components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    self.speed = speed
    self.fontSize = fontSize
    self.isMirrored = isMirrored

    // Estimate line index from scroll offset
    if !self.lines.isEmpty {
      let totalLines = self.lines.count
      let estimatedLine = Int((scrollOffset / 1000) * Double(totalLines))
      lineIndex = min(max(estimatedLine, 0), totalLines - 1)
    } else {
      lineIndex = 0
    }
    lineProgress = 0

    startDisplayLink()
    pipController.startPictureInPicture()
  }

  func stop() {
    pipController.stopPictureInPicture()
    stopDisplayLink()
  }

  func updateSpeed(_ newSpeed: Double) {
    speed = newSpeed
  }

  func updateSettings(fontSize: CGFloat?, mirrored: Bool?) {
    if let fs = fontSize { self.fontSize = fs }
    if let m = mirrored { self.isMirrored = m }
  }

  func seekTo(scrollOffset: Double) {
    guard !lines.isEmpty else { return }
    let totalLines = lines.count
    let estimatedLine = Int((scrollOffset / 1000) * Double(totalLines))
    lineIndex = min(max(estimatedLine, 0), totalLines - 1)
    lineProgress = 0
  }

  // MARK: - Pixel buffer pool

  private func createPixelBufferPool() {
    let attributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: canvasWidth,
      kCVPixelBufferHeightKey as String: canvasHeight,
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCIImageCompatibilityKey as String: true,
    ]
    CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pixelBufferPool)
  }

  // MARK: - Display link

  private func startDisplayLink() {
    stopDisplayLink()
    frameCount = 0
    displayLink = CADisplayLink(target: self, selector: #selector(renderFrame))
    displayLink?.preferredFramesPerSecond = 30
    displayLink?.add(to: .current, forMode: .common)
  }

  private func stopDisplayLink() {
    displayLink?.invalidate()
    displayLink = nil
  }

  // MARK: - Frame rendering

  @objc private func renderFrame() {
    advanceLineIfNeeded()
    guard let buffer = nextPixelBuffer() else { return }
    drawText(on: buffer)
    enqueue(buffer)
    frameCount += 1
  }

  private func advanceLineIfNeeded() {
    guard !lines.isEmpty else { return }
    // Each "speed" unit = 1 line per second
    // At 30 fps, each frame advances by speed/30 lines
    let advance = speed / 30.0
    lineProgress += advance

    while lineProgress >= 1.0 {
      lineProgress -= 1.0
      lineIndex += 1
      if lineIndex >= lines.count {
        lineIndex = 0  // loop back to beginning
      }
    }
  }

  // MARK: - Pixel buffer helpers

  private func nextPixelBuffer() -> CVPixelBuffer? {
    guard let pool = pixelBufferPool else {
      createPixelBufferPool()
      guard let pool = pixelBufferPool else { return nil }
      var buffer: CVPixelBuffer?
      CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
      return buffer
    }
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
    if status != kCVReturnSuccess {
      createPixelBufferPool()
      guard let pool2 = pixelBufferPool else { return nil }
      CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool2, &buffer)
    }
    return buffer
  }

  private func drawText(on pixelBuffer: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

    guard let context = CGContext(
      data: base,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bpr,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
    ) else { return }

    // Black background
    context.setFillColor(UIColor.black.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    context.saveGState()
    if isMirrored {
      context.translateBy(x: CGFloat(width), y: 0)
      context.scaleBy(x: -1, y: 1)
    }

    // Current line text
    let displayText: String
    if lines.isEmpty {
      displayText = "—"
    } else {
      displayText = lines[min(lineIndex, lines.count - 1)]
    }

    // Use a large font for readability in the small PiP window
    let font = UIFont.systemFont(ofSize: fontSize)
    let attrString = NSAttributedString(
      string: displayText,
      attributes: [
        .font: font,
        .foregroundColor: UIColor.white,
      ]
    )
    let line = CTLineCreateWithAttributedString(attrString)
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

    // Break into words if too wide, by drawing smaller
    var effectiveFontSize = fontSize
    if bounds.width > CGFloat(width) - 32 {
      // Scale down to fit
      let scale = (CGFloat(width) - 32) / bounds.width
      effectiveFontSize = fontSize * min(scale, 1.0)
      let scaledAttr = NSAttributedString(
        string: displayText,
        attributes: [
          .font: UIFont.systemFont(ofSize: effectiveFontSize),
          .foregroundColor: UIColor.white,
        ]
      )
      let scaledLine = CTLineCreateWithAttributedString(scaledAttr)
      let scaledBounds = CTLineGetBoundsWithOptions(scaledLine, .useOpticalBounds)
      let drawX = max(16, (CGFloat(width) - scaledBounds.width) / 2)
      let drawY = (CGFloat(height) - scaledBounds.height) / 2 + scaledBounds.origin.y
      context.textPosition = CGPoint(x: drawX, y: drawY)
      CTLineDraw(scaledLine, context)
    } else {
      let drawX = (CGFloat(width) - bounds.width) / 2
      let drawY = (CGFloat(height) - bounds.height) / 2 + bounds.origin.y
      context.textPosition = CGPoint(x: drawX, y: drawY)
      CTLineDraw(line, context)
    }

    context.restoreGState()
  }

  private func enqueue(_ pixelBuffer: CVPixelBuffer) {
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 30),
      presentationTimeStamp: CMTime(value: frameCount, timescale: 30),
      decodeTimeStamp: .invalid
    )

    var formatDescription: CMFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescriptionOut: &formatDescription
    ) == noErr, let formatDesc = formatDescription else { return }

    var sampleBuffer: CMSampleBuffer?
    CMSampleBufferCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      dataReady: true,
      makeDataReadyCallback: nil,
      refcon: nil,
      formatDescription: formatDesc,
      sampleTiming: &timing,
      sampleBufferOut: &sampleBuffer
    )

    guard let buffer = sampleBuffer else { return }
    displayLayer.enqueue(buffer)
  }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

@available(iOS 15.0, *)
extension PipManager: AVPictureInPictureSampleBufferPlaybackDelegate {
  func pictureInPictureController(_: AVPictureInPictureController, setPlaying _: Bool) {}

  func pictureInPictureControllerTimeRangeForPlayback(_: AVPictureInPictureController) -> CMTimeRange {
    CMTimeRange(start: .zero, duration: CMTime(value: Int64(lines.count), timescale: 30))
  }

  func pictureInPictureControllerIsPlaybackPaused(_: AVPictureInPictureController) -> Bool {
    false
  }

  func pictureInPictureController(_: AVPictureInPictureController, didTransitionToRenderSize _: CMVideoDimensions) {}

  func pictureInPictureController(_: AVPictureInPictureController, skipByInterval _: CMTime, completion: @escaping () -> Void) {
    completion()
  }

  func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_: AVPictureInPictureController) -> Bool {
    true
  }
}
