//
//  PDFFingerprint.swift
//  PDFtalkme
//

import Foundation
import CryptoKit

/// Background-friendly SHA-256 of a file. Streamed in 1 MiB chunks so a
/// large PDF doesn't blow up memory. Returns `nil` on any I/O error —
/// callers fall back to the filename match.
enum PDFFingerprint {
    nonisolated static func sha256(of url: URL) -> String? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1 << 20  // 1 MiB
        while true {
            let chunk: Data
            do {
                guard let next = try handle.read(upToCount: chunkSize), !next.isEmpty else { break }
                chunk = next
            } catch {
                return nil
            }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
