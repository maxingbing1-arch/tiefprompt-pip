import AVKit
import UIKit

/// Renders teleprompter text into a PiP floating window with smooth
/// continuous pixel-based scrolling.
@available(iOS 15.0, *)
final class PipManager: NSObject {
  // ── PiP primitives ────────────────────────────────────────────
  private var pipController: AVPictureInPictureController!
  private let displayLayer = AVSampleBufferDisplayLayer()

  // ── Render loop ───────────────────────────────────────────────
  private var displayLink: CADisplayLink?
  private var pixelBufferPool: CVPixelBufferPool?
  private var frameCount: Int64 = 0

  // ── Scrolling state (continuous pixels, not lines) ────────────
  private var displayText: NSAttributedString?
  private var totalTextHeight: CGFloat = 0
  /// Current scroll offset in points from the top of the text.
  private var scrollOffset: CGFloat = 0
  /// Scroll speed in points per second.
  private var speed: CGFloat = 60
  private var isPlaying = false

  // ── Settings (set from Flutter) ────────────────────────────────
  var fontSize: CGFloat = 56
  var isMirrored = false

  // MARK: - Canvas dimensions

  /// The PiP canvas matches the display layer's natural size.
  /// On iPad this gives ~720×540 which is legible even in a small PiP window.
  private let canvasWidth = 720
  private var canvasHeight: Int { 540 }

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
    // speed value from app (0.1-20) → points per second
    self.speed = max(1, CGFloat(speed * 80))
    self.fontSize = fontSize
    self.isMirrored = isMirrored
    self.scrollOffset = 0
    self.isPlaying = true

    buildDisplayText(text)
    createPixelBufferPool()
    startDisplayLink()
    pipController.startPictureInPicture()
  }

  func stop() {
    isPlaying = false
    pipController.stopPictureInPicture()
    stopDisplayLink()
  }

  func updateSpeed(_ newSpeed: Double) {
    speed = max(1, CGFloat(newSpeed * 80))
  }

  func updateSettings(fontSize: CGFloat?, mirrored: Bool?) {
    var needsRebuild = false
    if let fs = fontSize {
      self.fontSize = fs
      needsRebuild = true
    }
    if let m = mirrored { self.isMirrored = m }
    // Rebuild text layout when font size changes
    if needsRebuild, let text = displayText {
      buildDisplayText(text.string)
    }
  }

  func seekTo(scrollOffset: Double) {
    self.scrollOffset = max(0, CGFloat(scrollOffset))
  }

  // MARK: - Text layout

  private func buildDisplayText(_ text: String) {
    let paraStyle = NSMutableParagraphStyle()
    paraStyle.alignment = .center
    paraStyle.lineSpacing = fontSize * 0.12
    paraStyle.paragraphSpacing = fontSize * 0.3

    let attrText = NSAttributedString(
      string: text,
      attributes: [
        .font: UIFont.systemFont(ofSize: fontSize),
        .foregroundColor: UIColor.white,
        .paragraphStyle: paraStyle,
      ]
    )
    displayText = attrText

    // Estimate total rendered height
    let framesetter = CTFramesetterCreateWithAttributedString(attrText)
    let constraints = CGSize(width: CGFloat(canvasWidth) - 32, height: .greatestFiniteMagnitude)
    let bounds = CTFramesetterSuggestFrameSizeWithConstraints(
      framesetter, CFRange(), nil, constraints, nil
    )
    totalTextHeight = ceil(max(bounds.height, 1))
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
    advanceScroll()
    guard let buffer = nextPixelBuffer() else { return }
    drawText(on: buffer)
    enqueue(buffer)
    frameCount += 1
  }

  private func advanceScroll() {
    guard isPlaying, let _ = displayText, totalTextHeight > 0 else { return }
    guard scrollOffset < totalTextHeight else {
      // Reached the end — stop scrolling
      isPlaying = false
      return
    }
    scrollOffset += speed / 30.0
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
    CVPixelBufferLockBaseAddress(pixelBuffer, .readWrite)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readWrite) }

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

    guard let text = displayText, text.length > 0 else { return }

    context.saveGState()

    // Horizontal mirror
    if isMirrored {
      context.translateBy(x: CGFloat(width), y: 0)
      context.scaleBy(x: -1, y: 1)
    }

    // Flip vertically so Core Text lays out top-to-bottom
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1.0, y: -1.0)

    // Clip to visible canvas area
    context.clip(to: CGRect(x: 0, y: 0, width: width, height: height))

    // The text frame starts above the visible area by scrollOffset pixels.
    // As scrollOffset increases, the text slides upward (it enters
    // the visible area from the bottom and exits at the top).
    let textRect = CGRect(
      x: 16,
      y: -scrollOffset,
      width: CGFloat(width) - 32,
      height: max(totalTextHeight + scrollOffset + CGFloat(height), 200)
    )

    let path = CGPath(rect: textRect, transform: nil)
    let framesetter = CTFramesetterCreateWithAttributedString(text)
    let frame = CTFramesetterCreateFrame(
      framesetter, CFRange(location: 0, length: text.length), path, nil
    )
    CTFrameDraw(frame, context)

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
    CMTimeRange(start: .zero, duration: CMTime(value: 600, timescale: 30))
  }

  func pictureInPictureControllerIsPlaybackPaused(_: AVPictureInPictureController) -> Bool {
    !isPlaying
  }

  func pictureInPictureController(_: AVPictureInPictureController, didTransitionToRenderSize _: CMVideoDimensions) {}

  func pictureInPictureController(_: AVPictureInPictureController, skipByInterval _: CMTime, completion: @escaping () -> Void) {
    completion()
  }

  func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_: AVPictureInPictureController) -> Bool {
    true
  }
}
