//
//  PDFTypes.swift
//  PDFtalkme
//

import Foundation
#if os(macOS)
import AppKit
#endif

enum PDFSidebarMode {
    case outline
    case pages
}

struct PDFOutlineItem: Identifiable {
    let id = UUID()
    let title: String
    let page: Int
    let level: Int
}

struct PDFPagePreview: Identifiable {
    let id = UUID()
    let page: Int
#if os(macOS)
    let thumbnail: NSImage
#endif
}

enum PDFFindDirection {
    case previous
    case next
}

struct PDFFindRequest: Equatable {
    let query: String
    let direction: PDFFindDirection
    let requestID: UUID

    init(query: String, direction: PDFFindDirection, requestID: UUID = UUID()) {
        self.query = query
        self.direction = direction
        self.requestID = requestID
    }
}

extension Notification.Name {
    static let pdfTalkmeOpenFind = Notification.Name("PDFtalkme.OpenFind")
}
