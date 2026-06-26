package engine

import (
	"strings"
	"testing"

	"fantastty/remote-engine-helper/remotegrid"
	"fantastty/remote-engine-helper/tmuxcc"
)

func TestWorkspaceHandleStreamBuffersEarlyOutputUntilSnapshot(t *testing.T) {
	renderer := &fakePaneRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: makeEngineKeyframe(7, 1, "aa"),
		},
		deltas: map[string]remotegrid.PaneDelta{
			"early\n": makeEngineDelta(7, 1, 1, "bb"),
		},
	}
	workspace := NewWorkspace("workspace-1", renderer)
	reader := strings.NewReader(strings.Join([]string{
		`%output %7 early\012`,
		"%window-add @1",
		"%layout-change @1 b25d,2x1,0,0,%7",
	}, "\n"))

	err := workspace.HandleStream(reader, tmuxcc.NewModel("workspace-1"), tmuxcc.NewPaneOutputBuffer())

	if err != nil {
		t.Fatal(err)
	}
	if got := reliableKinds(t, workspace.DrainReliable()); got[0] != "snapshot:workspace-1" || got[1] != "keyframe:7:1" {
		t.Fatalf("reliable messages = %v, want snapshot then keyframe", got)
	}
	deltas := workspace.DrainDatagrams()
	if len(deltas) != 1 {
		t.Fatalf("datagram deltas = %d, want 1", len(deltas))
	}
	if deltas[0].PaneID != 7 || deltas[0].DeltaSequence != 1 {
		t.Fatalf("delta = pane %d sequence %d, want pane 7 sequence 1", deltas[0].PaneID, deltas[0].DeltaSequence)
	}
}
