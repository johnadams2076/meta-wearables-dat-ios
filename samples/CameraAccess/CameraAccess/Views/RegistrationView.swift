/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// RegistrationView.swift
//
// Background view that handles callbacks from the Meta AI mobile app during
// DAT SDK registration and permission flows. This invisible view processes deep links
// that complete the OAuth authorization process initiated by the DAT SDK.
//

import MWDATCore
import SwiftUI

struct RegistrationView: View {
  var viewModel: WearablesViewModel

  var body: some View {
    EmptyView()
      .onOpenURL { url in
        Task {
          do {
            AppLogger.shared.log(
              "Handling open URL: \(url.absoluteString)",
              category: "Registration",
              level: .debug
            )
            _ = try await Wearables.shared.handleUrl(url)
            AppLogger.shared.log(
              "Open URL handled successfully",
              category: "Registration",
              level: .info
            )
          } catch let error as RegistrationError {
            AppLogger.shared.logError(error, context: .registrationCallback)
            viewModel.showError(error, context: .registrationCallback)
          } catch {
            AppLogger.shared.logError(error, context: .registrationCallback)
            viewModel.showError(error, context: .registrationCallback)
          }
        }
      }
  }
}
