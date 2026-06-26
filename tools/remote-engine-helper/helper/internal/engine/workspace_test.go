package engine

import (
	"encoding/json"
	"errors"
	"reflect"
	"strconv"
	"strings"
	"testing"

	"fantastty/remote-engine-helper/remotegrid"
	"fantastty/remote-engine-helper/tmuxcc"
)

func TestWorkspacePublishesSnapshotAndSeedsPaneKeyframes(t *testing.T) {
	renderer := &fakePaneRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: makeEngineKeyframe(7, 1, "ok"),
			8: makeEngineKeyframe(8, 1, "hi"),
		},
	}
	workspace := NewWorkspace("workspace-1", renderer)

	if err := workspace.Handle(mustEngineSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 8, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
	})); err != nil {
		t.Fatal(err)
	}

	messages := workspace.DrainReliable()
	if got := reliableKinds(t, messages); !reflect.DeepEqual(got, []string{
		"snapshot:workspace-1",
		"keyframe:7:1",
		"keyframe:8:1",
	}) {
		t.Fatalf("reliable messages = %v, want snapshot then sorted keyframes", got)
	}
	if got := renderer.seeded; !reflect.DeepEqual(got, []int{7, 8}) {
		t.Fatalf("seeded panes = %v, want sorted panes 7,8", got)
	}
	if workspace.PendingReliable() != 0 {
		t.Fatalf("PendingReliable after drain = %d, want 0", workspace.PendingReliable())
	}
}

func TestWorkspaceCoalescesReliableMessagesWhileWriterIsStalled(t *testing.T) {
	renderer := &fakePaneRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: makeEngineKeyframe(7, 1, "aa"),
		},
	}
	workspace := NewWorkspace("workspace-1", renderer)

	mustHandle(t, workspace, mustEngineSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
	}))
	renderer.keyframes[7] = makeEngineKeyframe(7, 2, "bb")
	mustHandle(t, workspace, mustEngineSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 3, Rows: 1}},
	}))

	if pending := workspace.PendingReliable(); pending != 2 {
		t.Fatalf("PendingReliable = %d, want one snapshot and one keyframe", pending)
	}
	messages := workspace.DrainReliable()
	if got := reliableKinds(t, messages); !reflect.DeepEqual(got, []string{"snapshot:workspace-1", "keyframe:7:2"}) {
		t.Fatalf("reliable messages = %v, want latest snapshot and latest keyframe", got)
	}
}

func TestWorkspacePublishesPaneDeltasToLatestDatagramOutbox(t *testing.T) {
	renderer := &fakePaneRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: makeEngineKeyframe(7, 1, "aa"),
		},
		deltas: map[string]remotegrid.PaneDelta{
			"first":  makeEngineDelta(7, 1, 1, "bb"),
			"second": makeEngineDelta(7, 2, 2, "cc"),
		},
	}
	workspace := NewWorkspace("workspace-1", renderer)
	mustHandle(t, workspace, mustEngineSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
	}))

	mustHandle(t, workspace, mustEngineOutputAction(t, 7, "first"))
	mustHandle(t, workspace, mustEngineOutputAction(t, 7, "second"))

	if pending := workspace.PendingDatagrams(); pending != 1 {
		t.Fatalf("PendingDatagrams = %d, want one pending pane delta", pending)
	}
	deltas := workspace.DrainDatagrams()
	if len(deltas) != 1 {
		t.Fatalf("deltas = %d, want 1", len(deltas))
	}
	if deltas[0].DeltaSequence != 2 {
		t.Fatalf("delta sequence = %d, want latest sequence 2", deltas[0].DeltaSequence)
	}
	assertEngineFullRow(t, deltas[0].RowUpdates, 0, 2, []remotegrid.GridCell{
		engineTextCell("c"),
		engineTextCell("c"),
	})
}

