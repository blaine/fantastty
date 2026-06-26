package remotegrid

import (
	"reflect"
	"testing"
)

func TestLatestDeltaOutboxCoalescesRowsForStalledWriter(t *testing.T) {
	outbox := NewLatestDeltaOutbox()
	outbox.Publish(PaneDelta{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 1,
		BaseKeyframeID: 3,
		DeltaSequence:  1,
		RowUpdates: []RowUpdate{
			{RowIndex: 0, RowVersion: 2, Update: FullRow([]GridCell{TextCell("a"), TextCell("a")})},
			{RowIndex: 1, RowVersion: 2, Update: FullRow([]GridCell{TextCell("b"), TextCell("b")})},
		},
		Cursor: &CursorState{Row: 0, Column: 1, Visible: true, Shape: CursorShapeBlock, CursorVersion: 2},
	})
	outbox.Publish(PaneDelta{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 1,
		BaseKeyframeID: 3,
		DeltaSequence:  2,
		RowUpdates: []RowUpdate{
			{RowIndex: 1, RowVersion: 3, Update: FullRow([]GridCell{TextCell("c"), TextCell("c")})},
			{RowIndex: 2, RowVersion: 2, Update: FullRow([]GridCell{TextCell("d"), TextCell("d")})},
		},
		Cursor: &CursorState{Row: 0, Column: 0, Visible: true, Shape: CursorShapeBar, CursorVersion: 3},
	})

	deltas := outbox.Drain()

	if len(deltas) != 1 {
		t.Fatalf("drained deltas = %d, want 1", len(deltas))
	}
	delta := deltas[0]
	if delta.DeltaSequence != 2 {
		t.Fatalf("delta sequence = %d, want latest sequence 2", delta.DeltaSequence)
	}
	assertFullRowUpdateAt(t, delta.RowUpdates, 0, 0, 2, []GridCell{TextCell("a"), TextCell("a")})
	assertFullRowUpdateAt(t, delta.RowUpdates, 1, 1, 3, []GridCell{TextCell("c"), TextCell("c")})
	assertFullRowUpdateAt(t, delta.RowUpdates, 2, 2, 2, []GridCell{TextCell("d"), TextCell("d")})
	wantCursor := CursorState{Row: 0, Column: 0, Visible: true, Shape: CursorShapeBar, CursorVersion: 3}
	if delta.Cursor == nil || *delta.Cursor != wantCursor {
		t.Fatalf("cursor = %+v, want %+v", delta.Cursor, wantCursor)
	}
}

func TestLatestDeltaOutboxFoldsDependentSpanIntoPendingFullRow(t *testing.T) {
	outbox := NewLatestDeltaOutbox()
	outbox.Publish(PaneDelta{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 1,
		BaseKeyframeID: 3,
		DeltaSequence:  1,
		RowUpdates: []RowUpdate{{
			RowIndex:   0,
			RowVersion: 2,
			Update:     FullRow([]GridCell{TextCell("a"), TextCell("a")}),
		}},
	})
	outbox.Publish(PaneDelta{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 1,
		BaseKeyframeID: 3,
		DeltaSequence:  2,
		RowUpdates: []RowUpdate{{
			RowIndex:   0,
			RowVersion: 3,
			Update:     Span(2, 1, []GridCell{TextCell("b")}, nil),
		}},
	})

	deltas := outbox.Drain()

	if len(deltas) != 1 {
		t.Fatalf("drained deltas = %d, want 1", len(deltas))
	}
	if deltas[0].DeltaSequence != 2 {
		t.Fatalf("delta sequence = %d, want latest sequence 2", deltas[0].DeltaSequence)
	}
	assertFullRowUpdateAt(t, deltas[0].RowUpdates, 0, 0, 3, []GridCell{TextCell("a"), TextCell("b")})
}

