import Foundation

/// Parses individual lines from the tmux control mode protocol into typed `TmuxEvent` values.
///
/// Usage:
/// ```swift
/// var parser = TmuxProtocolParser()
/// for line in lines {
///     if let event = parser.parse(line: line) {
///         handleEvent(event)
///     }
/// }
/// ```
///
/// The parser is a value type with no I/O or side effects. It maintains minimal state
/// (a flag to strip the DCS prefix from the first line).
struct TmuxProtocolParser {

    /// Whether we have already stripped the DCS prefix from the first line.
    private var dcsStripped = false

    /// Parse a single line from tmux control mode output (raw bytes).
    ///
    /// This is the primary entry point. It processes `%output` payloads as raw
    /// bytes to avoid lossy UTF-8 conversion of high bytes (0x80-0xFF) that tmux
    /// passes through unescaped. All other event types are pure ASCII and are
    /// safely converted to String for parsing.
    ///
    /// - Parameter lineData: Raw bytes of one protocol line (without the trailing LF).
    /// - Returns: A `TmuxEvent` if the line is a `%`-prefixed notification, or `nil`
    ///   for data lines (e.g. command response bodies) and empty lines.
    mutating func parse(lineData: Data) -> TmuxEvent? {
        var bytes = Array(lineData)

        // Strip trailing \r from PTY line endings.
        if bytes.last == 0x0d { bytes.removeLast() }

        // Strip DCS prefix on the very first line.
        if !dcsStripped {
            dcsStripped = true
            let dcsBytes: [UInt8] = [0x1b, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70] // \x1bP1000p
            if let range = bytes.findSubrange(dcsBytes) {
                bytes = Array(bytes[(range.upperBound)...])
            }
        }

        // Strip control/whitespace prefix before first `%`.
        if bytes.first != 0x25, // '%'
           let percentIdx = bytes.firstIndex(of: 0x25) {
            let prefix = bytes[..<percentIdx]
            let hasOnlyControlPrefix = prefix.allSatisfy { $0 < 0x21 || $0 == 0x09 }
            if hasOnlyControlPrefix {
                bytes = Array(bytes[percentIdx...])
            }
        }

        guard bytes.first == 0x25 else { return nil } // '%'

        // Fast-path: check for `%output ` (8 bytes) to handle it in raw-byte space.
        let outputPrefix: [UInt8] = [0x25, 0x6f, 0x75, 0x74, 0x70, 0x75, 0x74, 0x20] // "%output "
        if bytes.count >= outputPrefix.count,
           bytes[..<outputPrefix.count].elementsEqual(outputPrefix) {
            return parseOutputFromBytes(Array(bytes[outputPrefix.count...]))
        }

        // For all other event types, convert to String (they are pure ASCII).
        let line = String(decoding: bytes, as: UTF8.self)
        return parse(line: line)
    }

