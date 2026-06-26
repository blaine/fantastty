package engine

import (
	"bytes"
	"encoding/json"
	"io"
	"strings"
	"sync"
	"testing"
	"time"

	"fantastty/remote-engine-helper/remotegrid"
)

func TestStreamPumpWritesReliableMessagesAsNewlineJSON(t *testing.T) {
	renderer := &fakePaneRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: makeEngineKeyframe(7, 1, "ok"),
		},
	}
	workspace := NewWorkspace("workspace-1", renderer)
	reliable := newRecordingReliableWriter()
	pump := NewStreamPump(reliable, newRecordingDatagramWriter())
	t.Cleanup(func() {
		if err := pump.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	mustHandle(t, workspace, mustEngineSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
	}))

	pump.PublishWorkspace(workspace)

	lines := reliable.waitForLines(t, 2)
	decodeReliableLine(t, lines[0], "workspaceSnapshot")
	decodeReliableLine(t, lines[1], "paneKeyframe")
	if got := reliable.contents(); !strings.HasSuffix(got, "\n") {
		t.Fatalf("reliable stream = %q, want trailing newline", got)
	}
}

func TestStreamPumpWritesPaneDeltasAsDatagramJSONPayloads(t *testing.T) {
	renderer := &fakePaneRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: makeEngineKeyframe(7, 1, "ok"),
		},
		deltas: map[string]remotegrid.PaneDelta{
			"delta": makeEngineDelta(7, 1, 2, "hi"),
		},
	}
	workspace := NewWorkspace("workspace-1", renderer)
	datagrams := newRecordingDatagramWriter()
	pump := NewStreamPump(newRecordingReliableWriter(), datagrams)
	t.Cleanup(func() {
		if err := pump.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	mustHandle(t, workspace, mustEngineSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
	}))
	pump.PublishWorkspace(workspace)
	mustHandle(t, workspace, mustEngineOutputAction(t, 7, "delta"))

	pump.PublishWorkspace(workspace)

	payload := datagrams.waitForPayload(t)
	if bytes.HasSuffix(payload, []byte("\n")) {
		t.Fatalf("datagram payload = %q, want JSON payload without newline framing", payload)
	}
	var delta remotegrid.PaneDelta
	if err := json.Unmarshal(payload, &delta); err != nil {
		t.Fatalf("datagram JSON: %v", err)
	}
	if delta.PaneID != 7 || delta.DeltaSequence != 1 {
		t.Fatalf("datagram delta = pane %d sequence %d, want pane 7 sequence 1", delta.PaneID, delta.DeltaSequence)
	}
	var envelope map[string]json.RawMessage
	if err := json.Unmarshal(payload, &envelope); err != nil {
		t.Fatalf("datagram envelope JSON: %v", err)
	}
	if _, ok := envelope["paneDelta"]; ok {
		t.Fatalf("datagram payload is envelope JSON, want raw pane delta: %s", payload)
	}
}

