package tmuxcc

import "testing"

func TestPaneOutputBufferFlushesOutputAfterPaneAppearsInSnapshot(t *testing.T) {
	buffer := NewPaneOutputBuffer()
	output := mustOutputAction(t, `%output %7 hello\012`)
	snapshot := mustListSnapshotAction(t,
		[]string{"@1\tmain\t0000,80x24,0,0,%7\t0\t1"},
		[]string{"@1\t%7\t1"},
	)

	if got := buffer.Filter([]Action{output}); len(got) != 0 {
		t.Fatalf("Filter unknown pane output = %d actions, want 0", len(got))
	}
	got := buffer.Filter([]Action{snapshot})

	if len(got) != 2 {
		t.Fatalf("Filter snapshot = %d actions, want snapshot and buffered output", len(got))
	}
	if _, ok := got[0].WorkspaceSnapshot(); !ok {
		t.Fatalf("action 0 = %#v, want workspace snapshot", got[0])
	}
	assertPaneOutput(t, got[1], 7, "hello\n")
	if pending := buffer.PendingCount(); pending != 0 {
		t.Fatalf("PendingCount() = %d, want 0", pending)
	}
}

func TestPaneOutputBufferPreservesBufferedOutputOrderAcrossPanes(t *testing.T) {
	buffer := NewPaneOutputBuffer()
	output7 := mustOutputAction(t, `%output %7 first\012`)
	output8 := mustOutputAction(t, `%output %8 second\012`)
	snapshot := mustListSnapshotAction(t,
		[]string{"@1\tmain\tb25d,120x30,0,0{60x30,0,0,%7,59x30,61,0,%8}\t0\t1"},
		[]string{"@1\t%7\t1", "@1\t%8\t0"},
	)

	buffer.Filter([]Action{output7, output8})
	got := buffer.Filter([]Action{snapshot})

	if len(got) != 3 {
		t.Fatalf("Filter snapshot = %d actions, want snapshot and two outputs", len(got))
	}
	assertPaneOutput(t, got[1], 7, "first\n")
	assertPaneOutput(t, got[2], 8, "second\n")
}

func TestPaneOutputBufferEmitsKnownPaneOutputImmediately(t *testing.T) {
	buffer := NewPaneOutputBuffer()
	snapshot := mustListSnapshotAction(t,
		[]string{"@1\tmain\t0000,80x24,0,0,%7\t0\t1"},
		[]string{"@1\t%7\t1"},
	)
	output := mustOutputAction(t, `%output %7 live\012`)
	buffer.Filter([]Action{snapshot})

	got := buffer.Filter([]Action{output})

	if len(got) != 1 {
		t.Fatalf("Filter known pane output = %d actions, want 1", len(got))
	}
	assertPaneOutput(t, got[0], 7, "live\n")
}

func TestPaneOutputBufferKeepsUnknownPaneOutputAfterUnrelatedSnapshot(t *testing.T) {
	buffer := NewPaneOutputBuffer()
	output := mustOutputAction(t, `%output %9 later\012`)
	snapshot := mustListSnapshotAction(t,
		[]string{"@1\tmain\t0000,80x24,0,0,%7\t0\t1"},
		[]string{"@1\t%7\t1"},
	)

	buffer.Filter([]Action{output})
	got := buffer.Filter([]Action{snapshot})

	if len(got) != 1 {
		t.Fatalf("Filter unrelated snapshot = %d actions, want only snapshot", len(got))
	}
	if pending := buffer.PendingCount(); pending != 1 {
		t.Fatalf("PendingCount() = %d, want 1", pending)
	}
}

func TestPaneOutputBufferDropsOldestPendingOutputAtLimit(t *testing.T) {
	buffer := NewPaneOutputBufferWithLimit(2)
	output1 := mustOutputAction(t, `%output %7 first\012`)
	output2 := mustOutputAction(t, `%output %7 second\012`)
	output3 := mustOutputAction(t, `%output %7 third\012`)
	snapshot := mustListSnapshotAction(t,
		[]string{"@1\tmain\t0000,80x24,0,0,%7\t0\t1"},
		[]string{"@1\t%7\t1"},
	)

	buffer.Filter([]Action{output1, output2, output3})
	got := buffer.Filter([]Action{snapshot})

	if len(got) != 3 {
		t.Fatalf("Filter snapshot = %d actions, want snapshot and two buffered outputs", len(got))
	}
	assertPaneOutput(t, got[1], 7, "second\n")
	assertPaneOutput(t, got[2], 7, "third\n")
	if pending := buffer.PendingCount(); pending != 0 {
		t.Fatalf("PendingCount() = %d, want 0", pending)
	}
}

func mustOutputAction(t *testing.T, line string) Action {
	t.Helper()

	model := NewModel("workspace-1")
	actions, err := model.ApplyLine(line)
	if err != nil {
		t.Fatal(err)
	}
	if len(actions) != 1 {
		t.Fatalf("ApplyLine(%q) produced %d actions, want 1", line, len(actions))
	}
	return actions[0]
}

func mustListSnapshotAction(t *testing.T, windowLines []string, paneLines []string) Action {
	t.Helper()

	model := NewModel("workspace-1")
	actions, err := model.ApplyListSnapshot(windowLines, paneLines)
	if err != nil {
		t.Fatal(err)
	}
	if len(actions) != 1 {
		t.Fatalf("ApplyListSnapshot produced %d actions, want 1", len(actions))
	}
	return actions[0]
}

func assertPaneOutput(t *testing.T, action Action, paneID int, data string) {
	t.Helper()

	output, ok := action.PaneOutput()
	if !ok {
		t.Fatalf("action = %#v, want pane output", action)
	}
	if output.PaneID != paneID || string(output.Data) != data {
		t.Fatalf("output = pane %d data %q, want pane %d data %q", output.PaneID, output.Data, paneID, data)
	}
}
