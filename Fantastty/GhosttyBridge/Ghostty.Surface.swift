import Foundation
import GhosttyKit

extension Ghostty {
    /// Represents a single surface within Ghostty.
    ///
    /// NOTE(mitchellh): This is a work-in-progress class as part of a general refactor
    /// of our Ghostty data model. At the time of writing there's still a ton of surface
    /// functionality that is not encapsulated in this class. It is planned to migrate that
    /// all over.
    ///
    /// Wraps a `ghostty_surface_t`
    final class Surface: Sendable, RemoteGridSurface {
        private let surface: ghostty_surface_t

        /// Read the underlying C value for this surface. This is unsafe because the value will be
        /// freed when the Surface class is deinitialized.
        var unsafeCValue: ghostty_surface_t {
            surface
        }

        /// Initialize from the C structure.
        init(cSurface: ghostty_surface_t) {
            self.surface = cSurface
        }

        deinit {
            // `ghostty_surface_free` can synchronously emit callbacks that still
            // reference the SurfaceView userdata. Freeing asynchronously after
            // SurfaceView teardown introduces a use-after-free window.
            // Keep teardown synchronous on the main thread to avoid callback races.
            let surface = self.surface
            if Thread.isMainThread {
                ghostty_surface_free(surface)
            } else {
                DispatchQueue.main.sync {
                    ghostty_surface_free(surface)
                }
            }
        }

        /// Send text to the terminal as if it was typed. This doesn't send the key events so keyboard
        /// shortcuts and other encodings do not take effect.
        @MainActor
        func sendText(_ text: String) {
            let len = text.utf8CString.count
            if (len == 0) { return }

            text.withCString { ptr in
                // len includes the null terminator so we do len - 1
                ghostty_surface_text(surface, ptr, UInt(len - 1))
            }
        }

        /// Reset the terminal grid backing remote pane contents.
        @MainActor
        func resetRemoteGrid(columns: Int, rows: Int) -> Bool {
            guard let columns = UInt32(exactly: columns), columns > 0 else { return false }
            guard let rows = UInt32(exactly: rows), rows > 0 else { return false }
            return ghostty_surface_remote_grid_reset(surface, columns, rows)
        }

        /// Replace one row in the remote grid with UTF-8 text.
        @MainActor
        func setRemoteGridRow(_ row: Int, text: String) -> Bool {
            guard let row = UInt32(exactly: row) else { return false }
            return text.withCString { ptr in
                ghostty_surface_remote_grid_set_row(surface, row, ptr, UInt(text.utf8.count))
            }
        }

