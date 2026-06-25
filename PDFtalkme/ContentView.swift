//
//  ContentView.swift
//  PDFtalkme
//

import SwiftUI
import SwiftData
import Combine
import UniformTypeIdentifiers
import PDFKit
#if os(macOS)
import AppKit
#endif

/// Two-pane PDFtalkme window: PDF reader on the left (with a tab strip for
/// multiple open PDFs), SilicIA chat on the right. All open tabs are fed
/// to ChatService as RAG context; the chat is anchored to the first tab,
/// which is what gets stored on the Conversation for reopen-by-filename.
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Binding var sharedPDFs: [URL]

    @StateObject private var chatService = ChatService()
    @State private var sharedURLs: [String] = []
    @State private var sharedImages: [URL] = []

    @State private var openTabs: [PDFTab] = []
    @State private var selectedTabID: UUID?

    @State private var focusedCitationRequest: PDFCitationFocusRequest?
    @State private var findRequest: PDFFindRequest?
    @State private var sidebarRefreshRequestID = UUID()
    @State private var selectionText = ""
    @State private var checksumTask: Task<Void, Never>?
    /// Publisher used to ask `ChatView` to drop a PDF context row when the
    /// user closes the matching tab on the left. We hold the subject so it
    /// outlives view updates; `ChatView` subscribes once via `.onReceive`.
    @State private var pdfRemovalSubject = PassthroughSubject<URL, Never>()

    /// Drives the floating page / search controls and bridges to the live
    /// PDFView. One per window.
    @State private var previewController = PDFPreviewController()

    /// PDF pane width as a fraction of the window's content width. Storing
    /// a ratio (rather than an absolute width) means a window resize keeps
    /// the two panes' relative proportions automatically.
    @AppStorage("pdftalkme.pdfPaneFraction") private var pdfPaneFraction: Double = 0.62
    /// Pane width captured at the start of a splitter drag, so the drag
    /// tracks the cursor 1:1 instead of compounding `translation` against a
    /// width we're mutating every frame.
    @State private var dragStartPaneWidth: CGFloat?

    private let minPaneWidth: CGFloat = 360
    private let dividerHitWidth: CGFloat = 6

    private var displayedPDFURL: URL? {
        openTabs.first(where: { $0.id == selectedTabID })?.url
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                pdfPane
                    .frame(width: pdfPaneWidth(for: geo.size.width))

                splitter(totalWidth: geo.size.width)

                chatPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 600)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    clearWindow()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .help("Close all PDFs and start a new conversation")

                Button {
                    openWindow(id: "main")
                } label: {
                    Label("New Window", systemImage: "plus.square.on.square")
                }
                .help("Open a new PDFtalkme window with an empty PDF view and a new conversation")
            }
        }
        .onAppear {
            previewController.onRequestPaneWidth = { desired in
                applyPaneWidth(desired)
            }
        }
        .onChange(of: sharedPDFs) { _, newValue in
            for url in newValue where url.pathExtension.lowercased() == "pdf" {
                addTab(for: url, makeActive: true)
            }
        }
        // React to the chat service switching conversations. The filename
        // is the source of truth — `currentConversationPDFBookmark` resolves
        // to a URL whose path can differ byte-for-byte from the URL the tab
        // was opened with (sandbox-container symlinks, security-scope
        // normalization). If a tab with that filename is already open we do
        // *nothing*: the tab was added on drop/pick before sendMessage ran,
        // and re-pushing `sharedPDFs` here would make `ChatView.mergeShared`
        // run a second time mid-streaming and risk a `resetConversation`.
        // Mirror the full PDF set of the active conversation into tabs.
        // When restoring a chat that had multiple documents in context,
        // every one of them needs to come back. We never close existing
        // tabs here — the user may have an unrelated PDF open they want
        // to keep — and we never yank the current selection.
        .onReceive(chatService.$currentConversationPDFFilenames.removeDuplicates()) { filenames in
            guard !filenames.isEmpty else { return }
            let bookmarks = chatService.currentConversationPDFBookmarks
            var addedAny = false
            for (index, name) in filenames.enumerated() {
                let key = ChatService.pdfBaseFilename(name)
                if openTabs.contains(where: {
                    ChatService.pdfBaseFilename($0.url.lastPathComponent) == key
                }) {
                    continue
                }
                guard index < bookmarks.count,
                      let url = resolveSecurityScopedBookmark(bookmarks[index]) else { continue }
                // makeActive only on the very first restored tab when the
                // window currently has no selection — otherwise leave the
                // user's selection where it is.
                let shouldActivate = !addedAny && selectedTabID == nil
                addTab(for: url, makeActive: shouldActivate)
                addedAny = true
            }
        }
        // When a new chat is started (conversation reset), re-register all
        // currently open PDF tabs as context sources. This handles the case
        // where the user clicks "New Chat" while PDFs are open in tabs —
        // the new conversation should automatically include those PDFs.
        // Watch for when the conversation is reset (filename becomes nil)
        // and there are still open tabs — re-push the PDFs so they're
        // available as context for the new chat.
        .onReceive(chatService.$currentConversationPDFFilename.removeDuplicates()) { filename in
            if filename == nil && !openTabs.isEmpty {
                // Small delay to avoid race condition with startOver() clearing sharedPDFs
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if !openTabs.isEmpty && chatService.currentConversationPDFFilename == nil {
                        sharedPDFs = openTabs.map(\.url)
                    }
                }
            }
        }
    }

    // MARK: - Panes

    private var pdfPane: some View {
        VStack(spacing: 0) {
            if !openTabs.isEmpty {
                tabStrip
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                Divider()
            }
            if let displayedPDFURL {
                PDFDocumentView(
                    pdfURL: displayedPDFURL,
                    focusedCitationRequest: focusedCitationRequest,
                    sidebarRefreshRequestID: sidebarRefreshRequestID,
                    findRequest: findRequest,
                    previewController: previewController,
                    onSelectionChanged: { selectionText = $0 },
                    onDropPDFURLs: { urls in
                        for u in urls { loadPDF(u) }
                    },
                    onSidebarDataUpdated: { _, _, _ in },
                    onFindStatusUpdated: { _, _ in }
                )
                .overlay(alignment: .bottom) {
                    PDFFloatingControls(controller: previewController)
                        .padding(.bottom, 14)
                }
                .overlay(alignment: .topTrailing) {
                    PDFSearchBar(controller: previewController)
                        .padding(.top, 12)
                        .padding(.trailing, 14)
                }
            } else {
                PDFEmptyState(
                    onPickPDF: { urls in
                        for u in urls { loadPDF(u) }
                    },
                    onChooseTapped: presentOpenPanel
                )
            }
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(openTabs) { tab in
                    tabChip(tab)
                }
                Button {
                    presentOpenPanel()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .help("Open another PDF in a new tab")
            }
        }
    }

    private func tabChip(_ tab: PDFTab) -> some View {
        let isSelected = tab.id == selectedTabID
        return HStack(spacing: 6) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(tab.title)
                .lineLimit(1)
                .font(.system(size: 12))
            Button {
                closeTab(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(2)
            }
            .buttonStyle(.plain)
            .help("Close tab")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedTabID = tab.id
        }
    }

    private var chatPane: some View {
        ChatView(
            sharedURLs: $sharedURLs,
            sharedPDFs: $sharedPDFs,
            sharedImages: $sharedImages,
            chatService: chatService,
            mode: .pdfTalkme,
            onPDFAddedToContext: { url in
                handlePDFAddedFromChat(url)
            },
            onPDFRemovedFromContext: { url in
                closeTabMatching(url)
            },
            pdfRemovalRequests: pdfRemovalSubject.eraseToAnyPublisher()
        )
    }

    /// Removes any tab whose base filename matches `url` — used when
    /// `ChatView` reports that the user clicked × on a PDF context row.
    private func closeTabMatching(_ url: URL) {
        let key = ChatService.pdfBaseFilename(url.lastPathComponent)
        guard let tab = openTabs.first(where: {
            ChatService.pdfBaseFilename($0.url.lastPathComponent) == key
        }) else { return }
        closeTab(tab, alsoRemoveFromChat: false)
    }

    // MARK: - Splitter

    /// Resolves the stored fraction to an absolute pane width for a given
    /// window content width, clamped so neither pane collapses below
    /// `minPaneWidth`.
    private func pdfPaneWidth(for total: CGFloat) -> CGFloat {
        let maxAllowed = max(minPaneWidth, total - minPaneWidth - dividerHitWidth)
        let raw = CGFloat(pdfPaneFraction) * total
        return min(max(raw, minPaneWidth), maxAllowed)
    }

    /// Sizes the PDF pane to exactly `desired` points and grows/shrinks the
    /// window by the matching delta so the chat pane keeps its width and the
    /// window height is preserved. Used by single-page (full-height) layout
    /// to reveal a whole page. Updates the fraction against the *new* total
    /// so a later window resize keeps the proportion.
    private func applyPaneWidth(_ desired: CGFloat) {
#if os(macOS)
        guard let window = previewController.pdfView?.window,
              let content = window.contentView else { return }
        let total = content.bounds.width
        let currentPaneWidth = pdfPaneWidth(for: total)
        let target = max(minPaneWidth, desired)
        let delta = target - currentPaneWidth
        guard abs(delta) > 0.5 else { return }

        let newTotal = total + delta
        pdfPaneFraction = Double(target / newTotal)

        var frame = window.frame
        // setFrame origin is bottom-left; growing width while keeping
        // origin.y preserves the top edge and the height.
        frame.size.width += delta
        window.setFrame(frame, display: true, animate: true)
#endif
    }

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
                        let start = dragStartPaneWidth ?? pdfPaneWidth(for: totalWidth)
                        if dragStartPaneWidth == nil { dragStartPaneWidth = start }
                        let proposed = start + value.translation.width
                        let maxAllowed = max(minPaneWidth, totalWidth - minPaneWidth - dividerHitWidth)
                        let clamped = min(max(proposed, minPaneWidth), maxAllowed)
                        pdfPaneFraction = Double(clamped / max(totalWidth, 1))
                    }
                    .onEnded { _ in dragStartPaneWidth = nil }
            )
    }

    // MARK: - Tab management

    /// Adds `url` as a new tab (or selects the existing one) and pushes the
    /// full open-tab list into `ChatView` so every PDF is part of the RAG
    /// context. Conversation restore happens only when the user explicitly
    /// picks one from history — not on drop / pick — so we no longer try
    /// to auto-load a prior chat here.
    private func addTab(for url: URL, makeActive: Bool) {
        if let existing = openTabs.first(where: { sameFile($0.url, url) }) {
            if makeActive { selectedTabID = existing.id }
        } else {
            let tab = PDFTab(url: url)
            openTabs.append(tab)
            if makeActive { selectedTabID = tab.id }
        }
        chatService.modelContext = modelContext

        // Push every open tab as RAG context. `ChatView.mergeShared` will
        // either attach (if any incoming PDF matches the active conv's
        // anchor) or reset (if the conv is unrelated / nil).
        sharedPDFs = openTabs.map(\.url)

        startBackgroundChecksum(for: openTabs.first?.url ?? url)
    }

    /// Closes a tab. `alsoRemoveFromChat: true` (default) also tells
    /// `ChatView` to drop the matching PDF context row — that's what the
    /// user expects when they click × on the tab. `false` is used for the
    /// inverse direction, when `ChatView` already removed the row and we
    /// just need to mirror the close.
    private func closeTab(_ tab: PDFTab, alsoRemoveFromChat: Bool = true) {
        guard let index = openTabs.firstIndex(of: tab) else { return }
        openTabs.remove(at: index)
        if alsoRemoveFromChat {
            pdfRemovalSubject.send(tab.url)
        }
        if openTabs.isEmpty {
            // Last tab closed — same effect as the trash button.
            clearWindow()
        } else if selectedTabID == tab.id {
            selectedTabID = openTabs.indices.contains(index)
                ? openTabs[index].id
                : openTabs.last?.id
        }
    }

    /// Toolbar "Clear" — wipe the window back to a fresh state: no tabs,
    /// no displayed PDF, brand-new chat conversation.
    private func clearWindow() {
        checksumTask?.cancel()
        openTabs.removeAll()
        selectedTabID = nil
        sharedPDFs = []
        chatService.resetConversation()
    }

    // MARK: - PDF entry points

    /// Drop / picker / external open on the *left* side. The PDF isn't yet
    /// in `ChatView`'s context — `addTab` will push it via `sharedPDFs`.
    private func loadPDF(_ url: URL) {
        addTab(for: url, makeActive: true)
    }

    /// `ChatView` itself ingested a PDF (drop on the chat pane, or shared
    /// inbox). The file is already in chat context — just mirror it as a
    /// tab on the left.
    private func handlePDFAddedFromChat(_ url: URL) {
        if !openTabs.contains(where: { sameFile($0.url, url) }) {
            let tab = PDFTab(url: url)
            openTabs.append(tab)
            selectedTabID = tab.id
        } else if selectedTabID == nil {
            selectedTabID = openTabs.first(where: { sameFile($0.url, url) })?.id
        }
        chatService.modelContext = modelContext
        startBackgroundChecksum(for: openTabs.first?.url ?? url)
    }

    private func startBackgroundChecksum(for url: URL) {
        checksumTask?.cancel()
        let filename = url.lastPathComponent
        // Capture the service as a non-Sendable reference via a local. The
        // hashing itself runs nonisolated; the stamp hops back to MainActor.
        let service = chatService
        checksumTask = Task.detached(priority: .utility) {
            guard let checksum = PDFFingerprint.sha256(of: url) else { return }
            await MainActor.run {
                guard service.currentConversationPDFFilename == filename else { return }
                service.updateCurrentConversationChecksum(checksum)
            }
        }
    }

    // MARK: - Open panel / bookmarks

    private func presentOpenPanel() {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.pdf]
        panel.prompt = "Open"
        panel.message = "Choose one or more PDFs to open in PDFtalkme."
        if panel.runModal() == .OK {
            for url in panel.urls {
                loadPDF(url)
            }
        }
#endif
    }

    /// Two URLs point at the "same" PDF for tab-deduplication purposes if
    /// their base names match (filename minus the `" (N)"` copy suffix
    /// `DroppedPDFStore` adds). Path comparison would fail on sandbox
    /// symlinks / security-scope wrappers, and raw `lastPathComponent`
    /// comparison would fail when SilicIA re-persists a re-dropped file as
    /// `X (2).pdf`. Base-name matching is what the wider conversation
    /// linking model already uses (see `ChatService.pdfBaseFilename`).
    private func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        ChatService.pdfBaseFilename(lhs.lastPathComponent)
            == ChatService.pdfBaseFilename(rhs.lastPathComponent)
    }

    private func resolveSecurityScopedBookmark(_ bookmark: Data) -> URL? {
        var isStale = false
#if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
#else
        let options: URL.BookmarkResolutionOptions = []
#endif
        return try? URL(
            resolvingBookmarkData: bookmark,
            options: options,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
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
