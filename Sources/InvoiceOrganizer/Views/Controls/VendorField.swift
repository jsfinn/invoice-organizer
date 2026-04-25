import SwiftUI

struct VendorField: View {
    @Binding var text: String
    let suggestions: [String]
    @FocusState.Binding var focus: DataEntryField?

    @State private var highlightedIndex: Int?
    @State private var isPopoverOpen = false

    private var filteredSuggestions: [String] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return Array(
            suggestions
                .filter { $0.localizedCaseInsensitiveContains(query) }
                .prefix(8)
        )
    }

    var body: some View {
        TextField("Vendor or Misc", text: $text)
            .textFieldStyle(.plain)
            .focused($focus, equals: .vendor)
            .onSubmit {
                acceptHighlightedOrCommit()
            }
            .onExitCommand {
                if isPopoverOpen {
                    isPopoverOpen = false
                    highlightedIndex = nil
                } else {
                    focus = nil
                }
            }
            .onKeyPress(.downArrow) {
                guard !filteredSuggestions.isEmpty else { return .ignored }
                if !isPopoverOpen { isPopoverOpen = true }
                let next = (highlightedIndex ?? -1) + 1
                highlightedIndex = next < filteredSuggestions.count ? next : 0
                return .handled
            }
            .onKeyPress(.upArrow) {
                guard !filteredSuggestions.isEmpty, isPopoverOpen else { return .ignored }
                let prev = (highlightedIndex ?? filteredSuggestions.count) - 1
                highlightedIndex = prev >= 0 ? prev : filteredSuggestions.count - 1
                return .handled
            }
            .onChange(of: text) { _, _ in
                highlightedIndex = nil
                isPopoverOpen = !filteredSuggestions.isEmpty && focus == .vendor
            }
            .onChange(of: focus) { oldValue, newValue in
                if oldValue == .vendor && newValue != .vendor {
                    isPopoverOpen = false
                    highlightedIndex = nil
                }
            }
            .popover(isPresented: $isPopoverOpen, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                suggestionList
            }
    }

    @ViewBuilder
    private var suggestionList: some View {
        let items = filteredSuggestions
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element) { index, suggestion in
                Button {
                    text = suggestion
                    isPopoverOpen = false
                    highlightedIndex = nil
                } label: {
                    Text(suggestion)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(index == highlightedIndex ? Color.accentColor.opacity(0.2) : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .frame(minWidth: 200)
    }

    private func acceptHighlightedOrCommit() {
        if let idx = highlightedIndex, idx < filteredSuggestions.count {
            text = filteredSuggestions[idx]
        }
        isPopoverOpen = false
        highlightedIndex = nil
    }
}
