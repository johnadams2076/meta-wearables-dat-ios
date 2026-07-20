/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import MWDATCamera
import MWDATCore
import Observation
import Photos
import SwiftUI
import Vision

enum StreamingStatus {
  case streaming
  case waiting
  case stopped
}

/// ViewModel for video streaming UI. Delegates device management to DeviceSessionManager.
@Observable
@MainActor
final class StreamSessionViewModel {
  // MARK: - State

  var currentVideoFrame: UIImage?
  var hasReceivedFirstFrame: Bool = false
  var streamingStatus: StreamingStatus = .stopped
  var showError: Bool = false
  var errorMessage: String = ""
  var requiresDATAppUpdate: Bool = false

  var capturedPhoto: UIImage?
  var showPhotoPreview: Bool = false
  var showPhotoCaptureError: Bool = false
  var isCapturingPhoto: Bool = false

  var hasActiveDevice: Bool { sessionManager.hasActiveDevice }
  var isDeviceSessionReady: Bool { sessionManager.isReady }

  var isStreaming: Bool { streamingStatus != .stopped }

  // MARK: - Private

  private let sessionManager: DeviceSessionManager
  private let wearables: WearablesInterface
  private let isUITestRun: Bool
  private let isTestRun: Bool
  private var stream: MWDATCamera.Stream?
  private var frameSkipCounter: Int = 0

  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?

