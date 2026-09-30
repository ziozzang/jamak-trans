import Foundation
import Translation

enum SkipReason: Equatable {
    case alreadyTarget
    case containsTarget(Int)
    case outputExists
    case outputConflict
    case backupExists
    case nothingToTranslate

    var text: String {
        switch self {
        case .alreadyTarget: "이미 대상 언어"
        case let .containsTarget(p): "대상 언어 포함 (\(p)%)"
        case .outputExists: "번역 파일이 이미 있음"
        case .outputConflict: "다른 파일과 출력 이름 충돌"
        case .backupExists: "원본 백업(.org)이 이미 있음"
        case .nothingToTranslate: "번역할 문장 없음"
        }
    }
}

enum JobStatus: Equatable {
    case analyzing, pending, waitingForModel, translating, completed, cancelled
    case skipped(SkipReason)
    case failed(String)

    var text: String {
        switch self {
        case .analyzing: "분석 중"
        case .pending: "대기"
        case .waitingForModel: "언어 모델 다운로드 대기"
        case .translating: "번역 중"
        case .completed: "완료"
        case .cancelled: "취소됨"
        case let .skipped(r): "건너뜀 · " + r.text
        case let .failed(m): "실패 · " + m
        }
    }

    var isActive: Bool { self == .translating || self == .waitingForModel }
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
    /// Statuses whose skip decision depends on the current settings.
    var isReevaluable: Bool {
        if self == .pending { return true }
        if case .skipped = self { return true }
        return false
    }
}

@MainActor
final class FileJob: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    let relativeDirectory: String

    @Published var status: JobStatus = .analyzing
    @Published var done = 0
    @Published private(set) var total = 0
    @Published private(set) var profile: LanguageProfile?
    @Published var outputURL: URL?

    private(set) var document: SubtitleDocument?
    private(set) var prepared: [PreparedCue] = []
    private(set) var fingerprint = ""
    /// State saved in a previous session / imported list, applied once analysis finishes.
    var restored: QueueSnapshot.Entry?

    var fileName: String { url.lastPathComponent }
    var fraction: Double {
        if status == .completed { return 1 }
        return total == 0 ? 0 : Double(done) / Double(total)
    }

    init(url: URL, relativeDirectory: String) {
        self.url = url
        self.relativeDirectory = relativeDirectory
    }

    func apply(_ analysis: Analysis) {
        document = analysis.document
        prepared = analysis.prepared
        profile = analysis.profile
        fingerprint = analysis.fingerprint
        total = analysis.prepared.reduce(0) { $0 + $1.parts.count }
    }
}

struct Analysis: Sendable {
    var document: SubtitleDocument
    var prepared: [PreparedCue]
    var profile: LanguageProfile
    var fingerprint: String
    var resumedCount: Int

    static func load(_ url: URL, targetKey: String) throws -> Analysis {
        let data = try Data(contentsOf: url)
        let document = SubtitleDocument.parse(try TextDecoding.decode(data))
        let prepared = document.cues.map(CueFormatter.prepare)
        let profile = LanguageDetector.profile(of: prepared.flatMap(\.parts))
        let fingerprint = AppStorage.sha256(data)
        let resumed = CheckpointStore.load(source: url, target: targetKey, fingerprint: fingerprint).count
        return Analysis(document: document, prepared: prepared, profile: profile,
                        fingerprint: fingerprint, resumedCount: resumed)
    }
}

struct QueueSummary: Equatable {
    var files = 0, completed = 0, active = 0, pending = 0, skipped = 0, failed = 0
    var totalSegments = 0, doneSegments = 0
    var fraction: Double { totalSegments == 0 ? 0 : Double(doneSegments) / Double(totalSegments) }
}

@MainActor
final class TranslationQueue: ObservableObject {
    static let shared = TranslationQueue()

    @Published private(set) var jobs: [FileJob] = []
    @Published private(set) var summary = QueueSummary()
    @Published private(set) var isRunning = false
    @Published private(set) var targets: [LanguageOption] = []
    @Published private(set) var segmentsPerSecond: Double = 0
    /// Shown after a previous session or an imported list was restored.
    @Published var restoreNotice: String?

