package remotegrid

import (
	"reflect"
	"strconv"
	"testing"
)

func TestLatestReliableOutboxReplacesSnapshotForSameWorkspace(t *testing.T) {
	outbox := NewLatestReliableOutbox()
	outbox.Publish(WorkspaceSnapshotMessage(WorkspaceSnapshot{
		WorkspaceID:      "workspace-1",
		LayoutGeneration: 1,
		Windows:          []WorkspaceWindow{{WindowID: 1, Title: "old"}},
	}))
	outbox.Publish(WorkspaceSnapshotMessage(WorkspaceSnapshot{
		WorkspaceID:      "workspace-1",
		LayoutGeneration: 2,
		Windows:          []WorkspaceWindow{{WindowID: 1, Title: "new"}},
	}))

	messages := outbox.Drain()

	if len(messages) != 1 {
		t.Fatalf("drained messages = %d, want 1", len(messages))
	}
	snapshot := mustWorkspaceSnapshot(t, messages[0])
	if snapshot.LayoutGeneration != 2 {
		t.Fatalf("layout generation = %d, want latest generation 2", snapshot.LayoutGeneration)
	}
	if len(snapshot.Windows) != 1 || snapshot.Windows[0].Title != "new" {
		t.Fatalf("snapshot windows = %+v, want latest window title", snapshot.Windows)
	}
}

func TestLatestReliableOutboxIgnoresStaleSnapshots(t *testing.T) {
	outbox := NewLatestReliableOutbox()
	outbox.Publish(WorkspaceSnapshotMessage(WorkspaceSnapshot{
		WorkspaceID:      "workspace-1",
		LayoutGeneration: 2,
		Windows:          []WorkspaceWindow{{WindowID: 1, Title: "new"}},
		Panes:            []WorkspacePane{{PaneID: 8, WindowID: 1, Frame: PaneFrame{Columns: 2, Rows: 1}}},
	}))

	accepted := outbox.Publish(WorkspaceSnapshotMessage(WorkspaceSnapshot{
		WorkspaceID:      "workspace-1",
		LayoutGeneration: 1,
		Windows:          []WorkspaceWindow{{WindowID: 1, Title: "old"}},
		Panes:            []WorkspacePane{{PaneID: 7, WindowID: 1, Frame: PaneFrame{Columns: 2, Rows: 1}}},
	}))

	if accepted {
		t.Fatal("stale snapshot accepted, want rejected")
	}
	messages := outbox.Drain()
	if len(messages) != 1 {
		t.Fatalf("drained messages = %d, want 1", len(messages))
	}
	snapshot := mustWorkspaceSnapshot(t, messages[0])
	if snapshot.LayoutGeneration != 2 {
		t.Fatalf("layout generation = %d, want latest generation 2", snapshot.LayoutGeneration)
	}
	if len(snapshot.Panes) != 1 || snapshot.Panes[0].PaneID != 8 {
		t.Fatalf("snapshot panes = %+v, want latest pane 8", snapshot.Panes)
	}
}

func TestLatestReliableOutboxIgnoresStalePaneKeyframes(t *testing.T) {
	outbox := NewLatestReliableOutbox()
	outbox.Publish(PaneKeyframeMessage(PaneKeyframe{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 2,
		KeyframeID:     1,
		Rows:           []GridRow{{Index: 0, RowVersion: 1, Cells: []GridCell{TextCell("generation-2")}}},
	}))
	outbox.Publish(PaneKeyframeMessage(PaneKeyframe{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 1,
		KeyframeID:     99,
		Rows:           []GridRow{{Index: 0, RowVersion: 99, Cells: []GridCell{TextCell("stale-generation")}}},
	}))
	outbox.Publish(PaneKeyframeMessage(PaneKeyframe{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 2,
		KeyframeID:     0,
		Rows:           []GridRow{{Index: 0, RowVersion: 2, Cells: []GridCell{TextCell("stale-keyframe")}}},
	}))
	outbox.Publish(PaneKeyframeMessage(PaneKeyframe{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 2,
		KeyframeID:     2,
		Rows:           []GridRow{{Index: 0, RowVersion: 3, Cells: []GridCell{TextCell("latest")}}},
	}))

	messages := outbox.Drain()

	if len(messages) != 1 {
		t.Fatalf("drained messages = %d, want 1", len(messages))
	}
	keyframe := mustPaneKeyframe(t, messages[0])
	if keyframe.PaneGeneration != 2 || keyframe.KeyframeID != 2 {
		t.Fatalf("keyframe identity = generation %d keyframe %d, want generation 2 keyframe 2", keyframe.PaneGeneration, keyframe.KeyframeID)
	}
	assertKeyframeCells(t, keyframe, []GridCell{TextCell("latest")})
}

