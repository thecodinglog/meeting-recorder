import AppKit
import SwiftUI

@main
struct MeetingRecorderApp: App {
    @StateObject private var recorder = Recorder()
    @StateObject private var menuBarPanel = MenuBarPanelController()

    init() {
        UserDefaults.standard.register(defaults: MeetingWatcher.defaults)
        if !LaunchMode.isCheck { LoginItem.registerOnFirstLaunch() }
        HelpSnapshot.runIfRequested()
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(recorder: recorder, watcher: recorder.watcher)
                .environment(\.dismissMenuBarPanel, menuBarPanel.dismiss)
                .background(MenuBarPanelSizer(controller: menuBarPanel))
        } label: {
            if recorder.isRecording {
                Image(nsImage: StatusIcon.recording(
                    time: recorder.elapsedText,
                    microphone: recorder.recordingMicrophone ? recorder.micLevel : nil,
                    system: recorder.systemLevel))
            } else if recorder.isSaving {
                Image(systemName: "hourglass")
            } else if recorder.isTranscribing {
                Image(systemName: "text.bubble")
            } else {
                Image(nsImage: StatusIcon.idle)
            }
        }
        // 메뉴 방식은 1초마다 다시 그려지며 항목이 사라지므로 패널 창으로 띄운다.
        .menuBarExtraStyle(.window)

        Window("회의 녹음기 도움말", id: "help") {
            HelpView()
        }
        .defaultSize(width: 860, height: 620)
        .defaultLaunchBehavior(.suppressed)

        Window("회의 녹음기 설정", id: "settings") {
            SettingsView(recorder: recorder)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("녹음 목록 · 재생과 편집", id: "recordings") {
            RecordingsView(library: recorder.library, recorder: recorder)
        }
        .defaultSize(width: 940, height: 700)
        .defaultLaunchBehavior(.suppressed)
    }
}

/// 점검용 실행(--selftest, --transcribe, --snapshot)에서는 회의 감지와 로그인 항목 등록을 하지 않는다.
enum LaunchMode {
    static let isCheck = CommandLine.arguments.contains { ["--selftest", "--transcribe", "--snapshot", "--lifecycle-check"].contains($0) }
    static let isSelfTest = CommandLine.arguments.contains("--selftest")
    static let isLifecycleCheck = CommandLine.arguments.contains("--lifecycle-check")
}

// MARK: - 색과 공통 모양

/// 앱 아이콘(파랑→남색, 빨간 점)과 같은 색감을 패널과 제안 창에서 함께 쓴다.
enum Theme {
    static let blue = Color(red: 0.30, green: 0.43, blue: 0.96)
    static let indigo = Color(red: 0.19, green: 0.24, blue: 0.62)
    static let red = Color(red: 1.00, green: 0.23, blue: 0.19)
    static let crimson = Color(red: 0.78, green: 0.12, blue: 0.18)
    static let amber = Color(red: 1.00, green: 0.62, blue: 0.04)
    static let orange = Color(red: 0.93, green: 0.38, blue: 0.12)

    /// 파랑→남색: 녹음 시작, 회의 시작 알림
    static let brand = LinearGradient(colors: [blue, indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// 빨강: 녹음 정지
    static let record = LinearGradient(colors: [red, crimson], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// 노을: 회의 종료 알림
    static let sunset = LinearGradient(colors: [amber, orange], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// 소리 막대
    static let meter = LinearGradient(colors: [Color(red: 0.36, green: 0.78, blue: 0.98), blue], startPoint: .leading, endPoint: .trailing)

    static let cardFill = Color.primary.opacity(0.05)
    static let cardStroke = Color.primary.opacity(0.06)
}

/// 둥근 카드 배경
struct CardBackground: ViewModifier {
    var radius: CGFloat = 12
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.cardStroke))
    }
}

extension View {
    func card(radius: CGFloat = 12) -> some View { modifier(CardBackground(radius: radius)) }
}

/// 앱 아이콘 느낌의 작은 배지(그라데이션 위에 말풍선+점)
struct BrandBadge: View {
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Theme.brand)
            Image(nsImage: StatusIcon.idle)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.62, height: size * 0.62)
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: Theme.blue.opacity(0.35), radius: 6, y: 3)
    }
}

