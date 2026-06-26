package remotegrid

import (
	"bytes"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func TestWorkspaceMessageEncodesPaneKeyframeEnvelope(t *testing.T) {
	keyframe := PaneKeyframe{
		WorkspaceID:                   "workspace-1",
		PaneID:                        7,
		PaneGeneration:                3,
		KeyframeID:                    11,
		GridSize:                      GridSize{Columns: 2, Rows: 1},
		Rows:                          []GridRow{{Index: 0, RowVersion: 10, Cells: []GridCell{textCell("o"), textCell("k")}}},
		Cursor:                        CursorState{Row: 0, Column: 1, Visible: true, Shape: CursorShapeBlock, CursorVersion: 9},
		ActiveScreen:                  ActiveScreenPrimary,
		DatagramsEnabledAfterKeyframe: true,
	}

	got, err := json.Marshal(PaneKeyframeMessage(keyframe))
	if err != nil {
		t.Fatal(err)
	}

	assertJSONEqual(t, got, `{
		"paneKeyframe": {
			"_0": {
				"workspaceID": "workspace-1",
				"paneID": 7,
				"paneGeneration": 3,
				"keyframeID": 11,
				"gridSize": { "columns": 2, "rows": 1 },
				"rows": [
						{
							"index": 0,
							"rowVersion": 10,
							"text": "ok"
						}
					],
				"cursor": { "row": 0, "column": 1, "visible": true, "shape": "block", "cursorVersion": 9 },
				"activeScreen": "primary",
				"datagramsEnabledAfterKeyframe": true
			}
		}
	}`)
}

func TestWorkspaceMessageEncodesWorkspaceSnapshotEnvelope(t *testing.T) {
	snapshot := WorkspaceSnapshot{
		WorkspaceID:      "workspace-1",
		LayoutGeneration: 4,
		Windows: []WorkspaceWindow{{
			WindowID: 1,
			Title:    "main",
			Index:    intPtr(0),
			IsActive: true,
		}},
		Panes: []WorkspacePane{{
			PaneID:   7,
			WindowID: 1,
			IsActive: true,
			Frame:    PaneFrame{X: 0, Y: 0, Columns: 80, Rows: 24},
		}},
	}

	got, err := json.Marshal(WorkspaceSnapshotMessage(snapshot))
	if err != nil {
		t.Fatal(err)
	}

	assertJSONEqual(t, got, `{
		"workspaceSnapshot": {
			"_0": {
				"workspaceID": "workspace-1",
				"layoutGeneration": 4,
				"windows": [
					{
						"windowID": 1,
						"title": "main",
						"index": 0,
						"isActive": true
					}
				],
				"panes": [
					{
						"paneID": 7,
						"windowID": 1,
						"isActive": true,
						"frame": {
							"x": 0,
							"y": 0,
							"columns": 80,
							"rows": 24
						}
					}
				]
			}
		}
	}`)
}

func TestGridRowEncodesNormalCellsAsText(t *testing.T) {
	row := GridRow{
		Index:      3,
		RowVersion: 9,
		Cells: []GridCell{
			TextCell("o"),
			TextCell("k"),
		},
	}

	got, err := json.Marshal(row)
	if err != nil {
		t.Fatal(err)
	}

	assertJSONEqual(t, got, `{
		"index": 3,
		"rowVersion": 9,
		"text": "ok"
	}`)
}

func TestGridRowKeepsStyledCellsExpanded(t *testing.T) {
	row := GridRow{
		Index:      3,
		RowVersion: 9,
		Cells: []GridCell{{
			Text:  "!",
			Width: 1,
			Style: CellStyle{
				Foreground:     IndexedColor(2),
				Background:     DefaultColor,
				UnderlineColor: DefaultColor,
				Underline:      UnderlineStyleNone,
			},
		}},
	}

	got, err := json.Marshal(row)
	if err != nil {
		t.Fatal(err)
	}

	if !strings.Contains(string(got), `"cells"`) {
		t.Fatalf("encoded styled row = %s, want expanded cells", got)
	}
}

func TestWorkspaceMessageEncodesUnsupportedPaneStateEnvelope(t *testing.T) {
	state := UnsupportedPaneState{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 3,
		Reason:         UnsupportedPaneReasonSnapshotExtractionFailure,
		Fallback:       UnsupportedPaneFallbackKeepLastGoodKeyframe,
	}

	got, err := json.Marshal(UnsupportedPaneStateMessage(state))
	if err != nil {
		t.Fatal(err)
	}

	assertJSONEqual(t, got, `{
		"unsupportedPaneState": {
			"_0": {
				"workspaceID": "workspace-1",
				"paneID": 7,
				"paneGeneration": 3,
				"reason": "snapshotExtractionFailure",
				"fallback": "keepLastGoodKeyframe"
			}
		}
	}`)
}

func TestUnsupportedPaneStateConstantsMirrorSwiftProtocolValues(t *testing.T) {
	reasons := map[UnsupportedPaneReason]string{
		UnsupportedPaneReasonImageProtocol:             "imageProtocol",
		UnsupportedPaneReasonGlyphGlossaryMutation:     "glyphGlossaryMutation",
		UnsupportedPaneReasonUnsupportedCellAttribute:  "unsupportedCellAttribute",
		UnsupportedPaneReasonSnapshotExtractionFailure: "snapshotExtractionFailure",
	}
	for reason, want := range reasons {
		if string(reason) != want {
			t.Fatalf("unsupported pane reason = %q, want %q", reason, want)
		}
	}

	fallbacks := map[UnsupportedPaneFallback]string{
		UnsupportedPaneFallbackKeepLastGoodKeyframe: "keepLastGoodKeyframe",
		UnsupportedPaneFallbackBlankWithDiagnostic:  "blankWithDiagnostic",
	}
	for fallback, want := range fallbacks {
		if string(fallback) != want {
			t.Fatalf("unsupported pane fallback = %q, want %q", fallback, want)
		}
	}
}

func TestPaneDeltaEncodesFullRowAndSpanUpdateEnvelopes(t *testing.T) {
	clearToColumn := 4
	delta := PaneDelta{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 3,
		BaseKeyframeID: 11,
		DeltaSequence:  12,
		RowUpdates: []RowUpdate{
			{RowIndex: 0, RowVersion: 13, Update: FullRow([]GridCell{textCell("o"), textCell("k")})},
			{
				RowIndex:   1,
				RowVersion: 14,
				Update:     Span(12, 2, []GridCell{textCell("!"), textCell(" ")}, &clearToColumn),
			},
		},
		Cursor: &CursorState{Row: 0, Column: 2, Visible: true, Shape: CursorShapeBar, CursorVersion: 10},
	}

	got, err := json.Marshal(delta)
	if err != nil {
		t.Fatal(err)
	}

	assertJSONEqual(t, got, `{
		"workspaceID": "workspace-1",
		"paneID": 7,
		"paneGeneration": 3,
		"baseKeyframeID": 11,
		"deltaSequence": 12,
		"rowUpdates": [
			{
				"rowIndex": 0,
				"rowVersion": 13,
				"update": {
					"fullRow": {
						"_0": [
							{
								"text": "o",
								"width": 1,
								"style": {
									"foreground": { "default": {} },
									"background": { "default": {} },
									"underlineColor": { "default": {} },
									"bold": false,
									"faint": false,
									"italic": false,
									"underline": "none",
									"blink": false,
									"inverse": false,
									"invisible": false,
									"strikethrough": false
								}
							},
							{
								"text": "k",
								"width": 1,
								"style": {
									"foreground": { "default": {} },
									"background": { "default": {} },
									"underlineColor": { "default": {} },
									"bold": false,
									"faint": false,
									"italic": false,
									"underline": "none",
									"blink": false,
									"inverse": false,
									"invisible": false,
									"strikethrough": false
								}
							}
						]
					}
				}
			},
			{
				"rowIndex": 1,
				"rowVersion": 14,
				"update": {
					"span": {
						"baseRowVersion": 12,
						"startColumn": 2,
						"cells": [
							{
								"text": "!",
								"width": 1,
								"style": {
									"foreground": { "default": {} },
									"background": { "default": {} },
									"underlineColor": { "default": {} },
									"bold": false,
									"faint": false,
									"italic": false,
									"underline": "none",
									"blink": false,
									"inverse": false,
									"invisible": false,
									"strikethrough": false
								}
							},
							{
								"text": " ",
								"width": 1,
								"style": {
									"foreground": { "default": {} },
									"background": { "default": {} },
									"underlineColor": { "default": {} },
									"bold": false,
									"faint": false,
									"italic": false,
									"underline": "none",
									"blink": false,
									"inverse": false,
									"invisible": false,
									"strikethrough": false
								}
							}
						],
						"clearToColumn": 4
					}
				}
			}
		],
		"cursor": { "row": 0, "column": 2, "visible": true, "shape": "bar", "cursorVersion": 10 }
	}`)
}

func TestProtocolArrayFieldsMarshalAsEmptyArrays(t *testing.T) {
	snapshotJSON, err := json.Marshal(WorkspaceSnapshotMessage(WorkspaceSnapshot{WorkspaceID: "workspace-1"}))
	if err != nil {
		t.Fatal(err)
	}
	assertJSONEqual(t, snapshotJSON, `{
		"workspaceSnapshot": {
			"_0": {
				"workspaceID": "workspace-1",
				"layoutGeneration": 0,
				"windows": [],
				"panes": []
			}
		}
	}`)

	keyframeJSON, err := json.Marshal(PaneKeyframeMessage(PaneKeyframe{
		WorkspaceID: "workspace-1",
		GridSize:    GridSize{Columns: 0, Rows: 0},
		Cursor:      CursorState{Shape: CursorShapeBlock, CursorVersion: 1},
	}))
	if err != nil {
		t.Fatal(err)
	}
	assertJSONEqual(t, keyframeJSON, `{
		"paneKeyframe": {
			"_0": {
				"workspaceID": "workspace-1",
				"paneID": 0,
				"paneGeneration": 0,
				"keyframeID": 0,
				"gridSize": { "columns": 0, "rows": 0 },
				"rows": [],
				"cursor": { "row": 0, "column": 0, "visible": false, "shape": "block", "cursorVersion": 1 },
				"activeScreen": "",
				"datagramsEnabledAfterKeyframe": false
			}
		}
	}`)

	deltaJSON, err := json.Marshal(PaneDelta{WorkspaceID: "workspace-1"})
	if err != nil {
		t.Fatal(err)
	}
	assertJSONEqual(t, deltaJSON, `{
		"workspaceID": "workspace-1",
		"paneID": 0,
		"paneGeneration": 0,
		"baseKeyframeID": 0,
		"deltaSequence": 0,
		"rowUpdates": []
	}`)

	rowJSON, err := json.Marshal(GridRow{Index: 1})
	if err != nil {
		t.Fatal(err)
	}
	assertJSONEqual(t, rowJSON, `{
		"index": 1,
		"rowVersion": 0,
		"cells": []
	}`)

	fullRowJSON, err := json.Marshal(FullRow(nil))
	if err != nil {
		t.Fatal(err)
	}
	assertJSONEqual(t, fullRowJSON, `{
		"fullRow": {
			"_0": []
		}
	}`)

	spanJSON, err := json.Marshal(Span(3, 1, nil, nil))
	if err != nil {
		t.Fatal(err)
	}
	assertJSONEqual(t, spanJSON, `{
		"span": {
			"baseRowVersion": 3,
			"startColumn": 1,
			"cells": []
		}
	}`)
}

func TestColorEncodesSwiftCodableEnumShapes(t *testing.T) {
	tests := []struct {
		name  string
		color Color
		want  string
	}{
		{
			name:  "default",
			color: DefaultColor,
			want:  `{"default":{}}`,
		},
		{
			name:  "indexed",
			color: IndexedColor(196),
			want:  `{"indexed":{"_0":196}}`,
		},
		{
			name:  "rgb",
			color: RGBColor(12, 34, 56),
			want:  `{"rgb":{"red":12,"green":34,"blue":56}}`,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := json.Marshal(tt.color)
			if err != nil {
				t.Fatal(err)
			}
			assertJSONEqual(t, got, tt.want)
		})
	}
}

