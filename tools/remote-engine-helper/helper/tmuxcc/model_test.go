package tmuxcc

import (
	"bytes"
	"encoding/json"
	"reflect"
	"testing"

	"fantastty/remote-engine-helper/remotegrid"
)

func TestModelBuildsWorkspaceSnapshotFromControlNotifications(t *testing.T) {
	model := NewModel("workspace-1")

	actions := mustApplyLines(t, model,
		"%window-add @1",
		"%window-renamed @1 main",
		"%layout-change @1 b25d,120x30,0,0{60x30,0,0,%7,59x30,61,0,%8}",
		"%window-pane-changed @1 %8",
		"%session-window-changed $1 @1",
	)

	if len(actions) == 0 {
		t.Fatal("ApplyLine returned no actions")
	}
	got, ok := actions[len(actions)-1].WorkspaceSnapshot()
	if !ok {
		t.Fatalf("last action = %#v, want workspace snapshot", actions[len(actions)-1])
	}

	want := remotegrid.WorkspaceSnapshot{
		WorkspaceID:      "workspace-1",
		LayoutGeneration: 2,
		Windows: []remotegrid.WorkspaceWindow{{
			WindowID: 1,
			Title:    "main",
			IsActive: true,
			Layout:   "b25d,120x30,0,0{60x30,0,0,%7,59x30,61,0,%8}",
		}},
		Panes: []remotegrid.WorkspacePane{
			{
				PaneID:   7,
				WindowID: 1,
				IsActive: false,
				Frame:    remotegrid.PaneFrame{X: 0, Y: 0, Columns: 60, Rows: 30},
			},
			{
				PaneID:   8,
				WindowID: 1,
				IsActive: true,
				Frame:    remotegrid.PaneFrame{X: 61, Y: 0, Columns: 59, Rows: 30},
			},
		},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("snapshot = %#v, want %#v", got, want)
	}
}

func TestModelIncludesControlModeLayoutInWorkspaceSnapshot(t *testing.T) {
	model := NewModel("workspace-1")
	layout := "abcd,120x30,0,0[120x14,0,0{60x14,0,0,%7,59x14,61,0,%8},120x15,0,15,%9]"

	actions := mustApplyLines(t, model,
		"%window-add @1",
		"%layout-change @1 "+layout,
	)
	if len(actions) != 1 {
		t.Fatalf("actions = %#v, want one snapshot", actions)
	}
	snapshot, ok := actions[0].WorkspaceSnapshot()
	if !ok {
		t.Fatalf("action = %#v, want workspace snapshot", actions[0])
	}

	if got := windowLayoutsFromJSON(t, snapshot); !reflect.DeepEqual(got, []string{layout}) {
		t.Fatalf("window layouts = %#v, want [%q]", got, layout)
	}
}