  // MARK: - Init

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.sessionManager = DeviceSessionManager(wearables: wearables)
    self.isUITestRun = ProcessInfo.processInfo.arguments.contains("--ui-testing")
    self.isTestRun =
      self.isUITestRun || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  }

  // MARK: - Public API

  func handleStartStreaming() async {
    let permission = Permission.camera
    AppLogger.shared.log("Checking camera permission", category: "Stream", level: .debug)
    do {
      var status = try await wearables.checkPermissionStatus(permission)
      if status != .granted {
        AppLogger.shared.log("Requesting camera permission", category: "Stream", level: .info)
        status = try await wearables.requestPermission(permission)
      }
      guard status == .granted else {
        AppLogger.shared.log("Camera permission denied", category: "Stream", level: .error)
        showError("Camera permission was not granted in Meta AI. Grant permission and try again.")
        return
      }
      AppLogger.shared.log("Camera permission granted — starting session", category: "Stream", level: .info)
      await startSession()
    } catch {
      AppLogger.shared.logError(error, context: .permission)
      showError(AppErrorFormatter.message(for: error, context: .permission))
    }
  }

  func stopSession() async {
    guard let activeStream = stream else { return }
    stream = nil
    clearListeners()
    streamingStatus = .stopped
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    await activeStream.stop()
  }

  /// Stops both the stream and the underlying device session. Call in test tearDown.
  func endSession() {
    stream = nil
    clearListeners()
    streamingStatus = .stopped
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    sessionManager.cleanup()
  }

  func capturePhoto() {
    guard !isCapturingPhoto, streamingStatus == .streaming else {
      showPhotoCaptureError = true
      return
    }

    if isUITestRun {
      capturedPhoto = makeUITestPlaceholderImage()
      showPhotoPreview = true
      isCapturingPhoto = false
      return
    }

    isCapturingPhoto = true
    let success = stream?.capturePhoto(format: .jpeg) ?? false
    if !success {
      isCapturingPhoto = false
      showPhotoCaptureError = true
    }
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  func dismissPhotoCaptureError() {
    showPhotoCaptureError = false
  }

  func dismissPhotoPreview() {
    showPhotoPreview = false
    capturedPhoto = nil
  }

  // MARK: - Private

  private func startSession() async {
    let deviceSession: DeviceSession
    AppLogger.shared.log("Requesting device session", category: "Session", level: .debug)
    do {
      deviceSession = try await sessionManager.getSession()
      requiresDATAppUpdate = false
      AppLogger.shared.log("Device session started successfully", category: "Session", level: .info)
    } catch DeviceSessionError.datAppOnTheGlassesUpdateRequired {
      requiresDATAppUpdate = true
      AppLogger.shared.log("DAT glasses app update required", category: "Session", level: .warning)
      showError("The app on glasses must be updated before streaming can start. Open Meta AI and update the glasses app.")
      return
    } catch {
      AppLogger.shared.logError(error, context: .deviceSession)
      showError(AppErrorFormatter.message(for: error, context: .deviceSession))
      return
    }

    guard deviceSession.state == .started else {
      showError("Device session is not ready. Please try again.")
      return
    }

    let config = StreamConfiguration(
      videoCodec: VideoCodec.raw,
      resolution: StreamingResolution.low,
      // Lower FPS in UI tests to reduce simulator/main-thread pressure and avoid
      // starving XCTest accessibility snapshots under CI load.
      frameRate: isUITestRun ? 7 : 24
    )

    guard let newStream = try? deviceSession.addStream(config: config) else { return }
    stream = newStream
    streamingStatus = .waiting
    setupListeners(for: newStream)
    await newStream.start()
  }

  private func setupListeners(for stream: MWDATCamera.Stream) {
    stateListenerToken = stream.statePublisher.listen { [weak self] state in
      Task { @MainActor in self?.handleStateChange(state) }
    }

    if !isUITestRun {
      videoFrameListenerToken = stream.videoFramePublisher.listen { [weak self] frame in
        Task { @MainActor in self?.handleVideoFrame(frame) }
      }
    }

    errorListenerToken = stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor in self?.handleError(error) }
    }

    photoDataListenerToken = stream.photoDataPublisher.listen { [weak self] data in
      Task { @MainActor in self?.handlePhotoData(data) }
    }
  }

  private func clearListeners() {
    stateListenerToken = nil
    videoFrameListenerToken = nil
    errorListenerToken = nil
    photoDataListenerToken = nil
  }

  private func handleStateChange(_ state: StreamState) {
    AppLogger.shared.log("Stream state → \(state)", category: "Stream", level: .debug)
    switch state {
    case .stopped:
      currentVideoFrame = nil
      streamingStatus = .stopped
    case .waitingForDevice:
      AppLogger.shared.log("Waiting for glasses — ensure Bluetooth is on and glasses are in range", category: "Stream", level: .warning)
      streamingStatus = .waiting
    case .starting, .stopping, .paused:
      streamingStatus = .waiting
    case .streaming:
      AppLogger.shared.log("Streaming started", category: "Stream", level: .info)
      streamingStatus = .streaming
      if isUITestRun {
        hasReceivedFirstFrame = true
      }
    }
  }

  private func handleVideoFrame(_ frame: VideoFrame) {
    if isUITestRun, hasReceivedFirstFrame {
      frameSkipCounter = (frameSkipCounter + 1) % 3
      if frameSkipCounter != 0 {
        return
      }
    }

    if let image = autoreleasepool(invoking: { frame.makeUIImage() }) {
      currentVideoFrame = image
      if !hasReceivedFirstFrame {
        hasReceivedFirstFrame = true
      }
    }
  }

  private func handleError(_ error: StreamError) {
    let message = AppErrorFormatter.message(for: error, context: .stream)
    AppLogger.shared.logError(error, context: .stream)
    if message != errorMessage {
      showError(message)
    }
  }

  private func handlePhotoData(_ data: PhotoData) {
    isCapturingPhoto = false
    guard let image = UIImage(data: data.data) else { return }

    if isTestRun {
      capturedPhoto = image
      showPhotoPreview = true
      return
    }

    Task {
      let result = await PaintingPhotoProcessor.processCapturedPhoto(image)
      capturedPhoto = result.image
      showPhotoPreview = true

      if let saveError = result.saveError {
        AppLogger.shared.log(
          "Captured photo could not be auto-saved: \(saveError.localizedDescription)",
          category: "Photo",
          level: .error
        )
        showError("The photo was captured but could not be saved automatically. \(saveError.localizedDescription)")
      } else {
        AppLogger.shared.log(
          "Captured photo auto-saved successfully",
          category: "Photo",
          level: .info
        )
      }
    }
  }

  private func makeUITestPlaceholderImage() -> UIImage {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
    return renderer.image { context in
      UIColor.systemBlue.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    }
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }
}

