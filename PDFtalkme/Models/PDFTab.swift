//
//  PDFTab.swift
//  PDFtalkme
//

import Foundation

/// One open PDF document in the left pane's tab strip. Equality is by
/// resolved file URL so re-opening the same path doesn't create a
/// duplicate tab.
struct PDFTab: Identifiable, Equatable, Hashable {
    let id: UUID
    let url: URL

    init(id: UUID = UUID(), url: URL) {
        self.id = id
        self.url = url
    }

    var title: String {
        url.deletingPathExtension().lastPathComponent
    }

    static func == (lhs: PDFTab, rhs: PDFTab) -> Bool {
        lhs.url == rhs.url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
}
