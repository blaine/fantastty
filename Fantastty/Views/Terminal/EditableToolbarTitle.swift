import SwiftUI
import AppKit

/// An NSTextField styled as a plain label that becomes editable on click.
/// When placed in a toolbar item, disables the bordered appearance.
struct EditableToolbarTitle: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont = .boldSystemFont(ofSize: NSFont.systemFontSize)

    func makeNSView(context: Context) -> ToolbarTextField {
        let textField = ToolbarTextField()
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.isBordered = false
        textField.isEditable = true
        textField.isSelectable = true
        textField.font = font
        textField.textColor = .labelColor
        textField.focusRingType = .none
        textField.delegate = context.coordinator
        textField.lineBreakMode = .byTruncatingTail
        textField.cell?.truncatesLastVisibleLine = true
        textField.cell?.sendsActionOnEndEditing = true
        textField.stringValue = text
        textField.sizeToFit()
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return textField
    }

    func updateNSView(_ nsView: ToolbarTextField, context: Context) {
        if nsView.currentEditor() == nil && nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: EditableToolbarTitle

        init(_ parent: EditableToolbarTitle) {
            self.parent = parent
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            if let textField = obj.object as? NSTextField {
                parent.text = textField.stringValue
            }
        }
    }
}

/// NSTextField subclass that strips the toolbar item border when placed in a toolbar.
class ToolbarTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.disableToolbarBorder()
        }
    }

    private func disableToolbarBorder() {
        guard let toolbar = window?.toolbar else { return }
        for item in toolbar.items {
            if let itemView = item.view, isDescendant(of: itemView) {
                item.isBordered = false
                return
            }
        }
    }
}
