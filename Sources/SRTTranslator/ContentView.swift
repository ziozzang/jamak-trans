import AppKit
import SwiftUI
import Translation
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var queue: TranslationQueue
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            SettingsBar(queue: queue)
            Divider()
            UpdateBanner(updater: .shared)
            if let notice = queue.restoreNotice {
                RestoreBanner(queue: queue, message: notice)
                Divider()
            }
            SummaryBar(queue: queue)
            Divider()
            if queue.jobs.isEmpty {
                DropPlaceholder(highlighted: isDropTargeted, onPick: Panels.addFiles)
            } else {
                List(queue.jobs) { job in
                    JobRow(job: job, queue: queue)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        .overlay {
            if isDropTargeted && !queue.jobs.isEmpty {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            queue.add(urls)
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .toolbar { toolbar }
        .modifier(ModelDownloadHost(preparer: queue.preparer))
        .task { await queue.loadLanguages() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button(action: Panels.addFiles) { Label("추가", systemImage: "plus") }
                .help("SRT 파일 또는 폴더 추가")
            Menu {
                Button("작업 목록 저장…", action: Panels.exportQueue)
                Button("작업 목록 불러오기…", action: Panels.importQueue)
                Divider()
                Button("목록 모두 비우기", role: .destructive, action: queue.clearAll)
            } label: { Label("작업 목록", systemImage: "list.bullet.rectangle") }
                .help("작업 목록을 파일로 저장하거나 불러옵니다")
            if queue.isRunning {
                Button(action: queue.pause) { Label("일시정지", systemImage: "pause.fill") }
                    .help("진행 중인 파일을 마친 뒤 대기열을 멈춥니다")
            } else {
                Button(action: { queue.restoreNotice = nil; queue.start() }) { Label("시작", systemImage: "play.fill") }
                    .disabled(queue.summary.pending == 0)
            }
            Button(action: queue.stopAll) { Label("중지", systemImage: "stop.fill") }
                .disabled(queue.summary.active == 0)
                .help("진행 중인 번역을 모두 취소합니다")
            Button(action: queue.retryFailed) { Label("다시 시도", systemImage: "arrow.clockwise") }
                .disabled(queue.summary.failed == 0)
                .help("실패/취소된 파일을 다시 대기열에 넣습니다")
            Button(action: queue.clearFinished) { Label("정리", systemImage: "trash") }
                .help("완료·건너뜀·실패 항목을 목록에서 지웁니다")
        }
    }

}

@MainActor
enum Panels {
    static func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText, .folder]
        panel.prompt = "추가"
        if panel.runModal() == .OK { TranslationQueue.shared.add(panel.urls) }
    }

    static func exportQueue() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "SRT 번역 작업.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try TranslationQueue.shared.exportSnapshot(to: url) } catch { showError(error) }
    }

    static func importQueue() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.prompt = "불러오기"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try TranslationQueue.shared.importSnapshot(from: url) } catch { showError(error) }
    }

    private static func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}

private struct UpdateBanner: View {
    @ObservedObject var updater: Updater

    var body: some View {
        if let text = updater.progressText {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(text).font(.callout).monospacedDigit()
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.1))
            Divider()
        }
    }
}

private struct RestoreBanner: View {
    @ObservedObject var queue: TranslationQueue
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(Color.accentColor)
            Text(message).font(.callout)
            Spacer()
            Button("이어서 번역") { queue.restoreNotice = nil; queue.start() }
                .buttonStyle(.borderedProminent)
                .disabled(queue.summary.pending == 0)
            Button("목록 비우기") { queue.clearAll() }
            Button { queue.restoreNotice = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
    }
}

// MARK: - Settings

private struct SettingsBar: View {
    @ObservedObject var queue: TranslationQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                Picker("대상 언어", selection: $queue.targetID) {
                    if queue.targets.isEmpty {
                        Text(LanguageNames.name(forCode: queue.targetID)).tag(queue.targetID)
                    }
                    ForEach(queue.targets) { Text($0.name).tag($0.id) }
                }
                .frame(maxWidth: 240)

                Stepper(value: $queue.maxConcurrent, in: 1...8) {
                    Text("동시 작업 \(queue.maxConcurrent)개").monospacedDigit()
                }

