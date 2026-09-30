import AppKit
import CryptoKit
import Foundation

/// Self-update from GitHub Releases, modelled on ziozzang/sugyeol:
/// latest release → version compare → asset download → SHA256SUMS check → replace → relaunch.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    static let repository = "ziozzang/jamak-trans"
    static let checkInterval: TimeInterval = 24 * 3600

    @Published var automaticallyChecks: Bool {
        didSet { defaults.set(automaticallyChecks, forKey: "autoCheckUpdates") }
    }
    /// Non-nil while downloading/installing; shown as a banner.
    @Published private(set) var progressText: String?

    private let defaults = UserDefaults.standard
    private var isBusy = false

    private init() {
        automaticallyChecks = defaults.object(forKey: "autoCheckUpdates") as? Bool ?? true
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: Checking

    func checkOnLaunch() {
        guard automaticallyChecks, ProcessInfo.processInfo.environment["JAMAK_TRANS_NO_UPDATE_CHECK"] == nil else { return }
        let last = defaults.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.checkInterval else { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let release = try await Self.fetchLatestRelease()
            defaults.set(Date(), forKey: "lastUpdateCheck")
            let latest = release.version
            guard Self.compareVersions(latest, Self.currentVersion) == .orderedDescending else {
                if userInitiated { inform("최신 버전을 사용 중입니다.", "현재 버전: \(Self.currentVersion)\n배포된 최신 버전: \(latest)") }
                return
            }
            if !userInitiated, defaults.string(forKey: "skippedVersion") == latest { return }
            switch askToInstall(release) {
            case .alertFirstButtonReturn: await install(release)
            case .alertThirdButtonReturn: defaults.set(latest, forKey: "skippedVersion")
            default: break
            }
        } catch {
            if userInitiated { inform("업데이트를 확인하지 못했습니다.", error.localizedDescription) }
        }
    }

    private func askToInstall(_ release: Release) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = "Jamak Trans \(release.version) 버전을 사용할 수 있습니다."
        var notes = (release.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.count > 1200 { notes = String(notes.prefix(1200)) + "…" }
        alert.informativeText = "현재 버전: \(Self.currentVersion)\n\n" + notes
        alert.addButton(withTitle: "업데이트 후 다시 시작")
        alert.addButton(withTitle: "나중에")
        alert.addButton(withTitle: "이 버전 건너뛰기")
        return alert.runModal()
    }

    private func inform(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    // MARK: Installing

    private func install(_ release: Release) async {
        do {
            let newApp = try await downloadAndVerify(release)
            try relaunch(replacingWith: newApp)
        } catch {
            progressText = nil
            inform("업데이트에 실패했습니다.", error.localizedDescription)
        }
    }

    private func downloadAndVerify(_ release: Release) async throws -> URL {
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app" else { throw UpdateError.notBundled }
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw UpdateError.notWritable(target.deletingLastPathComponent().path)
        }

        let assetName = Self.assetName(for: release.version)
        guard let asset = release.assets.first(where: { $0.name == assetName }) else { throw UpdateError.missingAsset(assetName) }
        guard let sums = release.assets.first(where: { $0.name == "SHA256SUMS" }) else { throw UpdateError.missingAsset("SHA256SUMS") }

        progressText = "체크섬 가져오는 중…"
        let (sumData, _) = try await URLSession.shared.data(from: sums.url)
        guard let expected = Self.parseChecksums(String(decoding: sumData, as: UTF8.self))[assetName] else {
            throw UpdateError.missingChecksum(assetName)
        }

        // Same volume as the installed app, so the final move is a rename.
        let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: target, create: true)
        let zip = work.appendingPathComponent(assetName)
        let actual = try await download(asset, to: zip)
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            throw UpdateError.checksumMismatch(assetName, actual, expected)
        }

        progressText = "압축 푸는 중…"
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, work.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0,
              let app = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }),
              let bundle = Bundle(url: app) else { throw UpdateError.badArchive }
        guard bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              bundle.infoDictionary?["CFBundleShortVersionString"] as? String == release.version else {
            throw UpdateError.badArchive
        }
        return app
    }

    /// Streams the asset to disk while hashing it; returns the SHA-256 hex digest.
    private func download(_ asset: Release.Asset, to file: URL) async throws -> String {
        let (bytes, response) = try await URLSession.shared.bytes(from: asset.url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.http }
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }

        let expectedSize = max(asset.size, response.expectedContentLength)
        var hasher = SHA256()
        var buffer = Data(capacity: 1 << 16)
        var received: Int64 = 0
        var lastPercent = -1
        for try await byte in bytes {
            buffer.append(byte)
            guard buffer.count == 1 << 16 else { continue }
            hasher.update(data: buffer); try handle.write(contentsOf: buffer)
            received += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
            let percent = expectedSize > 0 ? Int(received * 100 / expectedSize) : 0
            if percent != lastPercent { lastPercent = percent; progressText = "업데이트 다운로드 중… \(percent)%" }
        }
        hasher.update(data: buffer); try handle.write(contentsOf: buffer)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A detached shell script waits for this process to quit, swaps the bundle and reopens it.
    /// Quitting goes through the normal terminate path, so the queue and checkpoints are saved first.
    private func relaunch(replacingWith newApp: URL) throws {
        progressText = "설치 후 다시 시작하는 중…"
        let script = """
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        rm -rf "$TARGET.old"
        if mv "$TARGET" "$TARGET.old" && mv "$NEW" "$TARGET"; then
          rm -rf "$TARGET.old"
        else
          [ -e "$TARGET" ] || mv "$TARGET.old" "$TARGET"
        fi
        xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
        open "$TARGET"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = [
            "PID": String(ProcessInfo.processInfo.processIdentifier),
            "TARGET": Bundle.main.bundleURL.path,
            "NEW": newApp.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        try process.run()
        NSApp.terminate(nil)
    }

    // MARK: GitHub

    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let url: URL
            let size: Int64
            enum CodingKeys: String, CodingKey { case name, size, url = "browser_download_url" }
        }
        let tagName: String
        let notes: String?
        let assets: [Asset]
        enum CodingKeys: String, CodingKey { case assets, notes = "body", tagName = "tag_name" }

        var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }
    }

    static func fetchLatestRelease() async throws -> Release {
        // JAMAK_TRANS_UPDATE_API points the check at a test server instead of api.github.com.
        let api = ProcessInfo.processInfo.environment["JAMAK_TRANS_UPDATE_API"] ?? "https://api.github.com"
        var request = URLRequest(url: URL(string: "\(api)/repos/\(repository)/releases/latest")!)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("jamak-trans-selfupdate", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.http }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    static func assetName(for version: String) -> String { "JamakTrans_\(version)_macos_universal.zip" }

    /// `sha256sum` format: "<64 hex>  <file name>"
    static func parseChecksums(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[0].count == 64 else { continue }
            result[String(fields[1]).trimmingCharacters(in: CharacterSet(charactersIn: "*"))] = fields[0].lowercased()
        }
        return result
    }

    /// Numeric dot-separated compare; ignores a leading "v" and any "-pre"/"+build" suffix.
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ s: String) -> [Int] {
            var core = s.hasPrefix("v") ? String(s.dropFirst()) : s
            if let cut = core.firstIndex(where: { $0 == "-" || $0 == "+" }) { core = String(core[..<cut]) }
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

enum UpdateError: LocalizedError {
    case http, notBundled, badArchive
    case notWritable(String)
    case missingAsset(String)
    case missingChecksum(String)
    case checksumMismatch(String, String, String)

    var errorDescription: String? {
        switch self {
        case .http: "GitHub에서 릴리스 정보를 가져오지 못했습니다."
        case .notBundled: "앱 번들(.app)로 실행할 때만 업데이트할 수 있습니다."
        case .badArchive: "내려받은 업데이트 파일이 올바르지 않습니다."
        case let .notWritable(path): "\(path) 폴더에 쓸 권한이 없어 업데이트할 수 없습니다."
        case let .missingAsset(name): "릴리스에 \(name) 파일이 없습니다."
        case let .missingChecksum(name): "SHA256SUMS에 \(name) 항목이 없습니다."
        case let .checksumMismatch(name, got, want): "\(name) 체크섬이 맞지 않습니다.\n받은 값: \(got)\n기대 값: \(want)"
        }
    }
}
