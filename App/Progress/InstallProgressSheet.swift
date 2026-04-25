import Foundation
import SwiftUI
import CiderCore

// State driving the install progress sheet. Two display surfaces:
//   - a vertical phase checklist (the new schema-v3 UX)
//   - a single-line status header at the top for legacy
//     `.stage`/`.fraction` events (and detail messages emitted from
//     within an active phase)
@MainActor
final class InstallProgressModel: ObservableObject {

    enum PhaseState: Equatable {
        case pending
        case running(fraction: Double?, detail: String)
        case done
        case failed(message: String)
    }

    struct Phase: Identifiable, Equatable {
        let id: String
        let label: String
        let kind: PhaseDescriptor.Kind
        var state: PhaseState
    }

    // Phase list (empty for legacy callers that never emit
    // .phasesDeclared).
    @Published var phases: [Phase] = []

    // Header / ad-hoc status.
    @Published var stage: String = ""
    @Published var detail: String = ""
    @Published var fraction: Double? = nil

    @Published var isCancelling: Bool = false
    var onCancel: (() -> Void)?

    func apply(_ event: InstallProgress) {
        switch event {
        case .stage(let s, let d):
            stage = s
            detail = d
            fraction = nil
        case .fraction(let f):
            fraction = f

        case .phasesDeclared(let descriptors):
            phases = descriptors.map { d in
                Phase(id: d.id, label: d.label, kind: d.kind,
                      state: d.alreadyDone ? .done : .pending)
            }

        case .phaseStarted(let id):
            updatePhase(id: id) { $0.state = .running(fraction: nil, detail: "") }

        case .phaseProgress(let id, let f, let d):
            updatePhase(id: id) { $0.state = .running(fraction: f, detail: d) }

        case .phaseDone(let id):
            updatePhase(id: id) { $0.state = .done }

        case .phaseFailed(let id, let message):
            updatePhase(id: id) { $0.state = .failed(message: message) }
        }
    }

    private func updatePhase(id: String, _ mutate: (inout Phase) -> Void) {
        guard let idx = phases.firstIndex(where: { $0.id == id }) else { return }
        var phase = phases[idx]
        mutate(&phase)
        phases[idx] = phase
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
        VStack(alignment: .leading, spacing: 14) {
            header

            if !model.phases.isEmpty {
                Divider()
                phaseChecklist
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
        .frame(width: 460)
    }

    // MARK: - Header (stage label, detail, optional bar from
    //          legacy .stage/.fraction events)

    @ViewBuilder
    private var header: some View {
        let activeLabel = activePhaseLabel
        let label = model.isCancelling
            ? "Cancelling…"
            : (activeLabel ?? (model.stage.isEmpty ? "Working…" : model.stage))
        HStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.7)
                .opacity(model.isCancelling ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                if !headerDetail.isEmpty {
                    Text(headerDetail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var activePhaseLabel: String? {
        model.phases.first(where: {
            if case .running = $0.state { return true } else { return false }
        })?.label
    }

    private var headerDetail: String {
        // Prefer the active phase's detail / explicit .stage detail.
        if let phase = model.phases.first(where: {
            if case .running = $0.state { return true } else { return false }
        }), case .running(_, let d) = phase.state, !d.isEmpty {
            return d
        }
        return model.detail
    }

    // MARK: - Phase checklist

    private var phaseChecklist: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.phases) { phase in
                phaseRow(phase)
            }
        }
    }

    @ViewBuilder
    private func phaseRow(_ phase: InstallProgressModel.Phase) -> some View {
        HStack(alignment: .center, spacing: 10) {
            phaseGlyph(for: phase.state)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(phase.label)
                    .font(.system(size: 13))
                    .foregroundStyle(textColor(for: phase.state))
                determinateBar(for: phase)
                if let secondary = secondaryText(for: phase.state), !secondary.isEmpty {
                    Text(secondary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    @ViewBuilder
    private func phaseGlyph(for state: InstallProgressModel.PhaseState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .running:
            ProgressView()
                .scaleEffect(0.5)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func determinateBar(for phase: InstallProgressModel.Phase) -> some View {
        if case .running(let f, _) = phase.state, let f, phase.kind == .determinate {
            ProgressView(value: max(0, min(1, f)))
                .progressViewStyle(.linear)
                .frame(maxWidth: .infinity)
        }
    }

    private func secondaryText(for state: InstallProgressModel.PhaseState) -> String? {
        switch state {
        case .running(_, let d):  return d.isEmpty ? nil : d
        case .failed(let m):      return m
        default:                  return nil
        }
    }

    private func textColor(for state: InstallProgressModel.PhaseState) -> Color {
        switch state {
        case .pending: return .secondary
        case .failed:  return .red
        default:       return .primary
        }
    }
}
