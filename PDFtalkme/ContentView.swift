//
//  ContentView.swift
//  PDFtalkme
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import PDFKit
#if os(macOS)
import AppKit
#endif

/// Two-pane PDFtalkme window: PDF reader on the left, SilicIA chat on the right.
/// A single PDF is the only RAG context the chat sees.
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Binding var sharedPDFs: [URL]

    @StateObject private var chatService = ChatService()
    @State private var sharedURLs: [String] = []
    @State private var sharedImages: [URL] = []

    /// PDF currently displayed in the left pane. Kept independent from
    /// `sharedPDFs` because `ChatView` treats `sharedPDFs` as a transient
    /// inbox (it consumes it then calls `removeAll`).
    @State private var displayedPDFURL: URL?

    @State private var focusedCitationRequest: PDFCitationFocusRequest?
    @State private var findRequest: PDFFindRequest?
    @State private var sidebarRefreshRequestID = UUID()
    @State private var selectionText = ""

    /// Persisted PDF-pane width. Using a custom split (HStack + draggable
    /// divider) instead of `HSplitView`, which re-balances proportionally
    /// whenever a child's intrinsic size changes (sheet, settings, picker)
    /// — that caused the pane widths to drift on every interaction.
    @AppStorage("pdftalkme.pdfPaneWidth") private var pdfPaneWidth: Double = 760

    private let minPaneWidth: CGFloat = 360
    private let dividerHitWidth: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                pdfPane
                    .frame(width: clampedPDFPaneWidth(for: geo.size.width))

                splitter(totalWidth: geo.size.width)

                chatPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openWindow(id: "main")
                } label: {
                    Label("New Window", systemImage: "plus.square.on.square")
                }
                .help("Open a new PDFtalkme window with an empty PDF view and a new conversation")
            }
        }
        .onChange(of: sharedPDFs) { _, newValue in
            if let first = newValue.first(where: { $0.pathExtension.lowercased() == "pdf" }) {
                displayedPDFURL = first
            }
        }
    }

    private func clampedPDFPaneWidth(for total: CGFloat) -> CGFloat {
        let maxAllowed = max(minPaneWidth, total - minPaneWidth - dividerHitWidth)
        return min(max(CGFloat(pdfPaneWidth), minPaneWidth), maxAllowed)
    }

    /// Vertical hairline with an enlarged hit region for dragging.
    private func splitter(totalWidth: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: dividerHitWidth)
            .overlay(
                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 1)
            )
#if os(macOS)
            .onHover { inside in
                if inside {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
#endif
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let proposed = CGFloat(pdfPaneWidth) + value.translation.width
                        let maxAllowed = max(minPaneWidth, totalWidth - minPaneWidth - dividerHitWidth)
                        pdfPaneWidth = Double(min(max(proposed, minPaneWidth), maxAllowed))
                    }
            )
    }

    private var pdfPane: some View {
        Group {
            if displayedPDFURL != nil {
                PDFDocumentView(
                    pdfURL: displayedPDFURL,
                    focusedCitationRequest: focusedCitationRequest,
                    sidebarRefreshRequestID: sidebarRefreshRequestID,
                    findRequest: findRequest,
                    onSelectionChanged: { selectionText = $0 },
                    onDropPDFURLs: { urls in
                        if let first = urls.first { loadPDF(first) }
                    },
                    onSidebarDataUpdated: { _, _, _ in },
                    onFindStatusUpdated: { _, _ in }
                )
            } else {
                PDFEmptyState(
                    onPickPDF: { urls in
                        if let first = urls.first { loadPDF(first) }
                    },
                    onChooseTapped: presentOpenPanel
                )
            }
        }
    }

    private var chatPane: some View {
        ChatView(
            sharedURLs: $sharedURLs,
            sharedPDFs: $sharedPDFs,
            sharedImages: $sharedImages,
            chatService: chatService,
            mode: .pdfTalkme
        )
    }

    private func loadPDF(_ url: URL) {
        displayedPDFURL = url
        sharedPDFs = [url]
    }

    private func presentOpenPanel() {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.pdf]
        panel.prompt = "Open"
        panel.message = "Choose a PDF to open in PDFtalkme."
        if panel.runModal() == .OK, let url = panel.url {
            loadPDF(url)
        }
#endif
    }
}

/// Empty-state pane shown before any PDF is loaded.
private struct PDFEmptyState: View {
    let onPickPDF: ([URL]) -> Void
    let onChooseTapped: () -> Void
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop a PDF here to start")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button("Choose PDF…", action: onChooseTapped)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .background(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            loadPDFURLs(from: providers, completion: onPickPDF)
            return true
        }
    }

    private func loadPDFURLs(
        from providers: [NSItemProvider],
        completion: @escaping ([URL]) -> Void
    ) {
        let group = DispatchGroup()
        var results: [URL] = []
        let lock = NSLock()
        for provider in providers {
            group.enter()
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                defer { group.leave() }
                guard let data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      url.pathExtension.lowercased() == "pdf" else { return }
                lock.lock()
                results.append(url)
                lock.unlock()
            }
        }
        group.notify(queue: .main) {
            if !results.isEmpty { completion(results) }
        }
    }
}

#Preview {
    ContentView(sharedPDFs: .constant([]))
        .frame(width: 1400, height: 900)
}