func TestWorkspacePublishesReliableKeyframeWhenOutputChangesPaneGeneration(t *testing.T) {
	renderer := &fakePaneRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: makeEngineKeyframe(7, 1, "aa"),
		},
		deltas: map[string]remotegrid.PaneDelta{
			"pending": makeEngineDelta(7, 1, 1, "bb"),
		},
		outputUpdates: map[string]RenderUpdate{
			"alternate": {
				Keyframe: ptr(makeEngineKeyframeWithGeneration(7, 2, 1, remotegrid.ActiveScreenAlternate, "cc")),
			},
		},
	}
	workspace := NewWorkspace("workspace-1", renderer)
	mustHandle(t, workspace, mustEngineSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
	}))
	mustHandle(t, workspace, mustEngineOutputAction(t, 7, "pending"))
	mustHandle(t, workspace, mustEngineOutputAction(t, 7, "alternate"))

	if pending := workspace.PendingDatagrams(); pending != 0 {
		t.Fatalf("PendingDatagrams = %d, want stale pane deltas purged after generation keyframe", pending)
	}
	messages := workspace.DrainReliable()
	if got := reliableKinds(t, messages); !reflect.DeepEqual(got, []string{
		"snapshot:workspace-1",
		"keyframe:7:1",
	}) {
		t.Fatalf("reliable messages = %v, want snapshot and fresh keyframe", got)
	}
	keyframe := mustEngineReliableKeyframe(t, messages[1])
	if keyframe.PaneGeneration != 2 {
		t.Fatalf("pane generation = %d, want 2", keyframe.PaneGeneration)
	}
	if keyframe.ActiveScreen != remotegrid.ActiveScreenAlternate {
		t.Fatalf("active screen = %q, want alternate", keyframe.ActiveScreen)
	}
}

func TestWorkspaceIgnoresOutputForUnknownOrRemovedPanes(t *testing.T) {
	renderer := &fakePaneRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: makeEngineKeyframe(7, 1, "aa"),
		},
		deltas: map[string]remotegrid.PaneDelta{
			"known":   makeEngineDelta(7, 1, 1, "bb"),
			"removed": makeEngineDelta(7, 2, 2, "cc"),
		},
	}
	workspace := NewWorkspace("workspace-1", renderer)

	mustHandle(t, workspace, mustEngineOutputAction(t, 7, "unknown"))
	mustHandle(t, workspace, mustEngineSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
	}))
	mustHandle(t, workspace, mustEngineOutputAction(t, 7, "known"))
	mustHandle(t, workspace, mustEngineSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 8, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
	}))
	mustHandle(t, workspace, mustEngineOutputAction(t, 7, "removed"))

	deltas := workspace.DrainDatagrams()
	if len(deltas) != 0 {
		t.Fatalf("deltas = %+v, want removed pane deltas purged", deltas)
	}
	if got := renderer.removed; !reflect.DeepEqual(got, []int{7}) {
		t.Fatalf("removed panes = %v, want pane 7 removed", got)
	}
	if got := reliableKinds(t, workspace.DrainReliable()); !reflect.DeepEqual(got, []string{"snapshot:workspace-1"}) {
		t.Fatalf("reliable messages = %v, want only latest snapshot after pane removal", got)
	}
}

func TestWorkspaceReportsSeedErrorsAsUnsupportedStateWithoutStoppingDrain(t *testing.T) {
	rendererErr := errors.New("renderer failed")
	renderer := &fakePaneRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: makeEngineKeyframe(7, 1, "aa"),
		},
		err: rendererErr,
	}
	workspace := NewWorkspace("workspace-1", renderer)

	err := workspace.Handle(mustEngineSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
	}))

	if err != nil {
		t.Fatalf("Handle error = %v, want nil so tmux drain continues", err)
	}
	if got := reliableKinds(t, workspace.DrainReliable()); !reflect.DeepEqual(got, []string{
		"snapshot:workspace-1",
		"unsupported:7",
	}) {
		t.Fatalf("reliable messages = %v, want snapshot plus unsupported pane state", got)
	}
}

func TestWorkspaceReportsReseedFailureWithNextUnsupportedGeneration(t *testing.T) {
	renderer := &fakePaneRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: makeEngineKeyframeWithGeneration(7, 3, 1, remotegrid.ActiveScreenPrimary, "aa"),
		},
	}
	workspace := NewWorkspace("workspace-1", renderer)
	mustHandle(t, workspace, mustEngineSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
	}))
	_ = workspace.DrainReliable()

	renderer.err = errors.New("reseed failed")
	err := workspace.Handle(mustEngineSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 3, Rows: 1}},
	}))
	if err != nil {
		t.Fatalf("Handle error = %v, want nil so tmux drain continues", err)
	}

	messages := workspace.DrainReliable()
	if got := reliableKinds(t, messages); !reflect.DeepEqual(got, []string{"snapshot:workspace-1", "unsupported:7"}) {
		t.Fatalf("reliable messages = %v, want snapshot plus unsupported pane state", got)
	}
	state := mustEngineReliableUnsupported(t, messages[1])
	if state.PaneGeneration != 4 {
		t.Fatalf("unsupported pane generation = %d, want next generation 4", state.PaneGeneration)
	}
}

