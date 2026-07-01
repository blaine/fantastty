import Darwin
import Foundation

struct RemoteGridSize: Codable, Equatable, Sendable {
    let columns: Int
    let rows: Int
}

enum RemoteGridColor: Codable, Equatable, Sendable {
    case `default`
    case indexed(UInt8)
    case rgb(red: UInt8, green: UInt8, blue: UInt8)
}

struct RemoteCellStyle: Codable, Equatable, Sendable {
    var foreground: RemoteGridColor
    var background: RemoteGridColor
    var underlineColor: RemoteGridColor
    var bold: Bool
    var faint: Bool
    var italic: Bool
    var underline: RemoteUnderlineStyle
    var blink: Bool
    var inverse: Bool
    var invisible: Bool
    var strikethrough: Bool

    static let normal = RemoteCellStyle(
        foreground: .default,
        background: .default,
        underlineColor: .default,
        bold: false,
        faint: false,
        italic: false,
        underline: .none,
        blink: false,
        inverse: false,
        invisible: false,
        strikethrough: false
    )

    static var tentativePrediction: RemoteCellStyle {
        var style = RemoteCellStyle.normal
        style.faint = true
        style.underline = .dotted
        style.blink = true
        return style
    }
}

enum RemoteUnderlineStyle: String, Codable, Equatable, Sendable {
    case none
    case single
    case double
    case curly
    case dotted
    case dashed
}

struct RemoteGridCell: Codable, Equatable, Sendable {
    let text: String
    let width: Int
    let style: RemoteCellStyle

    static let blank = RemoteGridCell(text: " ", width: 1, style: .normal)
    static let continuation = RemoteGridCell(text: "", width: 0, style: .normal)

    static func text(
        _ text: String,
        width: Int = 1,
        style: RemoteCellStyle = .normal
    ) -> RemoteGridCell {
        RemoteGridCell(text: text, width: width, style: style)
    }
}

enum RemoteGridTextMetrics {
    static func containsControlScalars(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            return value < 0x20 || value == 0x7F || (value >= 0x80 && value <= 0x9F)
        }
    }

    static func displayWidth(of text: String, maximumColumns: Int) -> Int? {
        guard maximumColumns >= 0 else { return nil }

        var width = 0
        var sawSpacingScalar = false
        for scalar in text.unicodeScalars {
            let value = scalar.value
            guard !containsControlScalars(String(scalar)) else { return nil }

            let scalarWidth = Darwin.wcwidth(wchar_t(value))
            guard scalarWidth >= 0 else { return nil }
            if scalarWidth == 0 {
                guard sawSpacingScalar else { return nil }
                continue
            }

            sawSpacingScalar = true
            width += Int(scalarWidth)
            guard width <= maximumColumns else { return nil }
        }

        return width
    }
}

struct RemoteGridRow: Codable, Equatable, Sendable {
    let index: Int
    let rowVersion: UInt64
    let cells: [RemoteGridCell]

    private enum CodingKeys: String, CodingKey {
        case index
        case rowVersion
        case cells
        case text
    }