func TestLatestDeltaOutboxIgnoresStaleRowAndCursorUpdates(t *testing.T) {
	outbox := NewLatestDeltaOutbox()
	outbox.Publish(PaneDelta{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 1,
		BaseKeyframeID: 3,
		DeltaSequence:  5,
		RowUpdates: []RowUpdate{
			{RowIndex: 0, RowVersion: 5, Update: FullRow([]GridCell{TextCell("n"), TextCell("e"), TextCell("w")})},
		},
		Cursor: &CursorState{Row: 0, Column: 2, Visible: true, Shape: CursorShapeBlock, CursorVersion: 5},
	})
	outbox.Publish(PaneDelta{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 1,
		BaseKeyframeID: 3,
		DeltaSequence:  4,
		RowUpdates: []RowUpdate{
			{RowIndex: 0, RowVersion: 4, Update: FullRow([]GridCell{TextCell("o"), TextCell("l"), TextCell("d")})},
		},
		Cursor: &CursorState{Row: 0, Column: 1, Visible: true, Shape: CursorShapeBar, CursorVersion: 4},
	})

	delta := outbox.Drain()[0]

	if delta.DeltaSequence != 5 {
		t.Fatalf("delta sequence = %d, want 5", delta.DeltaSequence)
	}
	assertFullRowUpdateAt(t, delta.RowUpdates, 0, 0, 5, []GridCell{TextCell("n"), TextCell("e"), TextCell("w")})
	wantCursor := CursorState{Row: 0, Column: 2, Visible: true, Shape: CursorShapeBlock, CursorVersion: 5}
	if delta.Cursor == nil || *delta.Cursor != wantCursor {
		t.Fatalf("cursor = %+v, want %+v", delta.Cursor, wantCursor)
	}
}

func TestLatestDeltaOutboxReplacesPaneOnNewGenerationOrKeyframe(t *testing.T) {
	outbox := NewLatestDeltaOutbox()
	outbox.Publish(PaneDelta{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 1,
		BaseKeyframeID: 3,
		DeltaSequence:  1,
		RowUpdates: []RowUpdate{
			{RowIndex: 0, RowVersion: 2, Update: FullRow([]GridCell{TextCell("o"), TextCell("l"), TextCell("d")})},
		},
	})
	outbox.Publish(PaneDelta{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 2,
		BaseKeyframeID: 1,
		DeltaSequence:  1,
		RowUpdates: []RowUpdate{
			{RowIndex: 0, RowVersion: 1, Update: FullRow([]GridCell{TextCell("n"), TextCell("e"), TextCell("w")})},
		},
	})

	delta := outbox.Drain()[0]

	if delta.PaneGeneration != 2 || delta.BaseKeyframeID != 1 {
		t.Fatalf("delta identity = generation %d keyframe %d, want generation 2 keyframe 1", delta.PaneGeneration, delta.BaseKeyframeID)
	}
	assertFullRowUpdateAt(t, delta.RowUpdates, 0, 0, 1, []GridCell{TextCell("n"), TextCell("e"), TextCell("w")})
}

func TestLatestDeltaOutboxIgnoresStaleGenerationOrBaseKeyframe(t *testing.T) {
	outbox := NewLatestDeltaOutbox()
	outbox.Publish(PaneDelta{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 3,
		BaseKeyframeID: 2,
		DeltaSequence:  4,
		RowUpdates: []RowUpdate{
			{RowIndex: 0, RowVersion: 4, Update: FullRow([]GridCell{TextCell("n"), TextCell("e"), TextCell("w")})},
		},
	})
	outbox.Publish(PaneDelta{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 2,
		BaseKeyframeID: 99,
		DeltaSequence:  99,
		RowUpdates: []RowUpdate{
			{RowIndex: 0, RowVersion: 99, Update: FullRow([]GridCell{TextCell("o"), TextCell("l"), TextCell("d")})},
		},
	})
	outbox.Publish(PaneDelta{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 3,
		BaseKeyframeID: 1,
		DeltaSequence:  99,
		RowUpdates: []RowUpdate{
			{RowIndex: 0, RowVersion: 99, Update: FullRow([]GridCell{TextCell("b"), TextCell("a"), TextCell("d")})},
		},
	})

	delta := outbox.Drain()[0]

	if delta.PaneGeneration != 3 || delta.BaseKeyframeID != 2 || delta.DeltaSequence != 4 {
		t.Fatalf("delta identity = generation %d keyframe %d sequence %d, want original latest generation 3 keyframe 2 sequence 4", delta.PaneGeneration, delta.BaseKeyframeID, delta.DeltaSequence)
	}
	assertFullRowUpdateAt(t, delta.RowUpdates, 0, 0, 4, []GridCell{TextCell("n"), TextCell("e"), TextCell("w")})
}