func TestWorkspaceSuccessfulReseedUsesFencedPaneGenerationForKeyframesAndDeltas(t *testing.T) {
	renderer := &fakePaneRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: makeEngineKeyframeWithGeneration(7, 3, 1, remotegrid.ActiveScreenPrimary, "aa"),
		},
		deltas: map[string]remotegrid.PaneDelta{
			"ccc": makeEngineDelta(7, 1, 2, "ccc"),
		},
	}
	workspace := NewWorkspace("workspace-1", renderer)
	mustHandle(t, workspace, mustEngineSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
	}))
	_ = workspace.DrainReliable()

	renderer.err = errors.New("reseed failed")
	mustHandle(t, workspace, mustEngineSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 3, Rows: 1}},
	}))
	_ = workspace.DrainReliable()

	renderer.err = nil
	renderer.keyframes[7] = makeEngineKeyframe(7, 1, "bbb")
	mustHandle(t, workspace, mustEngineSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 3, Rows: 1}},
	}))
	messages := workspace.DrainReliable()
	if got := reliableKinds(t, messages); !reflect.DeepEqual(got, []string{"snapshot:workspace-1", "keyframe:7:1"}) {
		t.Fatalf("reseed reliable messages = %v, want snapshot plus keyframe", got)
	}
	keyframe := mustEngineReliableKeyframe(t, messages[1])
	if keyframe.PaneGeneration != 4 {
		t.Fatalf("reseed keyframe generation = %d, want fenced generation 4", keyframe.PaneGeneration)
	}

	mustHandle(t, workspace, mustEngineOutputAction(t, 7, "ccc"))
	deltas := workspace.DrainDatagrams()
	if len(deltas) != 1 {
		t.Fatalf("deltas after successful reseed = %d, want translated delta", len(deltas))
	}
	if deltas[0].PaneGeneration != 4 {
		t.Fatalf("delta generation after successful reseed = %d, want fenced generation 4", deltas[0].PaneGeneration)
	}
	if deltas[0].BaseKeyframeID != keyframe.KeyframeID {
		t.Fatalf("delta base keyframe id = %d, want reseed keyframe id %d", deltas[0].BaseKeyframeID, keyframe.KeyframeID)
	}
	assertEngineFullRow(t, deltas[0].RowUpdates, 0, 2, []remotegrid.GridCell{
		engineTextCell("c"),
		engineTextCell("c"),
		engineTextCell("c"),
	})
}

func TestWorkspaceKeepsEarlyOutputWhenSeedingFailsAndFlushesAfterRetry(t *testing.T) {
	seedErr := errors.New("seed failed")
	renderer := &fakePaneRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: makeEngineKeyframe(7, 1, "aa"),
		},
		deltas: map[string]remotegrid.PaneDelta{
			"early\n": makeEngineDelta(7, 1, 1, "bb"),
		},
		err: seedErr,
	}
	workspace := NewWorkspace("workspace-1", renderer)
	reader := strings.NewReader(strings.Join([]string{
		`%output %7 early\012`,
		"%window-add @1",
		"%layout-change @1 b25d,2x1,0,0,%7",
	}, "\n"))

	err := workspace.HandleStream(reader, tmuxcc.NewModel("workspace-1"), tmuxcc.NewPaneOutputBuffer())
	if err != nil {
		t.Fatalf("HandleStream seed failure error = %v, want nil so buffered output can retry", err)
	}
	if pending := workspace.PendingDatagrams(); pending != 0 {
		t.Fatalf("PendingDatagrams after failed seed = %d, want 0", pending)
	}

	renderer.err = nil
	mustHandle(t, workspace, mustEngineSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
	}))

	deltas := workspace.DrainDatagrams()
	if len(deltas) != 1 {
		t.Fatalf("deltas after retry = %d, want flushed early output delta", len(deltas))
	}
	if deltas[0].PaneID != 7 || deltas[0].DeltaSequence != 1 {
		t.Fatalf("delta after retry = pane %d sequence %d, want pane 7 sequence 1", deltas[0].PaneID, deltas[0].DeltaSequence)
	}
}

