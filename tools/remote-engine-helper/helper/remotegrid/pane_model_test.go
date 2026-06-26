package remotegrid

import (
	"reflect"
	"testing"
)

func TestPaneModelKeyframeIncludesVisibleRowsAndDefaultCursor(t *testing.T) {
	model := mustNewPaneModel(t, "workspace-1", 7, GridSize{Columns: 2, Rows: 1})

	mustSetRow(t, model, 0, []GridCell{TextCell("o"), TextCell("k")})
	keyframe := model.Keyframe()

	if keyframe.WorkspaceID != "workspace-1" {
		t.Fatalf("workspace id = %q, want workspace-1", keyframe.WorkspaceID)
	}
	if keyframe.PaneID != 7 {
		t.Fatalf("pane id = %d, want 7", keyframe.PaneID)
	}
	if keyframe.PaneGeneration != 1 {
		t.Fatalf("pane generation = %d, want 1", keyframe.PaneGeneration)
	}
	if keyframe.KeyframeID != 1 {
		t.Fatalf("keyframe id = %d, want 1", keyframe.KeyframeID)
	}
	if keyframe.GridSize != (GridSize{Columns: 2, Rows: 1}) {
		t.Fatalf("grid size = %+v, want 2x1", keyframe.GridSize)
	}
	if keyframe.ActiveScreen != ActiveScreenPrimary {
		t.Fatalf("active screen = %q, want primary", keyframe.ActiveScreen)
	}
	if !keyframe.DatagramsEnabledAfterKeyframe {
		t.Fatal("datagrams enabled after keyframe = false, want true")
	}
	if keyframe.Cursor != (CursorState{Row: 0, Column: 0, Visible: true, Shape: CursorShapeBlock, CursorVersion: 1}) {
		t.Fatalf("cursor = %+v, want visible block at 0,0", keyframe.Cursor)
	}

	wantRows := []GridRow{
		{Index: 0, RowVersion: 1, Cells: []GridCell{TextCell("o"), TextCell("k")}},
	}
	assertRowsEqual(t, keyframe.Rows, wantRows)
}

func TestPaneModelDeltaReportsDirtyFullRowAgainstLastKeyframe(t *testing.T) {
	model := mustNewPaneModel(t, "workspace-1", 7, GridSize{Columns: 2, Rows: 1})
	mustSetRow(t, model, 0, []GridCell{TextCell("o"), TextCell("k")})
	model.Keyframe()

	mustSetRow(t, model, 0, []GridCell{TextCell("h"), TextCell("i")})
	delta, ok := model.Delta()

	if !ok {
		t.Fatal("Delta() ok = false, want true")
	}
	if delta.WorkspaceID != "workspace-1" {
		t.Fatalf("workspace id = %q, want workspace-1", delta.WorkspaceID)
	}
	if delta.PaneID != 7 {
		t.Fatalf("pane id = %d, want 7", delta.PaneID)
	}
	if delta.PaneGeneration != 1 {
		t.Fatalf("pane generation = %d, want 1", delta.PaneGeneration)
	}
	if delta.BaseKeyframeID != 1 {
		t.Fatalf("base keyframe id = %d, want 1", delta.BaseKeyframeID)
	}
	if delta.DeltaSequence != 1 {
		t.Fatalf("delta sequence = %d, want 1", delta.DeltaSequence)
	}
	assertFullRowUpdate(t, delta.RowUpdates, 0, 2, []GridCell{TextCell("h"), TextCell("i")})
}