func TestLatestReliableOutboxIgnoresStaleUnsupportedPaneState(t *testing.T) {
	outbox := NewLatestReliableOutbox()
	outbox.Publish(UnsupportedPaneStateMessage(UnsupportedPaneState{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 2,
		Reason:         UnsupportedPaneReasonImageProtocol,
		Fallback:       UnsupportedPaneFallbackKeepLastGoodKeyframe,
	}))
	outbox.Publish(UnsupportedPaneStateMessage(UnsupportedPaneState{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 1,
		Reason:         UnsupportedPaneReasonSnapshotExtractionFailure,
		Fallback:       UnsupportedPaneFallbackBlankWithDiagnostic,
	}))
	outbox.Publish(UnsupportedPaneStateMessage(UnsupportedPaneState{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 2,
		Reason:         UnsupportedPaneReasonGlyphGlossaryMutation,
		Fallback:       UnsupportedPaneFallbackBlankWithDiagnostic,
	}))

	messages := outbox.Drain()

	if len(messages) != 1 {
		t.Fatalf("drained messages = %d, want 1", len(messages))
	}
	state := mustUnsupportedPaneState(t, messages[0])
	if state.PaneGeneration != 2 {
		t.Fatalf("pane generation = %d, want 2", state.PaneGeneration)
	}
	if state.Reason != UnsupportedPaneReasonGlyphGlossaryMutation || state.Fallback != UnsupportedPaneFallbackBlankWithDiagnostic {
		t.Fatalf("unsupported state = %+v, want latest state for generation 2", state)
	}
}

func TestLatestReliableOutboxKeepsPaneReliableStateMutuallyExclusive(t *testing.T) {
	outbox := NewLatestReliableOutbox()
	outbox.Publish(UnsupportedPaneStateMessage(UnsupportedPaneState{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 2,
		Reason:         UnsupportedPaneReasonSnapshotExtractionFailure,
		Fallback:       UnsupportedPaneFallbackBlankWithDiagnostic,
	}))
	outbox.Publish(PaneKeyframeMessage(PaneKeyframe{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 2,
		KeyframeID:     1,
		Rows:           []GridRow{{Index: 0, RowVersion: 1, Cells: []GridCell{TextCell("recovered")}}},
	}))

	messages := outbox.Drain()

	if got := reliableMessageOrder(messages); !reflect.DeepEqual(got, []string{"keyframe:workspace-1:7"}) {
		t.Fatalf("drain order = %v, want only recovered keyframe", got)
	}

	outbox.Publish(PaneKeyframeMessage(PaneKeyframe{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 3,
		KeyframeID:     1,
		Rows:           []GridRow{{Index: 0, RowVersion: 1, Cells: []GridCell{TextCell("before-unsupported")}}},
	}))
	if accepted := outbox.Publish(UnsupportedPaneStateMessage(UnsupportedPaneState{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 3,
		Reason:         UnsupportedPaneReasonImageProtocol,
		Fallback:       UnsupportedPaneFallbackKeepLastGoodKeyframe,
	})); accepted {
		t.Fatal("equal-generation unsupported state accepted after keyframe, want stale fence rejected")
	}

	messages = outbox.Drain()

	if got := reliableMessageOrder(messages); !reflect.DeepEqual(got, []string{"keyframe:workspace-1:7"}) {
		t.Fatalf("drain order = %v, want keyframe to suppress stale unsupported state", got)
	}
}

func TestLatestReliableOutboxSnapshotPrunesPaneMessagesOutsideLatestLayout(t *testing.T) {
	outbox := NewLatestReliableOutbox()
	outbox.Publish(PaneKeyframeMessage(PaneKeyframe{
		WorkspaceID:    "workspace-1",
		PaneID:         8,
		PaneGeneration: 1,
		KeyframeID:     1,
		Rows:           []GridRow{{Index: 0, RowVersion: 1, Cells: []GridCell{TextCell("removed")}}},
	}))
	outbox.Publish(UnsupportedPaneStateMessage(UnsupportedPaneState{
		WorkspaceID:    "workspace-1",
		PaneID:         9,
		PaneGeneration: 1,
		Reason:         UnsupportedPaneReasonImageProtocol,
		Fallback:       UnsupportedPaneFallbackKeepLastGoodKeyframe,
	}))
	outbox.Publish(WorkspaceSnapshotMessage(WorkspaceSnapshot{
		WorkspaceID: "workspace-1",
		Panes:       []WorkspacePane{{PaneID: 7, WindowID: 1, Frame: PaneFrame{Columns: 2, Rows: 1}}},
	}))
	outbox.Publish(PaneKeyframeMessage(PaneKeyframe{
		WorkspaceID:    "workspace-1",
		PaneID:         8,
		PaneGeneration: 2,
		KeyframeID:     1,
		Rows:           []GridRow{{Index: 0, RowVersion: 1, Cells: []GridCell{TextCell("still-removed")}}},
	}))
	outbox.Publish(PaneKeyframeMessage(PaneKeyframe{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 1,
		KeyframeID:     1,
		Rows:           []GridRow{{Index: 0, RowVersion: 1, Cells: []GridCell{TextCell("kept")}}},
	}))

	messages := outbox.Drain()

	got := reliableMessageOrder(messages)
	want := []string{"snapshot:workspace-1", "keyframe:workspace-1:7"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("drain order = %v, want %v", got, want)
	}
}

