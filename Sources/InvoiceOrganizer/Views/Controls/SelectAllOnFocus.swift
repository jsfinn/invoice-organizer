import AppKit
import SwiftUI

struct SelectAllOnFocusModifier<Field: Hashable>: ViewModifier {
    @FocusState.Binding var focus: Field?
    let whenFocused: Field

    func body(content: Content) -> some View {
        content
            .onChange(of: focus) { _, newValue in
                guard newValue == whenFocused else { return }
                DispatchQueue.main.async {
                    guard let responder = NSApp.keyWindow?.firstResponder else { return }
                    responder.tryToPerform(#selector(NSText.selectAll(_:)), with: nil)
                }
            }
    }
}

extension View {
    func selectAllOnFocus<Field: Hashable>(
        focus: FocusState<Field?>.Binding,
        whenFocused field: Field
    ) -> some View {
        modifier(SelectAllOnFocusModifier(focus: focus, whenFocused: field))
    }
}