        /// Replace one row in the remote grid with structured cells.
        @MainActor
        func setRemoteGridRow(_ row: Int, cells: [RemoteGridCell]) -> Bool {
            guard let row = UInt32(exactly: row) else { return false }
            var allocations: [UnsafeMutablePointer<CChar>] = []
            allocations.reserveCapacity(cells.count)
            defer {
                for allocation in allocations {
                    allocation.deallocate()
                }
            }

            var cCells: [ghostty_remote_grid_cell_s] = []
            cCells.reserveCapacity(cells.count)
            for cell in cells {
                guard let width = UInt32(exactly: cell.width) else { return false }
                let bytes = Array(cell.text.utf8CString)
                let allocation = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
                allocation.initialize(from: bytes, count: bytes.count)
                allocations.append(allocation)

                cCells.append(ghostty_remote_grid_cell_s(
                    text: UnsafePointer(allocation),
                    len: UInt(bytes.count - 1),
                    width: width,
                    style: Ghostty.remoteGridStyle(cell.style)
                ))
            }

            return cCells.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return false }
                return ghostty_surface_remote_grid_set_row_cells(surface, row, baseAddress, UInt(buffer.count))
            }
        }

        /// Set the remote grid cursor position and visibility.
        @MainActor
        func setRemoteGridCursor(row: Int, column: Int, visible: Bool) -> Bool {
            guard let row = UInt32(exactly: row) else { return false }
            guard let column = UInt32(exactly: column) else { return false }
            return ghostty_surface_remote_grid_set_cursor(surface, row, column, visible)
        }

        /// Set the remote grid cursor position, visibility, and shape.
        @MainActor
        func setRemoteGridCursor(_ cursor: RemoteCursorState) -> Bool {
            guard let row = UInt32(exactly: cursor.row) else { return false }
            guard let column = UInt32(exactly: cursor.column) else { return false }
            return ghostty_surface_remote_grid_set_cursor_ex(
                surface,
                row,
                column,
                cursor.visible,
                cursor.shape.cRemoteGridShape
            )
        }

        /// Send a key event to the terminal.
        ///
        /// This sends the full key event including modifiers, action type, and text to the terminal.
        /// Unlike `sendText`, this method processes keyboard shortcuts, key bindings, and terminal
        /// encoding based on the complete key event information.
        ///
        /// - Parameter event: The key event to send to the terminal
        @MainActor
        func sendKeyEvent(_ event: Input.KeyEvent) {
            event.withCValue { cEvent in
                ghostty_surface_key(surface, cEvent)
            }
        }

        /// Check if a key event matches a keybinding.
        ///
        /// This checks whether the given key event would trigger a keybinding in the terminal.
        /// If it matches, returns the binding flags indicating properties of the matched binding.
        ///
        /// - Parameter event: The key event to check
        /// - Returns: The binding flags if a binding matches, or nil if no binding matches
        @MainActor
        func keyIsBinding(_ event: ghostty_input_key_s) -> Input.BindingFlags? {
            var flags = ghostty_binding_flags_e(0)
            guard ghostty_surface_key_is_binding(surface, event, &flags) else { return nil }
            return Input.BindingFlags(cFlags: flags)
        }

        /// See `keyIsBinding(_ event: ghostty_input_key_s)`.
        @MainActor
        func keyIsBinding(_ event: Input.KeyEvent) -> Input.BindingFlags? {
            event.withCValue { keyIsBinding($0) }
        }

        /// Whether the terminal has captured mouse input.
        ///
        /// When the mouse is captured, the terminal application is receiving mouse events
        /// directly rather than the host system handling them. This typically occurs when
        /// a terminal application enables mouse reporting mode.
        @MainActor
        var mouseCaptured: Bool {
            ghostty_surface_mouse_captured(surface)
        }

        /// Send a mouse button event to the terminal.
        ///
        /// This sends a complete mouse button event including the button state (press/release),
        /// which button was pressed, and any modifier keys that were held during the event.
        /// The terminal processes this event according to its mouse handling configuration.
        ///
        /// - Parameter event: The mouse button event to send to the terminal
        @MainActor
        func sendMouseButton(_ event: Input.MouseButtonEvent) {
            ghostty_surface_mouse_button(
                surface,
                event.action.cMouseState,
                event.button.cMouseButton,
                event.mods.cMods)
        }

        /// Send a mouse position event to the terminal.
        ///
        /// This reports the current mouse position to the terminal, which may be used
        /// for mouse tracking, hover effects, or other position-dependent features.
        /// The terminal will only receive these events if mouse reporting is enabled.
        ///
        /// - Parameter event: The mouse position event to send to the terminal
        @MainActor
        func sendMousePos(_ event: Input.MousePosEvent) {
            ghostty_surface_mouse_pos(
                surface,
                event.x,
                event.y,
                event.mods.cMods)
        }

        /// Send a mouse scroll event to the terminal.
        ///
        /// This sends scroll wheel input to the terminal with delta values for both
        /// horizontal and vertical scrolling, along with precision and momentum information.
        /// The terminal processes this according to its scroll handling configuration.
        ///
        /// - Parameter event: The mouse scroll event to send to the terminal
        @MainActor
        func sendMouseScroll(_ event: Input.MouseScrollEvent) {
            ghostty_surface_mouse_scroll(
                surface,
                event.x,
                event.y,
                event.mods.cScrollMods)
        }

        /// Perform a keybinding action.
        ///
        /// The action can be any valid keybind parameter. e.g. `keybind = goto_tab:4`
        /// you can perform `goto_tab:4` with this.
        ///
        /// Returns true if the action was performed. Invalid actions return false.
        @MainActor
        func perform(action: String) -> Bool {
            let len = action.utf8CString.count
            if (len == 0) { return false }
            return action.withCString { cString in
                ghostty_surface_binding_action(surface, cString, UInt(len - 1))
            }
        }
    }
}