                Toggle("기존 번역 파일 덮어쓰기", isOn: $queue.overwriteExisting)
                Toggle("추가 시 자동 시작", isOn: $queue.autoStart)
                Spacer()
            }
            HStack(spacing: 18) {
                Picker("내용", selection: $queue.outputContent) {
                    ForEach(OutputContent.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                .help("번역문 + 원문: 번역문 아래에 원문을 회색으로 표시합니다")

                Picker("형식", selection: $queue.outputFormat) {
                    ForEach(OutputFormat.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 150)

                Picker("파일 이름", selection: $queue.namingMode) {
                    ForEach(NamingMode.allCases) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 330)
                .help("원본 이름 사용: foo.srt에 번역을 쓰고 원본은 foo.srt.org로 바꿉니다")
                Spacer()
            }
            .disabled(queue.summary.active > 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Overall progress

private struct SummaryBar: View {
    @ObservedObject var queue: TranslationQueue

    var body: some View {
        let s = queue.summary
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: s.fraction)
            HStack(spacing: 14) {
                Text("문장 \(s.doneSegments.formatted()) / \(s.totalSegments.formatted())")
                    .fontWeight(.semibold)
                Text(String(format: "%.1f%%", s.fraction * 100))
                Divider().frame(height: 12)
                Text("파일 \(s.completed)/\(s.completed + s.active + s.pending) 완료")
                if s.active > 0 { Text("진행 \(s.active)") }
                if s.pending > 0 { Text("대기 \(s.pending)") }
                if s.skipped > 0 { Text("건너뜀 \(s.skipped)").foregroundStyle(.secondary) }
                if s.failed > 0 { Text("실패 \(s.failed)").foregroundStyle(.red) }
                Spacer()
                if let eta { Text(eta).foregroundStyle(.secondary) }
            }
            .font(.callout)
            .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var eta: String? {
        let rate = queue.segmentsPerSecond
        let remaining = queue.summary.totalSegments - queue.summary.doneSegments
        guard rate > 0.1, remaining > 0 else { return nil }
        let seconds = Double(remaining) / rate
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        return String(format: "%.0f 문장/초 · 남은 시간 ", rate) + (f.string(from: seconds) ?? "")
    }
}

// MARK: - Rows

private struct JobRow: View {
    @ObservedObject var job: FileJob
    let queue: TranslationQueue

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.fileName).lineLimit(1).truncationMode(.middle)
                Text(job.relativeDirectory)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
            .help(job.url.path)
            Spacer(minLength: 12)
            languageBadge
            VStack(alignment: .trailing, spacing: 3) {
                ProgressView(value: job.fraction)
                    .tint(tint)
                    .frame(width: 170)
                HStack(spacing: 6) {
                    Text(job.status.text).foregroundStyle(job.status == .completed ? .primary : .secondary)
                    if job.total > 0, !isSkipped {
                        Text("\(job.status == .completed ? job.total : job.done)/\(job.total) 문장")
                    }
                }
                .font(.caption).monospacedDigit().lineLimit(1)
                .frame(width: 260, alignment: .trailing)
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Finder에서 원본 보기") { NSWorkspace.shared.activateFileViewerSelecting([job.url]) }
            if job.status == .completed, let out = job.outputURL {
                Button("번역 파일 보기") { NSWorkspace.shared.activateFileViewerSelecting([out]) }
            }
            Divider()
            Button("목록에서 제거") { queue.remove(job) }
        }
    }

    private var languageBadge: some View {
        let source = job.profile?.dominant.map(LanguageNames.name(forCode:)) ?? "?"
        return Text(isSkipped || job.profile == nil ? source : "\(source) → \(LanguageNames.name(for: queue.target))")
            .font(.caption)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }

    private var isSkipped: Bool {
        if case .skipped = job.status { return true }
        return false
    }

    private var icon: String {
        switch job.status {
        case .analyzing: "magnifyingglass"
        case .pending: "clock"
        case .waitingForModel: "arrow.down.circle"
        case .translating: "text.bubble"
        case .completed: "checkmark.circle.fill"
        case .skipped: "forward.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    private var tint: Color {
        switch job.status {
        case .completed: .green
        case .failed: .red
        case .skipped, .cancelled: .secondary
        case .waitingForModel: .orange
        default: .accentColor
        }
    }
}

private struct DropPlaceholder: View {
    let highlighted: Bool
    let onPick: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "captions.bubble")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(highlighted ? Color.accentColor : .secondary)
            Text("SRT 파일이나 폴더를 여기에 끌어다 놓으세요")
                .font(.title3)
            Text("폴더는 하위 폴더까지 모든 .srt 파일을 찾습니다.\n파일마다 원본 언어를 감지하고, 이미 대상 언어인 파일은 건너뜁니다.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("파일 선택…", action: onPick)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(highlighted ? Color.accentColor : Color.secondary.opacity(0.4))
                .padding(18)
        }
    }
}

/// Hosts the SwiftUI translation task that lets the system download missing language models.
private struct ModelDownloadHost: ViewModifier {
    @ObservedObject var preparer: LanguagePreparer

    func body(content: Content) -> some View {
        content.translationTask(preparer.configuration) { session in
            await preparer.handle(session)
        }
    }
}
