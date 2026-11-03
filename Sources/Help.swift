import AppKit
import AVFoundation
import SwiftUI

/// 도움말 창: 왼쪽 목차, 오른쪽 내용
/// 점검용: --snapshot <폴더> 로 실행하면 도움말 섹션마다 화면을 PNG로 저장하고 종료한다.
enum HelpSnapshot {
    @MainActor
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), args.count > i + 1 else { return }
        let folder = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            var pages: [(String, AnyView, CGSize)] = ([HelpContent.statusID] + HelpContent.sections.map(\.id)).map {
                ($0, AnyView(HelpView(selection: $0)), CGSize(width: 860, height: 1500))
            }
            pages.append(("prompt-start", AnyView(MeetingPromptView(
                kind: .start,
                title: "Microsoft Teams 회의가 시작된 것 같습니다",
                message: "녹음할까요? 녹음하기 전에 참석자 동의를 받으세요.",
                primary: "녹음 시작", secondary: "이번엔 안 함", deadline: nil,
                onPrimary: {}, onSecondary: {}).padding(20)), CGSize(width: 420, height: 190)))
            pages.append(("prompt-end", AnyView(MeetingPromptView(
                kind: .end,
                title: "Microsoft Teams 회의가 끝난 것 같습니다", message: "녹음을 정지할까요?",
                primary: "녹음 정지", secondary: "계속 녹음", deadline: Date().addingTimeInterval(97),
                onPrimary: {}, onSecondary: {}).padding(20)), CGSize(width: 420, height: 220)))

            // 패널: 대기 / 녹음 중
            let demo = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingRecorder-preview-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: demo) }
            let demoFolder = demo.appendingPathComponent("신사업 주간 회의")
            try? FileManager.default.createDirectory(at: demoFolder, withIntermediateDirectories: true)
            do {
                let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000 * 72)!
                buffer.frameLength = buffer.frameCapacity
                for frame in 0..<Int(buffer.frameLength) {
                    let seconds = Float(frame) / 48_000
                    let envelope = max(0, sin(seconds * 1.4)) * (0.12 + 0.08 * sin(seconds * 8))
                    buffer.floatChannelData![0][frame] = envelope * sin(seconds * 2 * .pi * 220)
                }
                let file = try AVAudioFile(forWriting: demoFolder.appendingPathComponent("전체.m4a"),
                    settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1])
                try file.write(from: buffer)
            } catch { audioLog.error("미리보기 오디오 생성 실패: \(error.localizedDescription, privacy: .public)") }
            try? "회의록 · 신사업 주간 회의\n\n[00:00:05] 나: 다음 주 일정을 확인하겠습니다.\n"
                .write(to: demoFolder.appendingPathComponent(Transcriber.transcriptName), atomically: true, encoding: .utf8)
            let idle = Recorder(baseFolder: demo)
            pages.append(("settings", AnyView(SettingsView(recorder: idle)), CGSize(width: 520, height: 680)))
            await idle.library.refresh()
            idle.library.seek(to: 24.5)
            idle.library.trimStart = 8.5
            idle.library.trimEnd = 65
            pages.append(("panel-idle", AnyView(snapshotPanel(idle)), CGSize(width: 340, height: 760)))
            pages.append(("recordings", AnyView(RecordingsView(library: idle.library, recorder: idle)), CGSize(width: 1020, height: 800)))
            pages.append(("recordings-edit", AnyView(RecordingsView(library: idle.library, recorder: idle, initialEditing: true)), CGSize(width: 1020, height: 800)))
            pages.append(("transcription-progress", AnyView(TranscriptionProgressView(source: "신사업 주간 회의", queuedCount: 1).padding(24)), CGSize(width: 620, height: 190)))
            let recording = Recorder()
            recording.previewRecordingState()
            recording.watcher.previewActiveApp("Microsoft Teams")
            pages.append(("panel-recording", AnyView(snapshotPanel(recording)), CGSize(width: 340, height: 520)))

            for (id, view, size) in pages {
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = host
                window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
                window.orderFront(nil)
                try? await Task.sleep(for: .seconds(1.3))  // 등장 애니메이션이 끝난 뒤 찍는다
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: folder.appendingPathComponent("\(id).png"))
                }
                window.orderOut(nil)
            }
            NSApp.terminate(nil)
        }
    }

    /// 메뉴바 창 배경을 흉내 내어 패널을 찍는다.
    @MainActor
    private static func snapshotPanel(_ recorder: Recorder) -> some View {
        PanelView(recorder: recorder, watcher: recorder.watcher)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
            .padding(20)
    }
}

