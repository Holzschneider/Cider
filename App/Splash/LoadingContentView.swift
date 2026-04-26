import Foundation
import SwiftUI

// State for the new translucent loading window. Mirrors the existing
// `ProgressModel` (which stays alive for the legacy splash overlay
// during the prefix-init / engine-download / settle phases) but lives
// independently so the loading window can be wired to the wine
// process's stdout / a tailed log file.
@MainActor
public final class LoadingProgressModel: ObservableObject {
    // Single status line shown under the progress bar — set to the
    // most recent line received from the configured source (terminal
    // stdout/stderr, or a tailed log file).
    @Published public var statusLine: String = ""

    // 0...1 progress; nil → indeterminate (renders as the system's
    // animated linear bar). Stays nil until calibration kicks in.
    @Published public var fraction: Double? = nil

    // Disables the (X) hover button after the user clicks it, so
    // double-clicks don't trigger SIGTERM twice.
    @Published public var isCancelling: Bool = false

    public var onCancel: (() -> Void)?

    public init() {}

    public func ingestLine(_ line: String) {
        statusLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func updateProgress(currentLines: Int, target: Int?) {
        guard let target, target > 0 else {
            fraction = nil
            return
        }
        fraction = min(1.0, Double(currentLines) / Double(target))
    }

    public func requestCancel() {
        guard !isCancelling else { return }
        isCancelling = true
        onCancel?()
    }
}

// Translucent rounded card with a progress bar on top + a single
// status line beneath. Hover the card to reveal the (X) close button
// in the top-right corner.
struct LoadingContentView: View {
    @ObservedObject var model: LoadingProgressModel
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 10) {
                progressBar
                Text(displayedStatus)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if isHovering {
                Button(action: { model.requestCancel() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                }
                .buttonStyle(.plain)
                .help(model.isCancelling ? "Cancelling…" : "Cancel")
                .disabled(model.isCancelling)
                .padding(8)
                .transition(.opacity)
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if let f = model.fraction {
            ProgressView(value: max(0, min(1, f)))
                .progressViewStyle(.linear)
                .tint(.accentColor)
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .tint(.accentColor)
        }
    }

    private var displayedStatus: String {
        if model.isCancelling { return "Cancelling…" }
        if !model.statusLine.isEmpty { return model.statusLine }
        return "Loading…"
    }
}
