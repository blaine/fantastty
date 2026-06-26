package remotegrid

import (
	"encoding/json"
	"fmt"
	"strings"
	"unicode/utf8"
)

type GridSize struct {
	Columns int `json:"columns"`
	Rows    int `json:"rows"`
}

type colorKind string

const (
	colorDefault colorKind = "default"
	colorIndexed colorKind = "indexed"
	colorRGB     colorKind = "rgb"
)

type Color struct {
	kind  colorKind
	index uint8
	red   uint8
	green uint8
	blue  uint8
}

var DefaultColor = Color{kind: colorDefault}

func IndexedColor(index uint8) Color {
	return Color{kind: colorIndexed, index: index}
}

func RGBColor(red uint8, green uint8, blue uint8) Color {
	return Color{kind: colorRGB, red: red, green: green, blue: blue}
}

func (c Color) MarshalJSON() ([]byte, error) {
	switch c.kind {
	case "", colorDefault:
		return []byte(`{"default":{}}`), nil
	case colorIndexed:
		return json.Marshal(struct {
			Indexed struct {
				Index uint8 `json:"_0"`
			} `json:"indexed"`
		}{
			Indexed: struct {
				Index uint8 `json:"_0"`
			}{Index: c.index},
		})
	case colorRGB:
		return json.Marshal(struct {
			RGB struct {
				Red   uint8 `json:"red"`
				Green uint8 `json:"green"`
				Blue  uint8 `json:"blue"`
			} `json:"rgb"`
		}{
			RGB: struct {
				Red   uint8 `json:"red"`
				Green uint8 `json:"green"`
				Blue  uint8 `json:"blue"`
			}{Red: c.red, Green: c.green, Blue: c.blue},
		})
	default:
		return nil, fmt.Errorf("remotegrid: unsupported color kind %q", c.kind)
	}
}

type UnderlineStyle string

const (
	UnderlineStyleNone   UnderlineStyle = "none"
	UnderlineStyleSingle UnderlineStyle = "single"
	UnderlineStyleDouble UnderlineStyle = "double"
	UnderlineStyleCurly  UnderlineStyle = "curly"
	UnderlineStyleDotted UnderlineStyle = "dotted"
	UnderlineStyleDashed UnderlineStyle = "dashed"
)

type CellStyle struct {
	Foreground     Color          `json:"foreground"`
	Background     Color          `json:"background"`
	UnderlineColor Color          `json:"underlineColor"`
	Bold           bool           `json:"bold"`
	Faint          bool           `json:"faint"`
	Italic         bool           `json:"italic"`
	Underline      UnderlineStyle `json:"underline"`
	Blink          bool           `json:"blink"`
	Inverse        bool           `json:"inverse"`
	Invisible      bool           `json:"invisible"`
	Strikethrough  bool           `json:"strikethrough"`
}

var NormalCellStyle = CellStyle{
	Foreground:     DefaultColor,
	Background:     DefaultColor,
	UnderlineColor: DefaultColor,
	Underline:      UnderlineStyleNone,
}

type GridCell struct {
	Text  string    `json:"text"`
	Width int       `json:"width"`
	Style CellStyle `json:"style"`
}

type GridRow struct {
	Index      int        `json:"index"`
	RowVersion uint64     `json:"rowVersion"`
	Cells      []GridCell `json:"cells"`
}

func (r GridRow) MarshalJSON() ([]byte, error) {
	if text, ok := r.compactText(); ok {
		type gridRowTextJSON struct {
			Index      int    `json:"index"`
			RowVersion uint64 `json:"rowVersion"`
			Text       string `json:"text"`
		}
		return json.Marshal(gridRowTextJSON{
			Index:      r.Index,
			RowVersion: r.RowVersion,
			Text:       text,
		})
	}

	type gridRowJSON struct {
		Index      int        `json:"index"`
		RowVersion uint64     `json:"rowVersion"`
		Cells      []GridCell `json:"cells"`
	}
	return json.Marshal(gridRowJSON{
		Index:      r.Index,
		RowVersion: r.RowVersion,
		Cells:      nonNilGridCells(r.Cells),
	})
}

