// ChoiceGroup.swift
// AVM — Accessible Virtual Machine
//
// Choices as pop-up buttons (2026-10-27, user feedback). A VoiceOver user
// reaching a radio group heard its name with one option already chosen
// and nothing saying it was a choice to make. SwiftUI's radio groups on
// macOS can't carry that: neither accessibilityHint nor help reaches the
// AXRadioGroup, and Tab skips them (MEASURED with the accessibility
// audit). A pop-up button says "pop-up button", takes Tab, and its hint
// says what to choose, so every choice in AVM is one.

import SwiftUI

extension View {
    /// A Picker as a pop-up button whose hint says what the choice is for.
    func choicePopUp(_ hint: String) -> some View {
        pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityHint(hint)
    }
}