enum PaintingPhotoProcessor {
  struct ProcessedPhoto {
    let image: UIImage
    let saveError: Error?
  }

  enum SaveError: LocalizedError {
    case permissionDenied
    case encodingFailed
    case saveFailed

    var errorDescription: String? {
      switch self {
      case .permissionDenied:
        return "Photo Library access was denied."
      case .encodingFailed:
        return "The captured image could not be prepared for saving."
      case .saveFailed:
        return "The cropped painting could not be written to the Photo Library."
      }
    }
  }

  static func processCapturedPhoto(_ image: UIImage) async -> ProcessedPhoto {
    let processedImage = detectPainting(in: image).flatMap { cropImage(image, to: $0) } ?? image

    do {
      try await saveToPhotoLibrary(processedImage)
      return ProcessedPhoto(image: processedImage, saveError: nil)
    } catch {
      return ProcessedPhoto(image: processedImage, saveError: error)
    }
  }

  static func detectPainting(in image: UIImage) -> CGRect? {
    guard let cgImage = cgImage(from: image) else { return nil }

    let request = VNDetectRectanglesRequest()
    request.maximumObservations = 1
    request.minimumConfidence = 0.75
    request.minimumAspectRatio = 0.5
    request.minimumSize = 0.2
    request.quadratureTolerance = 20

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

    do {
      try handler.perform([request])
      return request.results?.first?.boundingBox
    } catch {
      return nil
    }
  }

  static func cropRect(for normalizedRect: CGRect, imageSize: CGSize) -> CGRect {
    let imageRect = CGRect(origin: .zero, size: imageSize)
    let cropRect = CGRect(
      x: normalizedRect.origin.x * imageSize.width,
      y: (1 - normalizedRect.origin.y - normalizedRect.height) * imageSize.height,
      width: normalizedRect.width * imageSize.width,
      height: normalizedRect.height * imageSize.height
    )

    return cropRect.integral.intersection(imageRect)
  }

  static func cropImage(_ image: UIImage, to normalizedRect: CGRect) -> UIImage? {
    guard let cgImage = cgImage(from: image) else { return nil }

    let pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
    let cropRect = cropRect(for: normalizedRect, imageSize: pixelSize)
    guard !cropRect.isNull, !cropRect.isEmpty else { return nil }
    guard let croppedCGImage = cgImage.cropping(to: cropRect) else { return nil }

    return UIImage(cgImage: croppedCGImage, scale: image.scale, orientation: image.imageOrientation)
  }

  private static func cgImage(from image: UIImage) -> CGImage? {
    if let cgImage = image.cgImage {
      return cgImage
    }

    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    let renderedImage = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: image.size))
    }

    return renderedImage.cgImage
  }

  private static func saveToPhotoLibrary(_ image: UIImage) async throws {
    let authorizationStatus = await requestPhotoLibraryAuthorization()
    guard authorizationStatus == .authorized || authorizationStatus == .limited else {
      throw SaveError.permissionDenied
    }

    guard let imageData = image.jpegData(compressionQuality: 0.95) else {
      throw SaveError.encodingFailed
    }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      PHPhotoLibrary.shared().performChanges({
        let request = PHAssetCreationRequest.forAsset()
        request.addResource(with: .photo, data: imageData, options: nil)
      }) { success, error in
        if let error {
          continuation.resume(throwing: error)
        } else if success {
          continuation.resume(returning: ())
        } else {
          continuation.resume(throwing: SaveError.saveFailed)
        }
      }
    }
  }

  private static func requestPhotoLibraryAuthorization() async -> PHAuthorizationStatus {
    await withCheckedContinuation { continuation in
      PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
        continuation.resume(returning: status)
      }
    }
  }
}
