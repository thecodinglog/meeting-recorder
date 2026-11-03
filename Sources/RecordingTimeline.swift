import SwiftUI

struct RecordingEditor: View {
    @ObservedObject var library: RecordingLibrary
    @Binding var editing: Bool
    let unavailable: Bool
    let editingUnavailable: Bool
    let apply: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Label(editing ? "편집 모드" : "재생 모드", systemImage: editing ? "scissors" : "waveform")
                    .font(.headline).foregroundStyle(editing ? Color.orange : Theme.blue)
                Spacer()
                if library.isBusy || library.isLoading { ProgressView().controlSize(.small) }
                if !editing {
                    Button { enterEditing() } label: { Label("편집", systemImage: "scissors") }
                        .disabled(unavailable || editingUnavailable || library.isBusy || library.duration <= 0)
                }
            }
            HStack(spacing: 8) {
                TextField("녹음 이름", text: $library.name)
                    .font(.title3.weight(.semibold)).textFieldStyle(.plain)
                    .onSubmit { Task { await library.rename() } }
                    .accessibilityLabel("녹음 파일 이름")
                Button { Task { await library.rename() } } label: { Image(systemName: "checkmark.circle") }
                    .buttonStyle(.plain).foregroundStyle(Theme.blue).help("파일 이름 변경")
                    .disabled(library.name == library.selected?.title)
            }
            .disabled(unavailable || editingUnavailable || editing || library.isBusy)
            if let selected = library.selected {
                Text(selected.createdAt.formatted(.dateTime.year().month().day().hour().minute().locale(Locale(identifier: "ko_KR"))))
                    .font(.caption).foregroundStyle(.secondary)
            }

            RecordingTimeline(library: library, editing: editing)
                .disabled(unavailable || library.isBusy || library.duration <= 0)

            HStack(spacing: 24) {
                Text(RecordingLibrary.time(library.position))
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(Theme.blue)
                Spacer()
                Button { jump(-5) } label: { Image(systemName: "gobackward.5").font(.title2) }
                    .buttonStyle(.plain).accessibilityLabel("5초 뒤로")
                Button { togglePlayback() } label: {
                    Image(systemName: library.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 46)).foregroundStyle(Theme.blue)
                }
                .buttonStyle(.plain).accessibilityLabel(library.isPlaying ? "일시 정지" : "재생")
                Button { jump(5) } label: { Image(systemName: "goforward.5").font(.title2) }
                    .buttonStyle(.plain).accessibilityLabel("5초 앞으로")
                Spacer()
                Text(RecordingLibrary.time(library.duration))
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
            }
            .disabled(unavailable || library.isBusy || library.duration <= 0)

            if editing {
                VStack(spacing: 12) {
                    HStack {
                        Text("시작 \(RecordingLibrary.time(library.trimStart))")
                        Spacer()
                        Text("남길 길이 \(RecordingLibrary.time(max(0, library.trimEnd - library.trimStart)))").bold()
                        Spacer()
                        Text("끝 \(RecordingLibrary.time(library.trimEnd))")
                    }.font(.system(.caption, design: .monospaced))
                    Divider()
                    HStack {
                        Button("편집 취소") { leaveEditing() }
                        Spacer()
                        Text("노란 영역만 남깁니다").font(.caption).foregroundStyle(.secondary)
                        Button("자르기 적용…") { library.pause(); apply() }
                            .buttonStyle(.borderedProminent).tint(Theme.blue).disabled(!library.canTrim)
                    }
                }
                .disabled(unavailable || editingUnavailable || library.isBusy)
            } else {
                Text("파형을 클릭·드래그해 재생 위치를 이동하세요. ‘편집’을 누르면 좌우 자르기 핸들이 나타납니다.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20).card()
    }

    private func enterEditing() {
        library.pause()
        library.trimStart = 0
        library.trimEnd = library.duration
        editing = true
    }
    private func leaveEditing() {
        library.pause()
        library.trimStart = 0
        library.trimEnd = library.duration
        editing = false
    }
    private func togglePlayback() {
        if editing, !library.isPlaying { library.previewSelection(fromCurrent: true) }
        else { library.togglePlayback() }
    }
    private func jump(_ amount: Double) {
        library.seek(to: min(max(library.position + amount, editing ? library.trimStart : 0), editing ? library.trimEnd : library.duration))
    }
}

struct RecordingTimeline: View {
    @ObservedObject var library: RecordingLibrary
    let editing: Bool
    @State private var seeking = false
    @State private var dragAnchor: Double?