struct HelpView: View {
    @State private var selection: String?

    init(selection: String = HelpContent.statusID) {
        _selection = State(initialValue: selection)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("구성 요소 상태", systemImage: "checklist").tag(HelpContent.statusID)
                ForEach(HelpContent.sections) { section in
                    Label(section.title, systemImage: section.icon).tag(section.id)
                }
            }
            .navigationSplitViewColumnWidth(210)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if selection == HelpContent.statusID || selection == nil {
                        StatusView()
                    } else if let section = HelpContent.sections.first(where: { $0.id == selection }) {
                        Text(section.title).font(.title2.bold())
                        ForEach(Array(section.blocks.enumerated()), id: \.offset) { _, block in
                            BlockView(block: block)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

enum HelpBlock {
    case heading(String)
    case text(String)
    case bullets([String])
    case command(String, String)  // 설명, 명령어
}

struct HelpSection: Identifiable {
    let id: String
    let title: String
    let icon: String
    let blocks: [HelpBlock]
}

private struct BlockView: View {
    let block: HelpBlock

    var body: some View {
        switch block {
        case .heading(let text):
            Text(text).font(.headline).padding(.top, 6)
        case .text(let text):
            Text(LocalizedStringKey(text)).fixedSize(horizontal: false, vertical: true)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(LocalizedStringKey(item)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .command(let caption, let command):
            VStack(alignment: .leading, spacing: 4) {
                Text(caption).font(.callout).foregroundStyle(.secondary)
                HStack(alignment: .top) {
                    Text(command)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("복사") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
            }
        }
    }
}

/// 회의록·화자 구분에 필요한 파일이 있는지 보여 준다.
private struct StatusView: View {
    private struct Item: Identifiable {
        let id = UUID()
        let name: String
        let path: String
        let role: String
    }

    private let items = [
        Item(name: "whisper-cli", path: Transcriber.whisperPath, role: "회의록(전사) 실행"),
        Item(name: "전사 모델", path: Transcriber.modelPath, role: "회의록(전사)"),
        Item(name: "무음 제거 모델(VAD)", path: Transcriber.vadModelPath, role: "헛말 줄이기, 없으면 생략"),
        Item(name: "가상환경 Python", path: Transcriber.pythonPath, role: "상대방 화자 구분"),
        Item(name: "화자 모델(ECAPA)", path: Transcriber.speakerModelPath, role: "상대방 화자 구분"),
        Item(name: "화자 구분 스크립트", path: Transcriber.diarizeScript, role: "상대방 화자 구분(앱 안에 포함)"),
    ]

    var body: some View {
        Text("구성 요소 상태").font(.title2.bold())
        Text("녹음은 추가 설치 없이 됩니다. 아래는 녹음 뒤 회의록과 화자 구분에 쓰는 파일입니다.")
            .foregroundStyle(.secondary)
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            ForEach(items) { item in
                let ok = !item.path.isEmpty && FileManager.default.fileExists(atPath: item.path)
                GridRow(alignment: .firstTextBaseline) {
                    Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(ok ? Color.green : Color.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).bold()
                        Text(item.role).font(.callout).foregroundStyle(.secondary)
                        Text(item.path.isEmpty ? "(없음)" : HelpContent.short(item.path))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(.top, 4)
        Divider().padding(.vertical, 4)
        BlockView(block: .bullets([
            "**회의록 자동 작성:** \(Transcriber.isAvailable ? "사용 가능" : "사용 불가 — whisper-cli 또는 전사 모델이 없습니다")",
            "**상대방 화자 구분:** \(Transcriber.canSplitSpeakers ? "사용 가능" : "사용 불가 — 상대방은 번호 없이 '상대방'으로 적힙니다")",
            "**회의 감지:** \(UserDefaults.standard.bool(forKey: MeetingWatcher.enabledKey) ? "켜짐 — \(MeetingWatcher.enabledAppNames.joined(separator: ", "))" : "꺼짐")",
            "**로그인할 때 자동 실행:** \(LoginItem.isOn ? "켜짐" : "꺼짐")",
            "**앱 위치:** \(HelpContent.short(Bundle.main.bundlePath))",
        ]))
    }
}

enum HelpContent {
    static let statusID = "status"
    // 설치 위치를 가정하지 않는다. 아래 개발 명령은 소스 저장소 루트에서 실행한다.
    static let project = "."

    static func short(_ path: String) -> String {
        path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    private static var app: String { "\"\(Bundle.main.bundlePath)\"" }

    static let sections: [HelpSection] = [
        HelpSection(id: "usage", title: "기본 사용법", icon: "record.circle", blocks: [
            .text("메뉴바의 마이크 아이콘을 누르면 패널이 열립니다. **녹음 시작**(⌘R)과 **녹음 정지**(⌘S)로 씁니다. 단축키는 패널이 열려 있을 때 동작합니다."),
            .bullets([
                "Teams, 네이버웍스, Zoom과 전화·FaceTime 통화에서 맥으로 들리는 소리와 내 마이크를 녹음합니다.",
                "전화 통화는 패널에서 **녹음 시작**을 누르거나 **설정 → 전화 자동 녹음**의 **전화 통화 감지 시 바로 녹음**을 사용하세요(기본 켜짐). **내 마이크 함께 녹음**을 켜야 내 목소리도 저장됩니다. 통화 소리가 아이폰에서만 나오면 맥으로 옮겨야 합니다.",
                "회의에 봇이 들어가지 않으므로 다른 참석자 화면에는 아무것도 표시되지 않습니다.",
                "**설정 → 녹음**에서 **내 마이크 함께 녹음**(기본 켜짐)을 끄면 회의 앱 소리만 녹음합니다.",
                "**설정 → 녹음**의 **녹음 후 회의록 자동 작성**(기본 꺼짐)을 켜 두면 녹음이 끝난 뒤 회의록.txt를 만듭니다. 켜고 끈 값은 다음 실행에도 유지됩니다.",
                "자동 작성을 꺼 두었을 때는 패널의 **최근 녹음으로 회의록 만들기**나 **파일·폴더 골라서 회의록 만들기**…로 필요할 때 만듭니다.",
                "패널 위쪽 작은 줄에 회의 감지 상태가 보입니다. 예: '회의 감지 중: Microsoft Teams·NAVER WORKS·Zoom', 'Microsoft Teams 회의 중'.",
                "패널의 **설정**에서 녹음 옵션, 전화 자동 녹음, 회의 감지와 로그인할 때 자동 실행을 바꿉니다.",
            ]),
            .heading("메뉴바 표시"),
            .bullets([
                "대기: 마이크 아이콘",
                "녹음 중: 🎙 막대, 🔊 막대, 경과 시간. 🎙 막대는 내 마이크(입력), 🔊 막대는 회의 소리(출력)의 크기입니다.",
                "저장 중: 모래시계",
                "회의록 작성 중: 말풍선",
                "녹음 중 패널에도 '회의 소리'와 '내 마이크' 막대가 움직입니다. 막대가 안 움직이면 그쪽 소리가 들어오지 않는 것입니다.",
            ]),
            .heading("알아 둘 점"),
            .bullets([
                "**설정 → 녹음**의 **녹음 중 화면 꺼짐·잠자기 방지**(기본 켜짐)는 녹음 중 자동 화면 꺼짐과 자동 잠자기를 막습니다. 변경은 즉시 반영되고 다음 실행에도 유지되며, 녹음이 끝나면 방지가 해제됩니다. 덮개 닫기나 직접 선택한 잠자기는 막지 않습니다.",
                "녹음 중에 **종료**를 누르면 저장과 회의록 작성을 마친 뒤 종료합니다.",
                "회의 중 알림음, 음악 등 맥에서 나는 다른 소리도 함께 녹음됩니다.",
                "녹음 중 메뉴바 볼륨 막대는 0.2초마다 8단계로 갱신합니다.",
            ]),
        ]),
        HelpSection(id: "detect", title: "회의 감지·자동 실행", icon: "dot.radiowaves.left.and.right", blocks: [
            .text("회의 앱이 마이크를 쓰기 시작하면 녹음을 제안하고, 마이크를 놓으면 정지를 제안합니다. 기본적으로 제안 창에서 직접 눌러야 시작됩니다. **전화 통화 감지 시 바로 녹음**을 켜면 전화 통화는 확인 창 없이 시작합니다."),
            .heading("회의가 시작되면"),
            .bullets([
                "회의 앱이 마이크를 쓰기 시작하고 약 4초 뒤, 화면 오른쪽 위에 'Microsoft Teams 회의가 시작된 것 같습니다' 창이 뜹니다.",
                "**녹음 시작**을 누르면 녹음합니다. **이번엔 안 함**을 누르면 이번 회의에서는 다시 묻지 않습니다.",
                "1분 동안 응답이 없으면 창만 닫히고 녹음하지 않습니다.",
                "이미 녹음 중이면 묻지 않습니다.",
            ]),
            .heading("전화 통화 자동 녹음"),
            .text("**설정 → 전화 자동 녹음**의 **전화 통화 감지 시 바로 녹음**(기본 켜짐)을 사용하면 전화 앱의 마이크 사용을 확인한 첫 감지에서 바로 시작합니다. 통화 종료를 감지하면 약 2~4초 안에 확인 창 없이 자동 정지·저장합니다. 일반 회의 감지를 꺼도 동작하며, 앱이 실행 중이고 녹음 권한이 허용되어 있어야 합니다. 감지에 몇 초가 걸릴 수 있고, 직접 정지한 통화는 다시 자동 시작하지 않습니다. Phone과 FaceTime이 동시에 실행되어 공유 통화 서비스의 주체를 구별할 수 없으면 자동 감지를 제한합니다."),
            .heading("회의가 끝나면"),
            .bullets([
                "녹음 중에 회의 앱이 마이크를 놓으면 약 10초 뒤 '회의가 끝난 것 같습니다' 창이 뜹니다.",
                "**녹음 정지**를 누르면 정지합니다(회의록 자동 작성이 켜져 있으면 회의록도 만듭니다). **계속 녹음**을 누르면 그대로 둡니다.",
                "**회의가 끝나고 응답이 없으면 2분 뒤 자동 정지**가 켜져 있으면(기본), 창에 남은 시간이 보이고 2분 뒤 정지합니다.",
                "그 사이 회의가 다시 이어지면(마이크를 다시 쓰면) 정지 제안을 거둡니다.",
            ]),
            .heading("감지하는 앱"),
            .bullets([
                "**Microsoft Teams** — `com.microsoft.teams…` (기본 켜짐)",
                "**NAVER WORKS** — `com.naver.naverworks` (기본 켜짐)",
                "**Zoom** — `us.zoom…` (기본 켜짐)",
                "**웹 브라우저** — Chrome·Safari·Edge·웨일 등 (기본 꺼짐). 브라우저로 들어간 회의를 잡으려면 켭니다. 음성 검색 같은 다른 마이크 사용도 회의로 볼 수 있습니다.",
            ]),
            .text("설정에서 앱별로 켜고 끌 수 있습니다."),
            .heading("어떻게 감지하나"),
            .bullets([
                "마이크 장치가 켜지면 macOS 오디오 시스템(Core Audio)이 알려 주고, 그동안만 2초마다 '지금 마이크를 쓰는 앱'을 묻습니다. 마이크가 꺼져 있는 대기 중에는 아무것도 하지 않습니다. 소리는 듣지 않고, 추가 권한도 필요 없습니다.",
                "회의 중에 내 마이크를 음소거해도 회의 앱은 마이크를 잡고 있으므로 회의 중으로 봅니다.",
                "이 앱은 감지 대상에 포함하지 않으므로 자신의 마이크 녹음을 회의로 착각하지 않습니다.",
            ]),
            .heading("로그인할 때 자동 실행"),
            .bullets([
                "처음 실행할 때 자동으로 켜집니다. **설정 > 로그인할 때 자동 실행**에서 끄고 켭니다.",
                "켜져 있으면 시스템 설정 > 일반 > 로그인 항목에 '회의 녹음기'가 보입니다. '허용이 필요하다'는 안내가 나오면 그곳에서 허용합니다.",
                "앱을 다른 폴더(예: /Applications)로 옮겼다면 이 설정을 껐다가 다시 켜세요.",
            ]),
        ]),
        HelpSection(id: "permission", title: "처음 권한 설정", icon: "lock.shield", blocks: [
            .text("처음 **녹음 시작**을 누르면 macOS가 세 가지를 묻습니다. 모두 **허용**해야 합니다."),
            .bullets([
                "**마이크** — 내 목소리 녹음",
                "**시스템 오디오 녹음** — 회의·전화 앱의 상대방 소리 녹음. 화면은 녹화하지 않습니다.",
                "**문서 폴더 접근** — ~/Documents/회의녹음에 저장",
            ]),
            .text("시스템 오디오 권한은 허용한 뒤 앱을 **다시 실행**해야 적용되는 경우가 많습니다."),
            .text("설정 위치: 시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 녹음 / 마이크. macOS 버전에 따라 시스템 오디오 녹음 항목으로 표시됩니다. 업데이트 후 처음 녹음할 때 시스템 오디오 권한을 다시 물으면 허용하세요. 권한 문제가 생기면 패널에 **권한 설정 열기** 버튼이 나타납니다."),
        ]),
        HelpSection(id: "files", title: "저장되는 파일", icon: "folder", blocks: [
            .heading("앱 안에서 재생·이름 변경·자르기"),
            .bullets([
                "녹음이 끝나면 메뉴바 패널에서 바로 재생하고, 재생 막대를 드래그해 원하는 위치로 이동합니다. 회의록 작성 중에도 재생할 수 있습니다.",
                "이름 입력란에 새 이름을 적고 Return 또는 확인 버튼을 누르면 실제 전체 녹음 파일의 이름이 바뀝니다. 날짜별 폴더와 시스템·마이크 트랙 이름은 유지됩니다.",
                "**녹음 목록 · 재생과 편집**은 처음에 재생 모드로 열립니다. 파형을 클릭·드래그해 탐색하고 **편집**을 누르면 노란색 좌우 핸들이 나타납니다. 핸들을 끌어 남길 구간을 정하고 **자르기 적용**을 누르세요. **편집 취소**는 파일을 변경하지 않고 재생 모드로 돌아갑니다.",
                "적용 전 **전체만 자르기 / 시스템·마이크 함께 자르기**를 선택합니다. 함께 자르면 각 트랙의 시작 시간차도 반영합니다. 기존 회의록은 원본 ZIP에 보관하고 편집본에서 다시 만들 수 있습니다.",
                "원본 폴더를 **각 저장 위치/백업**에 ZIP으로 압축하고 무결성을 검사한 다음 편집본을 적용합니다. 재인코딩 없이 AAC 데이터를 유지해 자릅니다. 백업에 실패하면 원본을 바꾸지 않습니다.",
                "백업은 생성 후 30일이 지나면 자동 삭제합니다. 앱 실행 시와 실행 중 6시간마다 정리하며, 앱을 종료한 동안 지난 백업은 다음 실행 때 정리합니다. 복원하려면 백업 폴더의 ZIP을 풀어 사용하세요.",
            ]),
            .text("**설정 > 저장 위치 > 폴더 변경**에서 새 녹음을 저장할 위치를 바꿉니다. 기본은 `~/Documents/회의녹음`입니다. 기존 녹음은 이동하지 않고 이전 위치에서 계속 재생·편집할 수 있으며 백업도 각 위치에서 30일 후 정리합니다. 연결이 끊긴 저장 위치에는 녹음하지 않으므로 디스크를 연결하거나 설정에서 다시 선택하세요. 회의 하나마다 선택한 위치 아래 날짜·시각 폴더가 생깁니다."),
            .bullets([
                "**전체.m4a** — 상대방 소리와 내 목소리를 시간에 맞춰 합친 파일",
                "**시스템.m4a** — 맥에서 나온 소리(회의 상대방)",
                "**마이크.m4a** — 내 목소리",
                "**회의록.txt** — 화자별 회의록",
                "**.tracks.json**(숨김 파일) — 두 트랙의 시작 시각 차이. 나중에 다시 전사할 때 씁니다.",
            ]),
            .text("패널의 **최근 회의록 열기**, **최근 녹음 Finder에서 보기**, **저장 폴더 열기**로 바로 열 수 있습니다."),
            .text("음성·영상 파일을 직접 골라 만든 회의록은 그 파일과 같은 폴더에 '**파일 이름 회의록.txt**'로 저장됩니다."),
        ]),
        HelpSection(id: "transcript", title: "회의록(전사)", icon: "text.bubble", blocks: [
            .text("녹음이나 음성·영상 파일로 회의록을 만듭니다. 모든 처리는 이 맥 안에서 하며 외부로 보내지 않습니다."),
            .heading("만드는 방법"),
            .bullets([
                "**자동:** **설정 → 녹음**의 **녹음 후 회의록 자동 작성**을 켜면(기본 꺼짐) 녹음이 끝날 때마다 만듭니다.",
                "**최근 녹음:** 패널의 **최근 녹음으로 회의록 만들기**. 방금 녹음에 아직 회의록이 없을 때 보입니다.",
                "**직접 고르기:** 패널의 **파일·폴더 골라서 회의록 만들기**…에서 고릅니다. 여러 개를 한꺼번에 고를 수 있고, 이미 회의록이 있으면 새로 만듭니다.",
            ]),
            .heading("고를 수 있는 것"),
            .bullets([
                "**녹음 폴더**(~/Documents/회의녹음/날짜_시각): 마이크·시스템 트랙을 따로 전사해 **나 / 상대방1·2**…로 적습니다. 결과는 폴더 안 회의록.txt.",
                "**음성·영상 파일**(m4a, mp3, wav, aac, aiff, caf, flac, mp4, mov, m4v): 목소리가 한 트랙에 섞여 있으므로 **화자1, 화자2**…로 적습니다. 나도 번호 중 하나로 들어갑니다. 결과는 파일 옆 '파일 이름 회의록.txt'.",
                "다른 녹음 앱, 휴대폰 녹음, 회의 앱이 저장한 녹화 파일도 쓸 수 있습니다.",
            ]),
            .heading("사용하는 것"),
            .bullets([
                "whisper-cli(whisper.cpp, Homebrew로 설치됨)",
                "전사 모델: `~/models/ggml-large-v3-turbo.bin`",
                "무음 제거 모델(VAD): `~/models/ggml-silero-v5.1.2.bin`. 말소리만 넘겨서 무음 구간의 '감사합니다' 같은 헛말을 줄입니다.",
            ]),
            .heading("만드는 방식"),
            .bullets([
                "마이크 트랙과 시스템 트랙을 따로 전사한 뒤 시간순으로 합칩니다.",
                "같은 사람이 2초 안에 이어서 말한 조각은 한 줄로 붙입니다.",
                "앞 구간의 문장을 다음 구간의 힌트로 넘기지 않습니다. whisper가 같은 문장을 수십 번 반복해 적는 오류를 막고, 속도도 2배 빨라집니다.",
                "스피커폰에서 나온 상대방 목소리가 마이크로 다시 들어가 같은 말이 '나'로도 적히면 지웁니다.",
                "형식: `[00:01:23] 나: …`, `[00:01:30] 상대방1: …`",
            ]),
            .heading("걸리는 시간"),
            .text("녹음 길이의 1/5 정도입니다. 3분 남짓한 음성(세 사람 대화)은 전사와 화자 구분까지 약 40초가 걸렸고, 1시간 회의는 10~15분으로 예상합니다. 맥을 켠 뒤 처음 만들 때는 모델 파일(1.6GB)을 읽느라 조금 더 걸립니다. 작성 중에는 패널에 '회의록 작성 중…'이 보이고, 새 녹음은 그동안에도 할 수 있습니다."),
            .heading("명령으로 만들기"),
            .command("패널 대신 명령으로도 됩니다. 경로에 녹음 폴더나 음성·영상 파일을 넣습니다. 끝나면 앱이 종료되니, 평소 쓰는 앱과 따로 실행됩니다.",
                     "open -n \(app) --args --transcribe ~/Documents/회의녹음/2026-10-23_10-54-05"),
        ]),
        HelpSection(id: "speakers", title: "화자 구분", icon: "person.2", blocks: [
            .heading("나와 상대방"),
            .text("마이크 트랙은 **나**, 시스템 트랙은 **상대방**으로 적습니다. 녹음할 때부터 트랙이 나뉘어 있어서 이 구분은 정확합니다."),
            .heading("상대방 여러 명"),
            .bullets([
                "상대방 쪽 말 조각마다 `~/models/speaker-ecapa-voxceleb`(ECAPA) 모델로 목소리 특징을 뽑습니다.",
                "비슷한 목소리끼리 묶어 먼저 말한 사람부터 **상대방1, 상대방2, 상대방3…** 번호를 붙입니다.",
                "0.6초보다 짧은 조각('네' 같은 맞장구)은 시간상 가장 가까운 조각의 사람으로 정합니다.",
                "상대방이 한 명으로 판단되면 번호 없이 '상대방'으로 적습니다.",
                "화자 구분이 실패해도 회의록은 '상대방'으로 그대로 만들어집니다.",
                "1시간 회의 기준 30초 안팎이 걸립니다.",
            ]),
            .heading("파일로 만든 회의록"),
            .text("직접 고른 음성·영상 파일은 목소리가 한 트랙에 섞여 있어 나와 상대방을 나눌 수 없습니다. 파일 전체를 같은 방식으로 목소리별로 묶어 **화자1, 화자2**…로 적고, 나도 번호 중 하나로 들어갑니다. 한 명으로 판단되면 번호 없이 '화자'로 적습니다."),
            .heading("정확도"),
            .bullets([
                "목소리가 뚜렷이 다른 2~4명 회의는 잘 나뉩니다.",
                "비슷한 목소리, 짧은 맞장구, 여러 사람이 동시에 말하는 구간에서는 틀릴 수 있습니다.",
                "Teams·네이버웍스는 음성을 압축해서 보내므로 대면 녹음보다 조금 덜 정확할 수 있습니다.",
            ]),
            .heading("기준값 조정"),
            .text("`\(project)/diarize/diarize.py`의 **THRESHOLD**(기본 0.6)를 바꿉니다. 한 사람이 둘로 쪼개지면 값을 **키우고**, 두 사람이 하나로 합쳐지면 값을 **줄입니다**. 고친 뒤 다시 빌드해야 앱에 반영됩니다."),
            .heading("가상환경"),
            .bullets([
                "화자 구분은 `\(short(Transcriber.pythonPath))`의 Python으로 실행합니다. 가상머신이나 Docker가 아니라, 이 앱 전용 Python과 라이브러리를 넣어 둔 폴더입니다.",
                "설치 안내는 저장소 README에 있습니다. Python 3.12와 diarize/requirements.txt의 패키지를 사용합니다.",
                "macOS 시스템 Python이나 다른 프로젝트와 섞이지 않습니다.",
                "필요 없으면 앱 전용 가상환경을 제거하면 됩니다. 그러면 상대방 번호 구분만 꺼지고 녹음과 회의록은 그대로 됩니다.",
            ]),
            .command("소스 저장소 루트에서 실행(Homebrew의 python@3.12 필요)",
                     "MR_VENV=\"$HOME/Library/Application Support/MeetingRecorder/venv\"\n\"$(brew --prefix python@3.12)/bin/python3.12\" -m venv \"$MR_VENV\"\n\"$MR_VENV/bin/python\" -m pip install -r diarize/requirements.txt"),
        ]),
        HelpSection(id: "trouble", title: "문제 해결", icon: "wrench.and.screwdriver", blocks: [
            .heading("허용했는데 권한 요청이 계속 뜰 때"),
            .text("macOS는 앱의 서명으로 같은 앱인지 판단합니다. 서명이 바뀌면 권한을 다시 허용해야 할 수 있습니다. 개발 인증서가 없는 환경에서는 빌드할 때 임시 서명을 사용합니다. 권한 요청이 계속되면:"),
            .bullets([
                "시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 녹음에서 **MeetingRecorder**를 선택하고 **−**로 삭제합니다.",
                "앱을 다시 실행하고 **녹음 시작**을 눌러 다시 허용합니다.",
            ]),
            .command("또는 이 앱의 화면 녹음 허용 기록만 지웁니다(다른 앱에는 영향 없음).",
                     "tccutil reset ScreenCapture local.cothe.MeetingRecorder"),
            .heading("녹음 폴더나 파일이 생기지 않을 때"),
            .text("권한, 특히 **문서 폴더 접근**에서 '허용 안 함'을 누르지 않았는지 확인합니다. 패널에 뜬 안내 문구를 확인합니다."),
            .heading("시스템.m4a가 무음일 때"),
            .text("녹음하는 동안 맥에서 실제로 소리가 났는지 확인합니다. 녹음 중 🔊 막대가 움직여야 합니다."),
            .heading("마이크.m4a가 무음일 때"),
            .bullets([
                "시스템 설정 > 사운드 > 입력에서 기본 입력 장치를 확인합니다. 앱은 기본 입력 장치를 씁니다.",
                "장치가 음소거 상태가 아닌지 확인합니다.",
                "블루투스 스피커폰(Anker PowerConf 등)은 16kHz로 들어오는데 정상 지원합니다.",
            ]),
            .heading("회의를 감지하지 못할 때"),
            .bullets([
                "패널 위쪽 줄이 '회의 감지 꺼짐'이면 **설정**에서 회의 감지를 켭니다.",
                "설정에서 해당 회의 앱이 켜져 있는지 확인합니다. 브라우저로 들어간 회의는 **웹 브라우저**를 켜야 합니다.",
                "회의 앱이 마이크를 쓰는 동안에만 회의로 봅니다. 듣기만 하는 웨비나처럼 마이크를 열지 않는 회의는 감지되지 않으니 직접 녹음을 시작하세요.",
                "회의 앱이 업데이트되며 식별자가 바뀌면 감지되지 않을 수 있습니다(예: Teams는 예전에 `com.microsoft.teams`, 지금 `com.microsoft.teams2`). 이때는 앱의 감지 목록을 고쳐야 합니다.",
            ]),
            .heading("로그인해도 자동으로 뜨지 않을 때"),
            .text("**설정**의 '로그인할 때 자동 실행' 아래 안내를 확인합니다. 허용이 필요하면 **로그인 항목 설정 열기**를 눌러 '회의 녹음기'를 허용합니다. 앱을 옮겼다면 껐다가 다시 켭니다."),
            .heading("'○○ 저장 실패' 또는 '회의록 작성 실패'가 뜰 때"),
            .text("패널에 이유가 함께 표시됩니다. 회의록 문제라면 **구성 요소 상태**에서 빠진 파일이 있는지 확인합니다. '소리를 읽을 수 없는 파일입니다'가 뜨면 소리 트랙이 없거나 macOS가 읽지 못하는 형식입니다. QuickTime이나 ffmpeg로 m4a·wav로 바꾼 뒤 다시 고르세요."),
            .command("앱 기록(로그) 보기. zsh에는 이름이 같은 내장 명령이 있어 /usr/bin/log로 적습니다.",
                     "/usr/bin/log show --last 30m --style compact --predicate 'subsystem == \"local.cothe.MeetingRecorder\"'"),
            .command("자체 테스트: 6초 녹음하고 저장·회의록까지 만든 뒤 종료합니다.", "open -n \(app) --args --selftest 6"),
        ]),
        HelpSection(id: "manage", title: "설치·관리", icon: "gearshape", blocks: [
            .heading("계속 쓰려면"),
            .bullets([
                "앱을 `/Applications`로 옮기면 편합니다. 빌드 결과(`\(project)/build/MeetingRecorder.app`)는 다시 빌드할 때마다 덮어써집니다. 옮긴 뒤 다시 빌드했다면 새로 복사해야 합니다.",
                "로그인할 때 자동 실행은 처음 실행 때 켜집니다. **설정**에서 끄고 켤 수 있고, 앱을 옮긴 뒤에는 껐다가 다시 켜야 새 위치로 등록됩니다.",
            ]),
            .heading("빌드"),
            .text("저장소를 내려받은 폴더에서 아래 명령을 실행하세요. build.sh는 개발 인증서(Apple Development)가 있으면 그것으로 서명하고, 없으면 임시 서명을 사용합니다. 빌드 전에 앱을 종료하세요."),
            .command("다시 빌드", "\(project)/build.sh"),
            .command("앱 아이콘 다시 만들기(tools/make_icon.swift의 그림을 바꾼 뒤)", "\(project)/make_icon.sh"),
        ]),
        HelpSection(id: "privacy", title: "녹음 예절·개인정보", icon: "hand.raised", blocks: [
            .bullets([
                "녹음하기 전에 참석자에게 동의를 받으세요.",
                "일반 회의 감지는 녹음을 **제안**합니다. 별도 옵션인 **전화 통화 감지 시 바로 녹음**을 켜면 확인 없이 시작합니다(기본 켜짐).",
                "회의 감지는 어떤 앱이 마이크를 쓰는지만 확인하며 소리를 듣지 않습니다.",
                "녹음 파일과 회의록은 선택한 저장 위치(기본 `~/Documents/회의녹음`)에 저장하고 앱이 외부로 전송하지 않습니다. 클라우드 동기화 폴더를 선택하면 해당 서비스가 동기화할 수 있습니다.",
                "회사 보안 정책상 녹음이 제한된 회의인지 확인하세요.",
            ]),
        ]),
        HelpSection(id: "others", title: "다른 앱과 비교", icon: "square.grid.2x2", blocks: [
            .text("이 앱은 녹음, 회의록, 화자 구분까지 맥 안에서만 처리합니다. 요약, 일정 연동, 공유가 필요하면 아래 서비스도 있습니다."),
            .bullets([
                "**티로(Tiro)** — 맥 앱이 시스템 오디오와 마이크를 녹음하고, 한국어 회의록 품질이 좋습니다. 클라우드 처리.",
                "**네이버웍스 클로바노트** — 회사가 네이버웍스를 쓰면 기업용으로 신청할 수 있고 관리자 보안 설정이 가능합니다.",
                "**Granola** — 메모와 전사를 합쳐 정리하는 맥 메뉴바 앱. 한국어 지원은 확인이 필요합니다.",
                "**MacWhisper** — 맥 안에서 처리하는 전사 앱. 유료 버전에 시스템 오디오 녹음이 있습니다.",
            ]),
        ]),
    ]
}
