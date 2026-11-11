// Window plumbing: borderless floating panels hosting SwiftUI, AppKit
// tracking areas for hover (they work even when Sysbar isn't the active
// app), the menu-bar popover / screen-edge panel, and the detail panels that
// open beside them on hover and stay open when pinned.

import AppKit
import Combine
import SwiftUI

enum PinSide: String, CaseIterable {
    case left, right
}

/// Borderless panel that can take clicks/keys without activating Sysbar
/// for every interaction.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Hosting view whose buttons react on the first click even when the
/// window isn't key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Window content view: vibrant background + SwiftUI + hover tracking
/// (whole view and/or per-section rectangles).
final class TrackingContainer: NSView {
    override var isFlipped: Bool { true }
    var trackWholeView = false
    var onEnter: (SystemStatKind?) -> Void = { _ in }
    var onExit: (SystemStatKind?) -> Void = { _ in }
    var sectionFrames: [SystemStatKind: CGRect] = [:] {
        didSet { if sectionFrames != oldValue { updateTrackingAreas() } }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        if trackWholeView {
            addTrackingArea(NSTrackingArea(rect: bounds,
                                           options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }
        for (kind, frame) in sectionFrames {
            let rect = frame.intersection(bounds)
            guard !rect.isEmpty else { continue }
            addTrackingArea(NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .activeAlways],
                                           owner: self, userInfo: ["kind": kind.rawValue]))
        }
    }

    override func mouseEntered(with event: NSEvent) { onEnter(kind(of: event)) }
    override func mouseExited(with event: NSEvent) { onExit(kind(of: event)) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func kind(of event: NSEvent) -> SystemStatKind? {
        (event.trackingArea?.userInfo?["kind"] as? String).flatMap(SystemStatKind.init(rawValue:))
    }
}

/// One floating panel hosting a SwiftUI view.
@MainActor
final class HostedPanel {
    let window: KeyPanel
    let container = TrackingContainer()
    private let host: NSView

    init<V: View>(_ view: V) {
        let host = FirstMouseHostingView(rootView: view)
        self.host = host
        window = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                          styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        window.isFloatingPanel = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        host.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.addSubview(effect)
        effect.addSubview(host)
        window.contentView = container
        applyAppearance()
    }

    var isVisible: Bool { window.isVisible }
    var fittingSize: NSSize { host.fittingSize }

    func applyAppearance() { window.appearance = Settings.appearance.nsAppearance }

    func setFrame(_ frame: NSRect) {
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true)
        container.subviews.first?.frame = container.bounds
        host.frame = container.bounds
    }

    func show() { window.orderFrontRegardless() }
    func close() { window.orderOut(nil) }
}

// MARK: - Main panel (menu bar popover or screen edge)

@MainActor
final class MainPanelController {
    enum Placement { case popover, edge }

    let placement: Placement
    let panel: HostedPanel
    private let context = PanelContext()
    private weak var details: DetailManager?
    private var statusButton: () -> NSStatusBarButton?

    init(model: AppModel, details: DetailManager, placement: Placement,
         statusButton: @escaping () -> NSStatusBarButton?) {
        self.placement = placement
        self.details = details
        self.statusButton = statusButton
        panel = HostedPanel(MainPanelView(model: model, context: context))
        context.onSectionFrames = { [weak self] frames in self?.panel.container.sectionFrames = frames }
        context.onTapSection = { [weak self] kind in
            guard let self else { return }
            details.togglePin(kind, from: self)
        }
        panel.container.onEnter = { [weak self] kind in
            guard let self, let kind else { return }
            details.hoverBegan(kind, from: self)
        }
        panel.container.onExit = { kind in
            guard kind != nil else { return }
            details.hoverEnded()
        }
    }

    var isVisible: Bool { panel.isVisible }

    /// Screen-space top edge of a section (for aligning its detail panel).
    func sectionTop(_ kind: SystemStatKind) -> CGFloat {
        let frame = panel.window.frame
        guard let rect = panel.container.sectionFrames[kind] else { return frame.maxY }
        return frame.maxY - max(0, rect.minY)
    }

    var screen: NSScreen {
        panel.window.screen ?? statusButton()?.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func show() {
        layout()
        panel.show()
        if placement == .popover {
            panel.window.makeKey()
        }
    }

    func close() { panel.close() }

    /// Size to content and position (under the status item, or docked to
    /// the chosen screen edge).
    func layout() {
        let size = panel.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let visible = screen.visibleFrame
        var frame = NSRect(origin: .zero, size: size)
        switch placement {
        case .popover:
            if let buttonFrame = statusButton()?.window?.frame {
                frame.origin.x = buttonFrame.midX - size.width / 2
                frame.origin.y = buttonFrame.minY - 6 - size.height
            } else {
                frame.origin = NSPoint(x: visible.maxX - size.width - 10, y: visible.maxY - size.height - 6)
            }
            frame.origin.x = min(max(frame.origin.x, visible.minX + 6), visible.maxX - size.width - 6)
        case .edge:
            let side = Settings.pinSide ?? .right
            frame.origin.x = side == .left ? visible.minX + 8 : visible.maxX - size.width - 8
            frame.origin.y = visible.midY - size.height / 2
        }
        frame.origin.y = max(frame.origin.y, visible.minY + 6)
        panel.setFrame(frame.integral)
    }
}

// MARK: - Detail panels

@MainActor
final class DetailManager {
    private let model: AppModel
    private var windows: [SystemStatKind: HostedPanel] = [:]
    private var hoverKind: SystemStatKind?
    private var insideDetail: SystemStatKind?
    private var hideWork: DispatchWorkItem?
    private weak var anchor: MainPanelController?