func TestWorkspaceBuffersOutputWhenSeedDefersWithoutError(t *testing.T) {
	renderer := &fakePaneRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{},
		deltas: map[string]remotegrid.PaneDelta{
			"deferred": makeEngineDelta(7, 1, 1, "bb"),
		},
	}
	workspace := NewWorkspace("workspace-1", renderer)

	mustHandle(t, workspace, mustEngineSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
	}))
	mustHandle(t, workspace, mustEngineOutputAction(t, 7, "deferred"))
	if pending := workspace.PendingDatagrams(); pending != 0 {
		t.Fatalf("PendingDatagrams before seed = %d, want 0", pending)
	}

	renderer.keyframes[7] = makeEngineKeyframe(7, 1, "aa")
	mustHandle(t, workspace, mustEngineSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
	}))
	deltas := workspace.DrainDatagrams()
	if len(deltas) != 1 || deltas[0].DeltaSequence != 1 {
		t.Fatalf("deltas after deferred seed = %+v, want one flushed delta", deltas)
	}
}

func TestWorkspaceRequestKeyframePublishesCurrentPaneState(t *testing.T) {
	renderer := &fakePaneRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: makeEngineKeyframe(7, 1, "aa"),
		},
		deltas: map[string]remotegrid.PaneDelta{
			"bb": makeEngineDelta(7, 1, 2, "bb"),
			"cc": makeEngineDelta(7, 2, 3, "cc"),
		},
		failCurrentKeyframe: true,
	}
	workspace := NewWorkspace("workspace-1", renderer)
	mustHandle(t, workspace, mustEngineSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
	}))
	_ = workspace.DrainReliable()

	mustHandle(t, workspace, mustEngineOutputAction(t, 7, "bb"))
	if err := workspace.RequestKeyframe(7); err != nil {
		t.Fatal(err)
	}

	messages := workspace.DrainReliable()
	if got := reliableKinds(t, messages); !reflect.DeepEqual(got, []string{"keyframe:7:2"}) {
		t.Fatalf("reliable messages = %v, want current keyframe", got)
	}
	keyframe := mustEngineReliableKeyframe(t, messages[0])
	if len(keyframe.Rows) != 1 || keyframe.Rows[0].RowVersion != 2 {
		t.Fatalf("keyframe rows = %+v, want one row version 2", keyframe.Rows)
	}
	if len(keyframe.Rows[0].Cells) != 2 ||
		keyframe.Rows[0].Cells[0].Text != "b" ||
		keyframe.Rows[0].Cells[1].Text != "b" {
		t.Fatalf("keyframe cells = %+v, want text bb", keyframe.Rows[0].Cells)
	}

	mustHandle(t, workspace, mustEngineOutputAction(t, 7, "cc"))
	deltas := workspace.DrainDatagrams()
	if len(deltas) != 1 {
		t.Fatalf("deltas after request keyframe = %d, want 1", len(deltas))
	}
	if deltas[0].BaseKeyframeID != keyframe.KeyframeID {
		t.Fatalf("delta base keyframe id = %d, want request keyframe id %d", deltas[0].BaseKeyframeID, keyframe.KeyframeID)
	}
	assertEngineFullRow(t, deltas[0].RowUpdates, 0, 3, []remotegrid.GridCell{
		engineTextCell("c"),
		engineTextCell("c"),
	})
}