func TestLatestDeltaOutboxKeepsOnePendingDeltaPerPane(t *testing.T) {
	outbox := NewLatestDeltaOutbox()
	for paneID := 9; paneID >= 7; paneID-- {
		outbox.Publish(PaneDelta{
			WorkspaceID:    "workspace-1",
			PaneID:         paneID,
			PaneGeneration: 1,
			BaseKeyframeID: 1,
			DeltaSequence:  1,
			RowUpdates: []RowUpdate{
				{RowIndex: 0, RowVersion: 1, Update: FullRow([]GridCell{TextCell("x")})},
			},
		})
	}

	if got := outbox.Len(); got != 3 {
		t.Fatalf("Len() = %d, want 3", got)
	}
	deltas := outbox.Drain()
	if got := outbox.Len(); got != 0 {
		t.Fatalf("Len() after drain = %d, want 0", got)
	}
	var paneIDs []int
	for _, delta := range deltas {
		paneIDs = append(paneIDs, delta.PaneID)
	}
	if !reflect.DeepEqual(paneIDs, []int{7, 8, 9}) {
		t.Fatalf("drained pane ids = %v, want sorted pane ids 7,8,9", paneIDs)
	}
}

func TestLatestDeltaOutboxSnapshotDoesNotDrain(t *testing.T) {
	outbox := NewLatestDeltaOutbox()
	outbox.Publish(PaneDelta{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 1,
		BaseKeyframeID: 1,
		DeltaSequence:  1,
		RowUpdates: []RowUpdate{
			{RowIndex: 0, RowVersion: 1, Update: FullRow([]GridCell{TextCell("a")})},
		},
	})

	first := outbox.Snapshot()
	second := outbox.Snapshot()
	drained := outbox.Drain()

	for name, deltas := range map[string][]PaneDelta{
		"first snapshot":  first,
		"second snapshot": second,
		"drain":           drained,
	} {
		if len(deltas) != 1 {
			t.Fatalf("%s returned %d deltas, want 1", name, len(deltas))
		}
		if deltas[0].WorkspaceID != "workspace-1" || deltas[0].PaneID != 7 || deltas[0].DeltaSequence != 1 {
			t.Fatalf("%s delta = %+v, want workspace-1 pane 7 sequence 1", name, deltas[0])
		}
	}
	if got := outbox.Len(); got != 0 {
		t.Fatalf("Len() after drain = %d, want 0", got)
	}
}

func assertFullRowUpdateAt(t *testing.T, updates []RowUpdate, index int, rowIndex int, rowVersion uint64, cells []GridCell) {
	t.Helper()

	if len(updates) <= index {
		t.Fatalf("row updates = %d, want index %d", len(updates), index)
	}
	update := updates[index]
	if update.RowIndex != rowIndex {
		t.Fatalf("row update %d row index = %d, want %d", index, update.RowIndex, rowIndex)
	}
	if update.RowVersion != rowVersion {
		t.Fatalf("row update %d row version = %d, want %d", index, update.RowVersion, rowVersion)
	}
	if !reflect.DeepEqual(update.Update.fullRow, cells) {
		t.Fatalf("row update %d full row = %+v, want %+v", index, update.Update.fullRow, cells)
	}
}