func (r GridRow) compactText() (string, bool) {
	if len(r.Cells) == 0 {
		return "", false
	}

	var builder strings.Builder
	for _, cell := range r.Cells {
		if cell.Width != 1 || cell.Style != NormalCellStyle {
			return "", false
		}
		builder.WriteString(cell.Text)
	}
	return builder.String(), true
}

type CursorShape string

const (
	CursorShapeBlock     CursorShape = "block"
	CursorShapeBar       CursorShape = "bar"
	CursorShapeUnderline CursorShape = "underline"
)

type CursorState struct {
	Row           int         `json:"row"`
	Column        int         `json:"column"`
	Visible       bool        `json:"visible"`
	Shape         CursorShape `json:"shape"`
	CursorVersion uint64      `json:"cursorVersion"`
}

type ActiveScreen string

const (
	ActiveScreenPrimary   ActiveScreen = "primary"
	ActiveScreenAlternate ActiveScreen = "alternate"
)

type ScrollRegion struct {
	Upper int `json:"-"`
	Lower int `json:"-"`
}

type PaneInitialCapture struct {
	PrimaryRows   []string      `json:"-"`
	AlternateRows []string      `json:"-"`
	ActiveScreen  ActiveScreen  `json:"-"`
	Cursor        *CursorState  `json:"-"`
	ScrollRegion  *ScrollRegion `json:"-"`
}

type PaneKeyframe struct {
	WorkspaceID                   string       `json:"workspaceID"`
	PaneID                        int          `json:"paneID"`
	PaneGeneration                uint64       `json:"paneGeneration"`
	KeyframeID                    uint64       `json:"keyframeID"`
	GridSize                      GridSize     `json:"gridSize"`
	Rows                          []GridRow    `json:"rows"`
	Cursor                        CursorState  `json:"cursor"`
	ActiveScreen                  ActiveScreen `json:"activeScreen"`
	DatagramsEnabledAfterKeyframe bool         `json:"datagramsEnabledAfterKeyframe"`
}

func (k PaneKeyframe) MarshalJSON() ([]byte, error) {
	type paneKeyframeJSON struct {
		WorkspaceID                   string       `json:"workspaceID"`
		PaneID                        int          `json:"paneID"`
		PaneGeneration                uint64       `json:"paneGeneration"`
		KeyframeID                    uint64       `json:"keyframeID"`
		GridSize                      GridSize     `json:"gridSize"`
		Rows                          []GridRow    `json:"rows"`
		Cursor                        CursorState  `json:"cursor"`
		ActiveScreen                  ActiveScreen `json:"activeScreen"`
		DatagramsEnabledAfterKeyframe bool         `json:"datagramsEnabledAfterKeyframe"`
	}
	return json.Marshal(paneKeyframeJSON{
		WorkspaceID:                   k.WorkspaceID,
		PaneID:                        k.PaneID,
		PaneGeneration:                k.PaneGeneration,
		KeyframeID:                    k.KeyframeID,
		GridSize:                      k.GridSize,
		Rows:                          nonNilGridRows(k.Rows),
		Cursor:                        k.Cursor,
		ActiveScreen:                  k.ActiveScreen,
		DatagramsEnabledAfterKeyframe: k.DatagramsEnabledAfterKeyframe,
	})
}

type PaneDelta struct {
	WorkspaceID    string       `json:"workspaceID"`
	PaneID         int          `json:"paneID"`
	PaneGeneration uint64       `json:"paneGeneration"`
	BaseKeyframeID uint64       `json:"baseKeyframeID"`
	DeltaSequence  uint64       `json:"deltaSequence"`
	RowUpdates     []RowUpdate  `json:"rowUpdates"`
	Cursor         *CursorState `json:"cursor,omitempty"`
}