/// 둥근 틴트 바탕 위의 심볼
struct IconBadge: View {
    let systemImage: String
    var tint: Color = .secondary
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(tint.opacity(0.13))
            Image(systemName: systemImage)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }
}

/// 그라데이션 큰 버튼(녹음 시작·정지). 호버하면 밝아지고 누르면 살짝 눌린다.
/// 대기 중에는 정적으로 표시하고, 녹음 중엔 `level`(소리 크기)에 맞춰 빛이 번진다.
struct GlowButtonStyle: ButtonStyle {
    let gradient: LinearGradient
    let glow: Color
    var level: Float? = nil

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, gradient: gradient, glow: glow, level: level)
    }

    private struct Face: View {
        let configuration: Configuration
        let gradient: LinearGradient
        let glow: Color
        let level: Float?
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        private var pulse: CGFloat {
            if let level { return CGFloat(min(1, level * 1.4)) }
            return 0
        }

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(gradient))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(hovering ? 0.12 : 0)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                .shadow(color: glow.opacity(enabled ? 0.22 + 0.28 * pulse + (hovering ? 0.1 : 0) : 0),
                        radius: 8 + 8 * pulse + (hovering ? 4 : 0), y: 4)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .opacity(enabled ? 1 : 0.45)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.18), value: pulse)
                .onHover { hovering = $0 }
        }
    }
}

/// 패널이 열릴 때 요소가 아래에서 차례로 떠오른다.
struct Reveal: ViewModifier {
    let on: Bool
    let index: Int

    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .offset(y: on ? 0 : 10)
            .animation(.spring(duration: 0.55, bounce: 0.18).delay(Double(index) * 0.045), value: on)
    }
}

extension View {
    func reveal(_ on: Bool, index: Int) -> some View { modifier(Reveal(on: on, index: index)) }
}

