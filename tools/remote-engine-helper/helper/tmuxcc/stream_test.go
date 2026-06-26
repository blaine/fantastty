package tmuxcc

import (
	"errors"
	"strings"
	"testing"
)

func TestReadActionsReturnsModelActionsInStreamOrder(t *testing.T) {
	model := NewModel("workspace-1")
	reader := strings.NewReader(strings.Join([]string{
		"%window-add @1",
		"%layout-change @1 b25d,80x24,0,0,%7",
		`%output %7 hello\012`,
		"%window-renamed @1 main",
	}, "\n"))

	actions, err := ReadActions(reader, model)
	if err != nil {
		t.Fatal(err)
	}
	if len(actions) != 3 {
		t.Fatalf("actions = %#v, want 3 actions", actions)
	}

	firstSnapshot, ok := actions[0].WorkspaceSnapshot()
	if !ok {
		t.Fatalf("action 0 = %#v, want workspace snapshot", actions[0])
	}
	if firstSnapshot.LayoutGeneration != 1 {
		t.Fatalf("first layout generation = %d, want 1", firstSnapshot.LayoutGeneration)
	}

	output, ok := actions[1].PaneOutput()
	if !ok {
		t.Fatalf("action 1 = %#v, want pane output", actions[1])
	}
	if output.PaneID != 7 || string(output.Data) != "hello\n" {
		t.Fatalf("output = pane %d data %q, want pane 7 data hello newline", output.PaneID, output.Data)
	}

	lastSnapshot, ok := actions[2].WorkspaceSnapshot()
	if !ok {
		t.Fatalf("action 2 = %#v, want workspace snapshot", actions[2])
	}
	if lastSnapshot.LayoutGeneration != 2 {
		t.Fatalf("last layout generation = %d, want 2", lastSnapshot.LayoutGeneration)
	}
	if got := lastSnapshot.Windows[0].Title; got != "main" {
		t.Fatalf("window title = %q, want main", got)
	}
}

func TestReadActionsProcessesFinalLineWithoutTrailingNewline(t *testing.T) {
	model := NewModel("workspace-1")

	actions, err := ReadActions(strings.NewReader(`%output %7 tail\012`), model)
	if err != nil {
		t.Fatal(err)
	}
	if len(actions) != 1 {
		t.Fatalf("actions = %#v, want one action", actions)
	}
	output, ok := actions[0].PaneOutput()
	if !ok {
		t.Fatalf("action = %#v, want pane output", actions[0])
	}
	if output.PaneID != 7 || string(output.Data) != "tail\n" {
		t.Fatalf("output = pane %d data %q, want pane 7 data tail newline", output.PaneID, output.Data)
	}
}

func TestReadActionsWrapsModelErrorsWithLineNumber(t *testing.T) {
	model := NewModel("workspace-1")
	reader := strings.NewReader(strings.Join([]string{
		"%window-add @1",
		"%layout-change @1 not-a-layout",
	}, "\n"))

	_, err := ReadActions(reader, model)
	if err == nil {
		t.Fatal("ReadActions error = nil, want error")
	}
	if !strings.Contains(err.Error(), "line 2") {
		t.Fatalf("error = %q, want line number context", err)
	}
	if !strings.Contains(err.Error(), "layout contains no panes") {
		t.Fatalf("error = %q, want model error context", err)
	}
}

func TestScanActionsStreamsActionsAndStopsOnHandlerError(t *testing.T) {
	model := NewModel("workspace-1")
	reader := strings.NewReader(strings.Join([]string{
		"%window-add @1",
		"%layout-change @1 b25d,80x24,0,0,%7",
		`%output %7 hello\012`,
		"%window-renamed @1 should-not-be-applied",
	}, "\n"))
	handlerErr := errors.New("handler rejected action")
	seen := 0

	err := ScanActions(reader, model, func(Action) error {
		seen++
		if seen == 2 {
			return handlerErr
		}
		return nil
	})

	if !errors.Is(err, handlerErr) {
		t.Fatalf("ScanActions error = %v, want handler error", err)
	}
	if seen != 2 {
		t.Fatalf("seen actions = %d, want 2", seen)
	}
	actions := mustApplyLines(t, model, "%window-renamed @1 after-stop")
	snapshot, ok := actions[0].WorkspaceSnapshot()
	if !ok {
		t.Fatalf("post-stop action = %#v, want workspace snapshot", actions[0])
	}
	if got := snapshot.Windows[0].Title; got != "after-stop" {
		t.Fatalf("window title after stop = %q, want after-stop", got)
	}
}

func TestScanBufferedActionsHoldsOutputUntilPaneSnapshot(t *testing.T) {
	model := NewModel("workspace-1")
	buffer := NewPaneOutputBuffer()
	reader := strings.NewReader(strings.Join([]string{
		`%output %7 early\012`,
		"%window-add @1",
		"%layout-change @1 b25d,80x24,0,0,%7",
	}, "\n"))
	var actions []Action

	err := ScanBufferedActions(reader, model, buffer, func(action Action) error {
		actions = append(actions, action)
		return nil
	})

	if err != nil {
		t.Fatal(err)
	}
	if len(actions) != 2 {
		t.Fatalf("actions = %#v, want snapshot then buffered output", actions)
	}
	if _, ok := actions[0].WorkspaceSnapshot(); !ok {
		t.Fatalf("action 0 = %#v, want workspace snapshot", actions[0])
	}
	output, ok := actions[1].PaneOutput()
	if !ok {
		t.Fatalf("action 1 = %#v, want pane output", actions[1])
	}
	if output.PaneID != 7 || string(output.Data) != "early\n" {
		t.Fatalf("output = pane %d data %q, want pane 7 data early newline", output.PaneID, output.Data)
	}
}

func TestReadBufferedActionsUsesProvidedBuffer(t *testing.T) {
	model := NewModel("workspace-1")
	buffer := NewPaneOutputBuffer()
	buffer.Filter([]Action{mustOutputAction(t, `%output %7 before-read\012`)})
	reader := strings.NewReader(strings.Join([]string{
		"%window-add @1",
		"%layout-change @1 b25d,80x24,0,0,%7",
	}, "\n"))

	actions, err := ReadBufferedActions(reader, model, buffer)

	if err != nil {
		t.Fatal(err)
	}
	if len(actions) != 2 {
		t.Fatalf("actions = %#v, want snapshot and previously buffered output", actions)
	}
	output, ok := actions[1].PaneOutput()
	if !ok || output.PaneID != 7 || string(output.Data) != "before-read\n" {
		t.Fatalf("action 1 output = (%+v, %v), want pane 7 before-read", output, ok)
	}
}