    init(model: AppModel) {
        self.model = model
        model.toggleDetailPin = { [weak self] kind in self?.togglePin(kind, from: nil) }
        model.closeDetail = { [weak self] kind in self?.close(kind) }
    }

    var anyVisible: Bool { !windows.isEmpty }

    private func isPinned(_ kind: SystemStatKind) -> Bool { model.pinnedDetails.contains(kind) }

    func hoverBegan(_ kind: SystemStatKind, from host: MainPanelController) {
        anchor = host
        hideWork?.cancel()
        if let current = hoverKind, current != kind, !isPinned(current) {
            close(current)
        }
        hoverKind = kind
        show(kind)
    }

    func hoverEnded() { scheduleHide() }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hideHoverIfIdle() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func hideHoverIfIdle() {
        guard let kind = hoverKind, insideDetail != kind else { return }
        hoverKind = nil
        if !isPinned(kind) { close(kind) }
    }

    func togglePin(_ kind: SystemStatKind, from host: MainPanelController?) {
        if let host { anchor = host }
        if isPinned(kind) {
            model.pinnedDetails.removeAll { $0 == kind }
            if hoverKind != kind { close(kind) }
        } else {
            model.pinnedDetails.append(kind)
            show(kind)
        }
    }

    func close(_ kind: SystemStatKind) {
        windows[kind]?.close()
        windows[kind] = nil
        model.pinnedDetails.removeAll { $0 == kind }
        if hoverKind == kind { hoverKind = nil }
        if insideDetail == kind { insideDetail = nil }
    }

    /// The main popover closed: drop the hover preview, keep pinned ones.
    func closeUnpinned() {
        for kind in Array(windows.keys) where !isPinned(kind) { close(kind) }
    }

    func applyAppearance() { windows.values.forEach { $0.applyAppearance() } }

    private func show(_ kind: SystemStatKind) {
        if let existing = windows[kind] {
            existing.show()
            return
        }
        let panel = HostedPanel(DetailContainer(model: model, kind: kind))
        panel.container.trackWholeView = true
        panel.container.onEnter = { [weak self] _ in
            self?.insideDetail = kind
            self?.hideWork?.cancel()
        }
        panel.container.onExit = { [weak self] _ in
            if self?.insideDetail == kind { self?.insideDetail = nil }
            self?.scheduleHide()
        }
        windows[kind] = panel
        place(panel, kind: kind)
        panel.show()
    }

    /// Beside the anchor panel, top-aligned with the section; the first
    /// column (moving away from the anchor) where it doesn't overlap another
    /// open detail panel.
    private func place(_ panel: HostedPanel, kind: SystemStatKind) {
        let size = panel.fittingSize
        guard let anchor else {
            panel.setFrame(NSRect(origin: .zero, size: size))
            return
        }
        let anchorFrame = anchor.panel.window.frame
        let visible = anchor.screen.visibleFrame
        let toLeft = anchorFrame.midX > visible.midX
        let top = anchor.sectionTop(kind)
        let y = min(max(top - size.height, visible.minY + 4), visible.maxY - size.height - 4)
        let others = windows.filter { $0.key != kind }.map(\.value.window.frame)
        var chosen: NSRect?
        for column in 0..<8 {
            let x = toLeft
                ? anchorFrame.minX - 8 - size.width - CGFloat(column) * (size.width + 8)
                : anchorFrame.maxX + 8 + CGFloat(column) * (size.width + 8)
            let rect = NSRect(x: x, y: y, width: size.width, height: size.height)
            if rect.minX < visible.minX || rect.maxX > visible.maxX { break }
            if !others.contains(where: { $0.intersects(rect) }) { chosen = rect; break }
        }
        let fallbackX = toLeft ? anchorFrame.minX - 8 - size.width : anchorFrame.maxX + 8
        panel.setFrame((chosen ?? NSRect(x: fallbackX, y: y, width: size.width, height: size.height)).integral)
    }

    /// Re-fit sizes (e.g. after expanding "Per core"), keeping the top edge.
    func fitAll() {
        for panel in windows.values {
            let size = panel.fittingSize
            var frame = panel.window.frame
            guard abs(size.height - frame.height) > 0.5 || abs(size.width - frame.width) > 0.5 else { continue }
            let visible = panel.window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
            let top = frame.maxY
            frame.size = size
            frame.origin.y = max(visible.minY + 4, top - size.height)
            panel.setFrame(frame.integral)
        }
    }
}
