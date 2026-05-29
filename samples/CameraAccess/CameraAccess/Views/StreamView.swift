/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamView.swift
//
// Main UI for video streaming from Meta wearable devices using the DAT SDK.
// This view demonstrates the complete streaming API: video streaming with real-time display, photo capture,
// and error handling.
//

import MWDATCore
import SwiftUI
import UIKit
import Vision

struct StreamView: View {
  @Bindable var viewModel: StreamSessionViewModel
  @State private var isCopying = false
  @State private var copied = false
  @State private var copiedText = "Clipboard\nTap Copy to extract visible text."
  @State private var statusMessage: String?

  var body: some View {
    ZStack {
      // Black background for letterboxing/pillarboxing
      Color.black
        .edgesIgnoringSafeArea(.all)

      // Video backdrop
      if let videoFrame = viewModel.currentVideoFrame, viewModel.hasReceivedFirstFrame {
        GeometryReader { geometry in
          Image(uiImage: videoFrame)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .edgesIgnoringSafeArea(.all)
      } else {
        ProgressView()
          .scaleEffect(1.5)
          .foregroundStyle(.white)
      }

      // Bottom controls layer

      VStack {
        HStack {
          Spacer()
          Button(showOverlay ? "Hide Overlay" : "Show Overlay") {
            showOverlay.toggle()
          }
          .buttonStyle(.borderedProminent)
        }
        .padding(.top, 20)

        if showOverlay {
          HStack {
                .font(.headline)
                .foregroundStyle(.white)

                Button {
                  Task { await copyVisibleTextToClipboard() }
                } label: {
                  Label(
                    isCopying ? "Copying..." : (copied ? "Copied" : "Copy"),
                    systemImage: isCopying ? "hourglass" : (copied ? "checkmark" : "doc.on.doc")
                  )
                .foregroundStyle(.white.opacity(0.95))

                .disabled(isCopying)
              Text("Registration: \(registrationStatusText)")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.95))
              Spacer()

              VStack(alignment: .leading, spacing: 8) {
                Text("Clipboard")
                  .font(.headline)
                  .foregroundStyle(.white)

                Text(copiedText)
                  .font(.footnote)
                  .foregroundStyle(.white)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .lineLimit(6)

                if let statusMessage {
                  Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
              }
              .padding(12)
              .background(.black.opacity(0.45))
              .clipShape(RoundedRectangle(cornerRadius: 12))

              Spacer()

              HStack(spacing: 8) {
                CustomButton(
                  title: "Stop streaming",
                  style: .destructive,
                  isDisabled: false
                ) {
                  Task {
                    await viewModel.stopSession()
                  }
                }

                CircleButton(icon: "camera.fill", text: nil) {
                  viewModel.capturePhoto()
                }
                .accessibilityIdentifier("capture_photo_button")
        }
          onDismiss: {
            viewModel.dismissPhotoPreview()
          }
        )
      }
    }
  }

  private func copyVisibleTextToClipboard() async {
    guard let image = viewModel.currentVideoFrame else {
      statusMessage = "No video frame yet."
      return
    }

    isCopying = true
    copied = false
    statusMessage = nil

    do {
      let text = try await recognizeText(in: image)
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        statusMessage = "No readable text found in view."
        isCopying = false
        return
      }

      UIPasteboard.general.string = trimmed
      copiedText = trimmed
      copied = true
      statusMessage = "Copied \(trimmed.count) characters to iPhone clipboard."
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        copied = false
      }
    } catch {
      statusMessage = "Text recognition failed. Try holding still and retry."
    }

    isCopying = false
  }

  private func recognizeText(in image: UIImage) async throws -> String {
    let cgImage = try cgImageForOCR(from: image)

    return try await withCheckedThrowingContinuation { continuation in
      let request = VNRecognizeTextRequest { request, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }

        let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        continuation.resume(returning: lines.joined(separator: "\n"))
      }

      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true

      do {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }

  private func cgImageForOCR(from image: UIImage) throws -> CGImage {
    if let cgImage = image.cgImage {
      return cgImage
    }

    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    let rendered = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: image.size))
    }

    if let cgImage = rendered.cgImage {
      return cgImage
    }

    throw NSError(domain: "StreamView.OCR", code: -1, userInfo: nil)
  }
}