func TestWorkspaceRequestKeyframesPublishesCurrentStateForSeededPanes(t *testing.T) {
	renderer := &fakePaneRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: makeEngineKeyframe(7, 1, "aa"),
			8: makeEngineKeyframe(8, 1, "cc"),
		},
		deltas: map[string]remotegrid.PaneDelta{
			"bb": makeEngineDelta(7, 1, 2, "bb"),
			"dd": makeEngineDelta(8, 1, 2, "dd"),
		},
		failCurrentKeyframe: true,
	}
	workspace := NewWorkspace("workspace-1", renderer)
	mustHandle(t, workspace, mustEngineSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 8, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
	}))
	_ = workspace.DrainReliable()

	mustHandle(t, workspace, mustEngineOutputAction(t, 8, "dd"))
	mustHandle(t, workspace, mustEngineOutputAction(t, 7, "bb"))
	if err := workspace.RequestKeyframes(); err != nil {
		t.Fatal(err)
	}

	messages := workspace.DrainReliable()
	if got := reliableKinds(t, messages); !reflect.DeepEqual(got, []string{"keyframe:7:2", "keyframe:8:2"}) {
		t.Fatalf("reliable messages = %v, want sorted current keyframes", got)
	}
	first := mustEngineReliableKeyframe(t, messages[0])
	second := mustEngineReliableKeyframe(t, messages[1])
	if got := rowText(first.Rows[0].Cells); got != "bb" {
		t.Fatalf("pane 7 keyframe row = %q, want bb", got)
	}
	if got := rowText(second.Rows[0].Cells); got != "dd" {
		t.Fatalf("pane 8 keyframe row = %q, want dd", got)
	}
}

func TestWorkspaceRequestKeyframeDoesNotReplayStaleStateAfterUnsupportedUntilNewKeyframe(t *testing.T) {
	renderer := &fakePaneRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: makeEngineKeyframe(7, 1, "aa"),
		},
		outputUpdates: map[string]RenderUpdate{
			"unsupported": {
				Unsupported: &remotegrid.UnsupportedPaneState{
					WorkspaceID:    "workspace-1",
					PaneID:         7,
					PaneGeneration: 1,
					Reason:         remotegrid.UnsupportedPaneReasonImageProtocol,
					Fallback:       remotegrid.UnsupportedPaneFallbackBlankWithDiagnostic,
				},
			},
			"restored": {
				Keyframe: ptr(makeEngineKeyframe(7, 1, "zz")),
			},
		},
		failCurrentKeyframe: true,
	}
	workspace := NewWorkspace("workspace-1", renderer)
	mustHandle(t, workspace, mustEngineSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
	}))
	_ = workspace.DrainReliable()

	mustHandle(t, workspace, mustEngineOutputAction(t, 7, "unsupported"))
	_ = workspace.DrainReliable()
	if err := workspace.RequestKeyframe(7); err != nil {
		t.Fatal(err)
	}
	if got := reliableKinds(t, workspace.DrainReliable()); len(got) != 0 {
		t.Fatalf("reliable messages after unsupported request = %v, want no stale keyframe", got)
	}

	mustHandle(t, workspace, mustEngineOutputAction(t, 7, "restored"))
	_ = workspace.DrainReliable()
	if err := workspace.RequestKeyframe(7); err != nil {
		t.Fatal(err)
	}
	messages := workspace.DrainReliable()
	if got := reliableKinds(t, messages); !reflect.DeepEqual(got, []string{"keyframe:7:2"}) {
		t.Fatalf("reliable messages after restored keyframe = %v, want restored request keyframe", got)
	}
	keyframe := mustEngineReliableKeyframe(t, messages[0])
	if got := rowText(keyframe.Rows[0].Cells); got != "zz" {
		t.Fatalf("restored keyframe row = %q, want zz", got)
	}
}