    /// Parse a single line from tmux control mode output (String).
    ///
    /// Used for non-output event types and for backward compatibility with tests.
    /// For `%output` lines, prefer `parse(lineData:)` which avoids lossy UTF-8
    /// conversion of high bytes in the payload.
    mutating func parse(line rawLine: String) -> TmuxEvent? {
        var line = rawLine

        // Strip trailing \r from PTY line endings.
        if line.hasSuffix("\r") {
            line = String(line.dropLast())
        }

        // Strip DCS prefix on the very first line. Some environments prepend
        // control bytes before DCS, so strip from the first DCS marker onward.
        if !dcsStripped {
            dcsStripped = true
            let dcsPrefix = "\u{1b}P1000p"
            if let dcsRange = line.range(of: dcsPrefix) {
                line = String(line[dcsRange.upperBound...])
            }
        }

        // Some transports (notably `script`) may prepend control bytes before
        // the first tmux event token. If the prefix is only control/whitespace,
        // strip up to the first `%`.
        if !line.hasPrefix("%"),
           let percentIndex = line.firstIndex(of: "%") {
            let prefix = line[..<percentIndex]
            let hasOnlyControlPrefix = prefix.unicodeScalars.allSatisfy { scalar in
                CharacterSet.controlCharacters.contains(scalar) || scalar == " " || scalar == "\t"
            }
            if hasOnlyControlPrefix {
                line = String(line[percentIndex...])
            }
        }

        // Only % notifications are parsed; everything else is nil.
        guard line.hasPrefix("%") else {
            return nil
        }

        let parts = line.split(separator: " ", maxSplits: 1)
        guard let keyword = parts.first else { return nil }

        let rest = parts.count > 1 ? String(parts[1]) : ""

        switch keyword {
        case "%output":
            return parseOutput(rest)
        case "%extended-output":
            return parseExtendedOutput(rest, line: line)
        case "%client-detached":
            return parseClientDetached(rest, line: line)
        case "%client-session-changed":
            return parseClientSessionChanged(rest, line: line)
        case "%config-error":
            return .configError(message: rest)
        case "%continue":
            return parsePercentID(rest).map { .continued(paneID: $0) }
                ?? .unknown(line)
        case "%message":
            return .message(message: rest)
        case "%paste-buffer-changed":
            return .pasteBufferChanged(name: rest)
        case "%paste-buffer-deleted":
            return .pasteBufferDeleted(name: rest)
        case "%pause":
            return parsePercentID(rest).map { .pause(paneID: $0) }
                ?? .unknown(line)
        case "%session-renamed":
            return parseSessionRenamed(rest, line: line)
        case "%window-add":
            return parseAtID(rest).map { .windowAdd(windowID: $0) }
                ?? .unknown(line)
        case "%window-close":
            return parseAtID(rest).map { .windowClose(windowID: $0) }
                ?? .unknown(line)
        case "%session-window-changed":
            return parseSessionWindowChanged(rest, line: line)
        case "%subscription-changed":
            return parseSubscriptionChanged(rest, line: line)
        case "%unlinked-window-add":
            return parseAtID(rest).map { .unlinkedWindowAdd(windowID: $0) }
                ?? .unknown(line)
        case "%unlinked-window-close":
            return parseAtID(rest).map { .unlinkedWindowClose(windowID: $0) }
                ?? .unknown(line)
        case "%unlinked-window-renamed":
            return parseAtID(rest).map { .unlinkedWindowRenamed(windowID: $0) }
                ?? .unknown(line)
        case "%window-pane-changed":
            return parseWindowPaneChanged(rest, line: line)
        case "%window-renamed":
            return parseWindowRenamed(rest, line: line)
        case "%layout-change":
            return parseLayoutChange(rest, line: line)
        case "%session-changed":
            return parseSessionChanged(rest, line: line)
        case "%sessions-changed":
            return .sessionsChanged
        case "%pane-mode-changed":
            return parsePercentID(rest).map { .paneModeChanged(paneID: $0) }
                ?? .unknown(line)
        case "%begin":
            return parseBlock(rest, kind: .begin) ?? .unknown(line)
        case "%end":
            return parseBlock(rest, kind: .end) ?? .unknown(line)
        case "%error":
            return parseBlock(rest, kind: .error) ?? .unknown(line)
        case "%exit":
            let reason = rest.isEmpty ? nil : rest
            return .exit(reason: reason)
        default:
            return .unknown(line)
        }
    }

    // MARK: - Notification Parsers

