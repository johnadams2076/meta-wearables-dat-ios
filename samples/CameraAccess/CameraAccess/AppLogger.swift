/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// AppLogger.swift
//
// Centralised logging for CameraAccess. Every SDK error, state transition, and
// diagnostic event is written here so you can:
//   • See structured logs in Console.app on Mac (subsystem: com.cameraaccess)
//   • Browse the last 200 entries inside the app via the debug log sheet
//   • Copy all logs to clipboard for sharing from TestFlight builds
//

import Foundation
import os
import UIKit

// MARK: - Shake-to-show-logs
// Works in all build configurations including TestFlight (Release) builds.
// Shake the device to open the in-app log viewer.

extension Notification.Name {
  static let deviceDidShake = Notification.Name("com.cameraaccess.deviceDidShake")
}

extension UIWindow {
  open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
    super.motionEnded(motion, with: event)
    guard motion == .motionShake else { return }
    NotificationCenter.default.post(name: .deviceDidShake, object: nil)
  }
}

// MARK: - Log entry

struct LogEntry: Identifiable {
  let id: UUID = UUID()
  let timestamp: Date
  let category: String
  let level: Level
  let message: String

  enum Level: String {
    case info = "ℹ️"
    case warning = "⚠️"
    case error = "❌"
    case debug = "🔍"
  }

  var formatted: String {
    let ts = DateFormatter.logFormatter.string(from: timestamp)
    return "[\(ts)] [\(category)] \(level.rawValue) \(message)"
  }
}

private extension DateFormatter {
  static let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
  }()
}

// MARK: - AppLogger

@MainActor
final class AppLogger: ObservableObject {
  static let shared = AppLogger()

  @Published private(set) var entries: [LogEntry] = []

  private let maxEntries = 200
  private let osLog = Logger(subsystem: "com.cameraaccess", category: "DAT")

  private init() {}

  func log(_ message: String, category: String = "General", level: LogEntry.Level = .info) {
    let entry = LogEntry(timestamp: Date(), category: category, level: level, message: message)
    entries.append(entry)
    if entries.count > maxEntries {
      entries.removeFirst(entries.count - maxEntries)
    }
    switch level {
    case .info:
      osLog.info("[\(category)] \(message)")
    case .warning:
      osLog.warning("[\(category)] \(message)")
    case .error:
      osLog.error("[\(category)] \(message)")
    case .debug:
      osLog.debug("[\(category)] \(message)")
    }
  }

  func logError(_ error: Error, context: AppErrorContext) {
    let message = AppErrorFormatter.message(for: error, context: context)
    log(message, category: "\(context)", level: .error)
  }

  func clear() {
    entries.removeAll()
  }

  var allText: String {
    entries.map(\.formatted).joined(separator: "\n")
  }
}