func TestWorkspacePublishesRecoveryKeyframeWhenDeltaArrivesAfterUnsupported(t *testing.T) {
	renderer := &fakePaneRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: makeEngineKeyframe(7, 1, "aa"),
		},
		outputUpdates: map[string]RenderUpdate{
			"unsupported": {
				Unsupported: &remotegrid.UnsupportedPaneState{
					WorkspaceID:    "workspace-1",
					PaneID:         7,
					PaneGeneration: 1,
					Reason:         remotegrid.UnsupportedPaneReasonImageProtocol,
					Fallback:       remotegrid.UnsupportedPaneFallbackBlankWithDiagnostic,
				},
			},
		},
		deltas: map[string]remotegrid.PaneDelta{
			"bb": makeEngineDelta(7, 1, 2, "bb"),
		},
		failCurrentKeyframe: true,
	}
	workspace := NewWorkspace("workspace-1", renderer)
	mustHandle(t, workspace, mustEngineSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
	}))
	_ = workspace.DrainReliable()

	mustHandle(t, workspace, mustEngineOutputAction(t, 7, "unsupported"))
	unsupportedMessages := workspace.DrainReliable()
	unsupported := mustEngineReliableUnsupported(t, unsupportedMessages[0])
	if unsupported.PaneGeneration != 2 {
		t.Fatalf("unsupported generation = %d, want recovery fence generation 2", unsupported.PaneGeneration)
	}
	if err := workspace.RequestKeyframe(7); err != nil {
		t.Fatal(err)
	}
	if got := reliableKinds(t, workspace.DrainReliable()); len(got) != 0 {
		t.Fatalf("reliable messages after unsupported request = %v, want no stale keyframe", got)
	}

	mustHandle(t, workspace, mustEngineOutputAction(t, 7, "bb"))
	if pending := workspace.PendingDatagrams(); pending != 0 {
		t.Fatalf("PendingDatagrams after recovery = %d, want reliable recovery keyframe only", pending)
	}
	messages := workspace.DrainReliable()
	if got := reliableKinds(t, messages); !reflect.DeepEqual(got, []string{"keyframe:7:2"}) {
		t.Fatalf("recovery reliable messages = %v, want recovery keyframe", got)
	}
	keyframe := mustEngineReliableKeyframe(t, messages[0])
	if keyframe.PaneGeneration != 2 {
		t.Fatalf("recovery keyframe generation = %d, want unsupported fence generation 2", keyframe.PaneGeneration)
	}
	if got := rowText(keyframe.Rows[0].Cells); got != "bb" {
		t.Fatalf("recovery keyframe row = %q, want bb", got)
	}
}

type fakePaneRenderer struct {
	keyframes           map[int]remotegrid.PaneKeyframe
	deltas              map[string]remotegrid.PaneDelta
	outputUpdates       map[string]RenderUpdate
	err                 error
	failCurrentKeyframe bool
	seeded              []int
	removed             []int
}

func (r *fakePaneRenderer) SeedPane(pane remotegrid.WorkspacePane) (remotegrid.PaneKeyframe, bool, error) {
	r.seeded = append(r.seeded, pane.PaneID)
	if r.err != nil {
		return remotegrid.PaneKeyframe{}, false, r.err
	}
	keyframe, ok := r.keyframes[pane.PaneID]
	return keyframe, ok, nil
}

func (r *fakePaneRenderer) ApplyOutput(paneID int, data []byte) (RenderUpdate, error) {
	if r.err != nil {
		return RenderUpdate{}, r.err
	}
	if update, ok := r.outputUpdates[string(data)]; ok {
		return update, nil
	}
	delta, ok := r.deltas[string(data)]
	if !ok {
		return RenderUpdate{}, nil
	}
	return RenderUpdate{Delta: &delta}, nil
}

func (r *fakePaneRenderer) CurrentKeyframe(paneID int) (remotegrid.PaneKeyframe, bool, error) {
	if r.failCurrentKeyframe {
		return remotegrid.PaneKeyframe{}, false, errors.New("CurrentKeyframe must not be called")
	}
	if r.err != nil {
		return remotegrid.PaneKeyframe{}, false, r.err
	}
	keyframe, ok := r.keyframes[paneID]
	return keyframe, ok, nil
}

func (r *fakePaneRenderer) RemovePane(paneID int) {
	r.removed = append(r.removed, paneID)
}

func mustEngineSnapshotAction(t *testing.T, panes []remotegrid.WorkspacePane) tmuxcc.Action {
	t.Helper()

	model := tmuxcc.NewModel("workspace-1")
	if len(panes) == 0 {
		_, err := model.ApplyListSnapshot(
			[]string{"@1\tmain\t0000,2x1,0,0,%7\t0\t1"},
			[]string{"@1\t%7\t1"},
		)
		if err != nil {
			t.Fatal(err)
		}
		actions, err := model.ApplyLine("%window-close @1")
		if err != nil {
			t.Fatal(err)
		}
		if len(actions) != 1 {
			t.Fatalf("window close produced %d actions, want 1", len(actions))
		}
		return actions[0]
	}

	windowLines := []string{"@1\tmain\t" + engineLayout(panes) + "\t0\t1"}
	paneLines := make([]string, len(panes))
	for i, pane := range panes {
		active := "0"
		if i == 0 {
			active = "1"
		}
		paneLines[i] = "@1\t%" + strconv.Itoa(pane.PaneID) + "\t" + active
	}
	actions, err := model.ApplyListSnapshot(windowLines, paneLines)
	if err != nil {
		t.Fatal(err)
	}
	if len(actions) != 1 {
		t.Fatalf("ApplyListSnapshot produced %d actions, want 1", len(actions))
	}
	return actions[0]
}

