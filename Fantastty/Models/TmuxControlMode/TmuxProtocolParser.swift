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

    /// Parse a single line from tmux control mode output.
    ///
    /// - Parameter line: A raw line (possibly including trailing CR from the PTY).
    /// - Returns: A `TmuxEvent` if the line is a `%`-prefixed notification, or `nil`
    ///   for data lines (e.g. command response bodies) and empty lines.
    mutating func parse(line rawLine: String) -> TmuxEvent? {
        var line = rawLine

        // Strip trailing \r from PTY line endings.
        if line.hasSuffix("\r") {
            line = String(line.dropLast())
        }

        // Strip DCS prefix on the very first line.
        if !dcsStripped {
            dcsStripped = true
            let dcsPrefix = "\u{1b}P1000p"
            if line.hasPrefix(dcsPrefix) {
                line = String(line.dropFirst(dcsPrefix.count))
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
        case "%window-add":
            return parseAtID(rest).map { .windowAdd(windowID: $0) }
                ?? .unknown(line)
        case "%window-close":
            return parseAtID(rest).map { .windowClose(windowID: $0) }
                ?? .unknown(line)
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
        // Format: @<windowID> <layout-string>
        let parts = rest.split(separator: " ", maxSplits: 1)
        guard let winToken = parts.first,
              let windowID = Self.parseAtID(String(winToken)),
              parts.count > 1 else {
            return .unknown(line)
        }
        let layout = String(parts[1])
        return .layoutChange(windowID: windowID, layout: layout)
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
}
