//
//  PDFFloatingControls.swift
//  PDFtalkme
//

import SwiftUI

/// Liquid-glass floating controls overlaid on the bottom of the preview
/// pane: page navigation + jump field and fit-to-page-height.
struct PDFFloatingControls: View {
    @Bindable var controller: PDFPreviewController
    @FocusState private var pageFieldFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            navigationCluster
            fitWidthButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Page navigation

    private var navigationCluster: some View {
        HStack(spacing: 6) {
            controlButton(systemImage: "chevron.up", help: "Previous page") {
                controller.previousPage()
            }
            .disabled(controller.currentPage <= 1)

            controlButton(systemImage: "chevron.down", help: "Next page") {
                controller.nextPage()
            }
            .disabled(controller.totalPages > 0 && controller.currentPage >= controller.totalPages)

            HStack(spacing: 3) {
                TextField("", text: $controller.pageFieldText)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .frame(width: 34)
                    .focused($pageFieldFocused)
                    .onSubmit { controller.commitPageField() }
                    .onChange(of: pageFieldFocused) { _, focused in
                        if !focused { controller.commitPageField() }
                    }
                Text("/ \(controller.totalPages)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.callout)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
    }

    // MARK: - Fit-to-page-height (resize only, keeps scroll mode)

    private var fitWidthButton: some View {
        controlButton(
            systemImage: "arrow.left.and.right.square",
            help: "Resize window so a full page fits the height"
        ) {
            controller.fitWindowToPageHeight()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
    }

    // MARK: - Shared button

    private func controlButton(
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Floating glass search affordance for the top-right of the preview pane.
/// Collapsed, it's just a magnifying-glass icon. Tapping it expands into
/// the full search box and focuses the field; clearing the query and
/// clicking away (losing focus) collapses it back to the icon.
struct PDFSearchBar: View {
    @Bindable var controller: PDFPreviewController
    @State private var isExpanded = false
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        Group {
            if isExpanded {
                expandedBar
            } else {
                collapsedIcon
            }
        }
        .glassEffect(.regular, in: .capsule)
    }

    private var collapsedIcon: some View {
        Button {
            isExpanded = true
            searchFieldFocused = true
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Search the document")
    }

    private var expandedBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.callout)

            TextField("Search", text: $controller.searchQuery)
                .textFieldStyle(.plain)
                .frame(minWidth: 90, maxWidth: 160)
                .focused($searchFieldFocused)
                .onSubmit {
                    if controller.matchCount > 0 {
                        controller.nextMatch()
                    } else {
                        controller.runSearch(controller.searchQuery)
                    }
                }
                .onChange(of: controller.searchQuery) { _, newValue in
                    controller.runSearch(newValue)
                }

            if !controller.searchQuery.isEmpty {
                Text(matchLabel)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(controller.matchCount == 0 ? .red : .secondary)

                controlButton(systemImage: "chevron.up", help: "Previous match") {
                    controller.previousMatch()
                }
                .disabled(controller.matchCount == 0)

                controlButton(systemImage: "chevron.down", help: "Next match") {
                    controller.nextMatch()
                }
                .disabled(controller.matchCount == 0)

                controlButton(systemImage: "xmark.circle.fill", help: "Clear search") {
                    controller.searchQuery = ""
                    controller.clearSearch()
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .onChange(of: searchFieldFocused) { _, focused in
            // Collapse back to the icon when the field loses focus and the
            // user hasn't typed a query.
            if !focused && controller.searchQuery.isEmpty {
                isExpanded = false
            }
        }
    }

    private var matchLabel: String {
        guard controller.matchCount > 0 else { return "0/0" }
        return "\(controller.currentMatch)/\(controller.matchCount)"
    }

    private func controlButton(
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