func mustEngineOutputAction(t *testing.T, paneID int, data string) tmuxcc.Action {
	t.Helper()

	model := tmuxcc.NewModel("workspace-1")
	actions, err := model.ApplyLine("%output %" + strconv.Itoa(paneID) + " " + data)
	if err != nil {
		t.Fatal(err)
	}
	if len(actions) != 1 {
		t.Fatalf("ApplyLine output produced %d actions, want 1", len(actions))
	}
	return actions[0]
}

func engineLayout(panes []remotegrid.WorkspacePane) string {
	if len(panes) == 1 {
		frame := panes[0].Frame
		return "0000," + strconv.Itoa(frame.Columns) + "x" + strconv.Itoa(frame.Rows) + ",0,0,%" + strconv.Itoa(panes[0].PaneID)
	}
	return "0000,120x30,0,0{60x30,0,0,%" + strconv.Itoa(panes[0].PaneID) + ",59x30,61,0,%" + strconv.Itoa(panes[1].PaneID) + "}"
}

func makeEngineKeyframe(paneID int, keyframeID uint64, text string) remotegrid.PaneKeyframe {
	return makeEngineKeyframeWithGeneration(paneID, 1, keyframeID, remotegrid.ActiveScreenPrimary, text)
}

func makeEngineKeyframeWithGeneration(paneID int, generation uint64, keyframeID uint64, activeScreen remotegrid.ActiveScreen, text string) remotegrid.PaneKeyframe {
	return remotegrid.PaneKeyframe{
		WorkspaceID:                   "workspace-1",
		PaneID:                        paneID,
		PaneGeneration:                generation,
		KeyframeID:                    keyframeID,
		GridSize:                      remotegrid.GridSize{Columns: len(text), Rows: 1},
		Rows:                          []remotegrid.GridRow{{Index: 0, RowVersion: keyframeID, Cells: engineCells(text)}},
		Cursor:                        remotegrid.CursorState{Row: 0, Column: 0, Visible: true, Shape: remotegrid.CursorShapeBlock, CursorVersion: 1},
		ActiveScreen:                  activeScreen,
		DatagramsEnabledAfterKeyframe: true,
	}
}

func makeEngineDelta(paneID int, sequence uint64, rowVersion uint64, text string) remotegrid.PaneDelta {
	return makeEngineDeltaWithBase(paneID, 1, sequence, rowVersion, text)
}

func makeEngineDeltaWithBase(paneID int, baseKeyframeID uint64, sequence uint64, rowVersion uint64, text string) remotegrid.PaneDelta {
	return remotegrid.PaneDelta{
		WorkspaceID:    "workspace-1",
		PaneID:         paneID,
		PaneGeneration: 1,
		BaseKeyframeID: baseKeyframeID,
		DeltaSequence:  sequence,
		RowUpdates: []remotegrid.RowUpdate{{
			RowIndex:   0,
			RowVersion: rowVersion,
			Update:     remotegrid.FullRow(engineCells(text)),
		}},
	}
}

func engineCells(text string) []remotegrid.GridCell {
	cells := make([]remotegrid.GridCell, 0, len(text))
	for _, ch := range text {
		cells = append(cells, engineTextCell(string(ch)))
	}
	return cells
}

func engineTextCell(text string) remotegrid.GridCell {
	return remotegrid.GridCell{Text: text, Width: 1, Style: remotegrid.NormalCellStyle}
}

func rowText(cells []remotegrid.GridCell) string {
	var builder strings.Builder
	for _, cell := range cells {
		builder.WriteString(cell.Text)
	}
	return builder.String()
}

