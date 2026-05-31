//
//  PDFPreviewController.swift
//  PDFtalkme
//

import SwiftUI
import Observation
import PDFKit
#if os(macOS)
import AppKit
#endif

/// Page-layout mode for the preview pane.
enum PDFPageLayout {
    /// Vertically scrolling, all pages stacked (the default reading view).
    case continuousScroll
    /// One page at a time, sized to fit the pane height. Switching to this
    /// mode asks the host to widen the window so a full page is visible.
    case singlePageHeight
}

/// Bridges the SwiftUI floating controls to the live `PDFView` owned by
/// `PDFDocumentView`. The representable registers its `PDFView` here on
/// `makeNSView`; the controls read `@Published` state and call the action
/// methods. One instance per preview pane (per window).
///
/// Uses the modern `@Observable` macro rather than `ObservableObject`:
/// under this target's concurrency flags (`InferIsolatedConformances` +
/// `-default-isolation=MainActor`), an `ObservableObject` conformance is
/// inferred as main-actor-isolated, which `@ObservedObject` rejects.
/// `@Observable` sidesteps that entirely and is the recommended path on
/// macOS 26.
@Observable
final class PDFPreviewController {
    // Navigation
    var currentPage: Int = 1
    var totalPages: Int = 0
    /// Text-field mirror of `currentPage`. Kept separate so the user can
    /// type freely (including transient invalid values) without yanking the
    /// document until they commit.
    var pageFieldText: String = "1"

    // Layout
    var layout: PDFPageLayout = .continuousScroll

    // Search
    var searchQuery: String = ""
    var matchCount: Int = 0
    /// 1-based index of the focused match, or 0 when there are none.
    var currentMatch: Int = 0

    /// The live PDFView, set by `PDFDocumentView.makeNSView`. Excluded from
    /// observation — it's an imperative handle, not view state.
    @ObservationIgnored weak var pdfView: PDFView?
    /// Called when single-page mode wants the host to resize the PDF pane
    /// (and window) so one full page fits at the current height. The value
    /// is the desired PDF-pane width in points.
    @ObservationIgnored var onRequestPaneWidth: ((CGFloat) -> Void)?

    @ObservationIgnored private var pageObserver: NSObjectProtocol?
    @ObservationIgnored private var matches: [PDFSelection] = []

    // MARK: - Registration