func TestModelIncludesListWindowLayoutInWorkspaceSnapshot(t *testing.T) {
	model := NewModel("workspace-1")
	layout := "abcd,120x30,0,0[120x14,0,0{60x14,0,0,7,59x14,61,0,8},120x15,0,15,9]"

	actions, err := model.ApplyListSnapshot(
		[]string{"@1\tmain\t" + layout + "\t0\t1"},
		[]string{"@1\t%7\t1", "@1\t%8\t0", "@1\t%9\t0"},
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(actions) != 1 {
		t.Fatalf("actions = %#v, want one complete seed snapshot", actions)
	}
	snapshot, ok := actions[0].WorkspaceSnapshot()
	if !ok {
		t.Fatalf("action = %#v, want workspace snapshot", actions[0])
	}

	if got := windowLayoutsFromJSON(t, snapshot); !reflect.DeepEqual(got, []string{layout}) {
		t.Fatalf("window layouts = %#v, want [%q]", got, layout)
	}
}

func TestModelEmitsSnapshotWhenPaneFramesChange(t *testing.T) {
	model := NewModel("workspace-1")
	_ = mustApplyLines(t, model,
		"%window-add @1",
		"%layout-change @1 b25d,120x30,0,0{60x30,0,0,%7,59x30,61,0,%8}",
	)

	actions := mustApplyLines(t, model,
		"%layout-change @1 402b,120x30,0,0{59x30,0,0,%7,60x30,60,0,%8}",
	)

	if len(actions) != 1 {
		t.Fatalf("resize-only layout actions = %#v, want one snapshot", actions)
	}
	snapshot, ok := actions[0].WorkspaceSnapshot()
	if !ok {
		t.Fatalf("action = %#v, want workspace snapshot", actions[0])
	}
	if snapshot.LayoutGeneration != 2 {
		t.Fatalf("layout generation = %d, want 2", snapshot.LayoutGeneration)
	}
	if snapshot.Panes[0].Frame != (remotegrid.PaneFrame{X: 0, Y: 0, Columns: 59, Rows: 30}) {
		t.Fatalf("pane 7 frame = %+v, want resized frame", snapshot.Panes[0].Frame)
	}
	if snapshot.Panes[1].Frame != (remotegrid.PaneFrame{X: 60, Y: 0, Columns: 60, Rows: 30}) {
		t.Fatalf("pane 8 frame = %+v, want resized frame", snapshot.Panes[1].Frame)
	}
}

func TestModelEmitsSnapshotWhenPaneSetChanges(t *testing.T) {
	model := NewModel("workspace-1")
	_ = mustApplyLines(t, model,
		"%window-add @1",
		"%layout-change @1 b25d,120x30,0,0{60x30,0,0,%7,59x30,61,0,%8}",
	)

	actions := mustApplyLines(t, model,
		"%layout-change @1 e016,120x30,0,0{40x30,0,0,%7,39x30,41,0,%8,39x30,81,0,%9}",
	)

	if len(actions) != 1 {
		t.Fatalf("pane-set layout actions = %#v, want one snapshot", actions)
	}
	snapshot, ok := actions[0].WorkspaceSnapshot()
	if !ok {
		t.Fatalf("action = %#v, want workspace snapshot", actions[0])
	}
	if snapshot.LayoutGeneration != 2 {
		t.Fatalf("layout generation = %d, want 2", snapshot.LayoutGeneration)
	}
	if got := paneIDs(snapshot.Panes); !reflect.DeepEqual(got, []int{7, 8, 9}) {
		t.Fatalf("pane ids = %v, want [7 8 9]", got)
	}
}

func TestModelParsesRealControlModeLayoutChange(t *testing.T) {
	model := NewModel("workspace-1")

	actions := mustApplyLines(t, model,
		"%layout-change @0 b25d,80x24,0,0,0 b25d,80x24,0,0,0 *",
	)

	if len(actions) != 1 {
		t.Fatalf("actions = %#v, want one snapshot", actions)
	}
	snapshot, ok := actions[0].WorkspaceSnapshot()
	if !ok {
		t.Fatalf("action = %#v, want workspace snapshot", actions[0])
	}
	if snapshot.LayoutGeneration != 1 {
		t.Fatalf("layout generation = %d, want 1", snapshot.LayoutGeneration)
	}
	if len(snapshot.Windows) != 1 {
		t.Fatalf("window count = %d, want 1", len(snapshot.Windows))
	}
	if !snapshot.Windows[0].IsActive {
		t.Fatal("window isActive = false, want true")
	}
	if got := paneIDs(snapshot.Panes); !reflect.DeepEqual(got, []int{0}) {
		t.Fatalf("pane ids = %v, want [0]", got)
	}
	if !snapshot.Panes[0].IsActive {
		t.Fatal("pane isActive = false, want true")
	}
	if snapshot.Panes[0].Frame != (remotegrid.PaneFrame{X: 0, Y: 0, Columns: 80, Rows: 24}) {
		t.Fatalf("pane frame = %+v, want 80x24 at 0,0", snapshot.Panes[0].Frame)
	}
}

func TestModelUsesLayoutChangeActiveWindowMarker(t *testing.T) {
	model := NewModel("workspace-1")

	actions := mustApplyLines(t, model,
		"%layout-change @0 b25d,80x24,0,0,0 b25d,80x24,0,0,0 -",
		"%layout-change @1 e1dd,80x24,0,0,1 e1dd,80x24,0,0,1 *",
	)

	if len(actions) != 2 {
		t.Fatalf("actions = %#v, want two snapshots", actions)
	}
	snapshot, ok := actions[len(actions)-1].WorkspaceSnapshot()
	if !ok {
		t.Fatalf("last action = %#v, want workspace snapshot", actions[len(actions)-1])
	}
	if len(snapshot.Windows) != 2 {
		t.Fatalf("window count = %d, want 2", len(snapshot.Windows))
	}
	if snapshot.Windows[0].IsActive {
		t.Fatal("window @0 isActive = true, want false")
	}
	if !snapshot.Windows[1].IsActive {
		t.Fatal("window @1 isActive = false, want true")
	}
	if snapshot.Panes[0].IsActive {
		t.Fatal("pane 0 isActive = true, want false")
	}
	if !snapshot.Panes[1].IsActive {
		t.Fatal("pane 1 isActive = false, want true")
	}
}

func TestModelKeepsOneActivePaneWhenActivePaneDisappears(t *testing.T) {
	model := NewModel("workspace-1")
	_ = mustApplyLines(t, model,
		"%window-add @1",
		"%layout-change @1 b25d,120x30,0,0{60x30,0,0,%7,59x30,61,0,%8}",
		"%window-pane-changed @1 %8",
	)

	actions := mustApplyLines(t, model,
		"%layout-change @1 b25d,120x30,0,0,%7",
	)

	if len(actions) != 1 {
		t.Fatalf("actions = %#v, want one snapshot", actions)
	}
	snapshot, ok := actions[0].WorkspaceSnapshot()
	if !ok {
		t.Fatalf("action = %#v, want workspace snapshot", actions[0])
	}
	if len(snapshot.Panes) != 1 {
		t.Fatalf("pane count = %d, want 1", len(snapshot.Panes))
	}
	if !snapshot.Panes[0].IsActive {
		t.Fatal("remaining pane isActive = false, want true")
	}
}

func TestModelSeedsInitialWorkspaceFromTmuxListOutput(t *testing.T) {
	model := NewModel("workspace-1")

	actions, err := model.ApplyListSnapshot(
		[]string{
			"@0\tlogs\tb25d,80x24,0,0,0\t0\t0",
			"@1\tmain\te1dd,80x24,0,0{40x24,0,0,1,39x24,41,0,2}\t1\t1",
		},
		[]string{
			"@0\t%0\t1",
			"@1\t%1\t0",
			"@1\t%2\t1",
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(actions) != 1 {
		t.Fatalf("actions = %#v, want one complete seed snapshot", actions)
	}
	snapshot, ok := actions[0].WorkspaceSnapshot()
	if !ok {
		t.Fatalf("action = %#v, want workspace snapshot", actions[0])
	}

	if len(snapshot.Windows) != 2 {
		t.Fatalf("window count = %d, want 2", len(snapshot.Windows))
	}
	if snapshot.Windows[0].Title != "logs" || snapshot.Windows[0].Index == nil || *snapshot.Windows[0].Index != 0 || snapshot.Windows[0].IsActive {
		t.Fatalf("window 0 = %+v, want inactive logs index 0", snapshot.Windows[0])
	}
	if snapshot.Windows[1].Title != "main" || snapshot.Windows[1].Index == nil || *snapshot.Windows[1].Index != 1 || !snapshot.Windows[1].IsActive {
		t.Fatalf("window 1 = %+v, want active main index 1", snapshot.Windows[1])
	}
	if len(snapshot.Panes) != 3 {
		t.Fatalf("pane count = %d, want 3", len(snapshot.Panes))
	}
	if snapshot.Panes[0].IsActive {
		t.Fatal("pane 0 isActive = true, want false because active window is @1")
	}
	if snapshot.Panes[1].IsActive {
		t.Fatal("pane 1 isActive = true, want false")
	}
	if !snapshot.Panes[2].IsActive {
		t.Fatal("pane 2 isActive = false, want true")
	}
	if snapshot.LayoutGeneration != 1 {
		t.Fatalf("layout generation = %d, want 1", snapshot.LayoutGeneration)
	}
}

func TestModelRejectsMalformedListSnapshotWithoutPartialSeed(t *testing.T) {
	model := NewModel("workspace-1")

	if _, err := model.ApplyListSnapshot(
		[]string{"@0\tlogs\tnot-a-layout\t0\t1"},
		nil,
	); err == nil {
		t.Fatal("ApplyListSnapshot error = nil, want malformed layout error")
	}

	actions := mustApplyLines(t, model,
		"%window-add @1",
		"%layout-change @1 b25d,80x24,0,0,%7",
	)
	snapshot, ok := actions[0].WorkspaceSnapshot()
	if !ok {
		t.Fatalf("action = %#v, want workspace snapshot", actions[0])
	}
	if snapshot.Windows[0].WindowID != 1 {
		t.Fatalf("window id after rejected seed = %d, want clean model window 1", snapshot.Windows[0].WindowID)
	}
}

func TestModelRejectsMalformedControlLinesWithoutMutatingSnapshot(t *testing.T) {
	model := NewModel("workspace-1")
	initial := mustApplyLines(t, model,
		"%window-add @1",
		"%layout-change @1 b25d,80x24,0,0,%7",
	)
	if len(initial) != 1 {
		t.Fatalf("initial actions = %#v, want one snapshot", initial)
	}

	if _, err := model.ApplyLine("%layout-change @1 not-a-layout"); err == nil {
		t.Fatal("ApplyLine malformed layout error = nil, want error")
	}

	actions := mustApplyLines(t, model,
		"%window-renamed @1 renamed",
	)
	if len(actions) != 1 {
		t.Fatalf("post-error actions = %#v, want one snapshot", actions)
	}
	snapshot, ok := actions[0].WorkspaceSnapshot()
	if !ok {
		t.Fatalf("action = %#v, want workspace snapshot", actions[0])
	}
	if snapshot.LayoutGeneration != 2 {
		t.Fatalf("layout generation = %d, want 2", snapshot.LayoutGeneration)
	}
	if got := paneIDs(snapshot.Panes); !reflect.DeepEqual(got, []int{7}) {
		t.Fatalf("pane ids = %v, want [7]", got)
	}
}

func TestModelEmitsPaneOutputActions(t *testing.T) {
	model := NewModel("workspace-1")

	actions := mustApplyLines(t, model, `%output %7 hello\012`)

	if len(actions) != 1 {
		t.Fatalf("output actions = %#v, want one pane output", actions)
	}
	event, ok := actions[0].PaneOutput()
	if !ok {
		t.Fatalf("action = %#v, want pane output", actions[0])
	}
	if event.PaneID != 7 {
		t.Fatalf("pane id = %d, want 7", event.PaneID)
	}
	if want := []byte("hello\n"); !bytes.Equal(event.Data, want) {
		t.Fatalf("data = %q, want %q", event.Data, want)
	}
}

func TestModelEmitsPaneFlowControlActions(t *testing.T) {
	model := NewModel("workspace-1")

	actions := mustApplyLines(t, model,
		"%pause %7",
		"%continue %7",
	)
	if len(actions) != 2 {
		t.Fatalf("flow-control actions = %#v, want pause and continue", actions)
	}

	pause, ok := actions[0].PaneFlow()
	if !ok {
		t.Fatalf("first action = %#v, want pane flow event", actions[0])
	}
	if pause.PaneID != 7 || !pause.Paused {
		t.Fatalf("pause event = %+v, want pane 7 paused", pause)
	}
	resume, ok := actions[1].PaneFlow()
	if !ok {
		t.Fatalf("second action = %#v, want pane flow event", actions[1])
	}
	if resume.PaneID != 7 || resume.Paused {
		t.Fatalf("continue event = %+v, want pane 7 continued", resume)
	}
}

func TestModelRejectsMalformedPaneOutput(t *testing.T) {
	model := NewModel("workspace-1")

	if _, err := model.ApplyLine(`%output %7 bad\12`); err == nil {
		t.Fatal("ApplyLine malformed output error = nil, want error")
	}
}

func mustApplyLines(t *testing.T, model *Model, lines ...string) []Action {
	t.Helper()

	var actions []Action
	for _, line := range lines {
		next, err := model.ApplyLine(line)
		if err != nil {
			t.Fatalf("ApplyLine(%q): %v", line, err)
		}
		actions = append(actions, next...)
	}
	return actions
}

func windowLayoutsFromJSON(t *testing.T, snapshot remotegrid.WorkspaceSnapshot) []string {
	t.Helper()

	data, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	var decoded struct {
		Windows []struct {
			Layout string `json:"layout"`
		} `json:"windows"`
	}
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}
	layouts := make([]string, len(decoded.Windows))
	for index, window := range decoded.Windows {
		layouts[index] = window.Layout
	}
	return layouts
}

func paneIDs(panes []remotegrid.WorkspacePane) []int {
	ids := make([]int, len(panes))
	for i, pane := range panes {
		ids[i] = pane.PaneID
	}
	return ids
}