    @Published var targetID: String {
        didSet { defaults.set(targetID, forKey: "targetID"); reevaluate(); refreshResumeCounts() }
    }
    @Published var maxConcurrent: Int {
        didSet { defaults.set(maxConcurrent, forKey: "maxConcurrent"); pump() }
    }
    @Published var overwriteExisting: Bool {
        didSet { defaults.set(overwriteExisting, forKey: "overwriteExisting"); reevaluate() }
    }
    @Published var autoStart: Bool {
        didSet { defaults.set(autoStart, forKey: "autoStart") }
    }
    @Published var outputContent: OutputContent {
        didSet { defaults.set(outputContent.rawValue, forKey: "outputContent") }
    }
    @Published var outputFormat: OutputFormat {
        didSet { defaults.set(outputFormat.rawValue, forKey: "outputFormat"); reevaluate() }
    }
    @Published var namingMode: NamingMode {
        didSet { defaults.set(namingMode.rawValue, forKey: "namingMode"); reevaluate() }
    }

    var outputOptions: OutputOptions {
        OutputOptions(content: outputContent, format: outputFormat, naming: namingMode)
    }

    let preparer = LanguagePreparer()

    private let defaults = UserDefaults.standard
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var knownPaths: Set<String> = []
    private var summaryScheduled = false
    private var rateSamples: [(Date, Int)] = []
    private var sessionSaveScheduled = false
    private var persistenceFrozen = false

    var hasRunningTasks: Bool { !tasks.isEmpty }

    var target: Locale.Language { Locale.Language(identifier: targetID) }

    private init() {
        let preferred = Locale.Language(identifier: Locale.preferredLanguages.first ?? "ko").minimalIdentifier
        targetID = defaults.string(forKey: "targetID") ?? preferred
        let saved = defaults.integer(forKey: "maxConcurrent")
        maxConcurrent = saved > 0 ? saved : 3
        overwriteExisting = defaults.bool(forKey: "overwriteExisting")
        autoStart = defaults.object(forKey: "autoStart") as? Bool ?? true
        outputContent = defaults.string(forKey: "outputContent").flatMap(OutputContent.init) ?? .translation
        outputFormat = defaults.string(forKey: "outputFormat").flatMap(OutputFormat.init) ?? .srt
        namingMode = defaults.string(forKey: "namingMode").flatMap(NamingMode.init) ?? .languageSuffix

        Task.detached(priority: .background) { CheckpointStore.prune() }
        if let snapshot = try? QueueSnapshot.read(from: QueueSnapshot.sessionURL), !snapshot.entries.isEmpty {
            targetID = snapshot.targetID
            restore(snapshot, source: "이전 세션")
        }
    }

    func loadLanguages() async {
        let languages = await LanguageAvailability().supportedLanguages
        var seen = Set<String>()
        targets = languages
            .map(LanguageOption.init)
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !targets.contains(where: { $0.id == targetID }) {
            let code = target.languageCode
            targetID = targets.first(where: { $0.language.languageCode == code })?.id
                ?? targets.first(where: { $0.id.hasPrefix("ko") })?.id
                ?? targets.first?.id ?? "ko"
        }
    }

    // MARK: Adding files

    func add(_ urls: [URL]) {
        Task {
            let found = await Task.detached(priority: .userInitiated) { Self.collectSubtitles(in: urls) }.value
            let newJobs = enqueue(found.map { FileJob(url: $0.url, relativeDirectory: $0.relativeDirectory) })
            if !newJobs.isEmpty, autoStart { isRunning = true }
        }
    }

