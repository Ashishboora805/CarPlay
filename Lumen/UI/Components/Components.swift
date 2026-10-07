import LumenKit
import SwiftUI

struct SectionHeader: View {
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.medium))
            }
        }
        .padding(.horizontal, Theme.horizontalPadding)
    }
}

/// Full-area state for errors and empty content, with an optional action.
struct StateMessageView: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: 420)
        .accessibilityElement(children: .combine)
    }
}

extension StateMessageView {
    init(error: AppError, retry: (() -> Void)?) {
        self.init(systemImage: error == .offline ? "wifi.slash" : "exclamationmark.triangle",
                  title: error.title, message: error.message,
                  actionTitle: retry != nil && error.isRetryable ? "Retry" : nil, action: retry)
    }
}

/// "LIVE" label: conveys state with text, not color alone.
struct LiveBadge: View {
    var body: some View {
        Text("LIVE")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.live, in: Capsule())
            .foregroundStyle(.white)
            .accessibilityLabel("Live")
    }
}

/// Non-blocking error banner shown at the top of a screen.
struct ErrorBanner: View {
    let error: AppError
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: error == .offline ? "wifi.slash" : "exclamationmark.circle")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(error.title).font(.subheadline.weight(.semibold))
                Text(error.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.caption.weight(.bold))
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .cardStyle()
        .padding(.horizontal, Theme.horizontalPadding)
        .accessibilityElement(children: .contain)
    }
}

/// Program title + time range + progress.
struct NowNextView: View {
    let current: EPGProgram?
    let next: EPGProgram?
    var now: Date = .now

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let current {
                Text(current.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(timeRange(current))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    ProgressView(value: current.progress(at: now))
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 80)
                        .accessibilityLabel("\(Int(current.progress(at: now) * 100)) percent complete")
                }
            } else {
                Text("No guide information")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let next {
                Text("Next \(next.start.formatted(date: .omitted, time: .shortened))  \(next.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func timeRange(_ program: EPGProgram) -> String {
        "\(program.start.formatted(date: .omitted, time: .shortened)) – \(program.end.formatted(date: .omitted, time: .shortened))"
    }
}

extension Int64 {
    var formattedByteCount: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