/// 알약 모양 버튼(제안 창)
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    var tint: Color = Theme.blue
    var gradient: LinearGradient = Theme.brand

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, prominent: prominent, tint: tint, gradient: gradient)
    }

    private struct Face: View {
        let configuration: Configuration
        let prominent: Bool
        let tint: Color
        let gradient: LinearGradient
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background {
                    if prominent {
                        Capsule().fill(gradient)
                    } else {
                        Capsule().fill(Color.primary.opacity(hovering ? 0.11 : 0.07))
                    }
                }
                .overlay(Capsule().fill(Color.white.opacity(prominent && hovering ? 0.12 : 0)))
                .shadow(color: prominent ? tint.opacity(hovering ? 0.4 : 0.28) : .clear, radius: 7, y: 3)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// 가로로 늘어놓다가 폭이 모자라면 다음 줄로 넘기는 배치(태그용)
struct FlowLayout: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: width == .infinity ? widest : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - 패널

struct PanelView: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var watcher: MeetingWatcher
    @AppStorage(MeetingWatcher.enabledKey) private var detect = true
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissMenuBarPanel) private var dismissMenuBarPanel
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header.reveal(revealed, index: 0)
            DetectRow(detect: detect, activeApp: watcher.activeApp).reveal(revealed, index: 1)

            // 시작·정지 버튼은 같은 자리에서 서로 녹아들듯 바뀐다.
            ZStack {
                if recorder.isRecording {
                    Button { recorder.stop() } label: {
                        Label("녹음 정지", systemImage: "stop.fill")
                    }
                    .buttonStyle(GlowButtonStyle(gradient: Theme.record, glow: Theme.red, level: recorder.systemLevel))
                    .keyboardShortcut("s")
                    .transition(.opacity)
                } else {
                    Button { recorder.start() } label: {
                        Label("녹음 시작", systemImage: "record.circle")
                    }
                    .buttonStyle(GlowButtonStyle(gradient: Theme.brand, glow: Theme.blue))
                    .disabled(recorder.isSaving || recorder.isStarting || recorder.isEditing)
                    .keyboardShortcut("r")
                    .transition(.opacity)
                }
            }
            .reveal(revealed, index: 2)

            if recorder.isRecording {
                LevelCard(system: recorder.systemLevel, microphone: recorder.recordingMicrophone ? recorder.micLevel : nil)
                    .reveal(revealed, index: 3)
            }

            if !recorder.isRecording {
                RecordingPlayerCard(library: recorder.library,
                                    unavailable: recorder.isStarting || recorder.isSaving,
                                    editingUnavailable: recorder.isTranscribing,
                                    compact: true)
            }

            if recorder.isTranscribing {
                NoteCard(tint: Theme.blue, progress: true,
                         text: recorder.transcribingCount > 1
                             ? "회의록 작성 중… \(recorder.transcribingCount - 1)개가 차례를 기다립니다."
                             : "회의록 작성 중… 녹음 길이의 1/5 정도 걸립니다.")
                    .reveal(revealed, index: 4)
            }

            if let message = recorder.message {
                NoteCard(tint: messageTint, systemImage: messageSymbol, text: message) {
                    if recorder.needsPermission {
                        Button("권한 설정 열기") {
                            dismissMenuBarPanel()
                            recorder.openPrivacySettings()
                        }
                            .buttonStyle(PillButtonStyle(prominent: true, tint: Theme.amber, gradient: Theme.sunset))
                    }
                }
                .reveal(revealed, index: 4)
            }

            menu.reveal(revealed, index: 5)
        }
        .padding(16)
        .frame(width: 300)
        // 실제 콘텐츠 높이를 측정한다. 바깥 NSWindow 크기는 MenuBarPanelSizer가 함께 맞춘다.
        .fixedSize(horizontal: false, vertical: true)
        // 창 높이를 바꾸는 카드 삽입·제거는 즉시 반영한다. 중간 높이를 창이 유지하지 않게 한다.
        // 버튼·미터·등장 효과처럼 크기를 바꾸지 않는 애니메이션은 각 하위 뷰에서 처리한다.
        .onAppear { revealed = true }
        .onDisappear { revealed = false }
    }

    private var header: some View {
        HStack(spacing: 10) {
            BrandBadge()
            VStack(alignment: .leading, spacing: 1) {
                Text("회의 녹음기").font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.4), value: subtitle)
            }
            Spacer(minLength: 8)
            StatusChip(recorder: recorder)
        }
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 1) {
            // 녹음·회의록 작성 중에도 메뉴 위치를 유지하고 사용할 수 없는 항목만 비활성화한다.
            if Transcriber.isAvailable {
                let busy = recorder.isTranscribing || recorder.isRecording || recorder.isStarting || recorder.isEditing
                if let folder = recorder.lastFolderWithoutTranscript {
                    PanelButton(title: "최근 녹음으로 회의록 만들기", systemImage: "text.badge.plus", tint: Theme.blue) {
                        recorder.transcribe(folder)
                    }
                    .disabled(busy)
                }
                PanelButton(title: "파일·폴더 골라서 회의록 만들기…", systemImage: "doc.badge.plus") {
                    dismissMenuBarPanel()
                    recorder.chooseAndTranscribe()
                }
                .disabled(busy)
                .help(busy ? "녹음과 회의록 작성이 끝나면 쓸 수 있어요" : "")
            }
            if recorder.lastTranscript != nil {
                PanelButton(title: "최근 회의록 열기", systemImage: "doc.plaintext") {
                    dismissMenuBarPanel()
                    recorder.openLastTranscript()
                }
            }
            if let last = recorder.lastRecording {
                PanelButton(title: "최근 녹음 Finder에서 보기", systemImage: "doc.text.magnifyingglass") {
                    dismissMenuBarPanel()
                    NSWorkspace.shared.activateFileViewerSelecting([last])
                }
            }
            PanelButton(title: "녹음 목록 · 재생과 편집", systemImage: "waveform") {
                openAppWindow("recordings")
            }
            PanelButton(title: "저장 폴더 열기", systemImage: "folder") {
                dismissMenuBarPanel()
                recorder.openFolder()
            }

            ThinDivider()

            PanelButton(title: "설정", systemImage: "gearshape") {
                openAppWindow("settings")
            }
            PanelButton(title: "도움말", systemImage: "questionmark") {
                openAppWindow("help")
            }
            PanelButton(title: "종료", systemImage: "power") { recorder.quit() }
        }
    }

    private func openAppWindow(_ id: String) {
        dismissMenuBarPanel()
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var subtitle: String {
        if recorder.isStarting { return "녹음을 준비하고 있어요" }
        if recorder.isRecording { return "회의를 담고 있어요" }
        if recorder.isSaving { return "녹음을 저장하고 있어요" }
        if recorder.isTranscribing { return "회의록을 쓰고 있어요" }
        if let app = watcher.activeApp { return "\(app) 회의 중이에요" }
        if detect, !MeetingWatcher.enabledAppNames.isEmpty { return "회의가 시작되면 알려 드릴게요" }
        return "녹음 시작을 누르면 바로 시작해요"
    }

    private var messageTint: Color {
        if recorder.needsPermission { return Theme.amber }
        if let m = recorder.message, m.contains("실패") || m.contains("중단") { return Theme.red }
        return Theme.blue
    }

    private var messageSymbol: String {
        if recorder.needsPermission { return "lock.shield.fill" }
        if let m = recorder.message, m.contains("실패") || m.contains("중단") { return "exclamationmark.triangle.fill" }
        return "info.circle.fill"
    }
}