func TestStreamPumpSendsNormalPaneDeltasOnlyAsDatagrams(t *testing.T) {
	reliable := newRecordingReliableWriter()
	datagrams := newRecordingDatagramWriter()
	pump := NewStreamPump(reliable, datagrams)
	t.Cleanup(func() {
		if err := pump.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	pump.PublishReliable([]remotegrid.WorkspaceMessage{
		remotegrid.PaneKeyframeMessage(makeEngineKeyframe(7, 1, "ok")),
	})
	reliable.waitForLines(t, 1)
	pump.PublishDatagrams([]remotegrid.PaneDelta{
		makeEngineDelta(7, 1, 2, "hi"),
	})
	if err := pump.Flush(); err != nil {
		t.Fatalf("Flush: %v", err)
	}

	if payload := datagrams.waitForPayload(t); !bytes.Contains(payload, []byte(`"fullRowText"`)) {
		t.Fatalf("datagram payload = %s, want compact pane delta", payload)
	}
	assertReliableLineCount(t, reliable, 1)
}

func TestStreamPumpCoalescesNormalDatagramsWithoutReliableDeltas(t *testing.T) {
	reliable := newRecordingReliableWriter()
	datagrams := newRecordingDatagramWriter()
	pump := NewStreamPump(reliable, datagrams)
	t.Cleanup(func() {
		if err := pump.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	pump.PublishReliable([]remotegrid.WorkspaceMessage{
		remotegrid.PaneKeyframeMessage(makeEngineKeyframe(7, 1, "ok")),
	})
	reliable.waitForLines(t, 1)
	pump.PublishDatagrams([]remotegrid.PaneDelta{
		makeEngineDelta(7, 1, 2, "first"),
		makeEngineDelta(7, 2, 3, "second"),
	})
	if err := pump.Flush(); err != nil {
		t.Fatalf("Flush: %v", err)
	}

	assertReliableLineCount(t, reliable, 1)
	payload := datagrams.waitForPayload(t)
	if bytes.Contains(payload, []byte("first")) || !bytes.Contains(payload, []byte("second")) {
		t.Fatalf("datagram payload = %s, want coalesced latest delta only", payload)
	}
}

func TestStreamPumpDropQueuedPaneDeltasClearsReliableAndDatagramBacklog(t *testing.T) {
	pump := NewStreamPump(newRecordingReliableWriter(), newRecordingDatagramWriter())
	t.Cleanup(func() {
		if err := pump.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})
	delta := makeEngineDelta(7, 1, 2, "stale")
	pump.queueReliableDelta(delta)
	pump.datagrams.Publish(delta)

	pump.DropQueuedPaneDeltas("workspace-1", 7)

	pump.reliableMu.Lock()
	messages := pump.drainReliableMessages()
	pump.reliableMu.Unlock()
	if len(messages) != 0 {
		t.Fatalf("reliable messages = %d, want queued pane deltas dropped", len(messages))
	}
	if got := pump.datagrams.Snapshot(); len(got) != 0 {
		t.Fatalf("datagrams = %d, want queued pane datagrams dropped", len(got))
	}
}

func TestStreamPumpCanHoldDatagramsUntilInitialReliableFlush(t *testing.T) {
	reliable := newRecordingReliableWriter()
	datagrams := newRecordingDatagramWriter()
	pump := NewStreamPumpWithPausedDatagrams(reliable, datagrams)
	t.Cleanup(func() {
		if err := pump.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	pump.PublishDatagrams([]remotegrid.PaneDelta{makeEngineDelta(7, 1, 2, "hi")})
	if err := pump.Flush(); err != nil {
		t.Fatalf("Flush while paused: %v", err)
	}
	if got := reliable.contents(); got != "" {
		t.Fatalf("reliable stream while paused without barrier = %q, want no pre-keyframe delta", got)
	}
	datagrams.assertNoPayload(t)

	pump.PublishReliable([]remotegrid.WorkspaceMessage{
		remotegrid.PaneKeyframeMessage(makeEngineKeyframe(7, 1, "ok")),
	})
	if err := pump.Flush(); err != nil {
		t.Fatalf("Flush reliable barrier: %v", err)
	}
	decodeReliableLine(t, reliable.waitForLines(t, 1)[0], "paneKeyframe")
	assertReliableLineCount(t, reliable, 1)
	datagrams.assertNoPayload(t)

	pump.ResumeDatagrams()
	if err := pump.Flush(); err != nil {
		t.Fatalf("Flush after resume: %v", err)
	}
	payload := datagrams.waitForPayload(t)
	if !bytes.Contains(payload, []byte(`"fullRowText"`)) {
		t.Fatalf("datagram payload = %s, want held pane delta", payload)
	}
}

func TestStreamPumpHoldsFutureDeltasUntilMatchingReliableBarrier(t *testing.T) {
	reliable := newRecordingReliableWriter()
	datagrams := newRecordingDatagramWriter()
	pump := NewStreamPump(reliable, datagrams)
	t.Cleanup(func() {
		if err := pump.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	pump.PublishReliable([]remotegrid.WorkspaceMessage{
		remotegrid.PaneKeyframeMessage(makeEngineKeyframe(7, 1, "old")),
	})
	reliable.waitForLines(t, 1)
	future := makeEngineDelta(7, 1, 2, "future")
	future.BaseKeyframeID = 2
	pump.PublishDatagrams([]remotegrid.PaneDelta{future})
	if err := pump.Flush(); err != nil {
		t.Fatalf("Flush future delta: %v", err)
	}
	if got := splitReliableLines(reliable.contents()); len(got) != 1 {
		t.Fatalf("reliable lines = %d, want future delta held behind matching keyframe: %v", len(got), got)
	}
	datagrams.assertNoPayload(t)

	pump.PublishReliable([]remotegrid.WorkspaceMessage{
		remotegrid.PaneKeyframeMessage(makeEngineKeyframe(7, 2, "new")),
	})
	if err := pump.Flush(); err != nil {
		t.Fatalf("Flush matching barrier: %v", err)
	}
	lines := reliable.waitForLines(t, 2)
	decodeReliableLine(t, lines[1], "paneKeyframe")
	assertReliableLineCount(t, reliable, 2)
	if payload := datagrams.waitForPayload(t); !bytes.Contains(payload, []byte("future")) {
		t.Fatalf("future datagram payload = %s, want held delta after matching keyframe", payload)
	}
}

func TestStreamPumpStaleKeyframeDoesNotDowngradeReliableBarrier(t *testing.T) {
	reliable := newRecordingReliableWriter()
	datagrams := newRecordingDatagramWriter()
	pump := NewStreamPump(reliable, datagrams)
	t.Cleanup(func() {
		if err := pump.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	pump.PublishReliable([]remotegrid.WorkspaceMessage{
		remotegrid.PaneKeyframeMessage(makeEngineKeyframe(7, 2, "new")),
	})
	if err := pump.Flush(); err != nil {
		t.Fatalf("Flush newer keyframe: %v", err)
	}
	reliable.waitForLines(t, 1)

	pump.PublishReliable([]remotegrid.WorkspaceMessage{
		remotegrid.PaneKeyframeMessage(makeEngineKeyframe(7, 1, "old")),
	})
	if err := pump.Flush(); err != nil {
		t.Fatalf("Flush stale keyframe: %v", err)
	}

	delta := makeEngineDeltaWithBase(7, 2, 1, 3, "ok")
	pump.PublishDatagrams([]remotegrid.PaneDelta{delta})
	if err := pump.Flush(); err != nil {
		t.Fatalf("Flush delta after stale keyframe: %v", err)
	}
	payload := datagrams.waitForPayload(t)
	if !bytes.Contains(payload, []byte("ok")) {
		t.Fatalf("datagram payload = %s, want base-2 delta after stale keyframe", payload)
	}
}

func TestStreamPumpDatagramsWaitForReliableKeyframeFlush(t *testing.T) {
	reliable := newBlockingRecordingReliableWriter()
	datagrams := newRecordingDatagramWriter()
	pump := NewStreamPump(reliable, datagrams)
	t.Cleanup(func() {
		if err := pump.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	pump.PublishReliable([]remotegrid.WorkspaceMessage{
		remotegrid.PaneKeyframeMessage(makeEngineKeyframe(7, 2, "new")),
	})
	reliable.waitUntilBlocked(t)

	delta := makeEngineDeltaWithBase(7, 2, 1, 3, "ok")
	pump.PublishDatagrams([]remotegrid.PaneDelta{delta})
	datagrams.assertNoPayload(t)

	reliable.release()
	reliable.waitForLines(t, 1)
	if err := pump.Flush(); err != nil {
		t.Fatalf("Flush after keyframe write: %v", err)
	}
	payload := datagrams.waitForPayload(t)
	if !bytes.Contains(payload, []byte("ok")) {
		t.Fatalf("datagram payload = %s, want base-2 delta after keyframe write", payload)
	}
}

func TestStreamPumpQueuedKeyframeDropsStaleReliableFallbackDelta(t *testing.T) {
	reliable := newRecordingReliableWriter()
	pump := NewStreamPump(reliable, newRecordingDatagramWriter())
	t.Cleanup(func() {
		if err := pump.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	pump.PublishReliable([]remotegrid.WorkspaceMessage{
		remotegrid.PaneKeyframeMessage(makeEngineKeyframe(7, 1, "old")),
	})
	reliable.waitForLines(t, 1)

	pump.reliableWriteMu.Lock()
	pump.queueReliableDelta(makeEngineDelta(7, 1, 2, strings.Repeat("x", MaxDatagramPayloadBytes)))
	pump.reliableMu.Lock()
	messages := pump.drainReliableMessages()
	pump.reliableMu.Unlock()
	deltas := reliableDeltaMessages(t, messages)
	if len(deltas) != 1 {
		t.Fatalf("selected reliable fallback deltas = %d, want 1", len(deltas))
	}
	pump.PublishReliable([]remotegrid.WorkspaceMessage{
		remotegrid.PaneKeyframeMessage(makeEngineKeyframe(7, 2, "new")),
	})
	if !pump.reliableMessageInvalidatedByQueuedReliable(remotegrid.PaneDeltaMessage(deltas[0])) {
		t.Fatal("selected reliable fallback was not invalidated by queued keyframe")
	}
	pump.reliableWriteMu.Unlock()

	if err := pump.Flush(); err != nil {
		t.Fatalf("Flush: %v", err)
	}
	lines := reliable.waitForLines(t, 2)
	decodeReliableLine(t, lines[0], "paneKeyframe")
	decodeReliableLine(t, lines[1], "paneKeyframe")
	if got := reliable.contents(); strings.Contains(got, `"paneDelta"`) {
		t.Fatalf("reliable stream contained stale reliable fallback after newer keyframe queued: %s", got)
	}
	if got := len(splitReliableLines(reliable.contents())); got != 2 {
		t.Fatalf("reliable stream lines = %d, want stale reliable fallback dropped; stream=%q", got, reliable.contents())
	}
}

func TestStreamPumpQueuedKeyframeInvalidatesSelectedStaleKeyframe(t *testing.T) {
	pump := NewStreamPump(newRecordingReliableWriter(), newRecordingDatagramWriter())
	t.Cleanup(func() {
		if err := pump.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	pump.PublishReliable([]remotegrid.WorkspaceMessage{
		remotegrid.PaneKeyframeMessage(makeEngineKeyframe(7, 1, "old")),
	})
	pump.reliableMu.Lock()
	messages := pump.drainReliableMessages()
	pump.reliableMu.Unlock()
	if len(messages) != 1 {
		t.Fatalf("selected reliable messages = %d, want old keyframe", len(messages))
	}
	pump.PublishReliable([]remotegrid.WorkspaceMessage{
		remotegrid.PaneKeyframeMessage(makeEngineKeyframe(7, 2, "new")),
	})

	if !pump.reliableMessageInvalidatedByQueuedReliable(messages[0]) {
		t.Fatal("selected stale keyframe was not invalidated by queued newer keyframe")
	}
}

func TestStreamPumpNewerDatagramDropsStaleReliableFallback(t *testing.T) {
	reliable := newRecordingReliableWriter()
	datagrams := newRecordingDatagramWriter()
	pump := NewStreamPumpWithPausedDatagrams(reliable, datagrams)
	t.Cleanup(func() {
		if err := pump.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	pump.PublishReliable([]remotegrid.WorkspaceMessage{
		remotegrid.PaneKeyframeMessage(makeEngineKeyframe(7, 1, "base")),
	})
	reliable.waitForLines(t, 1)

	pump.reliableWriteMu.Lock()
	pump.PublishDatagrams([]remotegrid.PaneDelta{
		makeEngineDelta(7, 1, 2, strings.Repeat("x", MaxDatagramPayloadBytes)),
	})
	pump.PublishDatagrams([]remotegrid.PaneDelta{
		makeEngineDelta(7, 2, 3, "new"),
	})
	pump.reliableWriteMu.Unlock()

	pump.ResumeDatagrams()
	if err := pump.Flush(); err != nil {
		t.Fatalf("Flush: %v", err)
	}
	assertReliableLineCount(t, reliable, 1)
	payload := datagrams.waitForPayload(t)
	if !bytes.Contains(payload, []byte("new")) {
		t.Fatalf("datagram payload = %s, want newer normal datagram", payload)
	}
}

func TestStreamPumpNewerDifferentRowDatagramKeepsReliableFallback(t *testing.T) {
	pump := NewStreamPumpWithPausedDatagrams(newRecordingReliableWriter(), newRecordingDatagramWriter())
	t.Cleanup(func() {
		if err := pump.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	fallback := makeEngineDeltaForRow(7, 1, 2, 0, strings.Repeat("x", MaxDatagramPayloadBytes))
	pump.queueReliableDelta(fallback)
	pump.PublishDatagrams([]remotegrid.PaneDelta{
		makeEngineDeltaForRow(7, 2, 3, 1, "ok"),
	})

	pump.reliableMu.Lock()
	deltas := pump.reliableDeltas.Snapshot()
	pump.reliableMu.Unlock()
	if len(deltas) != 1 {
		t.Fatalf("queued reliable fallback deltas = %d, want row-0 fallback kept beside newer row-1 datagram", len(deltas))
	}
	if got := deltas[0].RowUpdates[0].RowIndex; got != 0 {
		t.Fatalf("queued reliable fallback row = %d, want row 0", got)
	}
}

func TestStreamPumpSpanDatagramKeepsReliableFallbackItDependsOn(t *testing.T) {
	pump := NewStreamPumpWithPausedDatagrams(newRecordingReliableWriter(), newRecordingDatagramWriter())
	t.Cleanup(func() {
		if err := pump.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	fallback := makeEngineDeltaForRow(7, 1, 2, 0, strings.Repeat("x", MaxDatagramPayloadBytes))
	pump.queueReliableDelta(fallback)
	pump.PublishDatagrams([]remotegrid.PaneDelta{{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 1,
		BaseKeyframeID: 1,
		DeltaSequence:  3,
		RowUpdates: []remotegrid.RowUpdate{{
			RowIndex:   0,
			RowVersion: 3,
			Update:     remotegrid.Span(2, 0, []remotegrid.GridCell{{Text: "y", Width: 1, Style: remotegrid.NormalCellStyle}}, nil),
		}},
	}})

	pump.reliableMu.Lock()
	deltas := pump.reliableDeltas.Snapshot()
	pump.reliableMu.Unlock()
	if len(deltas) != 1 {
		t.Fatalf("queued reliable fallback deltas = %d, want span-dependent fallback kept", len(deltas))
	}
}

func TestStreamPumpPromotesSpanDatagramThatDependsOnReliableFallback(t *testing.T) {
	reliable := newRecordingReliableWriter()
	datagrams := newRecordingDatagramWriter()
	pump := NewStreamPump(reliable, datagrams)
	t.Cleanup(func() {
		if err := pump.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	pump.PublishReliable([]remotegrid.WorkspaceMessage{
		remotegrid.PaneKeyframeMessage(makeEngineKeyframe(7, 1, "aa")),
	})
	if err := pump.Flush(); err != nil {
		t.Fatalf("Flush reliable barrier: %v", err)
	}
	reliable.waitForLines(t, 1)

	pump.reliableWriteMu.Lock()
	fallback := makeEngineDeltaForRow(7, 1, 2, 0, strings.Repeat("x", MaxDatagramPayloadBytes))
	fallback.RowUpdates[0].Update = remotegrid.FullRow([]remotegrid.GridCell{
		{Text: "a", Width: 1, Style: remotegrid.NormalCellStyle},
		{Text: "a", Width: 1, Style: remotegrid.NormalCellStyle},
	})
	pump.queueReliableDelta(fallback)
	pump.PublishDatagrams([]remotegrid.PaneDelta{{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 1,
		BaseKeyframeID: 1,
		DeltaSequence:  3,
		RowUpdates: []remotegrid.RowUpdate{{
			RowIndex:   0,
			RowVersion: 3,
			Update:     remotegrid.Span(2, 1, []remotegrid.GridCell{{Text: "b", Width: 1, Style: remotegrid.NormalCellStyle}}, nil),
		}},
	}})
	datagrams.assertNoPayload(t)
	pump.reliableMu.Lock()
	deltas := pump.reliableDeltas.Snapshot()
	pump.reliableMu.Unlock()
	pump.reliableWriteMu.Unlock()
	if len(deltas) != 1 {
		t.Fatalf("queued reliable fallback deltas = %d, want merged reliable delta", len(deltas))
	}
	if deltas[0].DeltaSequence != 3 {
		t.Fatalf("queued reliable delta sequence = %d, want dependent span folded into sequence 3", deltas[0].DeltaSequence)
	}
}

func TestStreamPumpHoldsSpanDatagramBehindInFlightReliableFallback(t *testing.T) {
	reliable := newBlockingRecordingReliableWriter()
	datagrams := newRecordingDatagramWriter()
	pump := NewStreamPump(reliable, datagrams)
	t.Cleanup(func() {
		reliable.release()
		if err := pump.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	pump.rememberReliableBarrier(remotegrid.PaneKeyframeMessage(makeEngineKeyframe(7, 1, "aa")))
	fallback := makeEngineDeltaForRow(7, 1, 2, 0, strings.Repeat("x", MaxDatagramPayloadBytes))
	fallback.RowUpdates[0].Update = remotegrid.FullRow([]remotegrid.GridCell{
		{Text: "a", Width: 1, Style: remotegrid.NormalCellStyle},
		{Text: "a", Width: 1, Style: remotegrid.NormalCellStyle},
	})
	pump.queueReliableDelta(fallback)
	pump.signal(pump.reliableReady)
	reliable.waitUntilBlocked(t)

	pump.PublishDatagrams([]remotegrid.PaneDelta{{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 1,
		BaseKeyframeID: 1,
		DeltaSequence:  3,
		RowUpdates: []remotegrid.RowUpdate{{
			RowIndex:   0,
			RowVersion: 3,
			Update:     remotegrid.Span(2, 1, []remotegrid.GridCell{{Text: "b", Width: 1, Style: remotegrid.NormalCellStyle}}, nil),
		}},
	}})
	datagrams.assertNoPayload(t)
}

func TestStreamPumpHoldsSpanDatagramBehindDrainedReliableFallback(t *testing.T) {
	reliable := newBlockingRecordingReliableWriter()
	datagrams := newRecordingDatagramWriter()
	pump := NewStreamPump(reliable, datagrams)
	t.Cleanup(func() {
		reliable.release()
		if err := pump.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	pump.rememberReliableBarrier(remotegrid.PaneKeyframeMessage(makeEngineKeyframe(7, 1, "aa")))
	if !pump.reliable.Publish(remotegrid.PaneKeyframeMessage(makeEngineKeyframe(8, 1, "zz"))) {
		t.Fatal("failed to queue leading reliable keyframe")
	}
	fallback := makeEngineDeltaForRow(7, 1, 2, 0, "aa")
	pump.queueReliableDelta(fallback)
	pump.signal(pump.reliableReady)
	reliable.waitUntilBlocked(t)

	pump.PublishDatagrams([]remotegrid.PaneDelta{{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 1,
		BaseKeyframeID: 1,
		DeltaSequence:  3,
		RowUpdates: []remotegrid.RowUpdate{{
			RowIndex:   0,
			RowVersion: 3,
			Update:     remotegrid.Span(1, 1, []remotegrid.GridCell{{Text: "b", Width: 1, Style: remotegrid.NormalCellStyle}}, nil),
		}},
	}})
	datagrams.assertNoPayload(t)
}

func TestStreamPumpClearsDrainedFallbacksWhenEarlierReliableWriteFails(t *testing.T) {
	pump := NewStreamPump(failingReliableWriter{}, newRecordingDatagramWriter())
	t.Cleanup(func() {
		_ = pump.Close()
	})

	pump.rememberReliableBarrier(remotegrid.PaneKeyframeMessage(makeEngineKeyframe(7, 1, "aa")))
	if !pump.reliable.Publish(remotegrid.PaneKeyframeMessage(makeEngineKeyframe(8, 1, "zz"))) {
		t.Fatal("failed to queue leading reliable keyframe")
	}
	fallback := makeEngineDeltaForRow(7, 1, 2, 0, "aa")
	pump.queueReliableDelta(fallback)
	if err := pump.Flush(); err == nil {
		t.Fatal("Flush error = nil, want reliable writer failure")
	}

	dependent := remotegrid.PaneDelta{
		WorkspaceID:    "workspace-1",
		PaneID:         7,
		PaneGeneration: 1,
		BaseKeyframeID: 1,
		DeltaSequence:  3,
		RowUpdates: []remotegrid.RowUpdate{{
			RowIndex:   0,
			RowVersion: 3,
			Update:     remotegrid.Span(1, 1, []remotegrid.GridCell{{Text: "b", Width: 1, Style: remotegrid.NormalCellStyle}}, nil),
		}},
	}
	if pump.datagramDependsOnReliableFallback(dependent) {
		t.Fatal("dependent datagram still sees a reliable fallback that never started writing")
	}
}

func TestStreamPumpKeyframeBarrierDropsQueuedPaneDatagrams(t *testing.T) {
	reliable := newRecordingReliableWriter()
	datagrams := newRecordingDatagramWriter()
	pump := NewStreamPumpWithPausedDatagrams(reliable, datagrams)
	t.Cleanup(func() {
		if err := pump.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	pump.PublishDatagrams([]remotegrid.PaneDelta{makeEngineDelta(7, 1, 2, "old")})
	pump.PublishReliable([]remotegrid.WorkspaceMessage{
		remotegrid.PaneKeyframeMessage(makeEngineKeyframe(7, 2, "new")),
	})
	if err := pump.Flush(); err != nil {
		t.Fatalf("Flush reliable barrier: %v", err)
	}
	decodeReliableLine(t, reliable.waitForLines(t, 1)[0], "paneKeyframe")

	pump.ResumeDatagrams()
	if err := pump.Flush(); err != nil {
		t.Fatalf("Flush after resume: %v", err)
	}
	datagrams.assertNoPayload(t)
}

func TestStreamPumpKeyframeBarrierDropsStalePaneDatagramsPublishedAfterBarrier(t *testing.T) {
	reliable := newRecordingReliableWriter()
	datagrams := newRecordingDatagramWriter()
	pump := NewStreamPumpWithPausedDatagrams(reliable, datagrams)
	t.Cleanup(func() {
		if err := pump.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	pump.PublishReliable([]remotegrid.WorkspaceMessage{
		remotegrid.PaneKeyframeMessage(makeEngineKeyframe(7, 2, "new")),
	})
	pump.PublishDatagrams([]remotegrid.PaneDelta{makeEngineDelta(7, 1, 2, "old")})
	if err := pump.Flush(); err != nil {
		t.Fatalf("Flush reliable barrier: %v", err)
	}
	decodeReliableLine(t, reliable.waitForLines(t, 1)[0], "paneKeyframe")

	pump.ResumeDatagrams()
	if err := pump.Flush(); err != nil {
		t.Fatalf("Flush after resume: %v", err)
	}
	datagrams.assertNoPayload(t)
}

func TestStreamPumpUnsupportedBarrierDropsQueuedPaneDatagrams(t *testing.T) {
	reliable := newRecordingReliableWriter()
	datagrams := newRecordingDatagramWriter()
	pump := NewStreamPumpWithPausedDatagrams(reliable, datagrams)
	t.Cleanup(func() {
		if err := pump.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	pump.PublishDatagrams([]remotegrid.PaneDelta{makeEngineDelta(7, 1, 2, "old")})
	pump.PublishReliable([]remotegrid.WorkspaceMessage{
		remotegrid.UnsupportedPaneStateMessage(remotegrid.UnsupportedPaneState{
			WorkspaceID:    "workspace-1",
			PaneID:         7,
			PaneGeneration: 1,
			Reason:         "unsupported sgr",
		}),
	})
	if err := pump.Flush(); err != nil {
		t.Fatalf("Flush reliable barrier: %v", err)
	}
	decodeReliableLine(t, reliable.waitForLines(t, 1)[0], "unsupportedPaneState")

	pump.ResumeDatagrams()
	if err := pump.Flush(); err != nil {
		t.Fatalf("Flush after resume: %v", err)
	}
	datagrams.assertNoPayload(t)
}

func TestStreamPumpQueuedRecoveryKeyframeHoldsDeltaAfterUnsupportedBarrier(t *testing.T) {
	reliable := newRecordingReliableWriter()
	datagrams := newRecordingDatagramWriter()
	pump := NewStreamPump(reliable, datagrams)
	t.Cleanup(func() {
		if err := pump.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	pump.PublishReliable([]remotegrid.WorkspaceMessage{
		remotegrid.UnsupportedPaneStateMessage(remotegrid.UnsupportedPaneState{
			WorkspaceID:    "workspace-1",
			PaneID:         7,
			PaneGeneration: 1,
			Reason:         "unsupported sgr",
		}),
	})
	if err := pump.Flush(); err != nil {
		t.Fatalf("Flush unsupported barrier: %v", err)
	}
	decodeReliableLine(t, reliable.waitForLines(t, 1)[0], "unsupportedPaneState")

	pump.PublishReliable([]remotegrid.WorkspaceMessage{
		remotegrid.PaneKeyframeMessage(makeEngineKeyframe(7, 1, "ok")),
	})
	delta := makeEngineDeltaWithBase(7, 1, 1, 2, "hi")
	pump.PublishDatagrams([]remotegrid.PaneDelta{delta})
	if queued := pump.datagrams.Snapshot(); len(queued) != 1 {
		t.Fatalf("queued datagrams = %d, want delta held for queued same-generation recovery keyframe", len(queued))
	}

	if err := pump.Flush(); err != nil {
		t.Fatalf("Flush recovery keyframe and delta: %v", err)
	}
	decodeReliableLine(t, reliable.waitForLines(t, 2)[1], "paneKeyframe")
	if payload := datagrams.waitForPayload(t); !bytes.Contains(payload, []byte("hi")) {
		t.Fatalf("datagram payload = %s, want post-recovery delta", payload)
	}
}

func TestStreamPumpSnapshotRemovalDropsQueuedPaneDeltas(t *testing.T) {
	reliable := newBlockingRecordingReliableWriter()
	datagrams := newRecordingDatagramWriter()
	pump := NewStreamPumpWithPausedDatagrams(reliable, datagrams)
	t.Cleanup(func() {
		reliable.release()
		if err := pump.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	pump.PublishReliable([]remotegrid.WorkspaceMessage{
		remotegrid.WorkspaceSnapshotMessage(remotegrid.WorkspaceSnapshot{
			WorkspaceID: "workspace-1",
			Panes: []remotegrid.WorkspacePane{
				{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
			},
		}),
		remotegrid.PaneKeyframeMessage(makeEngineKeyframe(7, 1, "ok")),
	})
	reliable.waitUntilBlocked(t)
	pump.PublishDatagrams([]remotegrid.PaneDelta{
		makeEngineDelta(7, 1, 2, "queued"),
		makeEngineDelta(7, 2, 3, strings.Repeat("x", MaxDatagramPayloadBytes)),
	})

	pump.PublishReliable([]remotegrid.WorkspaceMessage{
		remotegrid.WorkspaceSnapshotMessage(remotegrid.WorkspaceSnapshot{
			WorkspaceID:      "workspace-1",
			LayoutGeneration: 2,
		}),
	})

	reliable.release()
	if err := pump.Flush(); err != nil {
		t.Fatalf("Flush reliable removal snapshot: %v", err)
	}
	if strings.Contains(reliable.contents(), `"paneDelta"`) {
		t.Fatalf("reliable stream contained removed pane delta: %s", reliable.contents())
	}
	if strings.Contains(reliable.contents(), `"paneKeyframe"`) {
		t.Fatalf("reliable stream contained removed pane keyframe: %s", reliable.contents())
	}

	pump.ResumeDatagrams()
	if err := pump.Flush(); err != nil {
		t.Fatalf("Flush after resume: %v", err)
	}
	datagrams.assertNoPayload(t)
}

func TestStreamPumpRoutesOversizedPaneDeltasOverReliableStream(t *testing.T) {
	reliable := newRecordingReliableWriter()
	datagrams := newRecordingDatagramWriter()
	pump := NewStreamPump(reliable, datagrams)
	t.Cleanup(func() {
		if err := pump.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	pump.PublishReliable([]remotegrid.WorkspaceMessage{
		remotegrid.PaneKeyframeMessage(makeEngineKeyframe(7, 1, "ok")),
	})
	reliable.waitForLines(t, 1)
	pump.PublishDatagrams([]remotegrid.PaneDelta{
		makeEngineDelta(7, 1, 2, strings.Repeat("x", MaxDatagramPayloadBytes)),
	})
	if err := pump.Flush(); err != nil {
		t.Fatalf("Flush: %v", err)
	}

	lines := reliable.waitForLines(t, 2)
	decodeReliableLine(t, lines[1], "paneDelta")
	datagrams.assertNoPayload(t)
}

func TestStreamPumpPromotesCoalescedOversizedDatagramToReliable(t *testing.T) {
	reliable := newRecordingReliableWriter()
	datagrams := newRecordingDatagramWriter()
	pump := NewStreamPump(reliable, datagrams)
	t.Cleanup(func() {
		if err := pump.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	pump.PublishReliable([]remotegrid.WorkspaceMessage{
		remotegrid.PaneKeyframeMessage(makeEngineKeyframe(7, 1, "ok")),
	})
	reliable.waitForLines(t, 1)
	pump.PublishDatagrams(individuallySmallCoalescedOversizeDeltas(t))
	if err := pump.Flush(); err != nil {
		t.Fatalf("Flush: %v", err)
	}

	lines := reliable.waitForLines(t, 2)
	decodeReliableLine(t, lines[1], "paneDelta")
	datagrams.assertNoPayload(t)
}

func TestStreamPumpFlushWaitsForInFlightReliableWrite(t *testing.T) {
	reliable := newBlockingRecordingReliableWriter()
	pump := NewStreamPump(reliable, newRecordingDatagramWriter())
	t.Cleanup(func() {
		reliable.release()
		if err := pump.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	pump.PublishReliable([]remotegrid.WorkspaceMessage{
		remotegrid.PaneKeyframeMessage(makeEngineKeyframe(7, 1, "ok")),
	})
	reliable.waitUntilBlocked(t)

	done := make(chan error, 1)
	go func() {
		done <- pump.Flush()
	}()
	assertStillBlocked(t, "Flush", done)

	reliable.release()
	assertFlushReturned(t, "Flush", done)
	decodeReliableLine(t, reliable.waitForLines(t, 1)[0], "paneKeyframe")
}

func TestStreamPumpDefersOversizedFallbackUntilLatestDeltaSurvivesCoalescing(t *testing.T) {
	const fallbackCount = 12

	reliable := newBlockingRecordingReliableWriter()
	pump := NewStreamPump(reliable, newRecordingDatagramWriter())
	t.Cleanup(func() {
		reliable.release()
		if err := pump.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	pump.PublishReliable([]remotegrid.WorkspaceMessage{
		remotegrid.PaneKeyframeMessage(makeEngineKeyframe(7, 1, "ok")),
	})
	reliable.waitUntilBlocked(t)

	for sequence := 1; sequence <= fallbackCount; sequence++ {
		pump.PublishDatagrams([]remotegrid.PaneDelta{
			makeEngineDelta(7, uint64(sequence), uint64(sequence+1), strings.Repeat("x", MaxDatagramPayloadBytes)),
		})
	}

	pump.reliableMu.Lock()
	deltas := pump.reliableDeltas.Snapshot()
	pump.reliableMu.Unlock()
	if len(deltas) != 0 {
		t.Fatalf("queued reliable fallback deltas = %d, want none before barrier flush and coalescing", len(deltas))
	}
	queuedDatagrams := pump.datagrams.Snapshot()
	if len(queuedDatagrams) != 1 {
		t.Fatalf("queued datagrams = %d, want one latest delta before oversized fallback serialization", len(queuedDatagrams))
	}
	if got := queuedDatagrams[0].DeltaSequence; got != fallbackCount {
		t.Fatalf("queued datagram sequence = %d, want %d", got, fallbackCount)
	}

	reliable.release()
	lines := reliable.waitForLines(t, 2)
	decodeReliableLine(t, lines[0], "paneKeyframe")
	decodeReliableLine(t, lines[1], "paneDelta")
}

func TestStreamPumpPromotesTransportTooLargeDatagramToReliable(t *testing.T) {
	reliable := newRecordingReliableWriter()
	datagrams := &tooLargeDatagramWriter{}
	pump := NewStreamPump(reliable, datagrams)
	t.Cleanup(func() {
		if err := pump.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	pump.PublishReliable([]remotegrid.WorkspaceMessage{
		remotegrid.PaneKeyframeMessage(makeEngineKeyframe(7, 1, "ok")),
	})
	reliable.waitForLines(t, 1)
	pump.PublishDatagrams([]remotegrid.PaneDelta{
		makeEngineDelta(7, 1, 2, "transport-too-large"),
	})
	if err := pump.Flush(); err != nil {
		t.Fatalf("Flush: %v", err)
	}

	if datagrams.writes != 1 {
		t.Fatalf("datagram writes = %d, want 1 transport-too-large attempt", datagrams.writes)
	}
	lines := reliable.waitForLines(t, 2)
	decodeReliableLine(t, lines[1], "paneDelta")
}

func TestStreamPumpKeepsNormalFullRowsOffReliableStream(t *testing.T) {
	reliable := newRecordingReliableWriter()
	datagrams := newRecordingDatagramWriter()
	pump := NewStreamPump(reliable, datagrams)
	t.Cleanup(func() {
		if err := pump.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	pump.PublishReliable([]remotegrid.WorkspaceMessage{
		remotegrid.PaneKeyframeMessage(makeEngineKeyframe(7, 1, "ok")),
	})
	reliable.waitForLines(t, 1)
	pump.PublishDatagrams([]remotegrid.PaneDelta{
		makeEngineDelta(7, 1, 2, strings.Repeat("x", 80)),
	})
	if err := pump.Flush(); err != nil {
		t.Fatalf("Flush: %v", err)
	}

	payload := datagrams.waitForPayload(t)
	if len(payload) > MaxDatagramPayloadBytes {
		t.Fatalf("datagram payload size = %d, want <= %d: %s", len(payload), MaxDatagramPayloadBytes, payload)
	}
	if !bytes.Contains(payload, []byte(`"fullRowText"`)) {
		t.Fatalf("datagram payload = %s, want compact fullRowText update", payload)
	}
	assertReliableLineCount(t, reliable, 1)
}

func TestStreamPumpDatagramFailureDoesNotMaskReliableKeyframeRecovery(t *testing.T) {
	reliable := newRecordingReliableWriter()
	datagrams := &droppingDatagramWriter{}
	pump := NewStreamPump(reliable, datagrams)
	t.Cleanup(func() {
		if err := pump.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	pump.PublishReliable([]remotegrid.WorkspaceMessage{
		remotegrid.PaneKeyframeMessage(makeEngineKeyframe(7, 1, "initial")),
	})
	reliable.waitForLines(t, 1)
	pump.PublishDatagrams([]remotegrid.PaneDelta{
		makeEngineDelta(7, 1, 2, "dropped-datagram"),
	})
	if err := pump.Flush(); err != nil {
		t.Fatalf("Flush dropped datagram: %v", err)
	}
	if datagrams.writes != 1 {
		t.Fatalf("datagram writes = %d, want one dropped normal delta", datagrams.writes)
	}
	assertReliableLineCount(t, reliable, 1)

	pump.PublishReliable([]remotegrid.WorkspaceMessage{
		remotegrid.PaneKeyframeMessage(makeEngineKeyframe(7, 2, "recovered")),
	})
	if err := pump.Flush(); err != nil {
		t.Fatalf("Flush recovery keyframe: %v", err)
	}
	lines := reliable.waitForLines(t, 2)
	decodeReliableLine(t, lines[1], "paneKeyframe")
	if strings.Contains(reliable.contents(), `"paneDelta"`) {
		t.Fatalf("reliable stream contained paneDelta despite dropped normal datagram: %s", reliable.contents())
	}
}

func TestStreamPumpStalledDatagramWriterDoesNotBlockReliableOrWorkspacePublishing(t *testing.T) {
	renderer := &fakePaneRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: makeEngineKeyframe(7, 1, "aa"),
		},
		deltas: map[string]remotegrid.PaneDelta{
			"first":  makeEngineDelta(7, 1, 2, "bb"),
			"second": makeEngineDeltaWithBase(7, 2, 2, 3, "ccc"),
		},
	}
	workspace := NewWorkspace("workspace-1", renderer)
	reliable := newRecordingReliableWriter()
	datagrams := newBlockingDatagramWriter()
	pump := NewStreamPump(reliable, datagrams)
	t.Cleanup(func() {
		datagrams.release()
		if err := pump.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	mustHandle(t, workspace, mustEngineSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
	}))
	pump.PublishWorkspace(workspace)
	reliable.waitForLines(t, 2)

	mustHandle(t, workspace, mustEngineOutputAction(t, 7, "first"))
	assertReturns(t, "publish first datagram", func() {
		pump.PublishWorkspace(workspace)
	})
	datagrams.waitUntilBlocked(t)

	renderer.keyframes[7] = makeEngineKeyframe(7, 2, "aaa")
	mustHandle(t, workspace, mustEngineSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 3, Rows: 1}},
	}))
	assertReturns(t, "publish reliable while datagram writer is blocked", func() {
		pump.PublishWorkspace(workspace)
	})
	reliable.waitForLines(t, 4)

	mustHandle(t, workspace, mustEngineOutputAction(t, 7, "second"))
	assertReturns(t, "publish later datagram while datagram writer is blocked", func() {
		pump.PublishWorkspace(workspace)
	})
}

func TestStreamPumpCloseUnblocksCloseableDatagramWriter(t *testing.T) {
	datagrams := newBlockingDatagramWriter()
	pump := NewStreamPump(newRecordingReliableWriter(), datagrams)
	pump.PublishReliable([]remotegrid.WorkspaceMessage{
		remotegrid.PaneKeyframeMessage(makeEngineKeyframe(7, 1, "aa")),
	})
	pump.PublishDatagrams([]remotegrid.PaneDelta{makeEngineDelta(7, 1, 1, "bb")})
	datagrams.waitUntilBlocked(t)

	assertReturns(t, "close stalled pump", func() {
		if err := pump.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})
}

type recordingReliableWriter struct {
	mu     sync.Mutex
	buffer bytes.Buffer
	wrote  chan struct{}
}

func newRecordingReliableWriter() *recordingReliableWriter {
	return &recordingReliableWriter{wrote: make(chan struct{}, 32)}
}

func (w *recordingReliableWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()

	n, err := w.buffer.Write(p)
	if err != nil {
		return n, err
	}
	select {
	case w.wrote <- struct{}{}:
	default:
	}
	return n, nil
}

func (w *recordingReliableWriter) contents() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.buffer.String()
}

func (w *recordingReliableWriter) waitForLines(t *testing.T, count int) []string {
	t.Helper()

	deadline := time.After(2 * time.Second)
	for {
		if lines := splitReliableLines(w.contents()); len(lines) >= count {
			return lines
		}
		select {
		case <-w.wrote:
		case <-deadline:
			t.Fatalf("reliable stream lines = %d, want at least %d; stream=%q", len(splitReliableLines(w.contents())), count, w.contents())
		}
	}
}

type recordingDatagramWriter struct {
	payloads chan []byte
}

type failingReliableWriter struct{}

func (failingReliableWriter) Write([]byte) (int, error) {
	return 0, io.ErrClosedPipe
}

func newRecordingDatagramWriter() *recordingDatagramWriter {
	return &recordingDatagramWriter{payloads: make(chan []byte, 32)}
}

func (w *recordingDatagramWriter) WriteDatagram(payload []byte) error {
	next := append([]byte(nil), payload...)
	w.payloads <- next
	return nil
}

func (w *recordingDatagramWriter) waitForPayload(t *testing.T) []byte {
	t.Helper()

	select {
	case payload := <-w.payloads:
		return payload
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for datagram payload")
		return nil
	}
}

func (w *recordingDatagramWriter) assertNoPayload(t *testing.T) {
	t.Helper()

	select {
	case payload := <-w.payloads:
		t.Fatalf("unexpected datagram payload: %s", payload)
	case <-time.After(100 * time.Millisecond):
	}
}

type droppingDatagramWriter struct {
	writes int
}

func (w *droppingDatagramWriter) WriteDatagram([]byte) error {
	w.writes++
	return nil
}

type tooLargeDatagramWriter struct {
	writes int
}

func (w *tooLargeDatagramWriter) WriteDatagram([]byte) error {
	w.writes++
	return testDatagramTooLargeError{}
}

type testDatagramTooLargeError struct{}

func (testDatagramTooLargeError) Error() string {
	return "datagram too large"
}

func (testDatagramTooLargeError) DatagramTooLarge() bool {
	return true
}

type blockingDatagramWriter struct {
	startedOnce sync.Once
	started     chan struct{}
	released    chan struct{}
	releaseOnce sync.Once
}

func newBlockingDatagramWriter() *blockingDatagramWriter {
	return &blockingDatagramWriter{
		started:  make(chan struct{}),
		released: make(chan struct{}),
	}
}

func (w *blockingDatagramWriter) WriteDatagram(payload []byte) error {
	w.startedOnce.Do(func() {
		close(w.started)
	})
	<-w.released
	return nil
}

func (w *blockingDatagramWriter) waitUntilBlocked(t *testing.T) {
	t.Helper()

	select {
	case <-w.started:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for datagram writer to block")
	}
}

func (w *blockingDatagramWriter) release() {
	w.releaseOnce.Do(func() {
		close(w.released)
	})
}

func (w *blockingDatagramWriter) Close() error {
	w.release()
	return nil
}

type blockingRecordingReliableWriter struct {
	startedOnce sync.Once
	started     chan struct{}
	released    chan struct{}
	releaseOnce sync.Once
	mu          sync.Mutex
	buffer      bytes.Buffer
	wrote       chan struct{}
}

func newBlockingRecordingReliableWriter() *blockingRecordingReliableWriter {
	return &blockingRecordingReliableWriter{
		started:  make(chan struct{}),
		released: make(chan struct{}),
		wrote:    make(chan struct{}, 32),
	}
}

func (w *blockingRecordingReliableWriter) Write(payload []byte) (int, error) {
	w.startedOnce.Do(func() {
		close(w.started)
	})
	<-w.released

	w.mu.Lock()
	n, err := w.buffer.Write(payload)
	w.mu.Unlock()

	select {
	case w.wrote <- struct{}{}:
	default:
	}
	return n, err
}

func (w *blockingRecordingReliableWriter) waitUntilBlocked(t *testing.T) {
	t.Helper()

	select {
	case <-w.started:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for reliable writer to block")
	}
}

func (w *blockingRecordingReliableWriter) release() {
	w.releaseOnce.Do(func() {
		close(w.released)
	})
}

func (w *blockingRecordingReliableWriter) Close() error {
	w.release()
	return nil
}

func (w *blockingRecordingReliableWriter) contents() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.buffer.String()
}

func (w *blockingRecordingReliableWriter) waitForLines(t *testing.T, count int) []string {
	t.Helper()

	deadline := time.After(2 * time.Second)
	for {
		if lines := splitReliableLines(w.contents()); len(lines) >= count {
			return lines
		}
		select {
		case <-w.wrote:
		case <-deadline:
			t.Fatalf("reliable stream lines = %d, want at least %d; stream=%q", len(splitReliableLines(w.contents())), count, w.contents())
		}
	}
}

func assertReturns(t *testing.T, name string, fn func()) {
	t.Helper()

	done := make(chan struct{})
	go func() {
		defer close(done)
		fn()
	}()

	select {
	case <-done:
	case <-time.After(200 * time.Millisecond):
		t.Fatalf("%s did not return while datagram writer was stalled", name)
	}
}

func assertStillBlocked(t *testing.T, name string, done <-chan error) {
	t.Helper()

	select {
	case err := <-done:
		t.Fatalf("%s returned before reliable writer unblocked: %v", name, err)
	case <-time.After(100 * time.Millisecond):
	}
}

func assertFlushReturned(t *testing.T, name string, done <-chan error) {
	t.Helper()

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("%s returned error: %v", name, err)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("%s did not return after reliable writer unblocked", name)
	}
}

func decodeReliableLine(t *testing.T, line string, wantCase string) {
	t.Helper()

	var envelope map[string]json.RawMessage
	if err := json.Unmarshal([]byte(line), &envelope); err != nil {
		t.Fatalf("reliable line JSON: %v", err)
	}
	if _, ok := envelope[wantCase]; !ok {
		t.Fatalf("reliable line = %s, want %s case", line, wantCase)
	}
}

func reliableDeltaMessages(t *testing.T, messages []remotegrid.WorkspaceMessage) []remotegrid.PaneDelta {
	t.Helper()

	deltas := make([]remotegrid.PaneDelta, 0)
	for _, message := range messages {
		delta, ok := message.PaneDelta()
		if ok {
			deltas = append(deltas, delta)
		}
	}
	return deltas
}

func splitReliableLines(data string) []string {
	data = strings.TrimSuffix(data, "\n")
	if data == "" {
		return nil
	}
	return strings.Split(data, "\n")
}

func assertReliableLineCount(t *testing.T, reliable *recordingReliableWriter, count int) {
	t.Helper()

	if lines := splitReliableLines(reliable.contents()); len(lines) != count {
		t.Fatalf("reliable stream lines = %d, want %d; lines=%v", len(lines), count, lines)
	}
}

func individuallySmallCoalescedOversizeDeltas(t *testing.T) []remotegrid.PaneDelta {
	t.Helper()

	for textLength := 100; textLength < MaxDatagramPayloadBytes; textLength += 25 {
		first := makeEngineDeltaForRow(7, 1, 2, 0, strings.Repeat("a", textLength))
		second := makeEngineDeltaForRow(7, 2, 3, 1, strings.Repeat("b", textLength))
		if compactPaneDeltaSize(t, first) > MaxDatagramPayloadBytes ||
			compactPaneDeltaSize(t, second) > MaxDatagramPayloadBytes {
			continue
		}
		outbox := remotegrid.NewLatestDeltaOutbox()
		outbox.Publish(first)
		outbox.Publish(second)
		coalesced := outbox.Drain()
		if len(coalesced) != 1 {
			t.Fatalf("coalesced delta count = %d, want 1", len(coalesced))
		}
		if compactPaneDeltaSize(t, coalesced[0]) > MaxDatagramPayloadBytes {
			return []remotegrid.PaneDelta{first, second}
		}
	}
	t.Fatal("could not build individually small deltas that coalesce over datagram limit")
	return nil
}

func compactPaneDeltaSize(t *testing.T, delta remotegrid.PaneDelta) int {
	t.Helper()

	payload, err := remotegrid.MarshalCompactPaneDelta(delta)
	if err != nil {
		t.Fatalf("MarshalCompactPaneDelta: %v", err)
	}
	return len(payload)
}

func makeEngineDeltaForRow(paneID int, sequence uint64, rowVersion uint64, rowIndex int, text string) remotegrid.PaneDelta {
	delta := makeEngineDelta(paneID, sequence, rowVersion, text)
	delta.RowUpdates[0].RowIndex = rowIndex
	return delta
}

var _ io.Writer = (*recordingReliableWriter)(nil)