    init(index: Int, rowVersion: UInt64, cells: [RemoteGridCell]) {
        self.index = index
        self.rowVersion = rowVersion
        self.cells = cells
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        rowVersion = try container.decode(UInt64.self, forKey: .rowVersion)
        if container.contains(.cells) {
            cells = try container.decode([RemoteGridCell].self, forKey: .cells)
            return
        }
        let text = try container.decode(String.self, forKey: .text)
        cells = text.map { RemoteGridCell.text(String($0)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(index, forKey: .index)
        try container.encode(rowVersion, forKey: .rowVersion)
        try container.encode(cells, forKey: .cells)
    }
}

struct RemoteCursorState: Codable, Equatable, Sendable {
    let row: Int
    let column: Int
    let visible: Bool
    let shape: RemoteCursorShape
    let cursorVersion: UInt64

    init(
        row: Int,
        column: Int,
        visible: Bool,
        shape: RemoteCursorShape,
        cursorVersion: UInt64 = 1
    ) {
        self.row = row
        self.column = column
        self.visible = visible
        self.shape = shape
        self.cursorVersion = cursorVersion
    }
}

enum RemoteCursorShape: String, Codable, Equatable, Sendable {
    case block
    case bar
    case underline
}

enum RemoteActiveScreen: String, Codable, Equatable, Sendable {
    case primary
    case alternate
}

struct RemotePaneKeyframe: Codable, Equatable, Sendable {
    let workspaceID: String
    let paneID: Int
    let paneGeneration: UInt64
    let keyframeID: UInt64
    let gridSize: RemoteGridSize
    let rows: [RemoteGridRow]
    let cursor: RemoteCursorState
    let activeScreen: RemoteActiveScreen
    let datagramsEnabledAfterKeyframe: Bool
}

struct RemotePaneDelta: Codable, Equatable, Sendable {
    let workspaceID: String
    let paneID: Int
    let paneGeneration: UInt64
    let baseKeyframeID: UInt64
    let deltaSequence: UInt64
    let rowUpdates: [RemoteRowUpdate]
    let cursor: RemoteCursorState?
}

struct RemoteRowUpdate: Codable, Equatable, Sendable {
    let rowIndex: Int
    let rowVersion: UInt64
    let update: RemoteRowUpdateBody
}

enum RemoteRowUpdateBody: Codable, Equatable, Sendable {
    case fullRow([RemoteGridCell])
    case span(baseRowVersion: UInt64, startColumn: Int, cells: [RemoteGridCell], clearToColumn: Int?)

    private enum CodingKeys: String, CodingKey {
        case fullRow
        case fullRowText
        case span
    }

    private enum FullRowCodingKeys: String, CodingKey {
        case cells = "_0"
    }

    private enum SpanCodingKeys: String, CodingKey {
        case baseRowVersion
        case startColumn
        case cells
        case clearToColumn
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.fullRow) {
            let fullRow = try container.nestedContainer(keyedBy: FullRowCodingKeys.self, forKey: .fullRow)
            self = .fullRow(try fullRow.decode([RemoteGridCell].self, forKey: .cells))
            return
        }
        if container.contains(.fullRowText) {
            let fullRow = try container.nestedContainer(keyedBy: FullRowCodingKeys.self, forKey: .fullRowText)
            let text = try fullRow.decode(String.self, forKey: .cells)
            self = .fullRow(text.map { RemoteGridCell.text(String($0)) })
            return
        }
        if container.contains(.span) {
            let span = try container.nestedContainer(keyedBy: SpanCodingKeys.self, forKey: .span)
            self = .span(
                baseRowVersion: try span.decode(UInt64.self, forKey: .baseRowVersion),
                startColumn: try span.decode(Int.self, forKey: .startColumn),
                cells: try span.decode([RemoteGridCell].self, forKey: .cells),
                clearToColumn: try span.decodeIfPresent(Int.self, forKey: .clearToColumn)
            )
            return
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "missing row update body")
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fullRow(let cells):
            var fullRow = container.nestedContainer(keyedBy: FullRowCodingKeys.self, forKey: .fullRow)
            try fullRow.encode(cells, forKey: .cells)
        case .span(let baseRowVersion, let startColumn, let cells, let clearToColumn):
            var span = container.nestedContainer(keyedBy: SpanCodingKeys.self, forKey: .span)
            try span.encode(baseRowVersion, forKey: .baseRowVersion)
            try span.encode(startColumn, forKey: .startColumn)
            try span.encode(cells, forKey: .cells)
            try span.encodeIfPresent(clearToColumn, forKey: .clearToColumn)
        }
    }
}

struct RemoteWorkspaceSnapshot: Codable, Equatable, Sendable {
    let workspaceID: String
    let layoutGeneration: UInt64
    let windows: [RemoteWorkspaceWindow]
    let panes: [RemoteWorkspacePane]
}

struct RemoteWorkspaceWindow: Codable, Equatable, Sendable {
    let windowID: Int
    let title: String
    let index: Int?
    let isActive: Bool
    let layout: String?

    init(windowID: Int, title: String, index: Int?, isActive: Bool, layout: String? = nil) {
        self.windowID = windowID
        self.title = title
        self.index = index
        self.isActive = isActive
        self.layout = layout
    }
}

struct RemoteWorkspacePane: Codable, Equatable, Sendable {
    let paneID: Int
    let windowID: Int
    let isActive: Bool
    let frame: RemotePaneFrame
}

struct RemotePaneFrame: Codable, Equatable, Sendable {
    let x: Int
    let y: Int
    let columns: Int
    let rows: Int
}

struct RemoteUnsupportedPaneState: Codable, Equatable, Sendable {
    let workspaceID: String
    let paneID: Int
    let paneGeneration: UInt64
    let reason: RemoteUnsupportedPaneReason
    let fallback: RemoteUnsupportedPaneFallback
}

enum RemoteUnsupportedPaneReason: String, Codable, Equatable, Sendable {
    case imageProtocol
    case glyphGlossaryMutation
    case unsupportedCellAttribute
    case snapshotExtractionFailure
}

enum RemoteUnsupportedPaneFallback: String, Codable, Equatable, Sendable {
    case keepLastGoodKeyframe
    case blankWithDiagnostic
}

enum RemoteWorkspaceMessage: Codable, Equatable, Sendable {
    case workspaceSnapshot(RemoteWorkspaceSnapshot)
    case paneKeyframe(RemotePaneKeyframe)
    case paneDelta(RemotePaneDelta)
    case unsupportedPaneState(RemoteUnsupportedPaneState)
}