func TestPaneModelRetainedKeyframeFoldsFullRowDelta(t *testing.T) {
	model := mustNewPaneModelFromKeyframe(t, PaneKeyframe{
		WorkspaceID:                   "workspace-1",
		PaneID:                        7,
		PaneGeneration:                3,
		KeyframeID:                    11,
		GridSize:                      GridSize{Columns: 2, Rows: 1},
		Rows:                          []GridRow{{Index: 0, RowVersion: 12, Cells: []GridCell{TextCell("o"), TextCell("k")}}},
		Cursor:                        CursorState{Row: 0, Column: 0, Visible: true, Shape: CursorShapeBlock, CursorVersion: 4},
		ActiveScreen:                  ActiveScreenPrimary,
		DatagramsEnabledAfterKeyframe: true,
	})
	cursor := CursorState{Row: 0, Column: 1, Visible: true, Shape: CursorShapeBar, CursorVersion: 5}

	normalized, ok, err := model.ApplyDelta(PaneDelta{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 3,
		BaseKeyframeID: 11,
		DeltaSequence:  8,
		RowUpdates: []RowUpdate{{
			RowIndex:   0,
			RowVersion: 13,
			Update:     FullRow([]GridCell{TextCell("h"), TextCell("i")}),
		}},
		Cursor: &cursor,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("ApplyDelta ok = false, want true")
	}
	if normalized.BaseKeyframeID != 11 {
		t.Fatalf("normalized base keyframe id = %d, want 11", normalized.BaseKeyframeID)
	}
	if normalized.DeltaSequence != 8 {
		t.Fatalf("normalized delta sequence = %d, want 8", normalized.DeltaSequence)
	}

	keyframe := model.Keyframe()
	if keyframe.KeyframeID != 12 {
		t.Fatalf("retained keyframe id = %d, want next keyframe 12", keyframe.KeyframeID)
	}
	if keyframe.Cursor != cursor {
		t.Fatalf("retained cursor = %+v, want %+v", keyframe.Cursor, cursor)
	}
	assertRowsEqual(t, keyframe.Rows, []GridRow{
		{Index: 0, RowVersion: 13, Cells: []GridCell{TextCell("h"), TextCell("i")}},
	})
}

func TestPaneModelRetainedKeyframeFoldsSpanDelta(t *testing.T) {
	model := mustNewPaneModelFromKeyframe(t, PaneKeyframe{
		WorkspaceID:                   "workspace-1",
		PaneID:                        7,
		PaneGeneration:                3,
		KeyframeID:                    11,
		GridSize:                      GridSize{Columns: 5, Rows: 1},
		Rows:                          []GridRow{{Index: 0, RowVersion: 12, Cells: []GridCell{TextCell("a"), TextCell("b"), TextCell("c"), TextCell("d"), TextCell("e")}}},
		Cursor:                        CursorState{Row: 0, Column: 0, Visible: true, Shape: CursorShapeBlock, CursorVersion: 4},
		ActiveScreen:                  ActiveScreenPrimary,
		DatagramsEnabledAfterKeyframe: true,
	})
	clearToColumn := 4

	_, ok, err := model.ApplyDelta(PaneDelta{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 3,
		BaseKeyframeID: 11,
		DeltaSequence:  8,
		RowUpdates: []RowUpdate{{
			RowIndex:   0,
			RowVersion: 13,
			Update:     Span(12, 1, []GridCell{TextCell("X")}, &clearToColumn),
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("ApplyDelta ok = false, want true")
	}

	keyframe := model.Keyframe()
	assertRowsEqual(t, keyframe.Rows, []GridRow{
		{Index: 0, RowVersion: 13, Cells: []GridCell{TextCell("a"), TextCell("X"), TextCell(" "), TextCell(" "), TextCell("e")}},
	})
}

func TestPaneModelRetainedKeyframeSkipsStaleFullRowDelta(t *testing.T) {
	model := mustNewPaneModelFromKeyframe(t, PaneKeyframe{
		WorkspaceID:                   "workspace-1",
		PaneID:                        7,
		PaneGeneration:                3,
		KeyframeID:                    11,
		GridSize:                      GridSize{Columns: 2, Rows: 1},
		Rows:                          []GridRow{{Index: 0, RowVersion: 12, Cells: []GridCell{TextCell("o"), TextCell("k")}}},
		Cursor:                        CursorState{Row: 0, Column: 0, Visible: true, Shape: CursorShapeBlock, CursorVersion: 4},
		ActiveScreen:                  ActiveScreenPrimary,
		DatagramsEnabledAfterKeyframe: true,
	})

	_, ok, err := model.ApplyDelta(PaneDelta{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 3,
		BaseKeyframeID: 11,
		DeltaSequence:  8,
		RowUpdates: []RowUpdate{{
			RowIndex:   0,
			RowVersion: 11,
			Update:     FullRow([]GridCell{TextCell("n"), TextCell("o")}),
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("ApplyDelta ok = false, want true")
	}

	keyframe := model.Keyframe()
	assertRowsEqual(t, keyframe.Rows, []GridRow{
		{Index: 0, RowVersion: 12, Cells: []GridCell{TextCell("o"), TextCell("k")}},
	})
}

func TestPaneModelRetainedKeyframeSkipsStaleSpanDelta(t *testing.T) {
	model := mustNewPaneModelFromKeyframe(t, PaneKeyframe{
		WorkspaceID:                   "workspace-1",
		PaneID:                        7,
		PaneGeneration:                3,
		KeyframeID:                    11,
		GridSize:                      GridSize{Columns: 3, Rows: 1},
		Rows:                          []GridRow{{Index: 0, RowVersion: 12, Cells: []GridCell{TextCell("o"), TextCell("k"), TextCell("!")}}},
		Cursor:                        CursorState{Row: 0, Column: 0, Visible: true, Shape: CursorShapeBlock, CursorVersion: 4},
		ActiveScreen:                  ActiveScreenPrimary,
		DatagramsEnabledAfterKeyframe: true,
	})

	_, ok, err := model.ApplyDelta(PaneDelta{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 3,
		BaseKeyframeID: 11,
		DeltaSequence:  8,
		RowUpdates: []RowUpdate{{
			RowIndex:   0,
			RowVersion: 11,
			Update:     Span(10, 0, []GridCell{TextCell("n")}, nil),
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("ApplyDelta ok = false, want true")
	}

	keyframe := model.Keyframe()
	assertRowsEqual(t, keyframe.Rows, []GridRow{
		{Index: 0, RowVersion: 12, Cells: []GridCell{TextCell("o"), TextCell("k"), TextCell("!")}},
	})
}

func TestPaneModelRetainedKeyframeSkipsStaleCursorDelta(t *testing.T) {
	model := mustNewPaneModelFromKeyframe(t, PaneKeyframe{
		WorkspaceID:                   "workspace-1",
		PaneID:                        7,
		PaneGeneration:                3,
		KeyframeID:                    11,
		GridSize:                      GridSize{Columns: 2, Rows: 1},
		Rows:                          []GridRow{{Index: 0, RowVersion: 12, Cells: []GridCell{TextCell("o"), TextCell("k")}}},
		Cursor:                        CursorState{Row: 0, Column: 0, Visible: true, Shape: CursorShapeBlock, CursorVersion: 4},
		ActiveScreen:                  ActiveScreenPrimary,
		DatagramsEnabledAfterKeyframe: true,
	})
	staleCursor := CursorState{Row: 0, Column: 1, Visible: true, Shape: CursorShapeBar, CursorVersion: 3}

	_, ok, err := model.ApplyDelta(PaneDelta{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 3,
		BaseKeyframeID: 11,
		DeltaSequence:  8,
		Cursor:         &staleCursor,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("ApplyDelta ok = false, want true")
	}

	keyframe := model.Keyframe()
	wantCursor := CursorState{Row: 0, Column: 0, Visible: true, Shape: CursorShapeBlock, CursorVersion: 4}
	if keyframe.Cursor != wantCursor {
		t.Fatalf("retained cursor = %+v, want %+v", keyframe.Cursor, wantCursor)
	}
}

func TestPaneModelKeyframeDraftMaterializesSnapshotAfterLaterMutation(t *testing.T) {
	model := mustNewPaneModel(t, "workspace-1", 7, GridSize{Columns: 2, Rows: 1})
	mustSetRow(t, model, 0, []GridCell{TextCell("o"), TextCell("k")})

	draft := model.BeginKeyframeDraft()
	mustSetRow(t, model, 0, []GridCell{TextCell("n"), TextCell("o")})
	keyframe := draft.Materialize()

	assertRowsEqual(t, keyframe.Rows, []GridRow{
		{Index: 0, RowVersion: 1, Cells: []GridCell{TextCell("o"), TextCell("k")}},
	})
	if keyframe.KeyframeID != 1 {
		t.Fatalf("draft keyframe id = %d, want 1", keyframe.KeyframeID)
	}
}

func TestPaneModelSetRowDoesNotDirtyUnchangedRow(t *testing.T) {
	model := mustNewPaneModel(t, "workspace-1", 7, GridSize{Columns: 2, Rows: 1})
	row := []GridCell{TextCell("o"), TextCell("k")}
	mustSetRow(t, model, 0, row)
	keyframe := model.Keyframe()
	if keyframe.Rows[0].RowVersion != 1 {
		t.Fatalf("keyframe row version = %d, want 1", keyframe.Rows[0].RowVersion)
	}

	mustSetRow(t, model, 0, row)

	if delta, ok := model.Delta(); ok {
		t.Fatalf("Delta() after unchanged row = (%+v, true), want no delta", delta)
	}
	mustSetRow(t, model, 0, []GridCell{TextCell("h"), TextCell("i")})
	delta, ok := model.Delta()
	if !ok {
		t.Fatal("Delta() after changed row ok = false, want true")
	}
	assertFullRowUpdate(t, delta.RowUpdates, 0, 2, []GridCell{TextCell("h"), TextCell("i")})
}

func TestPaneModelResizeStartsFreshGenerationRequiringKeyframe(t *testing.T) {
	model := mustNewPaneModel(t, "workspace-1", 7, GridSize{Columns: 2, Rows: 1})
	mustSetRow(t, model, 0, []GridCell{TextCell("o"), TextCell("k")})
	model.Keyframe()
	if !model.HasKeyframe() {
		t.Fatal("HasKeyframe after Keyframe = false, want true")
	}
	mustSetRow(t, model, 0, []GridCell{TextCell("h"), TextCell("i")})
	if delta, ok := model.Delta(); !ok || delta.DeltaSequence != 1 {
		t.Fatalf("pre-resize delta = (%+v, %v), want sequence 1", delta, ok)
	}

	mustResize(t, model, GridSize{Columns: 3, Rows: 1})
	if model.HasKeyframe() {
		t.Fatal("HasKeyframe after resize = true, want false")
	}
	if delta, ok := model.Delta(); ok {
		t.Fatalf("Delta() after resize = (%+v, true), want no delta before fresh keyframe", delta)
	}

	keyframe := model.Keyframe()
	if !model.HasKeyframe() {
		t.Fatal("HasKeyframe after fresh resize keyframe = false, want true")
	}
	if keyframe.PaneGeneration != 2 {
		t.Fatalf("pane generation after resize = %d, want 2", keyframe.PaneGeneration)
	}
	if keyframe.KeyframeID != 1 {
		t.Fatalf("keyframe id after resize = %d, want reset to 1", keyframe.KeyframeID)
	}
	if keyframe.GridSize != (GridSize{Columns: 3, Rows: 1}) {
		t.Fatalf("grid size after resize = %+v, want 3x1", keyframe.GridSize)
	}

	mustSetRow(t, model, 0, []GridCell{TextCell("y"), TextCell("e"), TextCell("s")})
	delta, ok := model.Delta()
	if !ok {
		t.Fatal("Delta() after fresh resize keyframe ok = false, want true")
	}
	if delta.BaseKeyframeID != 1 {
		t.Fatalf("base keyframe id after resize = %d, want 1", delta.BaseKeyframeID)
	}
	if delta.DeltaSequence != 1 {
		t.Fatalf("delta sequence after resize = %d, want reset to 1", delta.DeltaSequence)
	}
}

func TestPaneModelActiveScreenChangeStartsFreshGenerationRequiringKeyframe(t *testing.T) {
	model := mustNewPaneModel(t, "workspace-1", 7, GridSize{Columns: 2, Rows: 1})
	mustSetRow(t, model, 0, []GridCell{TextCell("o"), TextCell("k")})
	model.Keyframe()
	mustSetRow(t, model, 0, []GridCell{TextCell("h"), TextCell("i")})
	if delta, ok := model.Delta(); !ok || delta.DeltaSequence != 1 {
		t.Fatalf("pre-screen-change delta = (%+v, %v), want sequence 1", delta, ok)
	}

	if changed := model.SetActiveScreen(ActiveScreenAlternate); !changed {
		t.Fatal("SetActiveScreen(alternate) changed = false, want true")
	}
	if delta, ok := model.Delta(); ok {
		t.Fatalf("Delta() after active screen change = (%+v, true), want no delta before fresh keyframe", delta)
	}

	keyframe := model.Keyframe()
	if keyframe.PaneGeneration != 2 {
		t.Fatalf("pane generation after active screen change = %d, want 2", keyframe.PaneGeneration)
	}
	if keyframe.KeyframeID != 1 {
		t.Fatalf("keyframe id after active screen change = %d, want reset to 1", keyframe.KeyframeID)
	}
	if keyframe.ActiveScreen != ActiveScreenAlternate {
		t.Fatalf("active screen after change = %q, want alternate", keyframe.ActiveScreen)
	}
	if changed := model.SetActiveScreen(ActiveScreenAlternate); changed {
		t.Fatal("SetActiveScreen(alternate) repeated changed = true, want false")
	}
}

func TestPaneModelDeltaCoalescesRepeatedRowUpdates(t *testing.T) {
	model := mustNewPaneModel(t, "workspace-1", 7, GridSize{Columns: 2, Rows: 1})
	mustSetRow(t, model, 0, []GridCell{TextCell("o"), TextCell("k")})
	model.Keyframe()

	mustSetRow(t, model, 0, []GridCell{TextCell("n"), TextCell("o")})
	mustSetRow(t, model, 0, []GridCell{TextCell("h"), TextCell("i")})
	delta, ok := model.Delta()

	if !ok {
		t.Fatal("Delta() ok = false, want true")
	}
	assertFullRowUpdate(t, delta.RowUpdates, 0, 3, []GridCell{TextCell("h"), TextCell("i")})
}

func TestPaneModelSetCursorReportsCursorDelta(t *testing.T) {
	model := mustNewPaneModel(t, "workspace-1", 7, GridSize{Columns: 2, Rows: 1})
	model.Keyframe()

	cursor := CursorState{Row: 0, Column: 1, Visible: true, Shape: CursorShapeBar, CursorVersion: 2}
	mustSetCursor(t, model, cursor)
	delta, ok := model.Delta()

	if !ok {
		t.Fatal("Delta() ok = false, want true")
	}
	if len(delta.RowUpdates) != 0 {
		t.Fatalf("row updates = %d, want 0", len(delta.RowUpdates))
	}
	if delta.Cursor == nil {
		t.Fatal("delta cursor = nil, want cursor update")
	}
	if *delta.Cursor != cursor {
		t.Fatalf("delta cursor = %+v, want %+v", *delta.Cursor, cursor)
	}
}

func TestPaneModelResizeSameSizeKeepsGenerationAndDeltaState(t *testing.T) {
	model := mustNewPaneModel(t, "workspace-1", 7, GridSize{Columns: 2, Rows: 1})
	mustSetRow(t, model, 0, []GridCell{TextCell("o"), TextCell("k")})
	model.Keyframe()

	mustResize(t, model, GridSize{Columns: 2, Rows: 1})
	mustSetRow(t, model, 0, []GridCell{TextCell("h"), TextCell("i")})
	delta, ok := model.Delta()

	if !ok {
		t.Fatal("Delta() after same-size resize ok = false, want true")
	}
	if delta.PaneGeneration != 1 {
		t.Fatalf("pane generation = %d, want 1", delta.PaneGeneration)
	}
	if delta.BaseKeyframeID != 1 {
		t.Fatalf("base keyframe id = %d, want 1", delta.BaseKeyframeID)
	}
	if delta.DeltaSequence != 1 {
		t.Fatalf("delta sequence = %d, want 1", delta.DeltaSequence)
	}
}

func TestPaneModelResizeClampsCursorInsideShrunkGrid(t *testing.T) {
	model := mustNewPaneModel(t, "workspace-1", 7, GridSize{Columns: 4, Rows: 2})
	mustSetCursor(t, model, CursorState{Row: 1, Column: 3, Visible: true, Shape: CursorShapeUnderline})

	mustResize(t, model, GridSize{Columns: 2, Rows: 1})
	keyframe := model.Keyframe()

	want := CursorState{Row: 0, Column: 1, Visible: true, Shape: CursorShapeUnderline, CursorVersion: 3}
	if keyframe.Cursor != want {
		t.Fatalf("cursor after shrink = %+v, want %+v", keyframe.Cursor, want)
	}
}

func TestPaneModelResizeRepairsTruncatedWideCells(t *testing.T) {
	model := mustNewPaneModel(t, "workspace-1", 7, GridSize{Columns: 3, Rows: 1})
	mustSetRow(t, model, 0, []GridCell{TextCell("a"), WideTextCell("界"), ContinuationCell()})

	mustResize(t, model, GridSize{Columns: 2, Rows: 1})
	keyframe := model.Keyframe()

	assertRowsEqual(t, keyframe.Rows, []GridRow{
		{Index: 0, RowVersion: 0, Cells: []GridCell{TextCell("a"), TextCell(" ")}},
	})
}

func TestPaneModelRejectsOutOfBoundsCursor(t *testing.T) {
	model := mustNewPaneModel(t, "workspace-1", 7, GridSize{Columns: 2, Rows: 1})
	model.Keyframe()

	if err := model.SetCursor(CursorState{Row: 1, Column: 0, Visible: true, Shape: CursorShapeBlock}); err == nil {
		t.Fatal("SetCursor out-of-bounds row error = nil, want error")
	}
	delta, ok := model.Delta()
	if ok {
		t.Fatalf("Delta() after rejected cursor = (%+v, true), want no dirty cursor", delta)
	}
}

func TestPaneModelRejectsInvalidRows(t *testing.T) {
	model := mustNewPaneModel(t, "workspace-1", 7, GridSize{Columns: 2, Rows: 1})

	tests := []struct {
		name     string
		rowIndex int
		cells    []GridCell
	}{
		{name: "negative row", rowIndex: -1, cells: []GridCell{TextCell("o"), TextCell("k")}},
		{name: "past last row", rowIndex: 1, cells: []GridCell{TextCell("o"), TextCell("k")}},
		{name: "wrong cell count", rowIndex: 0, cells: []GridCell{TextCell("o")}},
		{name: "wide cell without continuation", rowIndex: 0, cells: []GridCell{WideTextCell("界"), TextCell("x")}},
		{name: "stray continuation", rowIndex: 0, cells: []GridCell{ContinuationCell(), TextCell("x")}},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if err := model.SetRow(tt.rowIndex, tt.cells); err == nil {
				t.Fatal("SetRow error = nil, want error")
			}
		})
	}

	keyframe := model.Keyframe()
	assertRowsEqual(t, keyframe.Rows, []GridRow{
		{Index: 0, RowVersion: 0, Cells: []GridCell{TextCell(" "), TextCell(" ")}},
	})
}

func TestPaneModelRejectsInvalidGridSizes(t *testing.T) {
	for _, size := range []GridSize{
		{Columns: 0, Rows: 1},
		{Columns: 1, Rows: 0},
		{Columns: -1, Rows: 1},
		{Columns: 1, Rows: -1},
	} {
		t.Run("new", func(t *testing.T) {
			if model, err := NewPaneModel("workspace-1", 7, size); err == nil {
				t.Fatalf("NewPaneModel(%+v) = (%+v, nil), want error", size, model)
			}
		})
	}

	model := mustNewPaneModel(t, "workspace-1", 7, GridSize{Columns: 2, Rows: 1})
	model.Keyframe()
	if err := model.Resize(GridSize{Columns: 0, Rows: 1}); err == nil {
		t.Fatal("Resize invalid size error = nil, want error")
	}
	mustSetRow(t, model, 0, []GridCell{TextCell("h"), TextCell("i")})
	delta, ok := model.Delta()
	if !ok {
		t.Fatal("Delta() after rejected resize ok = false, want existing keyframe state preserved")
	}
	if delta.PaneGeneration != 1 {
		t.Fatalf("pane generation after rejected resize = %d, want 1", delta.PaneGeneration)
	}
}

func TextCell(text string) GridCell {
	return GridCell{Text: text, Width: 1, Style: NormalCellStyle}
}

func WideTextCell(text string) GridCell {
	return GridCell{Text: text, Width: 2, Style: NormalCellStyle}
}

func ContinuationCell() GridCell {
	return GridCell{Text: "", Width: 0, Style: NormalCellStyle}
}

func mustNewPaneModel(t *testing.T, workspaceID string, paneID int, size GridSize) *PaneModel {
	t.Helper()

	model, err := NewPaneModel(workspaceID, paneID, size)
	if err != nil {
		t.Fatal(err)
	}
	return model
}

func mustNewPaneModelFromKeyframe(t *testing.T, keyframe PaneKeyframe) *PaneModel {
	t.Helper()

	model, err := NewPaneModelFromKeyframe(keyframe)
	if err != nil {
		t.Fatal(err)
	}
	return model
}

func mustSetRow(t *testing.T, model *PaneModel, rowIndex int, cells []GridCell) {
	t.Helper()

	if err := model.SetRow(rowIndex, cells); err != nil {
		t.Fatal(err)
	}
}

func mustResize(t *testing.T, model *PaneModel, size GridSize) {
	t.Helper()

	if err := model.Resize(size); err != nil {
		t.Fatal(err)
	}
}

func mustSetCursor(t *testing.T, model *PaneModel, cursor CursorState) {
	t.Helper()

	if err := model.SetCursor(cursor); err != nil {
		t.Fatal(err)
	}
}

func assertRowsEqual(t *testing.T, got []GridRow, want []GridRow) {
	t.Helper()

	if !reflect.DeepEqual(got, want) {
		t.Fatalf("rows = %+v, want %+v", got, want)
	}
}

func assertFullRowUpdate(t *testing.T, updates []RowUpdate, rowIndex int, rowVersion uint64, cells []GridCell) {
	t.Helper()

	if len(updates) != 1 {
		t.Fatalf("row updates = %d, want 1", len(updates))
	}
	update := updates[0]
	if update.RowIndex != rowIndex {
		t.Fatalf("row index = %d, want %d", update.RowIndex, rowIndex)
	}
	if update.RowVersion != rowVersion {
		t.Fatalf("row version = %d, want %d", update.RowVersion, rowVersion)
	}
	if !reflect.DeepEqual(update.Update.fullRow, cells) {
		t.Fatalf("full row cells = %+v, want %+v", update.Update.fullRow, cells)
	}
}
