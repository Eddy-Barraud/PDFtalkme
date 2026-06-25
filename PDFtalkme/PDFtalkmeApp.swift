//
//  PDFtalkmeApp.swift
//  PDFtalkme
//

import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

@main
struct PDFtalkmeApp: App {
    init() {
    }

    @State private var sharedPDFs: [URL] = []
    @State private var modelUnavailableMessage: String?

#if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
#endif

    var body: some Scene {
        WindowGroup(id: "main") {

            ContentView(sharedPDFs: $sharedPDFs)
                .onOpenURL(perform: handleIncomingURL)
#if os(macOS)
                .onAppear {
                    appDelegate.onOpenURLs = { urls in
                        handleIncomingURLs(urls)
                    }
                    let pending = appDelegate.drainPendingURLs()
                    if !pending.isEmpty {
                        handleIncomingURLs(pending)
                    }
                }
#endif
        }
        .defaultSize(width: 1460, height: 940)
        .modelContainer(for: [Conversation.self, Message.self])
#if os(macOS)
        .commands {
            CommandMenu("Find") {
                Button("Find in PDF") {
                    NotificationCenter.default.post(name: .pdfTalkmeOpenFind, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }
#endif
    }

    private func handleIncomingURL(_ url: URL) {
        handleIncomingURLs([url])
    }

    private func handleIncomingURLs(_ urls: [URL]) {
        if let firstPDF = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) {
            sharedPDFs = [firstPDF]
        }
    }
}

#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onOpenURLs: (([URL]) -> Void)?
    private var pendingURLs: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        if let onOpenURLs {
            onOpenURLs(urls)
        } else {
            pendingURLs.append(contentsOf: urls)
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        if let onOpenURLs {
            onOpenURLs([url])
        } else {
            pendingURLs.append(url)
        }
        return true
    }

    func drainPendingURLs() -> [URL] {
        defer { pendingURLs.removeAll() }
        return pendingURLs
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
#endif
