package main

import (
	"reflect"
	"strings"
	"sync"
	"testing"

	"fantastty/remote-engine-helper/remotegrid"
)

func TestTmuxControlWorkspaceSourceSeedsListSnapshot(t *testing.T) {
	renderer := &sourceFakeRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: sourceKeyframe(7, 1, "aa"),
		},
	}
	source := newTmuxControlWorkspaceSource("workspace-1", renderer)

	if err := source.HandleListSnapshot(
		[]string{"@1\tmain\t0000,2x1,0,0,%7\t0\t1"},
		[]string{"@1\t%7\t1"},
		nil,
	); err != nil {
		t.Fatal(err)
	}

	payload, err := source.CurrentPayload("workspace-1")
	if err != nil {
		t.Fatal(err)
	}
	if got := sourceReliableKinds(t, payload.Reliable); !reflect.DeepEqual(got, []string{"snapshot:workspace-1", "keyframe:7:1"}) {
		t.Fatalf("reliable payload = %v, want snapshot and keyframe", got)
	}
}

func TestTmuxControlWorkspaceSourceAttachesStructuredInitialCapture(t *testing.T) {
	renderer := &sourceFakeRenderer{seedFromInitialRows: true}
	source := newTmuxControlWorkspaceSource("workspace-1", renderer)

	if err := source.HandleListSnapshot(
		[]string{"@1\tmain\t0000,9x2,0,0,%7\t0\t1"},
		[]string{"@1\t%7\t1"},
		map[int]remotegrid.PaneInitialCapture{
			7: {
				PrimaryRows:   []string{""},
				AlternateRows: []string{"alternate"},
				ActiveScreen:  remotegrid.ActiveScreenAlternate,
			},
		},
	); err != nil {
		t.Fatal(err)
	}

	payload, err := source.CurrentPayload("workspace-1")
	if err != nil {
		t.Fatal(err)
	}
	keyframe := sourceOnlyKeyframe(t, payload.Reliable)
	if got := sourceKeyframeText(keyframe); !strings.Contains(got, "alternate") || strings.Contains(got, "primary") {
		t.Fatalf("initial keyframe text = %q, want alternate capture rows", got)
	}
	if got := renderer.seededRows[7]; !reflect.DeepEqual(got, []string{"alternate"}) {
		t.Fatalf("renderer seeded rows = %q, want selected alternate rows", got)
	}
	if got := renderer.seededCaptures[7]; !reflect.DeepEqual(got.PrimaryRows, []string{""}) ||
		!reflect.DeepEqual(got.AlternateRows, []string{"alternate"}) ||
		got.ActiveScreen != remotegrid.ActiveScreenAlternate {
		t.Fatalf("renderer seeded capture = %+v, want primary+alternate rows and alternate active screen", got)
	}
}

func TestTmuxControlWorkspaceSourceUsesAlternateRowsWhenAlternateScreenActive(t *testing.T) {
	renderer := &sourceFakeRenderer{seedFromInitialRows: true}
	source := newTmuxControlWorkspaceSource("workspace-1", renderer)

	if err := source.HandleListSnapshot(
		[]string{"@1\tmain\t0000,12x2,0,0,%7\t0\t1"},
		[]string{"@1\t%7\t1"},
		map[int]remotegrid.PaneInitialCapture{
			7: {
				PrimaryRows:   []string{"stale-shell"},
				AlternateRows: []string{"visible-tui"},
				ActiveScreen:  remotegrid.ActiveScreenAlternate,
			},
		},
	); err != nil {
		t.Fatal(err)
	}

	payload, err := source.CurrentPayload("workspace-1")
	if err != nil {
		t.Fatal(err)
	}
	keyframe := sourceOnlyKeyframe(t, payload.Reliable)
	if got := sourceKeyframeText(keyframe); !strings.Contains(got, "visible-tui") || strings.Contains(got, "stale-shell") {
		t.Fatalf("initial keyframe text = %q, want active alternate rows", got)
	}
	if got := renderer.seededRows[7]; !reflect.DeepEqual(got, []string{"visible-tui"}) {
		t.Fatalf("renderer seeded rows = %q, want active alternate rows", got)
	}
}