private extension Ghostty {
    static func remoteGridStyle(_ style: RemoteCellStyle) -> ghostty_remote_grid_style_s {
        var cStyle = ghostty_remote_grid_style_s()
        cStyle.foreground = remoteGridColor(style.foreground)
        cStyle.background = remoteGridColor(style.background)
        cStyle.underline_color = remoteGridColor(style.underlineColor)
        cStyle.bold = style.bold ? 1 : 0
        cStyle.faint = style.faint ? 1 : 0
        cStyle.italic = style.italic ? 1 : 0
        cStyle.blink = style.blink ? 1 : 0
        cStyle.inverse = style.inverse ? 1 : 0
        cStyle.invisible = style.invisible ? 1 : 0
        cStyle.strikethrough = style.strikethrough ? 1 : 0
        cStyle.underline = style.underline.cRemoteGridUnderline
        return cStyle
    }

    static func remoteGridColor(_ color: RemoteGridColor) -> ghostty_remote_grid_color_s {
        var cColor = ghostty_remote_grid_color_s()
        switch color {
        case .default:
            cColor.tag = ghostty_remote_grid_color_tag_e(GHOSTTY_REMOTE_GRID_COLOR_DEFAULT)
        case .indexed(let index):
            cColor.tag = ghostty_remote_grid_color_tag_e(GHOSTTY_REMOTE_GRID_COLOR_INDEXED)
            cColor.index = index
        case .rgb(let red, let green, let blue):
            cColor.tag = ghostty_remote_grid_color_tag_e(GHOSTTY_REMOTE_GRID_COLOR_RGB)
            cColor.red = red
            cColor.green = green
            cColor.blue = blue
        }
        return cColor
    }
}

private extension RemoteUnderlineStyle {
    var cRemoteGridUnderline: ghostty_remote_grid_underline_e {
        switch self {
        case .none:
            return ghostty_remote_grid_underline_e(GHOSTTY_REMOTE_GRID_UNDERLINE_NONE)
        case .single:
            return ghostty_remote_grid_underline_e(GHOSTTY_REMOTE_GRID_UNDERLINE_SINGLE)
        case .double:
            return ghostty_remote_grid_underline_e(GHOSTTY_REMOTE_GRID_UNDERLINE_DOUBLE)
        case .curly:
            return ghostty_remote_grid_underline_e(GHOSTTY_REMOTE_GRID_UNDERLINE_CURLY)
        case .dotted:
            return ghostty_remote_grid_underline_e(GHOSTTY_REMOTE_GRID_UNDERLINE_DOTTED)
        case .dashed:
            return ghostty_remote_grid_underline_e(GHOSTTY_REMOTE_GRID_UNDERLINE_DASHED)
        }
    }
}

private extension RemoteCursorShape {
    var cRemoteGridShape: ghostty_remote_grid_cursor_shape_e {
        switch self {
        case .block:
            return ghostty_remote_grid_cursor_shape_e(GHOSTTY_REMOTE_GRID_CURSOR_SHAPE_BLOCK)
        case .bar:
            return ghostty_remote_grid_cursor_shape_e(GHOSTTY_REMOTE_GRID_CURSOR_SHAPE_BAR)
        case .underline:
            return ghostty_remote_grid_cursor_shape_e(GHOSTTY_REMOTE_GRID_CURSOR_SHAPE_UNDERLINE)
        }
    }
}
