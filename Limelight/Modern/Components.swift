//
//  Components.swift
//  Moonlight Duo
//
//  Small shared views and the fold helpers.
//

import SwiftUI
import UIKit

// MARK: - Fold (reserved region) helpers

extension GeometryProxy {
    /// The active hinge running down this view (book pose), as an x range in local
    /// coordinates, margins included. Nil when the display is flat or closed.
    @MainActor func verticalFoldBand() -> ClosedRange<CGFloat>? {
        if #available(iOS 27.1, *) {
            for region in reservedRegions(kind: .division) where region.isActive {
                let f = region.frame
                if f.height >= f.width, f.minX > 0, f.maxX < size.width {
                    return f.minX...f.maxX
                }
            }
        }
        return nil
    }
}

// MARK: - Busy HUD

struct BusyHUD: View {
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text(message)
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 320)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Pairing

struct PairingView: View {
    let hostName: String
    let pin: String
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "lock.open.laptopcomputer")
                    .font(.system(size: 52, weight: .regular))
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("Pair with \(hostName)")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text("Enter this PIN on your PC. With Sunshine or Lumen, open the web UI and choose PIN.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Text(pin)
                    .font(.system(size: 60, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .tracking(10)
                    .textSelection(.enabled)
                    .accessibilityLabel("PIN \(pin.map(String.init).joined(separator: " "))")

                HStack(spacing: 10) {
                    ProgressView()
                    Text("Waiting for your PC…")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(28)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel, action: onCancel)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()
    }
}

// MARK: - Host status

struct StatusDot: View {
    let status: HostStatus
    let paired: Bool

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(.background, lineWidth: 2))
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch status {
        case .online: return paired ? .green : .orange
        case .offline: return .gray
        case .connecting: return .yellow
        }
    }
}

// MARK: - Window size for the settings screen

@MainActor
enum DisplayInfo {
    static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
    }

    static var nativeStreamSize: CGSize {
        MLDuoBridge.nativeStreamSize(for: keyWindow)
    }

    static var safeAreaStreamSize: CGSize {
        MLDuoBridge.safeAreaStreamSize(for: keyWindow)
    }

    static var maximumFramesPerSecond: Int {
        MLDuoBridge.maximumFramesPerSecond(for: keyWindow)
    }
}

// MARK: - UIKit fold probe

/// Reports the active vertical hinge across this view through UIKit
/// (MLDuoBridge: reserved regions, or the DEBUG -MLSimulateFold hinge).
struct FoldProbe: UIViewRepresentable {
    @Binding var band: ClosedRange<CGFloat>?

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        let binding = $band
        view.onChange = { new in
            DispatchQueue.main.async { if binding.wrappedValue != new { binding.wrappedValue = new } }
        }
        view.setNeedsLayout()
    }

    final class ProbeView: UIView {
        var onChange: ((ClosedRange<CGFloat>?) -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            setNeedsLayout()
        }

        private func report() {
            let rects = MLDuoBridge.activeDivisionRects(in: self).map(\.cgRectValue)
            let hinge = rects.first { $0.height >= $0.width && $0.minX > 0 && $0.maxX < bounds.width }
            onChange?(hinge.map { $0.minX...$0.maxX })
        }
    }
}