func TestLatestReliableOutboxDrainsInDeterministicOrderAndClears(t *testing.T) {
	outbox := NewLatestReliableOutbox()
	outbox.Publish(UnsupportedPaneStateMessage(UnsupportedPaneState{WorkspaceID: "workspace-2", PaneID: 1, PaneGeneration: 1}))
	outbox.Publish(PaneKeyframeMessage(PaneKeyframe{WorkspaceID: "workspace-1", PaneID: 9, PaneGeneration: 1, KeyframeID: 1}))
	outbox.Publish(WorkspaceSnapshotMessage(WorkspaceSnapshot{
		WorkspaceID:      "workspace-2",
		LayoutGeneration: 1,
		Panes:            []WorkspacePane{{PaneID: 1, WindowID: 1, Frame: PaneFrame{Columns: 1, Rows: 1}}},
	}))
	outbox.Publish(PaneKeyframeMessage(PaneKeyframe{WorkspaceID: "workspace-1", PaneID: 3, PaneGeneration: 1, KeyframeID: 1}))
	outbox.Publish(WorkspaceSnapshotMessage(WorkspaceSnapshot{
		WorkspaceID:      "workspace-1",
		LayoutGeneration: 1,
		Panes: []WorkspacePane{
			{PaneID: 3, WindowID: 1, Frame: PaneFrame{Columns: 1, Rows: 1}},
			{PaneID: 8, WindowID: 1, Frame: PaneFrame{Columns: 1, Rows: 1}},
			{PaneID: 9, WindowID: 1, Frame: PaneFrame{Columns: 1, Rows: 1}},
		},
	}))
	outbox.Publish(UnsupportedPaneStateMessage(UnsupportedPaneState{WorkspaceID: "workspace-1", PaneID: 8, PaneGeneration: 1}))

	if got := outbox.Len(); got != 6 {
		t.Fatalf("Len() = %d, want 6", got)
	}
	messages := outbox.Drain()
	if got := outbox.Len(); got != 0 {
		t.Fatalf("Len() after drain = %d, want 0", got)
	}

	got := reliableMessageOrder(messages)
	want := []string{
		"snapshot:workspace-1",
		"snapshot:workspace-2",
		"keyframe:workspace-1:3",
		"keyframe:workspace-1:9",
		"unsupported:workspace-1:8",
		"unsupported:workspace-2:1",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("drain order = %v, want %v", got, want)
	}
	if secondDrain := outbox.Drain(); len(secondDrain) != 0 {
		t.Fatalf("second drain returned %d messages, want 0", len(secondDrain))
	}
}

func TestLatestReliableOutboxSnapshotDoesNotDrain(t *testing.T) {
	outbox := NewLatestReliableOutbox()
	outbox.Publish(WorkspaceSnapshotMessage(WorkspaceSnapshot{
		WorkspaceID:      "workspace-1",
		LayoutGeneration: 1,
		Panes:            []WorkspacePane{{PaneID: 7, WindowID: 1, Frame: PaneFrame{Columns: 1, Rows: 1}}},
	}))
	outbox.Publish(PaneKeyframeMessage(PaneKeyframe{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 1,
		KeyframeID:     1,
	}))

	first := outbox.Snapshot()
	second := outbox.Snapshot()
	drained := outbox.Drain()

	want := []string{"snapshot:workspace-1", "keyframe:workspace-1:7"}
	if got := reliableMessageOrder(first); !reflect.DeepEqual(got, want) {
		t.Fatalf("first snapshot order = %v, want %v", got, want)
	}
	if got := reliableMessageOrder(second); !reflect.DeepEqual(got, want) {
		t.Fatalf("second snapshot order = %v, want %v", got, want)
	}
	if got := reliableMessageOrder(drained); !reflect.DeepEqual(got, want) {
		t.Fatalf("drain after snapshots order = %v, want %v", got, want)
	}
	if got := outbox.Len(); got != 0 {
		t.Fatalf("Len() after drain = %d, want 0", got)
	}
}

