import AppKit
import CircuitKit

/// A part's value typed in place on the canvas: double-click a part, or press Return with one part selected, and a small
/// field over it takes its value (the one its label shows) as the inspector reads it ("4k7", "10u", "2.2 MΩ"). Return or
/// a click elsewhere sets it as one undo step; Esc puts the field away leaving the value as it was.
extension CircuitCanvasView: NSTextFieldDelegate {
    /// The field open over a part, if one is
    var inlineEditField: NSTextField? { inlineEdit?.field }

    /// Opens the field over the part; false when the part has no value to type in place (the caller shows the inspector)
    @discardableResult
    func beginInlineEdit(_ id: UUID) -> Bool {
        guard let element = editor.circuit[id], let spec = element.kind.inlineValueParam, window != nil else { return false }
        if inlineEdit != nil { finishInlineEdit() }
        editor.selection = [id]
        let field = NSTextField(string: SI.format(element[param: spec.key], unit: spec.unit, digits: 4))
        field.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        field.alignment = .center
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderString = spec.name
        field.toolTip = "\(spec.name): type a value such as 4k7, 10u or 2.2 MΩ. Return sets it, Esc leaves it."
        field.setAccessibilityLabel(spec.name)
        field.delegate = self
        // over the middle of the part
        let a = screen(element.a)
        let b = screen(element.b)
        let centre = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let size = CGSize(width: 116, height: 24)
        var frame = CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height)
        // kept inside the canvas
        frame.origin.x = max(4, min(bounds.width - size.width - 4, frame.origin.x))
        frame.origin.y = max(4, min(bounds.height - size.height - 4, frame.origin.y))
        field.frame = frame
        addSubview(field)
        inlineEdit = InlineEdit(id: id, field: field)
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        needsDisplay = true
        return true
    }

    /// Sets the typed value and closes the field. Text that is not a value beeps and leaves the field open.
    func commitInlineEdit() {
        guard let edit = inlineEdit else { return }
        let text = edit.field.currentEditor()?.string ?? edit.field.stringValue
        guard SI.parse(text) != nil else {
            NSSound.beep()
            edit.field.currentEditor()?.selectAll(nil)
            return
        }
        closeInlineEdit(restoreFocus: true)
        editor.setInlineValue(edit.id, from: text)
    }

    /// Sets what was typed when it is a value, else leaves the value as it was; the field closes either way (the view
    /// scrolled or zoomed under it)
    func finishInlineEdit() {
        guard let edit = inlineEdit else { return }
        let text = edit.field.currentEditor()?.string ?? edit.field.stringValue
        closeInlineEdit(restoreFocus: true)
        if SI.parse(text) != nil { editor.setInlineValue(edit.id, from: text) }
    }

    /// Closes the field leaving the value as it was
    func cancelInlineEdit() {
        closeInlineEdit(restoreFocus: true)
    }

    /// The field put away, and the keyboard given back to the canvas when `restoreFocus`. (When the field loses the
    /// keyboard itself, to a click elsewhere, it is removed a moment later rather than in the middle of that change.)
    private func closeInlineEdit(restoreFocus: Bool) {
        guard let edit = inlineEdit else { return }
        inlineEdit = nil
        edit.field.delegate = nil
        if restoreFocus {
            window?.makeFirstResponder(self)
            edit.field.removeFromSuperview()
        } else {
            let field = edit.field
            DispatchQueue.main.async {
                MainActor.assumeIsolated { field.removeFromSuperview() }
            }
        }
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === inlineEdit?.field else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            commitInlineEdit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelInlineEdit()
            return true
        default:
            return false
        }
    }

    /// The field lost the keyboard (a click elsewhere, another window): what was typed is set when it is a value
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let edit = inlineEdit, (notification.object as? NSTextField) === edit.field else { return }
        let text = edit.field.stringValue
        closeInlineEdit(restoreFocus: false)
        if SI.parse(text) != nil { editor.setInlineValue(edit.id, from: text) }
    }
}

/// The part whose value is being typed in place, and the field it is typed in
struct InlineEdit {
    let id: UUID
    let field: NSTextField
}
