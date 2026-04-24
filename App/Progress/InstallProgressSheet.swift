import Foundation
import SwiftUI
import CiderCore

// State driving the install progress sheet. Mirrors the existing
// ProgressModel pattern (used by the splash overlay) but adds a
// dedicated `cancel` callback so the Cancel button can route through
// the controller back into the running Task.
@MainActor
final class InstallProgressModel: ObservableObject {
    @Published var stage: String = ""
    @Published var detail: String = ""
    // nil → indeterminate spinner; 0...1 → determinate bar.
    @Published var fraction: Double? = nil
    @Published var isCancelling: Bool = false

    var onCancel: (() -> Void)?

    func apply(_ event: InstallProgress) {
        switch event {
        case .stage(let s, let d):
            stage = s
            detail = d
            // A new stage starts in indeterminate mode until the next
            // .fraction event lands (downloads emit fractions; cp/unzip
            // don't).
            fraction = nil
        case .fraction(let f):
            fraction = f
        }
    }

    func requestCancel() {
        guard !isCancelling else { return }
        isCancelling = true
        onCancel?()
    }
}

struct InstallProgressSheet: View {
    @ObservedObject var model: InstallProgressModel

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(0.7)
                    .opacity(model.isCancelling ? 0.4 : 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayStage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    if !model.detail.isEmpty {
                        Text(model.detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let f = model.fraction {
                ProgressView(value: max(0, min(1, f)))
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            HStack {
                Spacer()
                Button(model.isCancelling ? "Cancelling…" : "Cancel") {
                    model.requestCancel()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isCancelling)
            }
        }
        .padding(22)
        .frame(width: 420)
    }

    private var displayStage: String {
        if model.isCancelling { return "Cancelling…" }
        return model.stage.isEmpty ? "Working…" : model.stage
    }
}