func TestLatestReliableOutboxClonesQueuedMessages(t *testing.T) {
	index := 1
	scrollRegion := ScrollRegion{Upper: 1, Lower: 10}
	snapshot := WorkspaceSnapshot{
		WorkspaceID: "workspace-1",
		Windows:     []WorkspaceWindow{{WindowID: 1, Title: "queued", Index: &index}},
		Panes: []WorkspacePane{{
			PaneID:   7,
			WindowID: 1,
			Frame:    PaneFrame{Columns: 2, Rows: 1},
			InitialCapture: PaneInitialCapture{
				ScrollRegion: &scrollRegion,
			},
		}},
	}
	keyframe := PaneKeyframe{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 1,
		KeyframeID:     1,
		Rows:           []GridRow{{Index: 0, RowVersion: 1, Cells: []GridCell{TextCell("q"), TextCell("u")}}},
	}
	outbox := NewLatestReliableOutbox()
	outbox.Publish(WorkspaceSnapshotMessage(snapshot))
	outbox.Publish(PaneKeyframeMessage(keyframe))

	index = 99
	scrollRegion.Upper = 99
	snapshot.Windows[0].Title = "mutated"
	snapshot.Panes[0].Frame.Columns = 99
	keyframe.Rows[0].Cells[0] = TextCell("m")

	messages := outbox.Drain()

	gotSnapshot := mustWorkspaceSnapshot(t, messages[0])
	if gotSnapshot.Windows[0].Title != "queued" {
		t.Fatalf("snapshot window title = %q, want queued", gotSnapshot.Windows[0].Title)
	}
	if gotSnapshot.Windows[0].Index == nil || *gotSnapshot.Windows[0].Index != 1 {
		t.Fatalf("snapshot window index = %v, want cloned value 1", gotSnapshot.Windows[0].Index)
	}
	if gotSnapshot.Panes[0].Frame.Columns != 2 {
		t.Fatalf("snapshot pane columns = %d, want 2", gotSnapshot.Panes[0].Frame.Columns)
	}
	if gotSnapshot.Panes[0].InitialCapture.ScrollRegion == nil {
		t.Fatal("snapshot pane scroll region = nil, want cloned value")
	}
	if *gotSnapshot.Panes[0].InitialCapture.ScrollRegion != (ScrollRegion{Upper: 1, Lower: 10}) {
		t.Fatalf("snapshot pane scroll region = %+v, want upper 1 lower 10", *gotSnapshot.Panes[0].InitialCapture.ScrollRegion)
	}
	gotKeyframe := mustPaneKeyframe(t, messages[1])
	assertKeyframeCells(t, gotKeyframe, []GridCell{TextCell("q"), TextCell("u")})
}

func mustWorkspaceSnapshot(t *testing.T, message WorkspaceMessage) WorkspaceSnapshot {
	t.Helper()

	if message.kind != workspaceMessageWorkspaceSnapshot || message.workspaceSnapshot == nil {
		t.Fatalf("message kind = %q, want workspace snapshot", message.kind)
	}
	return *message.workspaceSnapshot
}

func mustPaneKeyframe(t *testing.T, message WorkspaceMessage) PaneKeyframe {
	t.Helper()

	if message.kind != workspaceMessagePaneKeyframe || message.keyframe == nil {
		t.Fatalf("message kind = %q, want pane keyframe", message.kind)
	}
	return *message.keyframe
}

func mustUnsupportedPaneState(t *testing.T, message WorkspaceMessage) UnsupportedPaneState {
	t.Helper()

	if message.kind != workspaceMessageUnsupportedPaneState || message.unsupportedPaneState == nil {
		t.Fatalf("message kind = %q, want unsupported pane state", message.kind)
	}
	return *message.unsupportedPaneState
}

func assertKeyframeCells(t *testing.T, keyframe PaneKeyframe, cells []GridCell) {
	t.Helper()

	if len(keyframe.Rows) != 1 {
		t.Fatalf("keyframe rows = %d, want 1", len(keyframe.Rows))
	}
	if !reflect.DeepEqual(keyframe.Rows[0].Cells, cells) {
		t.Fatalf("keyframe row cells = %+v, want %+v", keyframe.Rows[0].Cells, cells)
	}
}

func reliableMessageOrder(messages []WorkspaceMessage) []string {
	order := make([]string, 0, len(messages))
	for _, message := range messages {
		switch message.kind {
		case workspaceMessageWorkspaceSnapshot:
			order = append(order, "snapshot:"+message.workspaceSnapshot.WorkspaceID)
		case workspaceMessagePaneKeyframe:
			order = append(order, "keyframe:"+message.keyframe.WorkspaceID+":"+strconv.Itoa(message.keyframe.PaneID))
		case workspaceMessageUnsupportedPaneState:
			order = append(order, "unsupported:"+message.unsupportedPaneState.WorkspaceID+":"+strconv.Itoa(message.unsupportedPaneState.PaneID))
		default:
			order = append(order, "unknown")
		}
	}
	return order
}
