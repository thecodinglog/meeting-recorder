import AppKit
import SwiftUI
import Testing
@testable import MeetingRecorder

@Suite(.serialized)
@MainActor
struct MenuBarPanelSizerTests {
    @Test func contentChangesResizeTheWindowWithoutMovingItsTopEdge() async {
        _ = NSApplication.shared
        let model = PanelModel()
        let host = NSHostingView(rootView: TestPanel(model: model))
        // MenuBarExtra가 이전 크기를 유지하는 상황을 재현한다.
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        let top = window.frame.maxY

        for height: CGFloat in [400, 240, 500, 240, 400] {
            model.height = height
            await settle(host)
            #expect(abs(window.contentView!.bounds.height - height) < 1)
            #expect(abs(window.frame.maxY - top) < 1)
            #expect(abs(window.frame.width - 300) < 1)
        }

        // 내용은 그대로인데 다시 열 때 호스트가 예전 창 크기를 복원한 경우도 보정한다.
        window.setContentSize(NSSize(width: 300, height: 600))
        let restoredTop = window.frame.maxY
        await settle(host)
        #expect(abs(window.contentView!.bounds.height - model.height) < 1)
        #expect(abs(window.frame.maxY - restoredTop) < 1)
    }

    @Test func detachedSizerDoesNotResizeItsFormerWindow() async {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 500))
        window.contentView = container
        let sizer = MenuBarPanelSizer.SizingView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        container.addSubview(sizer)
        sizer.removeFromSuperview()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(window.frame.height == 500)
    }

    private func settle(_ host: NSView) async {
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
    }
}

@MainActor
private final class PanelModel: ObservableObject {
    @Published var height: CGFloat = 400
}

private struct TestPanel: View {
    @ObservedObject var model: PanelModel
    var body: some View {
        Color.clear
            .frame(width: 300, height: model.height)
            .fixedSize()
            .background(MenuBarPanelSizer())
    }
}
