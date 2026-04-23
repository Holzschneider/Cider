import Foundation
import SwiftUI
import Combine

// Observable model that drives the progress overlay sitting on top of the
// splash image. Phases 5–7 publish into this from the launch pipeline:
// download progress, "preparing prefix…", "loading game…" etc.
@MainActor
public final class ProgressModel: ObservableObject {
    @Published public var visible: Bool = false
    @Published public var title: String = ""
    @Published public var detail: String = ""
    // nil → indeterminate spinner; 0…1 → determinate bar.
    @Published public var fraction: Double? = nil

    public init() {}

    public func show(title: String, detail: String = "", fraction: Double? = nil) {
        self.title = title
        self.detail = detail
        self.fraction = fraction
        self.visible = true
    }

    public func update(detail: String? = nil, fraction: Double? = nil) {
        if let detail { self.detail = detail }
        self.fraction = fraction
    }

    public func hide() {
        self.visible = false
    }
}

// SwiftUI overlay rendered into an NSHostingView and stacked on top of the
// splash image. Stays visually subdued (regular material) so the splash
// image still reads through.
public struct ProgressOverlayView: View {
    @ObservedObject public var model: ProgressModel

    public init(model: ProgressModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            if model.visible {
                VStack(spacing: 10) {
                    if !model.title.isEmpty {
                        Text(model.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                    }
                    if let f = model.fraction {
                        ProgressView(value: f)
                            .progressViewStyle(.linear)
                    } else {
                        ProgressView()
                            .progressViewStyle(.circular)
                    }
                    if !model.detail.isEmpty {
                        Text(model.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 18, y: 4)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 28)
        .animation(.easeOut(duration: 0.18), value: model.visible)
        .animation(.linear(duration: 0.15), value: model.fraction)
    }
}