func (d PaneDelta) MarshalJSON() ([]byte, error) {
	type paneDeltaJSON struct {
		WorkspaceID    string       `json:"workspaceID"`
		PaneID         int          `json:"paneID"`
		PaneGeneration uint64       `json:"paneGeneration"`
		BaseKeyframeID uint64       `json:"baseKeyframeID"`
		DeltaSequence  uint64       `json:"deltaSequence"`
		RowUpdates     []RowUpdate  `json:"rowUpdates"`
		Cursor         *CursorState `json:"cursor,omitempty"`
	}
	return json.Marshal(paneDeltaJSON{
		WorkspaceID:    d.WorkspaceID,
		PaneID:         d.PaneID,
		PaneGeneration: d.PaneGeneration,
		BaseKeyframeID: d.BaseKeyframeID,
		DeltaSequence:  d.DeltaSequence,
		RowUpdates:     nonNilRowUpdates(d.RowUpdates),
		Cursor:         d.Cursor,
	})
}

func MarshalCompactPaneDelta(delta PaneDelta) ([]byte, error) {
	type compactPaneDeltaJSON struct {
		WorkspaceID    string             `json:"workspaceID"`
		PaneID         int                `json:"paneID"`
		PaneGeneration uint64             `json:"paneGeneration"`
		BaseKeyframeID uint64             `json:"baseKeyframeID"`
		DeltaSequence  uint64             `json:"deltaSequence"`
		RowUpdates     []compactRowUpdate `json:"rowUpdates"`
		Cursor         *CursorState       `json:"cursor,omitempty"`
	}
	updates := make([]compactRowUpdate, len(nonNilRowUpdates(delta.RowUpdates)))
	for index, update := range nonNilRowUpdates(delta.RowUpdates) {
		updates[index] = compactRowUpdate(update)
	}
	return json.Marshal(compactPaneDeltaJSON{
		WorkspaceID:    delta.WorkspaceID,
		PaneID:         delta.PaneID,
		PaneGeneration: delta.PaneGeneration,
		BaseKeyframeID: delta.BaseKeyframeID,
		DeltaSequence:  delta.DeltaSequence,
		RowUpdates:     updates,
		Cursor:         delta.Cursor,
	})
}

func MarshalCompactPaneDeltaMessage(delta PaneDelta) ([]byte, error) {
	payload, err := MarshalCompactPaneDelta(delta)
	if err != nil {
		return nil, err
	}
	type paneDeltaEnvelope struct {
		PaneDelta struct {
			Value json.RawMessage `json:"_0"`
		} `json:"paneDelta"`
	}
	var envelope paneDeltaEnvelope
	envelope.PaneDelta.Value = json.RawMessage(payload)
	return json.Marshal(envelope)
}

type WorkspaceSnapshot struct {
	WorkspaceID      string            `json:"workspaceID"`
	LayoutGeneration uint64            `json:"layoutGeneration"`
	Windows          []WorkspaceWindow `json:"windows"`
	Panes            []WorkspacePane   `json:"panes"`
}

func (s WorkspaceSnapshot) MarshalJSON() ([]byte, error) {
	type workspaceSnapshotJSON struct {
		WorkspaceID      string            `json:"workspaceID"`
		LayoutGeneration uint64            `json:"layoutGeneration"`
		Windows          []WorkspaceWindow `json:"windows"`
		Panes            []WorkspacePane   `json:"panes"`
	}
	return json.Marshal(workspaceSnapshotJSON{
		WorkspaceID:      s.WorkspaceID,
		LayoutGeneration: s.LayoutGeneration,
		Windows:          nonNilWorkspaceWindows(s.Windows),
		Panes:            nonNilWorkspacePanes(s.Panes),
	})
}

type WorkspaceWindow struct {
	WindowID int    `json:"windowID"`
	Title    string `json:"title"`
	Index    *int   `json:"index"`
	IsActive bool   `json:"isActive"`
	Layout   string `json:"layout,omitempty"`
}