func TestTmuxControlWorkspaceSourceKeepsBlankAlternateRowsWhenAlternateScreenActive(t *testing.T) {
	renderer := &sourceFakeRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: sourceKeyframe(7, 1, "  "),
		},
	}
	source := newTmuxControlWorkspaceSource("workspace-1", renderer)

	if err := source.HandleListSnapshot(
		[]string{"@1\tmain\t0000,12x2,0,0,%7\t0\t1"},
		[]string{"@1\t%7\t1"},
		map[int]remotegrid.PaneInitialCapture{
			7: {
				PrimaryRows:   []string{"stale-shell"},
				AlternateRows: nil,
				ActiveScreen:  remotegrid.ActiveScreenAlternate,
			},
		},
	); err != nil {
		t.Fatal(err)
	}

	payload, err := source.CurrentPayload("workspace-1")
	if err != nil {
		t.Fatal(err)
	}
	keyframe := sourceOnlyKeyframe(t, payload.Reliable)
	if got := sourceKeyframeText(keyframe); strings.Contains(got, "stale-shell") {
		t.Fatalf("initial keyframe text = %q, want blank alternate screen without stale primary rows", got)
	}
	if got := renderer.seededRows[7]; len(got) != 0 {
		t.Fatalf("renderer seeded rows = %q, want blank active alternate capture", got)
	}
}

func TestTmuxControlWorkspaceSourceStreamsLiveOutputAfterSnapshot(t *testing.T) {
	renderer := &sourceFakeRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: sourceKeyframe(7, 1, "aa"),
		},
		deltas: map[string]remotegrid.PaneDelta{
			"bb": sourceDelta(7, 1, "bb"),
		},
	}
	source := newTmuxControlWorkspaceSource("workspace-1", renderer)
	if err := source.HandleListSnapshot(
		[]string{"@1\tmain\t0000,2x1,0,0,%7\t0\t1"},
		[]string{"@1\t%7\t1"},
		nil,
	); err != nil {
		t.Fatal(err)
	}

	if err := source.HandleStream(strings.NewReader("%output %7 bb\n")); err != nil {
		t.Fatal(err)
	}

	payload, err := source.CurrentPayload("workspace-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(payload.Datagrams) != 1 {
		t.Fatalf("datagrams = %d, want 1", len(payload.Datagrams))
	}
	if payload.Datagrams[0].PaneID != 7 || payload.Datagrams[0].DeltaSequence != 1 {
		t.Fatalf("delta = pane %d sequence %d, want pane 7 sequence 1", payload.Datagrams[0].PaneID, payload.Datagrams[0].DeltaSequence)
	}
}

func TestTmuxControlWorkspaceSourceBuffersEarlyOutputUntilLayout(t *testing.T) {
	renderer := &sourceFakeRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: sourceKeyframe(7, 1, "aa"),
		},
		deltas: map[string]remotegrid.PaneDelta{
			"bb": sourceDelta(7, 1, "bb"),
		},
	}
	source := newTmuxControlWorkspaceSource("workspace-1", renderer)

	if err := source.HandleStream(strings.NewReader(strings.Join([]string{
		"%output %7 bb",
		"%window-add @1",
		"%layout-change @1 0000,2x1,0,0,%7",
	}, "\n") + "\n")); err != nil {
		t.Fatal(err)
	}

	payload, err := source.CurrentPayload("workspace-1")
	if err != nil {
		t.Fatal(err)
	}
	if got := sourceReliableKinds(t, payload.Reliable); !reflect.DeepEqual(got, []string{"snapshot:workspace-1", "keyframe:7:1"}) {
		t.Fatalf("reliable payload = %v, want snapshot and keyframe", got)
	}
	if len(payload.Datagrams) != 1 {
		t.Fatalf("datagrams = %d, want buffered output delta", len(payload.Datagrams))
	}
}

func TestTmuxControlWorkspaceSourceSerializesConcurrentStreamAndSnapshots(t *testing.T) {
	renderer := &sourceFakeRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: sourceKeyframe(7, 1, "aa"),
		},
		deltas: map[string]remotegrid.PaneDelta{
			"bb": sourceDelta(7, 1, "bb"),
		},
	}
	source := newTmuxControlWorkspaceSource("workspace-1", renderer)
	if err := source.HandleListSnapshot(
		[]string{"@1\tmain\t0000,2x1,0,0,%7\t0\t1"},
		[]string{"@1\t%7\t1"},
		nil,
	); err != nil {
		t.Fatal(err)
	}

	var wg sync.WaitGroup
	errs := make(chan error, 2)
	wg.Add(2)
	go func() {
		defer wg.Done()
		for i := 0; i < 100; i++ {
			if err := source.HandleStream(strings.NewReader("%output %7 bb\n")); err != nil {
				errs <- err
				return
			}
		}
	}()
	go func() {
		defer wg.Done()
		for i := 0; i < 100; i++ {
			if err := source.HandleListSnapshot(
				[]string{"@1\tmain\t0000,2x1,0,0,%7\t0\t1"},
				[]string{"@1\t%7\t1"},
				nil,
			); err != nil {
				errs <- err
				return
			}
		}
	}()
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}

	if _, err := source.CurrentPayload("workspace-1"); err != nil {
		t.Fatal(err)
	}
}