/// 오른쪽 위 상태 칩. 녹음 중이면 빨간 점이 숨 쉬듯 깜빡인다.
struct StatusChip: View {
    @ObservedObject var recorder: Recorder
    @State private var breathing = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(recorder.isRecording ? Theme.red : Color.secondary.opacity(0.45))
                .frame(width: 6, height: 6)
                .scaleEffect(recorder.isRecording && breathing ? 0.7 : 1)
                .opacity(recorder.isRecording && breathing ? 0.4 : 1)
                .animation(recorder.isRecording ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: breathing)
            Text(text)
                .font(.caption.weight(.medium).monospacedDigit())
                .contentTransition(.numericText(countsDown: false))
                .animation(.snappy(duration: 0.3), value: text)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(recorder.isRecording ? Theme.red.opacity(0.12) : Color.primary.opacity(0.06)))
        .foregroundStyle(recorder.isRecording ? Theme.red : Color.secondary)
        .animation(.easeInOut(duration: 0.35), value: recorder.isRecording)
        .onAppear { breathing = true }
    }

    private var text: String {
        if recorder.isRecording { return recorder.elapsedText }
        if recorder.isSaving { return "저장 중" }
        return "대기"
    }
}

/// 회의 감지 상태를 태그로 보여 준다. 회의 중인 앱은 파랗게 채운다.
struct DetectRow: View {
    let detect: Bool
    let activeApp: String?

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: detect ? "dot.radiowaves.left.and.right" : "moon.zzz.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(activeApp != nil ? Theme.blue : Color.secondary)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: activeApp != nil)
                .frame(width: 16, height: 18)
            FlowLayout(spacing: 5) {
                if !detect {
                    Tag(text: "회의 감지 꺼짐")
                } else if MeetingWatcher.enabledAppNames.isEmpty {
                    Tag(text: "감지할 앱 없음")
                } else {
                    ForEach(MeetingWatcher.enabledAppNames, id: \.self) { name in
                        Tag(text: name, active: name == activeApp)
                    }
                }
            }
        }
        .animation(.spring(duration: 0.5, bounce: 0.3), value: activeApp)
    }

    private struct Tag: View {
        let text: String
        var active = false

        var body: some View {
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(active ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color.primary.opacity(0.06))))
                .foregroundStyle(active ? Color.white : Color.secondary)
                .shadow(color: active ? Theme.blue.opacity(0.35) : .clear, radius: 5, y: 2)
                .scaleEffect(active ? 1.05 : 1)
        }
    }
}