    /// Connects a freshly created `PDFView` and starts observing its page
    /// changes so `currentPage` tracks scrolling.
    func attach(_ pdfView: PDFView) {
        self.pdfView = pdfView
        if let pageObserver {
            NotificationCenter.default.removeObserver(pageObserver)
        }
        pageObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged,
            object: pdfView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncCurrentPageFromView() }
        }
    }

    /// Refreshes `totalPages` / `currentPage` after a document loads.
    func documentDidChange() {
        guard let document = pdfView?.document else {
            totalPages = 0
            currentPage = 1
            pageFieldText = "1"
            clearSearch()
            return
        }
        totalPages = document.pageCount
        syncCurrentPageFromView()
        clearSearch()
    }

    private func syncCurrentPageFromView() {
        guard let pdfView, let page = pdfView.currentPage,
              let document = pdfView.document else { return }
        let index = document.index(for: page)
        currentPage = index + 1
        pageFieldText = "\(currentPage)"
    }

    // MARK: - Navigation

    func goToPage(_ oneBased: Int) {
        guard let pdfView, let document = pdfView.document else { return }
        let clamped = min(max(oneBased, 1), document.pageCount)
        guard let page = document.page(at: clamped - 1) else { return }
        pdfView.go(to: page)
        currentPage = clamped
        pageFieldText = "\(clamped)"
    }

    /// Commits whatever the user typed in the page field.
    func commitPageField() {
        if let value = Int(pageFieldText.trimmingCharacters(in: .whitespaces)) {
            goToPage(value)
        } else {
            // Reject junk — restore the field to the real page.
            pageFieldText = "\(currentPage)"
        }
    }

    func nextPage() {
        guard let pdfView else { return }
        if pdfView.canGoToNextPage { pdfView.goToNextPage(nil) }
        syncCurrentPageFromView()
    }

    func previousPage() {
        guard let pdfView else { return }
        if pdfView.canGoToPreviousPage { pdfView.goToPreviousPage(nil) }
        syncCurrentPageFromView()
    }

    // MARK: - Layout

    func toggleLayout() {
        setLayout(layout == .continuousScroll ? .singlePageHeight : .continuousScroll)
    }

    /// Resizes the window so one full page fits at the current pane height,
    /// *without* changing the scroll/display mode. Useful in continuous
    /// scroll to size the column to a whole page width on demand.
    func fitWindowToPageHeight() {
        fitPaneToCurrentPage()
    }

    func setLayout(_ newLayout: PDFPageLayout) {
        layout = newLayout
        guard let pdfView else { return }

        switch newLayout {
        case .continuousScroll:
            pdfView.displayMode = .singlePageContinuous
            pdfView.autoScales = true
        case .singlePageHeight:
            pdfView.displayMode = .singlePage
            // Let PDFKit fit the *entire* page inside the view — this never
            // crops. We then size the pane to the page's aspect ratio so the
            // fit is bound by height (full-height page) with no side gaps.
            pdfView.autoScales = true
            fitPaneToCurrentPage()
        }
    }

    /// Asks the host to size the PDF pane to the current page's aspect ratio
    /// at the present pane height, so one full page fills the height. Because
    /// `autoScales` fits the whole page, an aspect-matched pane shows the
    /// page edge-to-edge without clipping the right side.
    private func fitPaneToCurrentPage() {
        guard let pdfView,
              let page = pdfView.currentPage else { return }
        // cropBox is the region PDFKit actually renders (mediaBox minus any
        // crop). Using it avoids over-wide panes for documents with large
        // media boxes but tight crops.
        let pageBounds = page.bounds(for: .cropBox)
        let paneHeight = pdfView.bounds.height
        guard pageBounds.width > 0, pageBounds.height > 0, paneHeight > 0 else { return }

        let aspect = pageBounds.width / pageBounds.height
        // Pane width that makes the page fit by height. A small inset keeps
        // a hair of margin so autoScales doesn't render flush to the edges.
        let desiredWidth = (paneHeight * aspect) + 12
        onRequestPaneWidth?(desiredWidth)
    }

    // MARK: - Search

    func runSearch(_ rawQuery: String) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        searchQuery = rawQuery
        guard let pdfView, let document = pdfView.document, !query.isEmpty else {
            clearSearch()
            return
        }

        matches = document.findString(query, withOptions: .caseInsensitive)
        applyHighlights()
        matchCount = matches.count
        if matches.isEmpty {
            currentMatch = 0
        } else {
            currentMatch = 1
            focusMatch(at: 0)
        }
    }

    func clearSearch() {
        matches = []
        matchCount = 0
        currentMatch = 0
        pdfView?.highlightedSelections = nil
        pdfView?.clearSelection()
    }

    /// Highlights every match with the system accent colour.
    private func applyHighlights() {
        let accent = PDFPreviewController.accentNSColor
        for selection in matches {
            selection.color = accent
        }
        pdfView?.highlightedSelections = matches.isEmpty ? nil : matches
    }

    func nextMatch() {
        guard !matches.isEmpty else { return }
        let next = currentMatch >= matches.count ? 1 : currentMatch + 1
        currentMatch = next
        focusMatch(at: next - 1)
    }

    func previousMatch() {
        guard !matches.isEmpty else { return }
        let prev = currentMatch <= 1 ? matches.count : currentMatch - 1
        currentMatch = prev
        focusMatch(at: prev - 1)
    }

    /// Scrolls to a match and selects it. The accent-coloured highlight
    /// bloom is enough of a visual cue — no zoom.
    private func focusMatch(at index: Int) {
        guard let pdfView, matches.indices.contains(index) else { return }
        let selection = matches[index]
        pdfView.setCurrentSelection(selection, animate: true)
        pdfView.go(to: selection)
        syncCurrentPageFromView()
    }

    private static var accentNSColor: NSColor {
#if os(macOS)
        return NSColor.controlAccentColor.withAlphaComponent(0.45)
#else
        return NSColor.systemBlue.withAlphaComponent(0.45)
#endif
    }

    deinit {
        if let pageObserver {
            NotificationCenter.default.removeObserver(pageObserver)
        }
    }
}