    /// Adds jobs not already in the list and analyzes them one by one in the background.
    @discardableResult
    private func enqueue(_ candidates: [FileJob]) -> [FileJob] {
        let newJobs = candidates.filter { knownPaths.insert($0.url.standardizedFileURL.path).inserted }
        guard !newJobs.isEmpty else { return [] }
        jobs.append(contentsOf: newJobs)
        scheduleSummary()
        scheduleSessionSave()

        Task {
            for job in newJobs {
                let url = job.url, targetKey = targetID
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try Analysis.load(url, targetKey: targetKey) }
                }.value
                guard job.status == .analyzing else { continue } // removed/cancelled meanwhile
                switch result {
                case let .success(analysis):
                    job.apply(analysis)
                    job.done = targetKey == targetID ? analysis.resumedCount : 0
                    if let restored = restoredStatus(job) {
                        job.status = restored
                    } else {
                        job.status = analysis.profile.dominant == nil && job.total > 0
                            ? .failed("언어를 감지할 수 없음") : .pending
                    }
                case let .failure(error):
                    job.status = .failed(error.localizedDescription)
                }
                job.restored = nil
                reevaluate()
                pump()
            }
        }
        return newJobs
    }

    /// Finished states from a saved list are kept; everything else is re-queued (and resumes from its checkpoint).
    private func restoredStatus(_ job: FileJob) -> JobStatus? {
        guard let entry = job.restored else { return nil }
        switch entry.state {
        case .completed:
            guard let path = entry.outputPath, FileManager.default.fileExists(atPath: path) else { return nil }
            job.outputURL = URL(fileURLWithPath: path)
            return .completed
        case .failed: return .failed(entry.message ?? "")
        case .cancelled: return .cancelled
        case .pending, .skipped: return nil
        }
    }

    /// Checkpoints are per target language, so the resumable count changes with the target.
    private func refreshResumeCounts() {
        let targetKey = targetID
        let items = jobs.filter { $0.status == .pending || $0.status == .cancelled || $0.status.isFailed }
            .map { ($0, $0.url, $0.fingerprint) }
        Task {
            for (job, url, fingerprint) in items {
                let count = await Task.detached {
                    CheckpointStore.load(source: url, target: targetKey, fingerprint: fingerprint).count
                }.value
                if targetKey == targetID, !job.status.isActive { job.done = count }
            }
            scheduleSummary()
        }
    }

    nonisolated private static func collectSubtitles(in urls: [URL]) -> [(url: URL, relativeDirectory: String)] {
        let fm = FileManager.default
        var found: [(URL, String)] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                if url.pathExtension.lowercased() == "srt" {
                    found.append((url, url.deletingLastPathComponent().lastPathComponent))
                }
                continue
            }
            let rootPath = url.standardizedFileURL.path
            let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            var inFolder: [URL] = []
            while let item = enumerator?.nextObject() as? URL {
                if item.pathExtension.lowercased() == "srt" { inFolder.append(item) }
            }
            inFolder.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            for item in inFolder {
                let dir = item.deletingLastPathComponent().standardizedFileURL.path
                let relative = dir.hasPrefix(rootPath) ? String(dir.dropFirst(rootPath.count)) : dir
                found.append((item, url.lastPathComponent + relative))
            }
        }
        return found
    }

    // MARK: Control

    func start() {
        isRunning = true
        pump()
    }

    func pause() { isRunning = false }

    func stopAll() {
        isRunning = false
        for task in tasks.values { task.cancel() }
    }

    func retryFailed() {
        for job in jobs where (job.status.isFailed || job.status == .cancelled) && job.document != nil {
            job.status = .pending
        }
        reevaluate()
        pump()
    }

    func clearAll() {
        stopAll()
        jobs.removeAll()
        knownPaths.removeAll()
        restoreNotice = nil
        scheduleSummary()
        scheduleSessionSave()
    }

    func clearFinished() {
        jobs.removeAll { job in
            let remove: Bool
            switch job.status {
            case .completed, .skipped, .failed, .cancelled: remove = true
            default: remove = false
            }
            if remove { knownPaths.remove(job.url.standardizedFileURL.path) }
            return remove
        }
        scheduleSummary()
        scheduleSessionSave()
    }

    func remove(_ job: FileJob) {
        tasks[job.id]?.cancel()
        job.status = .cancelled
        jobs.removeAll { $0.id == job.id }
        knownPaths.remove(job.url.standardizedFileURL.path)
        reevaluate()
    }

    // MARK: Scheduling

    /// Re-decides pending/skipped files against the current target language and options.
    private func reevaluate() {
        var claimed = Set<String>()
        for job in jobs {
            if let out = job.outputURL, job.status.isActive || job.status == .completed {
                claimed.insert(out.standardizedFileURL.path)
            }
        }
        for job in jobs where job.status.isReevaluable {
            job.status = decide(job, claimed: &claimed)
        }
        scheduleSummary()
        scheduleSessionSave()
    }

    private func decide(_ job: FileJob, claimed: inout Set<String>) -> JobStatus {
        guard let profile = job.profile else { return job.status }
        if job.total == 0 { return .skipped(.nothingToTranslate) }
        if let source = profile.dominantLanguage, LanguageMatch.same(source, target) {
            return .skipped(.alreadyTarget)
        }
        let share = profile.share(of: target)
        if share >= 0.3 { return .skipped(.containsTarget(Int((share * 100).rounded()))) }

        let output = OutputNaming.outputURL(for: job.url, target: target, options: outputOptions)
        job.outputURL = output
        let path = output.standardizedFileURL.path
        if claimed.contains(path) { return .skipped(.outputConflict) }
        if let reason = existingFileConflict(job) { return .skipped(reason) }
        claimed.insert(path)
        return .pending
    }

    private func existingFileConflict(_ job: FileJob) -> SkipReason? {
        let fm = FileManager.default
        // Never overwrite an earlier backup: that would destroy the real original.
        if namingMode == .replaceOriginal, fm.fileExists(atPath: OutputNaming.backupURL(for: job.url).path) {
            return .backupExists
        }
        guard let output = job.outputURL,
              output.standardizedFileURL != job.url.standardizedFileURL, // replace mode writes over the source itself
              !overwriteExisting, fm.fileExists(atPath: output.path) else { return nil }
        return .outputExists
    }

    private func pump() {
        defer { scheduleSummary(); scheduleSessionSave() }
        guard isRunning else { return }
        while tasks.count < maxConcurrent, let job = jobs.first(where: { $0.status == .pending }) {
            // Re-check right before starting: files may have appeared in the meantime.
            if let reason = existingFileConflict(job) {
                job.status = .skipped(reason)
                continue
            }
            launch(job)
        }
        if tasks.isEmpty, !jobs.contains(where: { $0.status == .pending || $0.status == .analyzing }) {
            isRunning = false
        }
    }

    private func launch(_ job: FileJob) {
        guard let document = job.document, let source = job.profile?.dominantLanguage, let output = job.outputURL else {
            job.status = .failed("분석 정보 없음")
            return
        }
        let input = WorkInput(sourceURL: job.url, fingerprint: job.fingerprint, targetKey: targetID,
                              document: document, prepared: job.prepared, source: source, target: target, output: output,
                              options: outputOptions)
        let preparer = self.preparer
        let queue = self
        job.status = .translating

        tasks[job.id] = Task.detached(priority: .userInitiated) {
            let outcome: JobStatus
            do {
                _ = try await Worker.run(
                    input,
                    preparer: preparer,
                    phase: { status in await MainActor.run { if job.status.isActive { job.status = status } } },
                    progress: { count in await MainActor.run { job.done = count; queue.scheduleSummary() } }
                )
                outcome = .completed
            } catch {
                outcome = Task.isCancelled || error is CancellationError ? .cancelled : .failed(error.localizedDescription)
            }
            await MainActor.run {
                if job.status.isActive { job.status = outcome }
                queue.tasks[job.id] = nil
                queue.pump()
            }
        }
    }

    // MARK: Summary

    private func scheduleSummary() {
        guard !summaryScheduled else { return }
        summaryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                self?.summaryScheduled = false
                self?.recomputeSummary()
            }
        }
    }

    private func recomputeSummary() {
        var s = QueueSummary()
        s.files = jobs.count
        for job in jobs {
            switch job.status {
            case .completed:
                s.completed += 1; s.totalSegments += job.total; s.doneSegments += job.total
            case .translating, .waitingForModel:
                s.active += 1; s.totalSegments += job.total; s.doneSegments += job.done
            case .pending, .analyzing:
                s.pending += 1; s.totalSegments += job.total; s.doneSegments += job.done
            case .skipped:
                s.skipped += 1
            case .failed, .cancelled:
                s.failed += 1
            }
        }
        summary = s
        updateRate()
    }

    private func updateRate() {
        let now = Date()
        guard summary.active > 0 else { rateSamples.removeAll(); segmentsPerSecond = 0; return }
        rateSamples.append((now, summary.doneSegments))
        rateSamples.removeAll { now.timeIntervalSince($0.0) > 10 }
        if let first = rateSamples.first, let last = rateSamples.last, last.0 > first.0 {
            segmentsPerSecond = max(0, Double(last.1 - first.1) / last.0.timeIntervalSince(first.0))
        }
    }

    // MARK: Session persistence

    /// Restores a saved list. Nothing starts automatically; the user resumes from the notice.
    func restore(_ snapshot: QueueSnapshot, source: String) {
        let candidates = snapshot.entries.map { entry -> FileJob in
            let job = FileJob(url: URL(fileURLWithPath: entry.path), relativeDirectory: entry.relativeDirectory)
            job.restored = entry
            return job
        }
        let added = enqueue(candidates)
        guard !added.isEmpty else { return }
        let unfinished = added.filter { $0.restored?.state != .completed && $0.restored?.state != .skipped }.count
        restoreNotice = unfinished > 0
            ? "\(source)의 작업 \(added.count)개를 복원했습니다. 미완료 \(unfinished)개는 중단된 문장부터 이어서 번역합니다."
            : "\(source)의 작업 \(added.count)개를 복원했습니다."
    }

    func importSnapshot(from url: URL) throws {
        restore(try QueueSnapshot.read(from: url), source: url.lastPathComponent)
    }

    func exportSnapshot(to url: URL) throws {
        try makeSnapshot().write(to: url)
    }

    func makeSnapshot() -> QueueSnapshot {
        let entries = jobs.map { job -> QueueSnapshot.Entry in
            // Not analyzed yet: keep whatever state it was restored with.
            if job.status == .analyzing, let restored = job.restored { return restored }
            var entry = QueueSnapshot.Entry(path: job.url.path, relativeDirectory: job.relativeDirectory,
                                            state: .pending, outputPath: job.outputURL?.path)
            switch job.status {
            case .completed: entry.state = .completed
            case .skipped: entry.state = .skipped
            case .cancelled: entry.state = .cancelled
            case let .failed(message): entry.state = .failed; entry.message = message
            case .analyzing, .pending, .waitingForModel, .translating: entry.state = .pending
            }
            return entry
        }
        return QueueSnapshot(targetID: targetID, entries: entries)
    }

    private func scheduleSessionSave() {
        guard !sessionSaveScheduled, !persistenceFrozen else { return }
        sessionSaveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                self?.sessionSaveScheduled = false
                self?.saveSessionNow()
            }
        }
    }

    func saveSessionNow() {
        guard !persistenceFrozen else { return }
        if jobs.isEmpty {
            try? FileManager.default.removeItem(at: QueueSnapshot.sessionURL)
        } else {
            try? makeSnapshot().write(to: QueueSnapshot.sessionURL)
        }
    }

    /// On quit: save the list with running files as "pending", then cancel them so each
    /// worker flushes its checkpoint (bounded wait).
    func shutdown() async {
        saveSessionNow()
        persistenceFrozen = true
        let running = Array(tasks.values)
        running.forEach { $0.cancel() }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for task in running { await task.value } }
            group.addTask { try? await Task.sleep(for: .seconds(3)) }
            await group.next()
            group.cancelAll()
        }
    }
}
