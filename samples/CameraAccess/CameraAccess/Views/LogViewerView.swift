/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// LogViewerView.swift
//
// In-app diagnostic log viewer. Shows all SDK, session, stream, and error events
// collected by AppLogger. Available from the debug menu (ladybug icon).
// Use "Copy All" to paste logs into Slack/email for remote debugging.
//

import SwiftUI

struct LogViewerView: View {
  @ObservedObject private var logger = AppLogger.shared
  @State private var copied = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationView {
      VStack(spacing: 0) {
        if logger.entries.isEmpty {
          Spacer()
          Text("No log entries yet.\nStart streaming to generate diagnostics.")
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding()
          Spacer()
        } else {
          ScrollViewReader { proxy in
            ScrollView {
              LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(logger.entries) { entry in
                  Text(entry.formatted)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(color(for: entry.level))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .id(entry.id)
                }
              }
              .padding(.vertical, 8)
            }
            .onChange(of: logger.entries.count) { _, _ in
              if let last = logger.entries.last {
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
              }
            }
          }
        }

        HStack(spacing: 12) {
          Button {
            UIPasteboard.general.string = logger.allText
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
          } label: {
            Label(copied ? "Copied!" : "Copy All", systemImage: copied ? "checkmark" : "doc.on.doc")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)

          Button(role: .destructive) {
            logger.clear()
          } label: {
            Label("Clear", systemImage: "trash")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)
        }
        .padding()
      }
      .navigationTitle("Diagnostic Logs")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }

  private func color(for level: LogEntry.Level) -> Color {
    switch level {
    case .error:   return .red
    case .warning: return .orange
    case .info:    return .primary
    case .debug:   return .secondary
    }
  }
}
