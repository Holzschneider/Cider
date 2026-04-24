import Foundation
import SwiftUI
import AppKit

// SwiftUI doesn't ship an editable combo box on macOS — bridge NSComboBox.
// Free-text edits and dropdown picks both flow through the `text` Binding;
// the dropdown is rebuilt every time `items` changes.
struct EditableComboBox: NSViewRepresentable {
    @Binding var text: String
    var items: [String]
    var placeholder: String = ""

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.isEditable = true
        box.completes = true
        box.usesDataSource = false
        box.numberOfVisibleItems = 12
        box.placeholderString = placeholder
        box.font = NSFont.systemFont(ofSize: 13)
        box.target = context.coordinator
        box.action = #selector(Coordinator.changed(_:))
        box.delegate = context.coordinator
        box.controlSize = .regular
        return box
    }

    func updateNSView(_ box: NSComboBox, context: Context) {
        // Reload items when the catalogue changes.
        let current = (0..<box.numberOfItems).map { box.itemObjectValue(at: $0) as? String ?? "" }
        if current != items {
            box.removeAllItems()
            box.addItems(withObjectValues: items)
        }
        if box.stringValue != text {
            box.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: EditableComboBox
        init(_ parent: EditableComboBox) { self.parent = parent }

        // Free-text Return / focus-out.
        @objc func changed(_ sender: NSComboBox) {
            propagate(sender.stringValue)
        }

        // Live edits while typing.
        func controlTextDidChange(_ obj: Notification) {
            guard let box = obj.object as? NSComboBox else { return }
            propagate(box.stringValue)
        }

        // Dropdown selection.
        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            let idx = box.indexOfSelectedItem
            if idx >= 0, let value = box.itemObjectValue(at: idx) as? String {
                propagate(value)
            }
        }

        private func propagate(_ value: String) {
            if parent.text != value { parent.text = value }
        }
    }
}
