import AppKit
import SwiftUI

/// 현재 키 창 대신 메뉴바 패널만 닫는다. 다른 창과 도움말 미리보기에는 적용하지 않는다.
@MainActor
final class MenuBarPanelController: ObservableObject {
    weak var window: NSWindow?

    func dismiss() { window?.orderOut(nil) }
}

private struct DismissMenuBarPanelKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var dismissMenuBarPanel: () -> Void {
        get { self[DismissMenuBarPanelKey.self] }
        set { self[DismissMenuBarPanelKey.self] = newValue }
    }
}

/// MenuBarExtra는 내용이 줄어도 이전 창 높이를 유지할 수 있다.
/// fixedSize로 측정한 패널을 배경에서 관찰하고, 메뉴바에 붙은 윗변을 유지하며 창도 맞춘다.
/// 메뉴바 Scene에만 붙이므로 도움말의 미리보기나 다른 창에는 영향을 주지 않는다.
struct MenuBarPanelSizer: NSViewRepresentable {
    var controller: MenuBarPanelController? = nil

    func makeNSView(context: Context) -> SizingView {
        let view = SizingView()
        view.controller = controller
        return view
    }
    func updateNSView(_ view: SizingView, context: Context) { view.scheduleResize() }

    final class SizingView: NSView {
        var controller: MenuBarPanelController?
        private var resizePending = false
        private var windowObserver: NSObjectProtocol?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            controller?.window = window
            if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
            windowObserver = nil
            if let window {
                windowObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didResizeNotification, object: window, queue: .main
                ) { [weak self] _ in self?.scheduleResize() }
            }
            scheduleResize()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            scheduleResize()
        }

        func scheduleResize() {
            guard !resizePending else { return }
            resizePending = true
            // SwiftUI/AppKit이 배치 중일 때 창 크기를 다시 바꾸지 않는다.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.resizePending = false
                self.resizeWindowToContent()
            }
        }

        func resizeWindowToContent() {
            guard let window, bounds.width > 0, bounds.height > 0 else { return }
            let contentSize = NSSize(width: ceil(bounds.width), height: ceil(bounds.height))
            var target = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
            // 작은 화면에서는 OS가 허용하는 높이까지만 요청한다. 재배치와 크기 조정의 반복을 막는다.
            if let screen = window.screen { target.size.height = min(target.height, screen.visibleFrame.height) }
            let current = window.frame
            guard abs(current.width - target.width) > 0.5 || abs(current.height - target.height) > 0.5 else { return }
            target.origin = NSPoint(x: current.minX, y: current.maxY - target.height)
            window.setFrame(target, display: true, animate: false)
        }

        deinit {
            if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        }
    }
}