/// 녹음 중 소리 막대 카드
struct LevelCard: View {
    let system: Float
    let microphone: Float?

    var body: some View {
        VStack(spacing: 10) {
            LevelRow(title: "회의 소리", systemImage: "speaker.wave.2.fill", level: system)
            // 마이크를 안 쓸 때도 입력 상태를 같은 자리에서 보여 준다.
            LevelRow(title: "내 마이크", systemImage: microphone == nil ? "mic.slash.fill" : "mic.fill",
                     level: microphone ?? 0, muted: microphone == nil)
        }
        .padding(12)
        .card()
    }
}

/// 소리 크기 막대 한 줄
struct LevelRow: View {
    let title: String
    let systemImage: String
    let level: Float
    var muted = false
    @State private var shown: CGFloat = 0   // 그려지는 값: 빨리 오르고 천천히 내려온다
    @State private var peak: CGFloat = 0    // 꼭대기 점: 잠시 머물다 떨어진다

    var body: some View {
        HStack(spacing: 10) {
            IconBadge(systemImage: systemImage, tint: shown > 0.03 ? Theme.blue : .secondary)
                .animation(.easeInOut(duration: 0.3), value: shown > 0.03)
            Text(title)
                .font(.callout)
                .frame(width: 58, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(shown > 0.9 ? AnyShapeStyle(Theme.sunset) : AnyShapeStyle(Theme.meter))
                        .frame(width: max(6, geo.size.width * shown))
                        .shadow(color: Theme.blue.opacity(0.45 * shown), radius: 4, y: 1)
                    Circle()
                        .fill(peak > 0.9 ? Theme.orange : Theme.blue)
                        .frame(width: 6, height: 6)
                        .offset(x: max(0, geo.size.width * peak - 6))
                        .opacity(peak > 0.03 ? 0.9 : 0)
                }
            }
            .frame(height: 6)
        }
        .opacity(muted ? 0.4 : 1)
        .onChange(of: level, initial: true) { _, new in
            let value = CGFloat(new)
            withAnimation(value > shown ? .easeOut(duration: 0.08) : .easeOut(duration: 0.5)) { shown = value }
            withAnimation(value >= peak ? .easeOut(duration: 0.08) : .easeIn(duration: 1.1)) { peak = value }
        }
    }
}

/// 안내·오류 카드
struct NoteCard<Action: View>: View {
    let tint: Color
    var systemImage: String? = nil
    var progress = false
    let text: String
    @ViewBuilder var action: Action

    init(tint: Color, systemImage: String? = nil, progress: Bool = false, text: String,
         @ViewBuilder action: () -> Action = { EmptyView() }) {
        self.tint = tint
        self.systemImage = systemImage
        self.progress = progress
        self.text = text
        self.action = action()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            if progress {
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating)
                    .frame(width: 16, height: 16)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 16, height: 16)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                action
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.15)))
    }
}

/// 메뉴 묶음 사이의 가는 선
struct ThinDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.cardStroke)
            .frame(height: 1)
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
    }
}

/// 메뉴 항목처럼 보이는 버튼
struct PanelButton: View {
    let title: String
    let systemImage: String
    var tint: Color = .secondary
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconBadge(systemImage: systemImage, tint: hovering && enabled ? Theme.blue : tint)
                    .scaleEffect(hovering && enabled ? 1.08 : 1)
                Text(title).font(.callout)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hovering && enabled ? Color.primary.opacity(0.07) : Color.clear))
        .opacity(enabled ? 1 : 0.4)
        .animation(.spring(duration: 0.35, bounce: 0.3), value: hovering)
        .onHover { hovering = $0 }
    }
}