    /// Parse `%output` payload from raw bytes, avoiding lossy String conversion.
    /// `rest` is everything after "%output " (the pane ID and octal-encoded payload).
    private func parseOutputFromBytes(_ rest: [UInt8]) -> TmuxEvent? {
        // Find the pane ID: starts with '%', ends at first space.
        guard rest.first == 0x25 else { return nil } // '%'
        guard let spaceIdx = rest.firstIndex(of: 0x20) else {
            // No payload — just pane ID
            let paneStr = String(decoding: rest, as: UTF8.self)
            guard let paneID = Self.parsePercentID(paneStr) else { return nil }
            return .output(paneID: paneID, data: Data())
        }
        let paneStr = String(decoding: rest[..<spaceIdx], as: UTF8.self)
        guard let paneID = Self.parsePercentID(paneStr) else { return nil }

        // Payload starts after the space — decode octal escapes from raw bytes.
        let payload = Array(rest[(spaceIdx + 1)...])
        let data = Self.decodeOctalEscapesFromBytes(payload)
        return .output(paneID: paneID, data: data)
    }

    private func parseOutput(_ rest: String) -> TmuxEvent? {
        // Format: %<paneID> <octal-encoded-data>
        let parts = rest.split(separator: " ", maxSplits: 1)
        guard let paneToken = parts.first,
              let paneID = parsePercentID(String(paneToken)) else {
            return nil
        }
        let encoded = parts.count > 1 ? String(parts[1]) : ""
        let data = Self.decodeOctalEscapes(encoded)
        return .output(paneID: paneID, data: data)
    }

    private func parseExtendedOutput(_ rest: String, line: String) -> TmuxEvent {
        // Format: %<paneID> <age> ... : <octal-encoded-data>
        guard let delimiter = rest.range(of: " : ") else {
            return .unknown(line)
        }

        let header = rest[..<delimiter.lowerBound]
        let payload = String(rest[delimiter.upperBound...])
        guard let paneToken = header.split(separator: " ", maxSplits: 1).first,
              let paneID = parsePercentID(String(paneToken)) else {
            return .unknown(line)
        }

        return .output(paneID: paneID, data: Self.decodeOctalEscapes(payload))
    }

    private func parseClientDetached(_ rest: String, line: String) -> TmuxEvent {
        guard !rest.isEmpty else { return .unknown(line) }
        return .clientDetached(client: rest)
    }

    private func parseClientSessionChanged(_ rest: String, line: String) -> TmuxEvent {
        // Format: <client> $<sessionID> <name>
        let parts = rest.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              let sessionID = Self.parseDollarID(String(parts[1])) else {
            return .unknown(line)
        }
        return .clientSessionChanged(
            client: String(parts[0]),
            sessionID: sessionID,
            name: String(parts[2])
        )
    }

    private func parseWindowRenamed(_ rest: String, line: String) -> TmuxEvent {
        // Format: @<windowID> <name>
        let parts = rest.split(separator: " ", maxSplits: 1)
        guard let winToken = parts.first,
              let windowID = Self.parseAtID(String(winToken)),
              parts.count > 1 else {
            return .unknown(line)
        }
        let name = String(parts[1])
        return .windowRenamed(windowID: windowID, name: name)
    }

    private func parseLayoutChange(_ rest: String, line: String) -> TmuxEvent {
        // Format: @<windowID> <layout> <visibleLayout> <flags>
        let parts = rest.split(separator: " ", omittingEmptySubsequences: true)
        guard let winToken = parts.first,
              let windowID = Self.parseAtID(String(winToken)),
              parts.count == 4 else {
            return .unknown(line)
        }
        return .layoutChange(
            windowID: windowID,
            layout: String(parts[1]),
            visibleLayout: String(parts[2]),
            flags: String(parts[3])
        )
    }

    private func parseSessionChanged(_ rest: String, line: String) -> TmuxEvent {
        // Format: $<sessionID> <name>
        let parts = rest.split(separator: " ", maxSplits: 1)
        guard let sessionToken = parts.first,
              let sessionID = Self.parseDollarID(String(sessionToken)),
              parts.count > 1 else {
            return .unknown(line)
        }
        let name = String(parts[1])
        return .sessionChanged(sessionID: sessionID, name: name)
    }

