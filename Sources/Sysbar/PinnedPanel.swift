// "Pin": the same CPU/GPU/Memory/Disk panels in a small floating window
// docked to the left or right edge of the screen, kept on top and visible on
// every Space. Its header has buttons to switch sides and to unpin.

import AppKit
import SwiftUI

enum PinSide: String, CaseIterable {
    case left, right

    var title: String {
        switch self {
        case .left: return tr("Left edge", "Lateral esquerda")
        case .right: return tr("Right edge", "Lateral direita")
        }
    }
}

struct PinnedStatsView: View {
    let snapshot: SystemStatsSnapshot
    let refreshInterval: TimeInterval
    let side: PinSide
    let appearance: AppAppearance
    let onToggleSide: () -> Void
    let onUnpin: () -> Void
    let onActivityMonitor: () -> Void
    let onCycleAppearance: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Sysbar")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onActivityMonitor) {
                    Image(systemName: "waveform.path.ecg")
                }
                .help(tr("Open Activity Monitor", "Abrir Monitor de Atividade"))
                Button(action: onCycleAppearance) {
                    Image(systemName: appearance.symbol)
                }
                .help(tr("Appearance: ", "Aparência: ") + appearance.title)
                Button(action: onToggleSide) {
                    Image(systemName: side == .left ? "arrow.right.to.line" : "arrow.left.to.line")
                }
                .help(side == .left ? tr("Move to right edge", "Mover para a direita")
                                    : tr("Move to left edge", "Mover para a esquerda"))
                Button(action: onUnpin) {
                    Image(systemName: "pin.slash")
                }
                .help(tr("Unpin", "Desafixar"))
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 2)

            SystemStatsPanelStack(kinds: SystemStatKind.allCases, snapshot: snapshot,
                                  refreshInterval: refreshInterval)
                .padding(.bottom, 6)
        }
    }
}

@MainActor
final class PinnedPanelController {
    private var panel: NSPanel?
    private var host: FirstMouseHostingView<PinnedStatsView>?
    private var screenObserver: NSObjectProtocol?
    var onToggleSide: () -> Void = {}
    var onUnpin: () -> Void = {}
    var onActivityMonitor: () -> Void = {}
    var onCycleAppearance: () -> Void = {}

    var isShown: Bool { panel != nil }

    func show(snapshot: SystemStatsSnapshot, interval: TimeInterval, side: PinSide) {
        let view = makeView(snapshot, interval, side)
        if let host {
            host.rootView = view
        } else {
            let host = FirstMouseHostingView(rootView: view)
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 12
            effect.layer?.masksToBounds = true
            effect.addSubview(host)

            let panel = NSPanel(contentRect: .zero,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isMovable = false
            panel.contentView = effect
            self.panel = panel
            self.host = host

            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reposition() }
            }
        }
        panel?.appearance = Settings.appearance.nsAppearance
        reposition()
        panel?.orderFrontRegardless()
    }

    /// Cheap per-tick refresh while pinned.
    func update(snapshot: SystemStatsSnapshot, interval: TimeInterval, side: PinSide) {
        guard let host else { return }
        host.rootView = makeView(snapshot, interval, side)
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        host = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    private func makeView(_ s: SystemStatsSnapshot, _ i: TimeInterval, _ side: PinSide) -> PinnedStatsView {
        PinnedStatsView(snapshot: s, refreshInterval: i, side: side,
                        appearance: Settings.appearance,
                        onToggleSide: { [weak self] in self?.onToggleSide() },
                        onUnpin: { [weak self] in self?.onUnpin() },
                        onActivityMonitor: { [weak self] in self?.onActivityMonitor() },
                        onCycleAppearance: { [weak self] in self?.onCycleAppearance() })
    }

    /// Docks the panel to the chosen edge of the main screen, 8 pt inset,
    /// vertically centered in the visible area (below the menu bar).
    private func reposition() {
        guard let panel, let host, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let side = Settings.pinSide ?? .right
        let size = host.fittingSize
        let visible = screen.visibleFrame
        let height = min(size.height, visible.height - 16)
        let x = side == .left ? visible.minX + 8 : visible.maxX - size.width - 8
        let y = visible.midY - height / 2
        let frame = NSRect(x: x, y: y, width: size.width, height: height)
        panel.setFrame(frame, display: true)
        host.frame = NSRect(origin: .zero, size: frame.size)
    }
}

/// The pinned panel never becomes key (it must not steal focus), so its
/// buttons need to act on the first click.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