type WorkspacePane struct {
	PaneID                 int                `json:"paneID"`
	WindowID               int                `json:"windowID"`
	IsActive               bool               `json:"isActive"`
	Frame                  PaneFrame          `json:"frame"`
	InitialRows            []string           `json:"-"`
	InitialCapture         PaneInitialCapture `json:"-"`
	RepaintFromInitialRows bool               `json:"-"`
}

type PaneFrame struct {
	X       int `json:"x"`
	Y       int `json:"y"`
	Columns int `json:"columns"`
	Rows    int `json:"rows"`
}

type UnsupportedPaneReason string

const (
	UnsupportedPaneReasonImageProtocol             UnsupportedPaneReason = "imageProtocol"
	UnsupportedPaneReasonGlyphGlossaryMutation     UnsupportedPaneReason = "glyphGlossaryMutation"
	UnsupportedPaneReasonUnsupportedCellAttribute  UnsupportedPaneReason = "unsupportedCellAttribute"
	UnsupportedPaneReasonSnapshotExtractionFailure UnsupportedPaneReason = "snapshotExtractionFailure"
)

type UnsupportedPaneFallback string

const (
	UnsupportedPaneFallbackKeepLastGoodKeyframe UnsupportedPaneFallback = "keepLastGoodKeyframe"
	UnsupportedPaneFallbackBlankWithDiagnostic  UnsupportedPaneFallback = "blankWithDiagnostic"
)

type UnsupportedPaneState struct {
	WorkspaceID    string                  `json:"workspaceID"`
	PaneID         int                     `json:"paneID"`
	PaneGeneration uint64                  `json:"paneGeneration"`
	Reason         UnsupportedPaneReason   `json:"reason"`
	Fallback       UnsupportedPaneFallback `json:"fallback"`
}

type RowUpdate struct {
	RowIndex   int           `json:"rowIndex"`
	RowVersion uint64        `json:"rowVersion"`
	Update     RowUpdateBody `json:"update"`
}

type RowUpdateBody struct {
	fullRow []GridCell
	span    *rowUpdateSpan
}

type rowUpdateSpan struct {
	BaseRowVersion uint64     `json:"baseRowVersion"`
	StartColumn    int        `json:"startColumn"`
	Cells          []GridCell `json:"cells"`
	ClearToColumn  *int       `json:"clearToColumn,omitempty"`
}

func FullRow(cells []GridCell) RowUpdateBody {
	return RowUpdateBody{fullRow: cells}
}

func Span(baseRowVersion uint64, startColumn int, cells []GridCell, clearToColumn *int) RowUpdateBody {
	return RowUpdateBody{
		span: &rowUpdateSpan{
			BaseRowVersion: baseRowVersion,
			StartColumn:    startColumn,
			Cells:          cells,
			ClearToColumn:  clearToColumn,
		},
	}
}

func (b RowUpdateBody) IsFullRow() bool {
	return b.span == nil
}

func (b RowUpdateBody) SpanBaseRowVersion() (uint64, bool) {
	if b.span == nil {
		return 0, false
	}
	return b.span.BaseRowVersion, true
}

func (b RowUpdateBody) MarshalJSON() ([]byte, error) {
	if b.span != nil {
		span := *b.span
		span.Cells = nonNilGridCells(span.Cells)
		return json.Marshal(struct {
			Span rowUpdateSpan `json:"span"`
		}{Span: span})
	}

	return json.Marshal(struct {
		FullRow struct {
			Cells []GridCell `json:"_0"`
		} `json:"fullRow"`
	}{
		FullRow: struct {
			Cells []GridCell `json:"_0"`
		}{Cells: nonNilGridCells(b.fullRow)},
	})
}