    private func parseSessionRenamed(_ rest: String, line: String) -> TmuxEvent {
        guard !rest.isEmpty else { return .unknown(line) }
        return .sessionRenamed(name: rest)
    }

    private func parseSessionWindowChanged(_ rest: String, line: String) -> TmuxEvent {
        // Format: $<sessionID> @<windowID>
        let parts = rest.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2,
              let sessionID = Self.parseDollarID(String(parts[0])),
              let windowID = Self.parseAtID(String(parts[1])) else {
            return .unknown(line)
        }
        return .sessionWindowChanged(sessionID: sessionID, windowID: windowID)
    }

    private func parseSubscriptionChanged(_ rest: String, line: String) -> TmuxEvent {
        // Format: <name> $<sessionID> @<windowID> <windowIndex> %<paneID> ... : <value>
        guard let delimiter = rest.range(of: " : ") else {
            return .unknown(line)
        }

        let header = rest[..<delimiter.lowerBound]
        let value = String(rest[delimiter.upperBound...])
        let headerParts = header.split(separator: " ", omittingEmptySubsequences: true)
        guard headerParts.count >= 5,
              let sessionID = Self.parseDollarID(String(headerParts[1])),
              let windowID = Self.parseAtID(String(headerParts[2])),
              let windowIndex = Int(headerParts[3]),
              let paneID = Self.parsePercentID(String(headerParts[4])) else {
            return .unknown(line)
        }

        return .subscriptionChanged(
            name: String(headerParts[0]),
            sessionID: sessionID,
            windowID: windowID,
            windowIndex: windowIndex,
            paneID: paneID,
            value: value
        )
    }

    private func parseWindowPaneChanged(_ rest: String, line: String) -> TmuxEvent {
        // Format: @<windowID> %<paneID>
        let parts = rest.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2,
              let windowID = Self.parseAtID(String(parts[0])),
              let paneID = Self.parsePercentID(String(parts[1])) else {
            return .unknown(line)
        }
        return .windowPaneChanged(windowID: windowID, paneID: paneID)
    }

    private enum BlockKind { case begin, end, error }

    private func parseBlock(_ rest: String, kind: BlockKind) -> TmuxEvent? {
        // Format: <timestamp> <command_number> <flags>
        let parts = rest.split(separator: " ")
        guard parts.count >= 3,
              let id = Int(parts[1]),
              let flags = Int(parts[2]) else {
            return nil
        }
        switch kind {
        case .begin: return .beginBlock(id: id, flags: flags)
        case .end:   return .endBlock(id: id, flags: flags)
        case .error: return .errorBlock(id: id, flags: flags)
        }
    }

    // MARK: - ID Parsing Helpers

    /// Parse a `@<number>` window ID token.
    static func parseAtID(_ s: String) -> Int? {
        guard s.hasPrefix("@") else { return nil }
        return Int(s.dropFirst())
    }

    /// Parse a `%<number>` pane ID token.
    static func parsePercentID(_ s: String) -> Int? {
        guard s.hasPrefix("%") else { return nil }
        return Int(s.dropFirst())
    }

    /// Parse a `$<number>` session ID token.
    static func parseDollarID(_ s: String) -> Int? {
        guard s.hasPrefix("$") else { return nil }
        return Int(s.dropFirst())
    }

    // Instance wrappers for use in non-static methods.
    private func parseAtID(_ s: String) -> Int? { Self.parseAtID(s) }
    private func parsePercentID(_ s: String) -> Int? { Self.parsePercentID(s) }

    // MARK: - Octal Escape Decoding

