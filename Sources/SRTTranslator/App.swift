import AppKit
import SwiftUI

@main
struct SRTTranslatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Jamak Trans — 자막 번역기", id: "main") {
            ContentView(queue: .shared)
        }
        .defaultSize(width: 980, height: 640)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("업데이트 확인…") { Task { await Updater.shared.check(userInitiated: true) } }
                AutoUpdateToggle(updater: .shared)
            }
            CommandGroup(replacing: .newItem) {
                Button("파일 추가…") { Panels.addFiles() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("작업 목록 저장…") { Panels.exportQueue() }.keyboardShortcut("s")
                Button("작업 목록 불러오기…") { Panels.importQueue() }.keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // Give the window a moment to appear before a possible update prompt.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated { Updater.shared.checkOnLaunch() }
        }
    }

    /// Files/folders dropped on the Dock icon or opened with "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { TranslationQueue.shared.add(urls) }
    }

    /// Saves the queue and lets running files flush their checkpoints before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let queue = TranslationQueue.shared
            guard queue.hasRunningTasks else {
                queue.saveSessionNow()
                return .terminateNow
            }
            Task {
                await queue.shutdown()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

private struct AutoUpdateToggle: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Toggle("자동으로 업데이트 확인", isOn: $updater.automaticallyChecks)
    }
}