    var body: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                timeline(height: 140, handles: editing)
                if library.isLoadingWaveform {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("파형 불러오는 중") }
                        .font(.caption).foregroundStyle(.secondary).padding(10).allowsHitTesting(false)
                }
            }
            HStack {
                ForEach(0..<5) { index in
                    if index > 0 { Spacer(minLength: 0) }
                    Text(RecordingLibrary.time(library.duration * Double(index) / 4))
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 14)
            if editing {
                Label("좌우의 노란 핸들을 안쪽으로 끌어 남길 구간을 정하세요", systemImage: "arrow.left.and.right")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: editing) { _, _ in dragAnchor = nil }
    }

    private func timeline(height: CGFloat, handles: Bool) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let usable = max(1, width - 28)
            let duration = max(library.duration, 0.01)
            let startX = 14 + CGFloat(library.trimStart / duration) * usable
            let endX = 14 + CGFloat(library.trimEnd / duration) * usable
            let cursor = 14 + CGFloat(library.position / duration) * usable
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6),
                                 with: .color(Color.primary.opacity(0.035)))
                    if editing {
                        context.fill(Path(CGRect(x: startX, y: 0, width: max(0, endX - startX), height: size.height)),
                                     with: .color(.yellow.opacity(0.2)))
                    }
                    let count = max(1, Int(usable / 3))
                    for index in 0..<count {
                        let begin = index * library.waveform.count / count
                        let finish = min(library.waveform.count, max(begin + 1, (index + 1) * library.waveform.count / count))
                        let peak = begin < finish ? library.waveform[begin..<finish].max() ?? 0 : 0
                        let amplitude = CGFloat(pow(min(max(peak, 0), 1), 0.45))
                        let barHeight = max(1, amplitude * (size.height - 20))
                        let x = 14 + CGFloat(index) / CGFloat(count) * usable
                        var bar = Path()
                        bar.move(to: CGPoint(x: x, y: (size.height - barHeight) / 2))
                        bar.addLine(to: CGPoint(x: x, y: (size.height + barHeight) / 2))
                        let inside = !editing || (x >= startX && x <= endX)
                        context.stroke(bar, with: .color(inside ? (editing ? Color.orange : Theme.blue).opacity(0.8) : Color.secondary.opacity(0.25)),
                                       style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                    if handles {
                        context.stroke(Path(CGRect(x: startX, y: 1, width: max(0, endX - startX), height: size.height - 2)),
                                       with: .color(.yellow), lineWidth: 2)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    if !seeking { library.scrubbingChanged(true); seeking = true }
                    let time = TrimTimelineMath.time(at: value.location.x, width: width, duration: library.duration)
                    library.scrub(to: editing ? min(max(time, library.trimStart), library.trimEnd) : time)
                }.onEnded { _ in library.scrubbingChanged(false); seeking = false })
                .accessibilityLabel(handles ? "편집 구간 안의 재생 위치" : "녹음 파형과 재생 위치")

                Rectangle().fill(Theme.blue).frame(width: 2, height: height)
                    .offset(x: min(max(cursor - 1, 0), width - 2)).allowsHitTesting(false)
                Circle().fill(Theme.blue).frame(width: 6, height: 6)
                    .offset(x: min(max(cursor - 3, 0), width - 6), y: -2).allowsHitTesting(false)
                if handles {
                    handle(start: true, width: width).position(x: startX - 7, y: height / 2)
                    handle(start: false, width: width).position(x: endX + 7, y: height / 2)
                }
            }
            .coordinateSpace(name: "recordingTrim")
        }
        .frame(height: height)
    }

    private func handle(start: Bool, width: CGFloat) -> some View {
        Image(systemName: start ? "chevron.left" : "chevron.right")
            .font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
            .frame(width: 14, height: 52).background(.yellow, in: RoundedRectangle(cornerRadius: 3))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("recordingTrim"))
                .onChanged { value in
                    library.pause()
                    if dragAnchor == nil { dragAnchor = start ? library.trimStart : library.trimEnd }
                    let movement = Double(value.translation.width / max(width - 28, 1)) * library.duration
                    updateHandle(start: start, time: (dragAnchor ?? 0) + movement)
                }.onEnded { _ in dragAnchor = nil })
            .accessibilityLabel(start ? "자르기 시작 핸들" : "자르기 끝 핸들")
            .accessibilityValue(RecordingLibrary.time(start ? library.trimStart : library.trimEnd))
            .accessibilityAdjustableAction { direction in
                let value = start ? library.trimStart : library.trimEnd
                switch direction {
                case .increment: updateHandle(start: start, time: value + 0.1)
                case .decrement: updateHandle(start: start, time: value - 0.1)
                @unknown default: break
                }
            }
    }

    private func updateHandle(start: Bool, time: Double) {
        library.pause()
        let rounded = (time * 10).rounded() / 10
        if start { library.trimStart = TrimTimelineMath.start(rounded, end: library.trimEnd, duration: library.duration) }
        else { library.trimEnd = TrimTimelineMath.end(rounded, start: library.trimStart, duration: library.duration) }
    }
}