    /// Decode tmux octal-escaped output data into raw bytes.
    ///
    /// Tmux encodes bytes < 32 (and backslash itself) as `\NNN` where NNN is
    /// exactly three octal digits. All other characters pass through verbatim.
    static func decodeOctalEscapes(_ string: String) -> Data {
        var data = Data()
        var iterator = string.unicodeScalars.makeIterator()

        while let scalar = iterator.next() {
            if scalar == "\\" {
                // Attempt to read three octal digits.
                var octalDigits: [UnicodeScalar] = []
                // We need to peek ahead. Collect up to 3 octal digits.
                var pending: [UnicodeScalar] = []
                for _ in 0..<3 {
                    if let next = iterator.next() {
                        if next >= "0" && next <= "7" {
                            octalDigits.append(next)
                        } else {
                            // Not an octal digit; save it for later processing.
                            pending.append(next)
                            break
                        }
                    }
                }
                if octalDigits.count == 3 {
                    // Valid three-digit octal escape.
                    let octalString = String(String.UnicodeScalarView(octalDigits))
                    if let value = UInt8(octalString, radix: 8) {
                        data.append(value)
                    }
                    // Process any pending scalars.
                    for p in pending {
                        appendScalar(p, to: &data)
                    }
                } else {
                    // Not a valid octal escape; emit the backslash and
                    // whatever digits we consumed, plus any non-digit.
                    data.append(UInt8(ascii: "\\"))
                    for d in octalDigits {
                        appendScalar(d, to: &data)
                    }
                    for p in pending {
                        appendScalar(p, to: &data)
                    }
                }
            } else {
                appendScalar(scalar, to: &data)
            }
        }

        return data
    }

    /// Append a single Unicode scalar as its UTF-8 encoding.
    private static func appendScalar(_ scalar: UnicodeScalar, to data: inout Data) {
        var buf = [UInt8](repeating: 0, count: 4)
        var count = 0
        for byte in String(scalar).utf8 {
            buf[count] = byte
            count += 1
        }
        data.append(contentsOf: buf[0..<count])
    }

    // MARK: - Raw Byte Octal Escape Decoding

    /// Decode tmux octal-escaped output from raw bytes, preserving all byte values.
    ///
    /// Unlike `decodeOctalEscapes(_:String)`, this operates directly on raw bytes
    /// so that high bytes (0x80-0xFF) are never run through Swift's lossy UTF-8
    /// String conversion. Tmux passes bytes >= 0x20 (except backslash) through
    /// unescaped, including raw UTF-8 continuation bytes. If a multi-byte UTF-8
    /// sequence is split across two `%output` messages, the String-based decoder
    /// would corrupt the incomplete sequence with U+FFFD replacement characters.
    static func decodeOctalEscapesFromBytes(_ bytes: [UInt8]) -> Data {
        var data = Data()
        data.reserveCapacity(bytes.count)
        var i = bytes.startIndex

        while i < bytes.endIndex {
            let byte = bytes[i]
            if byte == 0x5c { // backslash '\'
                // Attempt to read three octal digits.
                var octalCount = 0
                var value: UInt8 = 0
                let remaining = bytes.endIndex - (i + 1)
                let limit = min(3, remaining)
                for j in 0..<limit {
                    let next = bytes[i + 1 + j]
                    if next >= 0x30, next <= 0x37 { // '0'...'7'
                        octalCount += 1
                        value = value &* 8 &+ (next - 0x30)
                    } else {
                        break
                    }
                }
                if octalCount == 3 {
                    data.append(value)
                    i += 4 // skip backslash + 3 digits
                } else {
                    // Not a valid octal escape; emit the backslash and any
                    // consumed digits literally.
                    data.append(byte)
                    i += 1
                }
            } else {
                data.append(byte)
                i += 1
            }
        }

        return data
    }
}

// MARK: - Array Subrange Search

extension Array where Element: Equatable {
    /// Find the first occurrence of `subrange` in this array.
    func findSubrange(_ subrange: [Element]) -> Range<Int>? {
        guard !subrange.isEmpty, subrange.count <= count else { return nil }
        let end = count - subrange.count
        for i in 0...end {
            if self[i..<(i + subrange.count)].elementsEqual(subrange) {
                return i..<(i + subrange.count)
            }
        }
        return nil
    }
}
