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
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return textField
    }

    func updateNSView(_ nsView: ToolbarTextField, context: Context) {
        if nsView.currentEditor() == nil && nsView.stringValue != text {
            nsView.stringValue = text
            nsView.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ToolbarTextField, context: Context) -> CGSize? {
        let intrinsic = nsView.intrinsicContentSize
        var width = intrinsic.width
        if let proposedWidth = proposal.width {
            width = min(width, proposedWidth)
        }
        return CGSize(width: width, height: intrinsic.height)
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
    /// Editable text fields report no intrinsic width (AppKit expects constraints
    /// to size them), which leaves the title stuck at whatever width the toolbar
    /// first assigned. Measure the cell so the title sizes to its text.
    override var intrinsicContentSize: NSSize {
        guard let cell else { return super.intrinsicContentSize }
        let bounds = NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let size = cell.cellSize(forBounds: bounds)
        // Small margin so the truncating cell doesn't clip the last glyph.
        return NSSize(width: ceil(size.width) + 4, height: ceil(size.height))
    }

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
