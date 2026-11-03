import ServiceManagement
import SwiftUI

/// 로그인할 때 자동 실행(시스템 설정 > 일반 > 로그인 항목)
enum LoginItem {
    static var isOn: Bool {
        [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
    }

    static func set(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// 처음 실행할 때 한 번만 켠다. 이후에는 설정에서 바꾼 대로 둔다.
    static func registerOnFirstLaunch() {
        let key = "loginItemInitialized"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? set(true)
    }

    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: "로그인하면 메뉴바에 자동으로 뜹니다. 앱을 다른 폴더로 옮겼다면 껐다가 다시 켜세요."
        case .requiresApproval: "시스템 설정 > 일반 > 로그인 항목에서 '회의 녹음기'를 허용해야 합니다."
        default: "로그인해도 자동으로 실행되지 않습니다."
        }
    }
}

struct SettingsView: View {
    @ObservedObject var recorder: Recorder
    @AppStorage(MeetingWatcher.enabledKey) private var detect = true
    @AppStorage(MeetingWatcher.autoStopKey) private var autoStop = true
    @AppStorage(MeetingWatcher.phoneAutoRecordKey) private var phoneAutoRecord = true
    @State private var loginOn = LoginItem.isOn
    @State private var loginText = LoginItem.statusText

    var body: some View {
        Form {
            Section("저장 위치") {
                Text(recorder.baseFolder.path).font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("폴더 변경…") { Task { await recorder.chooseStorageFolder() } }
                    Button("기본 위치로") { Task { await recorder.changeStorage(to: RecordingStorage.defaultFolder) } }
                        .disabled(recorder.baseFolder == RecordingStorage.defaultFolder)
                    Button("폴더 열기") { recorder.openFolder() }
                }
                .disabled(!recorder.canChangeStorage)
                Text("새 녹음과 백업은 선택한 위치에 저장합니다. 기존 녹음은 이동하지 않고 목록에서 계속 보여줍니다. 백업은 각 녹음의 저장 위치 아래 ‘백업’ 폴더에 30일 동안 보관됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
                if let message = recorder.storageMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                if !recorder.canChangeStorage { Text("녹음·저장·편집·회의록 작성이 끝나면 변경할 수 있습니다.").font(.caption).foregroundStyle(.secondary) }
            }
            Section("녹음") {
                SettingsToggle("내 마이크 함께 녹음", systemImage: "mic.fill",
                               detail: "내 목소리도 함께 저장합니다. 기본 켜짐.",
                               isOn: $recorder.includeMicrophone)
                    .disabled(recorder.isRecording || recorder.isSaving || recorder.isStarting)
                SettingsToggle("녹음 후 회의록 자동 작성", systemImage: "text.badge.checkmark",
                               detail: Transcriber.isAvailable
                                   ? "녹음이 끝나면 회의록을 만듭니다. 기본 꺼짐."
                                   : "whisper-cli와 전사 모델을 설치하면 사용할 수 있습니다.",
                               isOn: $recorder.autoTranscribe)
                    .disabled(!Transcriber.isAvailable)
                SettingsToggle("녹음 중 화면 꺼짐·잠자기 방지", systemImage: "display",
                               detail: "녹음 중에만 자동 잠자기를 막습니다. 기본 켜짐. 변경은 즉시 반영되며, 덮개 닫기나 직접 선택한 잠자기는 막지 않습니다.",
                               isOn: $recorder.preventSleepWhileRecording)
            }

            Section("전화 자동 녹음") {
                SettingsToggle("전화 통화 감지 시 바로 녹음", systemImage: "phone.fill",
                               detail: "앱 실행 중 통화를 감지하면 시작하고, 통화 종료 후 약 2~4초 안에 정지·저장합니다. 기본 켜짐.",
                               isOn: $phoneAutoRecord)
                Text("수동 정지한 통화는 다시 녹음하지 않습니다. Phone과 FaceTime을 함께 실행하면 자동 감지가 제한될 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("시작") {
                SettingsToggle("로그인할 때 자동 실행", systemImage: "power",
                               detail: loginText, isOn: $loginOn)
                    .onChange(of: loginOn) { _, on in setLogin(on) }
                Button("로그인 항목 설정 열기") { SMAppService.openSystemSettingsLoginItems() }
            }

            Section {
                SettingsToggle("회의 시작 시 녹음 제안", systemImage: "waveform",
                               detail: "선택한 회의 앱이 마이크를 쓰기 시작하면 알려줍니다.",
                               isOn: $detect)
                ForEach(MeetingWatcher.apps) { app in
                    AppToggle(app: app).disabled(!detect)
                }
                SettingsToggle("회의 종료 후 자동 정지", systemImage: "stop.circle",
                               detail: "회의가 끝나고 응답이 없으면 2분 뒤 녹음을 정지합니다.",
                               isOn: $autoStop)
                    .disabled(!detect)
            } header: {
                Text("회의 감지")
            } footer: {
                Text("마이크가 켜져 있는 동안만 어떤 앱이 쓰는지 2초마다 확인하며, 소리는 듣지 않습니다. 마이크가 꺼져 있을 때는 아무것도 하지 않습니다. 녹음은 제안 창에서 직접 눌러야 시작됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .tint(Theme.blue)
        .controlSize(.small)
        .frame(width: 520, height: 680)
    }

    private func setLogin(_ on: Bool) {
        if on != LoginItem.isOn {
            do {
                try LoginItem.set(on)
            } catch {
                loginText = "바꾸지 못했습니다: \(error.localizedDescription)"
                loginOn = LoginItem.isOn
                return
            }
        }
        loginOn = LoginItem.isOn
        loginText = LoginItem.statusText
    }
}

/// 제목과 설명을 한 행으로 묶고, 오른쪽에 스위치를 정렬한다.
private struct SettingsToggle: View {
    let title: String
    let systemImage: String
    let detail: String
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var enabled

    init(_ title: String, systemImage: String, detail: String, isOn: Binding<Bool>) {
        self.title = title
        self.systemImage = systemImage
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(systemImage: systemImage, tint: isOn && enabled ? Theme.blue : .secondary, size: 30)
                .padding(.top, 2)
                .accessibilityHidden(true)
            Toggle(isOn: $isOn) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.body.weight(.medium))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.trailing, 12)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct AppToggle: View {
    let app: MeetingWatcher.MeetingApp
    @AppStorage private var isOn: Bool

    init(app: MeetingWatcher.MeetingApp) {
        self.app = app
        _isOn = AppStorage(wrappedValue: app.enabledByDefault, app.key)
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(app.name)
            Text(app.id == "browser" ? "Chrome·Safari·Edge·웨일 등. 회의가 아닌 마이크 사용도 회의로 볼 수 있습니다." : app.prefixes.joined(separator: ", "))
        }
        .padding(.leading, 16)
    }
}