func TestCellStyleEncodesUnderlineColor(t *testing.T) {
	style := NormalCellStyle
	style.Foreground = IndexedColor(196)
	style.UnderlineColor = RGBColor(12, 34, 56)
	style.Underline = UnderlineStyleSingle

	got, err := json.Marshal(style)
	if err != nil {
		t.Fatal(err)
	}

	assertJSONEqual(t, got, `{
		"foreground": { "indexed": { "_0": 196 } },
		"background": { "default": {} },
		"underlineColor": { "rgb": { "red": 12, "green": 34, "blue": 56 } },
		"bold": false,
		"faint": false,
		"italic": false,
		"underline": "single",
		"blink": false,
		"inverse": false,
		"invisible": false,
		"strikethrough": false
	}`)
}

func textCell(text string) GridCell {
	return GridCell{Text: text, Width: 1, Style: NormalCellStyle}
}

func intPtr(value int) *int {
	return &value
}

func assertJSONEqual(t *testing.T, got []byte, want string) {
	t.Helper()

	var gotValue any
	if err := json.Unmarshal(got, &gotValue); err != nil {
		t.Fatalf("unmarshal actual JSON: %v\n%s", err, got)
	}

	var wantValue any
	if err := json.Unmarshal([]byte(want), &wantValue); err != nil {
		t.Fatalf("unmarshal expected JSON: %v\n%s", err, want)
	}

	if !reflect.DeepEqual(gotValue, wantValue) {
		t.Fatalf("JSON mismatch\nactual:   %s\nexpected: %s", compactJSON(t, got), compactJSON(t, []byte(want)))
	}
}

func compactJSON(t *testing.T, data []byte) string {
	t.Helper()

	var buf bytes.Buffer
	if err := json.Compact(&buf, data); err != nil {
		t.Fatal(err)
	}
	return buf.String()
}