func reliableKinds(t *testing.T, messages []remotegrid.WorkspaceMessage) []string {
	t.Helper()

	kinds := make([]string, 0, len(messages))
	for _, message := range messages {
		if snapshot, ok := decodeReliablePayload[remotegrid.WorkspaceSnapshot](t, message, "workspaceSnapshot"); ok {
			kinds = append(kinds, "snapshot:"+snapshot.WorkspaceID)
			continue
		}
		if keyframe, ok := decodeReliablePayload[remotegrid.PaneKeyframe](t, message, "paneKeyframe"); ok {
			kinds = append(kinds, "keyframe:"+strconv.Itoa(keyframe.PaneID)+":"+strconv.FormatUint(keyframe.KeyframeID, 10))
			continue
		}
		if state, ok := decodeReliablePayload[remotegrid.UnsupportedPaneState](t, message, "unsupportedPaneState"); ok {
			kinds = append(kinds, "unsupported:"+strconv.Itoa(state.PaneID))
			continue
		}
		kinds = append(kinds, "unknown")
	}
	return kinds
}

func decodeReliablePayload[T any](t *testing.T, message remotegrid.WorkspaceMessage, kind string) (T, bool) {
	t.Helper()

	var zero T
	data, err := json.Marshal(message)
	if err != nil {
		t.Fatal(err)
	}
	var envelope map[string]struct {
		Value json.RawMessage `json:"_0"`
	}
	if err := json.Unmarshal(data, &envelope); err != nil {
		t.Fatal(err)
	}
	payload, ok := envelope[kind]
	if !ok {
		return zero, false
	}
	var decoded T
	if err := json.Unmarshal(payload.Value, &decoded); err != nil {
		t.Fatal(err)
	}
	return decoded, true
}

func mustEngineReliableKeyframe(t *testing.T, message remotegrid.WorkspaceMessage) remotegrid.PaneKeyframe {
	t.Helper()

	keyframe, ok := message.PaneKeyframe()
	if !ok {
		t.Fatalf("reliable message is not paneKeyframe: %+v", message)
	}
	return keyframe
}

func mustEngineReliableUnsupported(t *testing.T, message remotegrid.WorkspaceMessage) remotegrid.UnsupportedPaneState {
	t.Helper()

	state, ok := decodeReliablePayload[remotegrid.UnsupportedPaneState](t, message, "unsupportedPaneState")
	if !ok {
		t.Fatalf("reliable message is not unsupportedPaneState: %+v", message)
	}
	return state
}

func ptr[T any](value T) *T {
	return &value
}

func mustHandle(t *testing.T, workspace *Workspace, action tmuxcc.Action) {
	t.Helper()
	if err := workspace.Handle(action); err != nil {
		t.Fatal(err)
	}
}

func assertEngineFullRow(t *testing.T, updates []remotegrid.RowUpdate, rowIndex int, rowVersion uint64, cells []remotegrid.GridCell) {
	t.Helper()
	if len(updates) != 1 {
		t.Fatalf("row updates = %d, want 1", len(updates))
	}
	if updates[0].RowIndex != rowIndex || updates[0].RowVersion != rowVersion {
		t.Fatalf("row update = row %d version %d, want row %d version %d", updates[0].RowIndex, updates[0].RowVersion, rowIndex, rowVersion)
	}
	if !sameCellTextAndWidth(fullRowCells(t, updates[0].Update), cells) {
		t.Fatalf("full row = %+v, want text/width from %+v", fullRowCells(t, updates[0].Update), cells)
	}
}

func sameCellTextAndWidth(left []remotegrid.GridCell, right []remotegrid.GridCell) bool {
	if len(left) != len(right) {
		return false
	}
	for i := range left {
		if left[i].Text != right[i].Text || left[i].Width != right[i].Width {
			return false
		}
	}
	return true
}

func fullRowCells(t *testing.T, update remotegrid.RowUpdateBody) []remotegrid.GridCell {
	t.Helper()

	data, err := json.Marshal(update)
	if err != nil {
		t.Fatal(err)
	}
	var body struct {
		FullRow struct {
			Cells []remotegrid.GridCell `json:"_0"`
		} `json:"fullRow"`
	}
	if err := json.Unmarshal(data, &body); err != nil {
		t.Fatal(err)
	}
	return body.FullRow.Cells
}