func (b *RowUpdateBody) UnmarshalJSON(data []byte) error {
	var raw struct {
		FullRow *struct {
			Cells []GridCell `json:"_0"`
		} `json:"fullRow"`
		FullRowText *struct {
			Text string `json:"_0"`
		} `json:"fullRowText"`
		Span *rowUpdateSpan `json:"span"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	switch {
	case raw.FullRow != nil:
		*b = FullRow(raw.FullRow.Cells)
	case raw.FullRowText != nil:
		*b = FullRow(textCells(raw.FullRowText.Text))
	case raw.Span != nil:
		span := *raw.Span
		span.Cells = nonNilGridCells(span.Cells)
		*b = RowUpdateBody{span: &span}
	default:
		return fmt.Errorf("remotegrid: missing row update body")
	}
	return nil
}

type compactRowUpdate RowUpdate

func (u compactRowUpdate) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		RowIndex   int                  `json:"rowIndex"`
		RowVersion uint64               `json:"rowVersion"`
		Update     compactRowUpdateBody `json:"update"`
	}{
		RowIndex:   u.RowIndex,
		RowVersion: u.RowVersion,
		Update:     compactRowUpdateBody(u.Update),
	})
}

type compactRowUpdateBody RowUpdateBody

func (b compactRowUpdateBody) MarshalJSON() ([]byte, error) {
	body := RowUpdateBody(b)
	if text, ok := compactFullRowText(body.fullRow); ok {
		return json.Marshal(struct {
			FullRowText struct {
				Text string `json:"_0"`
			} `json:"fullRowText"`
		}{
			FullRowText: struct {
				Text string `json:"_0"`
			}{Text: text},
		})
	}
	return body.MarshalJSON()
}

func compactFullRowText(cells []GridCell) (string, bool) {
	var text string
	for _, cell := range cells {
		if cell.Width != 1 || cell.Style != NormalCellStyle || utf8.RuneCountInString(cell.Text) != 1 {
			return "", false
		}
		text += cell.Text
	}
	return text, true
}

func textCells(text string) []GridCell {
	cells := make([]GridCell, 0, utf8.RuneCountInString(text))
	for _, r := range text {
		cells = append(cells, GridCell{Text: string(r), Width: 1, Style: NormalCellStyle})
	}
	return cells
}

type workspaceMessageKind string

const (
	workspaceMessagePaneKeyframe         workspaceMessageKind = "paneKeyframe"
	workspaceMessagePaneDelta            workspaceMessageKind = "paneDelta"
	workspaceMessageWorkspaceSnapshot    workspaceMessageKind = "workspaceSnapshot"
	workspaceMessageUnsupportedPaneState workspaceMessageKind = "unsupportedPaneState"
)

type WorkspaceMessage struct {
	kind                 workspaceMessageKind
	keyframe             *PaneKeyframe
	delta                *PaneDelta
	workspaceSnapshot    *WorkspaceSnapshot
	unsupportedPaneState *UnsupportedPaneState
}

func PaneKeyframeMessage(keyframe PaneKeyframe) WorkspaceMessage {
	return WorkspaceMessage{kind: workspaceMessagePaneKeyframe, keyframe: &keyframe}
}

func PaneDeltaMessage(delta PaneDelta) WorkspaceMessage {
	return WorkspaceMessage{kind: workspaceMessagePaneDelta, delta: &delta}
}

func WorkspaceSnapshotMessage(snapshot WorkspaceSnapshot) WorkspaceMessage {
	return WorkspaceMessage{kind: workspaceMessageWorkspaceSnapshot, workspaceSnapshot: &snapshot}
}

func UnsupportedPaneStateMessage(state UnsupportedPaneState) WorkspaceMessage {
	return WorkspaceMessage{kind: workspaceMessageUnsupportedPaneState, unsupportedPaneState: &state}
}

func (m WorkspaceMessage) WorkspaceSnapshot() (WorkspaceSnapshot, bool) {
	if m.kind != workspaceMessageWorkspaceSnapshot || m.workspaceSnapshot == nil {
		return WorkspaceSnapshot{}, false
	}
	return cloneWorkspaceSnapshot(*m.workspaceSnapshot), true
}

func (m WorkspaceMessage) PaneKeyframe() (PaneKeyframe, bool) {
	if m.kind != workspaceMessagePaneKeyframe || m.keyframe == nil {
		return PaneKeyframe{}, false
	}
	return ClonePaneKeyframe(*m.keyframe), true
}

func (m WorkspaceMessage) PaneKeyframeIdentity() (string, int, bool) {
	if m.kind != workspaceMessagePaneKeyframe || m.keyframe == nil {
		return "", 0, false
	}
	return m.keyframe.WorkspaceID, m.keyframe.PaneID, true
}

func (m WorkspaceMessage) UnsupportedPaneState() (UnsupportedPaneState, bool) {
	if m.kind != workspaceMessageUnsupportedPaneState || m.unsupportedPaneState == nil {
		return UnsupportedPaneState{}, false
	}
	return *m.unsupportedPaneState, true
}

func (m WorkspaceMessage) PaneDelta() (PaneDelta, bool) {
	if m.kind != workspaceMessagePaneDelta || m.delta == nil {
		return PaneDelta{}, false
	}
	return clonePaneDelta(*m.delta), true
}

func (m WorkspaceMessage) MarshalJSON() ([]byte, error) {
	switch m.kind {
	case workspaceMessagePaneKeyframe:
		if m.keyframe == nil {
			return nil, fmt.Errorf("remotegrid: pane keyframe message missing payload")
		}
		return json.Marshal(struct {
			PaneKeyframe struct {
				Value PaneKeyframe `json:"_0"`
			} `json:"paneKeyframe"`
		}{
			PaneKeyframe: struct {
				Value PaneKeyframe `json:"_0"`
			}{Value: *m.keyframe},
		})
	case workspaceMessagePaneDelta:
		if m.delta == nil {
			return nil, fmt.Errorf("remotegrid: pane delta message missing payload")
		}
		return json.Marshal(struct {
			PaneDelta struct {
				Value PaneDelta `json:"_0"`
			} `json:"paneDelta"`
		}{
			PaneDelta: struct {
				Value PaneDelta `json:"_0"`
			}{Value: *m.delta},
		})
	case workspaceMessageWorkspaceSnapshot:
		if m.workspaceSnapshot == nil {
			return nil, fmt.Errorf("remotegrid: workspace snapshot message missing payload")
		}
		return json.Marshal(struct {
			WorkspaceSnapshot struct {
				Value WorkspaceSnapshot `json:"_0"`
			} `json:"workspaceSnapshot"`
		}{
			WorkspaceSnapshot: struct {
				Value WorkspaceSnapshot `json:"_0"`
			}{Value: *m.workspaceSnapshot},
		})
	case workspaceMessageUnsupportedPaneState:
		if m.unsupportedPaneState == nil {
			return nil, fmt.Errorf("remotegrid: unsupported pane state message missing payload")
		}
		return json.Marshal(struct {
			UnsupportedPaneState struct {
				Value UnsupportedPaneState `json:"_0"`
			} `json:"unsupportedPaneState"`
		}{
			UnsupportedPaneState: struct {
				Value UnsupportedPaneState `json:"_0"`
			}{Value: *m.unsupportedPaneState},
		})
	default:
		return nil, fmt.Errorf("remotegrid: unsupported workspace message kind %q", m.kind)
	}
}

func nonNilGridCells(cells []GridCell) []GridCell {
	if cells == nil {
		return []GridCell{}
	}
	return cells
}

func nonNilGridRows(rows []GridRow) []GridRow {
	if rows == nil {
		return []GridRow{}
	}
	return rows
}

func nonNilRowUpdates(updates []RowUpdate) []RowUpdate {
	if updates == nil {
		return []RowUpdate{}
	}
	return updates
}

func nonNilWorkspaceWindows(windows []WorkspaceWindow) []WorkspaceWindow {
	if windows == nil {
		return []WorkspaceWindow{}
	}
	return windows
}

func nonNilWorkspacePanes(panes []WorkspacePane) []WorkspacePane {
	if panes == nil {
		return []WorkspacePane{}
	}
	return panes
}
