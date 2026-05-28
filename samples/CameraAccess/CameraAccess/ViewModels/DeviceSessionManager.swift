/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import MWDATCore
import Observation
import SwiftUI

enum AppErrorContext {
  case registrationCallback
  case registrationStart
  case unregistration
  case permission
  case deviceSession
  case stream
  case firmwareUpdate
  case datAppUpdate
}

enum AppErrorFormatter {
  static func message(for error: Error, context: AppErrorContext) -> String {
    let rawMessage = (error as NSError).localizedDescription
    let normalized = rawMessage.lowercased()

    if normalized.contains("invalid operation") {
      return "The app tried an action at the wrong time for the current glasses session. Disconnect and reconnect the glasses, then try again. Details: \(rawMessage)"
    }

    if normalized.contains("internal") {
      return "The SDK reported an internal operation error. This is usually temporary and often caused by a stale session or interrupted callback. Restart the app and reconnect the glasses. Details: \(rawMessage)"
    }

    if normalized.contains("upload") || normalized.contains("download") || normalized.contains("network") || normalized.contains("timed out") || normalized.contains("timeout") {
      return "Network transfer issue detected while talking to Meta services. Check phone internet, disable VPN if enabled, and retry. Details: \(rawMessage)"
    }

    if normalized.contains("waitingfordevice") || normalized.contains("not connected") || normalized.contains("bluetooth") || normalized.contains("connection") {
      return "Glasses connection problem detected. Confirm Bluetooth is on, glasses are powered and in range, then reconnect. Details: \(rawMessage)"
    }

    switch context {
    case .registrationCallback:
      return "Registration callback from Meta AI could not be processed. Make sure AppLinkURLScheme matches the app URL scheme exactly. Details: \(rawMessage)"
    case .registrationStart:
      return "Could not start registration with Meta AI. Ensure Meta AI is installed, internet is available, and the app credentials are correct. Details: \(rawMessage)"
    case .unregistration:
      return "Could not disconnect this app from Meta AI. Try again after confirming the phone and glasses are still connected. Details: \(rawMessage)"
    case .permission:
      return "Camera permission flow failed. Open Meta AI and grant camera access for this app, then retry streaming. Details: \(rawMessage)"
    case .deviceSession:
      return "Could not start a device session with the glasses. This usually means no active compatible device or session startup was interrupted. Details: \(rawMessage)"
    case .stream:
      return "Camera stream failed or was interrupted. Check glasses connection and try starting the stream again. Details: \(rawMessage)"
    case .firmwareUpdate:
      return "Could not open the firmware update flow. Open Meta AI manually and check device firmware status. Details: \(rawMessage)"
    case .datAppUpdate:
      return "Could not open the update flow for the app on glasses. Open Meta AI manually and update the glasses app. Details: \(rawMessage)"
    }
  }
}

/// Manages DeviceSession lifecycle with 1:1 device-to-session mapping.
/// Monitors device availability and creates sessions on demand via `getSession()`.
@Observable
@MainActor
final class DeviceSessionManager {
  private(set) var isReady: Bool = false
  private(set) var hasActiveDevice: Bool = false

  private let wearables: WearablesInterface
  private let deviceSelector: AutoDeviceSelector
  private var deviceSession: DeviceSession?
  @ObservationIgnored private var deviceMonitorTask: Task<Void, Never>?
  @ObservationIgnored private var stateObserverTask: Task<Void, Never>?

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.deviceSelector = AutoDeviceSelector(wearables: wearables)
    startDeviceMonitoring()
  }

  /// Stops the device session and cancels monitoring. Call before releasing.
  /// The stateObserverTask handles cleanup when .stopped arrives.
  func cleanup() {
    deviceMonitorTask?.cancel()
    deviceMonitorTask = nil
    deviceSession?.stop()
  }

  /// Returns a ready DeviceSession, creating one if needed.
  /// Waits for the session to reach .started state before returning.
  func getSession() async throws(DeviceSessionError) -> DeviceSession {
    if let session = deviceSession, session.state == .started {
      isReady = true
      return session
    }

    if deviceSession?.state == .stopped {
      deviceSession = nil
    }

    // Wait for an in-progress session to finish starting
    if let session = deviceSession {
      // The session may have already transitioned to .started before the
      // for-await loop begins iterating (stateStream doesn't buffer past events).
      if session.state == .started {
        isReady = true
        startStateObserver(for: session)
        return session
      }

      try await waitForSessionStart(
        stateStream: session.stateStream(),
        errorStream: session.errorStream()
      )
      isReady = true
      startStateObserver(for: session)
      return session
    }

    // Create a new session
    do {
      let session = try wearables.createSession(deviceSelector: deviceSelector)
      deviceSession = session

      let stateStream = session.stateStream()
      let errorStream = session.errorStream()
      try session.start()

      // The session may have already transitioned to .started before the
      // for-await loop begins iterating (the state change is delivered on
      // another thread and the stream does not buffer past events).
      if session.state == .started {
        isReady = true
        startStateObserver(for: session)
        return session
      }

      try await waitForSessionStart(stateStream: stateStream, errorStream: errorStream)
      isReady = true
      startStateObserver(for: session)
      return session
    } catch {
      isReady = false
      deviceSession = nil
      throw error
    }
  }

  // MARK: - Private

  private func waitForSessionStart(
    stateStream: AsyncStream<DeviceSessionState>,
    errorStream: AsyncStream<DeviceSessionError>
  ) async throws(DeviceSessionError) {
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          for await state in stateStream {
            if state == .started {
              return
            }
            if state == .stopped {
              throw DeviceSessionError.unexpectedError(description: "Session moved to stopped before it reached started")
            }
          }
          guard !Task.isCancelled else {
            return
          }
          throw DeviceSessionError.unexpectedError(description: "Session state stream ended before started")
        }

        group.addTask {
          for await error in errorStream {
            throw error
          }
          guard !Task.isCancelled else {
            return
          }
          throw DeviceSessionError.unexpectedError(description: "Session error stream ended before started")
        }

        guard try await group.next() != nil else {
          throw DeviceSessionError.unexpectedError(description: "Session start task group completed unexpectedly")
        }
        group.cancelAll()
      }
    } catch let error as DeviceSessionError {
      throw error
    } catch {
      throw .unexpectedError(description: error.localizedDescription)
    }
  }

  /// Monitors device availability only — does NOT create sessions.
  /// Session creation is deferred to `getSession()` to avoid races.
  private func startDeviceMonitoring() {
    deviceMonitorTask = Task { [weak self] in
      guard let self else { return }
      for await device in deviceSelector.activeDeviceStream() {
        hasActiveDevice = device != nil
      }
    }
  }

  private func startStateObserver(for session: DeviceSession) {
    stateObserverTask?.cancel()
    stateObserverTask = Task { [weak self] in
      for await state in session.stateStream() {
        guard let self else { return }
        if state == .started {
          isReady = true
        } else if state == .stopped {
          isReady = false
          deviceSession = nil
          stateObserverTask = nil
          return
        }
      }
    }
  }
}
