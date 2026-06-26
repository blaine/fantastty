package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"fantastty/remote-engine-helper/internal/engine"
	"fantastty/remote-engine-helper/remotegrid"
	"fantastty/remote-engine-helper/tmuxcc"
)

func TestEngineWorkspaceSourceRetainsCurrentPayloadAcrossDrains(t *testing.T) {
	renderer := &sourceFakeRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: sourceKeyframe(7, 1, "aa"),
		},
	}
	source := newEngineWorkspaceSource("workspace-1", renderer)

	if err := source.Handle(sourceSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
	})); err != nil {
		t.Fatal(err)
	}

	first, err := source.CurrentPayload("workspace-1")
	if err != nil {
		t.Fatal(err)
	}
	second, err := source.CurrentPayload("workspace-1")
	if err != nil {
		t.Fatal(err)
	}

	want := []string{"snapshot:workspace-1", "keyframe:7:1"}
	if got := sourceReliableKinds(t, first.Reliable); !reflect.DeepEqual(got, want) {
		t.Fatalf("first payload = %v, want %v", got, want)
	}
	if got := sourceReliableKinds(t, second.Reliable); !reflect.DeepEqual(got, want) {
		t.Fatalf("second payload = %v, want %v", got, want)
	}
}

func TestEngineWorkspaceSourcePublishesLiveDatagramsToSubscribers(t *testing.T) {
	renderer := &sourceFakeRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: sourceKeyframe(7, 1, "aa"),
		},
		deltas: map[string]remotegrid.PaneDelta{
			"bb": sourceDelta(7, 1, "bb"),
		},
	}
	source := newEngineWorkspaceSource("workspace-1", renderer)
	var reliable bytes.Buffer
	datagrams := &sourceDatagramWriter{}
	pump := engine.NewStreamPump(&reliable, datagrams)
	defer func() {
		if err := pump.Close(); err != nil {
			t.Fatalf("pump close: %v", err)
		}
	}()
	unsubscribe := source.Subscribe(pump)
	defer unsubscribe()

	if err := source.Handle(sourceSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
	})); err != nil {
		t.Fatal(err)
	}
	if err := source.Handle(sourceOutputAction(t, 7, "bb")); err != nil {
		t.Fatal(err)
	}
	if err := pump.Flush(); err != nil {
		t.Fatal(err)
	}

	if len(datagrams.payloads) != 1 {
		t.Fatalf("datagrams = %d, want 1", len(datagrams.payloads))
	}
	delta := sourceDecodeDelta(t, datagrams.payloads[0])
	if delta.PaneID != 7 || delta.DeltaSequence != 1 {
		t.Fatalf("delta = pane %d sequence %d, want pane 7 sequence 1", delta.PaneID, delta.DeltaSequence)
	}
}

func TestEngineWorkspaceSourceRequestKeyframePublishesFreshCurrentKeyframe(t *testing.T) {
	renderer := &sourceFakeRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: sourceKeyframe(7, 1, "aa"),
		},
		deltas: map[string]remotegrid.PaneDelta{
			"bb": sourceDelta(7, 1, "bb"),
		},
		failCurrentKeyframe: true,
	}
	source := newEngineWorkspaceSource("workspace-1", renderer)
	if err := source.Handle(sourceSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
	})); err != nil {
		t.Fatal(err)
	}

	if err := source.Handle(sourceOutputAction(t, 7, "bb")); err != nil {
		t.Fatal(err)
	}
	payload, err := source.RequestKeyframe("workspace-1", 7)
	if err != nil {
		t.Fatal(err)
	}

	if got := sourceReliableKinds(t, payload.Reliable); !reflect.DeepEqual(got, []string{"keyframe:7:2"}) {
		t.Fatalf("keyframe payload = %v, want fresh keyframe", got)
	}
	retained, err := source.CurrentPayload("workspace-1")
	if err != nil {
		t.Fatal(err)
	}
	if got := sourceReliableKinds(t, retained.Reliable); !reflect.DeepEqual(got, []string{"snapshot:workspace-1", "keyframe:7:2"}) {
		t.Fatalf("retained payload = %v, want snapshot plus fresh keyframe", got)
	}
	if got := sourceKeyframeText(sourceOnlyKeyframe(t, payload.Reliable)); got != "bb\n" {
		t.Fatalf("request keyframe text = %q, want bb", got)
	}
}

func TestEngineWorkspaceSourceRequestKeyframesReturnsReliableBarrierWithoutRetainedDatagrams(t *testing.T) {
	renderer := &sourceFakeRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: sourceKeyframe(7, 1, "aa"),
		},
		deltas: map[string]remotegrid.PaneDelta{
			"bb": sourceDelta(7, 1, "bb"),
		},
		failCurrentKeyframe: true,
	}
	source := newEngineWorkspaceSource("workspace-1", renderer)
	if err := source.Handle(sourceSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
	})); err != nil {
		t.Fatal(err)
	}
	if err := source.Handle(sourceOutputAction(t, 7, "bb")); err != nil {
		t.Fatal(err)
	}

	payload, err := source.RequestKeyframes("workspace-1")
	if err != nil {
		t.Fatal(err)
	}

	if got := sourceReliableKinds(t, payload.Reliable); !reflect.DeepEqual(got, []string{"snapshot:workspace-1", "keyframe:7:2"}) {
		t.Fatalf("keyframe barrier payload = %v, want snapshot plus fresh keyframe", got)
	}
	if len(payload.Datagrams) != 0 {
		t.Fatalf("barrier datagrams = %d, want none", len(payload.Datagrams))
	}
	retained, err := source.CurrentPayload("workspace-1")
	if err != nil {
		t.Fatal(err)
	}
	if got := sourceReliableKinds(t, retained.Reliable); !reflect.DeepEqual(got, []string{"snapshot:workspace-1", "keyframe:7:2"}) {
		t.Fatalf("retained payload = %v, want snapshot plus fresh keyframe", got)
	}
	if len(retained.Datagrams) != 0 {
		t.Fatalf("retained datagrams = %d, want stale datagram purged", len(retained.Datagrams))
	}
	if got := sourceKeyframeText(sourceOnlyKeyframe(t, payload.Reliable)); got != "bb\n" {
		t.Fatalf("request keyframe text = %q, want bb", got)
	}
}

func TestEngineWorkspaceSourceRequestKeyframesReleasesWorkspaceLockBeforeRetain(t *testing.T) {
	renderer := &sourceFakeRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: sourceKeyframe(7, 1, "aa"),
		},
		deltas: map[string]remotegrid.PaneDelta{
			"bb": sourceDelta(7, 1, "bb"),
		},
		failCurrentKeyframe: true,
	}
	source := newEngineWorkspaceSource("workspace-1", renderer)
	if err := source.Handle(sourceSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
	})); err != nil {
		t.Fatal(err)
	}

	source.mu.Lock()
	requestDone := make(chan error, 1)
	go func() {
		_, err := source.RequestKeyframes("workspace-1")
		requestDone <- err
	}()

	waitForPendingSourceKeyframe(t, source, 7, 1, 2)
	waitForWorkspaceLockReleased(t, source, "RequestKeyframes retaining fresh barrier")
	handleDone := make(chan error, 1)
	go func() {
		handleDone <- source.Handle(sourceOutputAction(t, 7, "bb"))
	}()
	waitForWorkspaceLockReleased(t, source, "Handle retaining post-draft output")
	source.mu.Unlock()
	if err := <-requestDone; err != nil {
		t.Fatal(err)
	}
	if err := <-handleDone; err != nil {
		t.Fatal(err)
	}
	payload, err := source.CurrentPayload("workspace-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(payload.Datagrams) != 1 {
		t.Fatalf("retained datagrams = %d, want output after fresh barrier retained", len(payload.Datagrams))
	}
	if payload.Datagrams[0].BaseKeyframeID != 2 {
		t.Fatalf("retained datagram base keyframe = %d, want fresh barrier base 2", payload.Datagrams[0].BaseKeyframeID)
	}
}

func TestEngineWorkspaceSourceHandleKeepsSeedPayloadOrderedBeforeLaterOutput(t *testing.T) {
	renderer := &sourceFakeRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: sourceKeyframe(7, 1, "aa"),
		},
		deltas: map[string]remotegrid.PaneDelta{
			"bb": sourceDelta(7, 1, "bb"),
		},
	}
	source := newEngineWorkspaceSource("workspace-1", renderer)

	source.publishMu.Lock()
	snapshotDone := make(chan error, 1)
	go func() {
		snapshotDone <- source.Handle(sourceSnapshotAction(t, []remotegrid.WorkspacePane{
			{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
		}))
	}()
	waitForPublishSequenceReserved(t, source, 1, "seed payload waiting to publish")

	outputDone := make(chan error, 1)
	go func() {
		outputDone <- source.Handle(sourceOutputAction(t, 7, "bb"))
	}()
	waitForPublishSequenceReserved(t, source, 2, "later output waiting behind seed publish")

	source.publishMu.Unlock()
	if err := <-snapshotDone; err != nil {
		t.Fatal(err)
	}
	if err := <-outputDone; err != nil {
		t.Fatal(err)
	}

	payload, err := source.CurrentPayload("workspace-1")
	if err != nil {
		t.Fatal(err)
	}
	if got := sourceReliableKinds(t, payload.Reliable); !reflect.DeepEqual(got, []string{"snapshot:workspace-1", "keyframe:7:1"}) {
		t.Fatalf("retained reliable payload = %v, want seed barrier", got)
	}
	if len(payload.Datagrams) != 1 {
		t.Fatalf("retained datagrams = %d, want later output after seed barrier", len(payload.Datagrams))
	}
}

func TestEngineWorkspaceSourceHandleReleasesWorkspaceLockBeforePublishing(t *testing.T) {
	renderer := &sourceFakeRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: sourceKeyframe(7, 1, "aa"),
		},
		deltas: map[string]remotegrid.PaneDelta{
			"bb": sourceDelta(7, 1, "bb"),
		},
	}
	source := newEngineWorkspaceSource("workspace-1", renderer)

	source.publishMu.Lock()
	snapshotDone := make(chan error, 1)
	go func() {
		snapshotDone <- source.Handle(sourceSnapshotAction(t, []remotegrid.WorkspacePane{
			{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
		}))
	}()
	waitForPublishSequenceReserved(t, source, 1, "snapshot drained while waiting to publish")

	outputDone := make(chan error, 1)
	go func() {
		outputDone <- source.Handle(sourceOutputAction(t, 7, "bb"))
	}()
	waitForPublishSequenceReserved(t, source, 2, "output drained while earlier publish is blocked")

	source.publishMu.Unlock()
	if err := <-snapshotDone; err != nil {
		t.Fatal(err)
	}
	if err := <-outputDone; err != nil {
		t.Fatal(err)
	}
}

func TestEngineWorkspaceSourceRetainRejectsStaleDatagramAfterFreshKeyframe(t *testing.T) {
	renderer := &sourceFakeRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: sourceKeyframe(7, 1, "aa"),
		},
		deltas: map[string]remotegrid.PaneDelta{
			"bb": sourceDelta(7, 1, "bb"),
		},
		failCurrentKeyframe: true,
	}
	source := newEngineWorkspaceSource("workspace-1", renderer)
	if err := source.Handle(sourceSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
	})); err != nil {
		t.Fatal(err)
	}
	if err := source.Handle(sourceOutputAction(t, 7, "bb")); err != nil {
		t.Fatal(err)
	}
	stale := remoteWorkspacePayload{Datagrams: []remotegrid.PaneDelta{sourceDelta(7, 1, "bb")}}
	if _, err := source.RequestKeyframes("workspace-1"); err != nil {
		t.Fatal(err)
	}

	source.mu.Lock()
	source.retainPayloadLocked(stale)
	source.mu.Unlock()

	retained, err := source.CurrentPayload("workspace-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(retained.Datagrams) != 0 {
		t.Fatalf("retained datagrams = %d, want stale datagram rejected after fresh keyframe", len(retained.Datagrams))
	}
}

func TestEngineWorkspaceSourceRequestKeyframeDoesNotPublishStaleDraft(t *testing.T) {
	renderer := &sourceFakeRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: sourceKeyframe(7, 1, "aa"),
		},
		deltas: map[string]remotegrid.PaneDelta{
			"bb": sourceDelta(7, 1, "bb"),
		},
		failCurrentKeyframe: true,
	}
	source := newEngineWorkspaceSource("workspace-1", renderer)
	if err := source.Handle(sourceSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
	})); err != nil {
		t.Fatal(err)
	}
	if err := source.Handle(sourceOutputAction(t, 7, "bb")); err != nil {
		t.Fatal(err)
	}
	source.mu.Lock()
	source.retainPayloadLocked(remoteWorkspacePayload{Reliable: []remotegrid.WorkspaceMessage{
		remotegrid.PaneKeyframeMessage(sourceKeyframe(7, 3, "cc")),
	}})
	source.mu.Unlock()

	var subscriberReliable bytes.Buffer
	pump := engine.NewStreamPump(&subscriberReliable, &sourceDatagramWriter{})
	t.Cleanup(func() {
		if err := pump.Close(); err != nil {
			t.Fatalf("pump close: %v", err)
		}
	})
	unsubscribe := source.Subscribe(pump)
	t.Cleanup(unsubscribe)

	payload, err := source.RequestKeyframe("workspace-1", 7)
	if err != nil {
		t.Fatal(err)
	}
	if got := sourceReliableKinds(t, payload.Reliable); !reflect.DeepEqual(got, []string{"snapshot:workspace-1", "keyframe:7:3"}) {
		t.Fatalf("request payload = %v, want retained newer keyframe", got)
	}
	if err := pump.Flush(); err != nil {
		t.Fatal(err)
	}
	subscriberMessages := sourceDecodeReliableLines(t, subscriberReliable.Bytes())
	if got := sourceReliableKinds(t, subscriberMessages); !reflect.DeepEqual(got, []string{"snapshot:workspace-1", "keyframe:7:3"}) {
		t.Fatalf("subscriber payload = %v, want retained newer keyframe", got)
	}
}

func TestEngineWorkspaceSourceDoesNotRetainDatagramBeforeDraftKeyframe(t *testing.T) {
	renderer := &sourceFakeRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: sourceKeyframe(7, 1, "aa"),
		},
		deltas: map[string]remotegrid.PaneDelta{
			"bb": sourceDelta(7, 1, "bb"),
		},
	}
	source := newEngineWorkspaceSource("workspace-1", renderer)
	if err := source.Handle(sourceSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
	})); err != nil {
		t.Fatal(err)
	}

	source.workspaceMu.Lock()
	draft, ok, err := source.workspace.RequestKeyframeDraft(7)
	source.workspaceMu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("RequestKeyframeDraft ok = false, want true")
	}
	if draft.KeyframeID != 2 {
		t.Fatalf("draft keyframe id = %d, want 2", draft.KeyframeID)
	}

	if err := source.Handle(sourceOutputAction(t, 7, "bb")); err != nil {
		t.Fatal(err)
	}
	payload, err := source.CurrentPayload("workspace-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(payload.Datagrams) != 0 {
		t.Fatalf("retained datagrams = %+v, want no datagram before draft keyframe is retained", payload.Datagrams)
	}
}

func TestEngineWorkspaceSourceSnapshotRemovalPurgesRetainedPaneDatagrams(t *testing.T) {
	renderer := &sourceFakeRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: sourceKeyframe(7, 1, "aa"),
		},
		deltas: map[string]remotegrid.PaneDelta{
			"bb": sourceDelta(7, 1, "bb"),
		},
	}
	source := newEngineWorkspaceSource("workspace-1", renderer)
	if err := source.Handle(sourceSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
	})); err != nil {
		t.Fatal(err)
	}
	if err := source.Handle(sourceOutputAction(t, 7, "bb")); err != nil {
		t.Fatal(err)
	}

	beforeRemoval, err := source.CurrentPayload("workspace-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(beforeRemoval.Datagrams) != 1 {
		t.Fatalf("retained datagrams before removal = %d, want 1", len(beforeRemoval.Datagrams))
	}
	if err := source.Handle(sourceSnapshotAction(t, nil)); err != nil {
		t.Fatal(err)
	}

	afterRemoval, err := source.CurrentPayload("workspace-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(afterRemoval.Datagrams) != 0 {
		t.Fatalf("retained datagrams after removal = %d, want removed pane datagram purged", len(afterRemoval.Datagrams))
	}
}

func TestEngineWorkspaceSourceSubscribeKeyframesPublishesFreshBarrierToExistingSubscribers(t *testing.T) {
	renderer := &sourceFakeRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: sourceKeyframe(7, 1, "aa"),
		},
		deltas: map[string]remotegrid.PaneDelta{
			"bb": sourceDelta(7, 1, "bb"),
		},
		failCurrentKeyframe: true,
	}
	source := newEngineWorkspaceSource("workspace-1", renderer)
	if err := source.Handle(sourceSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
	})); err != nil {
		t.Fatal(err)
	}

	var existingReliable bytes.Buffer
	existingPump := engine.NewStreamPump(&existingReliable, &sourceDatagramWriter{})
	defer func() {
		if err := existingPump.Close(); err != nil {
			t.Fatalf("existing pump close: %v", err)
		}
	}()
	unsubscribeExisting := source.Subscribe(existingPump)
	defer unsubscribeExisting()

	if err := source.Handle(sourceOutputAction(t, 7, "bb")); err != nil {
		t.Fatal(err)
	}
	var attachingReliable bytes.Buffer
	attachingPump := engine.NewStreamPumpWithPausedDatagrams(&attachingReliable, &sourceDatagramWriter{})
	defer func() {
		if err := attachingPump.Close(); err != nil {
			t.Fatalf("attaching pump close: %v", err)
		}
	}()
	payload, unsubscribeAttach, err := source.SubscribeKeyframes("workspace-1", attachingPump)
	if err != nil {
		t.Fatal(err)
	}
	defer unsubscribeAttach()

	if got := sourceReliableKinds(t, payload.Reliable); !reflect.DeepEqual(got, []string{"snapshot:workspace-1", "keyframe:7:2"}) {
		t.Fatalf("attaching payload = %v, want snapshot plus fresh keyframe", got)
	}
	if err := attachingPump.Flush(); err != nil {
		t.Fatal(err)
	}
	attachingMessages := sourceDecodeReliableLines(t, attachingReliable.Bytes())
	if got := sourceReliableKinds(t, attachingMessages); !reflect.DeepEqual(got, []string{"snapshot:workspace-1", "keyframe:7:2"}) {
		t.Fatalf("attaching pump queued payload = %v, want fresh barrier queued before live subscription", got)
	}
	if err := existingPump.Flush(); err != nil {
		t.Fatal(err)
	}
	existingMessages := sourceDecodeReliableLines(t, existingReliable.Bytes())
	if got := sourceReliableKinds(t, existingMessages); !reflect.DeepEqual(got, []string{"keyframe:7:2"}) {
		t.Fatalf("existing subscriber payload = %v, want fresh keyframe barrier", got)
	}
}

func TestEngineWorkspaceSourceSubscribeKeyframesIncludesRetainedPostBarrierDatagrams(t *testing.T) {
	renderer := &sourceFakeRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: sourceKeyframe(7, 1, "aa"),
		},
	}
	source := newEngineWorkspaceSource("workspace-1", renderer)
	if err := source.Handle(sourceSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
	})); err != nil {
		t.Fatal(err)
	}
	postBarrier := sourceDelta(7, 1, "bb")
	postBarrier.BaseKeyframeID = 2
	source.datagrams.Publish(postBarrier)

	reliable := newSourceRecordingReliableWriter()
	datagrams := &sourceDatagramWriter{}
	pump := engine.NewStreamPumpWithPausedDatagrams(reliable, datagrams)
	defer func() {
		if err := pump.Close(); err != nil {
			t.Fatalf("pump close: %v", err)
		}
	}()
	payload, unsubscribe, err := source.SubscribeKeyframes("workspace-1", pump)
	if err != nil {
		t.Fatal(err)
	}
	defer unsubscribe()

	if got := sourceReliableKinds(t, payload.Reliable); !reflect.DeepEqual(got, []string{"snapshot:workspace-1", "keyframe:7:2"}) {
		t.Fatalf("attaching payload = %v, want snapshot plus fresh keyframe", got)
	}
	if len(payload.Datagrams) != 1 {
		t.Fatalf("attaching payload datagrams = %d, want retained post-barrier delta", len(payload.Datagrams))
	}
	if err := pump.Flush(); err != nil {
		t.Fatal(err)
	}
	reliable.waitForKind(t, "paneKeyframe")
	pump.ResumeDatagrams()
	if err := pump.Flush(); err != nil {
		t.Fatal(err)
	}
	if len(datagrams.payloads) != 1 {
		t.Fatalf("attaching pump datagrams = %d, want retained post-barrier delta", len(datagrams.payloads))
	}
}

func TestEngineWorkspaceSourceKeyframeRequestsDoNotCallCurrentKeyframeOrBlockHandle(t *testing.T) {
	tests := []struct {
		name string
		run  func(t *testing.T, source *engineWorkspaceSource) error
	}{
		{
			name: "RequestKeyframe",
			run: func(t *testing.T, source *engineWorkspaceSource) error {
				t.Helper()
				_, err := source.RequestKeyframe("workspace-1", 7)
				return err
			},
		},
		{
			name: "RequestKeyframes",
			run: func(t *testing.T, source *engineWorkspaceSource) error {
				t.Helper()
				_, err := source.RequestKeyframes("workspace-1")
				return err
			},
		},
		{
			name: "SubscribeKeyframes",
			run: func(t *testing.T, source *engineWorkspaceSource) error {
				t.Helper()
				var reliable bytes.Buffer
				pump := engine.NewStreamPumpWithPausedDatagrams(&reliable, &sourceDatagramWriter{})
				t.Cleanup(func() {
					if err := pump.Close(); err != nil {
						t.Fatalf("pump close: %v", err)
					}
				})
				_, unsubscribe, err := source.SubscribeKeyframes("workspace-1", pump)
				if unsubscribe != nil {
					t.Cleanup(unsubscribe)
				}
				return err
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			renderer := newSourceBlockingCurrentKeyframeRenderer()
			t.Cleanup(renderer.releaseCurrentKeyframe)
			source := newEngineWorkspaceSource("workspace-1", renderer)
			if err := source.Handle(sourceSnapshotAction(t, []remotegrid.WorkspacePane{
				{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
			})); err != nil {
				t.Fatal(err)
			}
			if err := source.Handle(sourceOutputAction(t, 7, "bb")); err != nil {
				t.Fatal(err)
			}

			done := make(chan error, 1)
			go func() {
				done <- tt.run(t, source)
			}()

			select {
			case err := <-done:
				if err != nil {
					t.Fatalf("%s returned error: %v", tt.name, err)
				}
			case <-renderer.currentKeyframeEntered:
				t.Fatalf("%s called renderer.CurrentKeyframe; request keyframes must use workspace-retained state", tt.name)
			case <-time.After(200 * time.Millisecond):
				t.Fatalf("%s did not return without renderer.CurrentKeyframe", tt.name)
			}

			assertSourceReturns(t, tt.name+" source.Handle after request", func() error {
				return source.Handle(sourceOutputAction(t, 7, "cc"))
			})
		})
	}
}

func TestEngineWorkspaceSourceSubscribeKeyframesRemovesPumpOnClose(t *testing.T) {
	renderer := &sourceFakeRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: sourceKeyframe(7, 1, "aa"),
		},
	}
	source := newEngineWorkspaceSource("workspace-1", renderer)
	if err := source.Handle(sourceSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
	})); err != nil {
		t.Fatal(err)
	}

	pump := engine.NewStreamPumpWithPausedDatagrams(newSourceRecordingReliableWriter(), &sourceDatagramWriter{})
	_, unsubscribe, err := source.SubscribeKeyframes("workspace-1", pump)
	if err != nil {
		t.Fatal(err)
	}
	if !sourceHasSubscriber(source, pump) {
		t.Fatal("pump was not subscribed by SubscribeKeyframes")
	}

	if err := pump.Close(); err != nil {
		t.Fatalf("pump close: %v", err)
	}
	if sourceHasSubscriber(source, pump) {
		t.Fatal("pump remained subscribed after close")
	}
	unsubscribe()
	if sourceHasSubscriber(source, pump) {
		t.Fatal("pump remained subscribed after idempotent unsubscribe")
	}
}

func TestEngineWorkspaceSourceStalledStreamPumpsDoNotBlockDrainOrReplayStaleState(t *testing.T) {
	const outputCount = 1100
	const oversizedCount = 12
	const tmuxControlMaximumAgeMillis = 5 * 60 * 1000

	renderer := &sourceFakeRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: sourceKeyframe(7, 1, "aa"),
		},
		deltas: make(map[string]remotegrid.PaneDelta, outputCount+oversizedCount),
	}
	for sequence := 1; sequence <= outputCount; sequence++ {
		text := "delta-" + strconv.Itoa(sequence)
		renderer.deltas[text] = sourceDelta(7, uint64(sequence), text)
	}
	for sequence := 1; sequence <= oversizedCount; sequence++ {
		text := "oversized-" + strconv.Itoa(sequence)
		renderer.deltas[text] = sourceOversizedDelta(7, uint64(outputCount+sequence))
	}

	source := newEngineWorkspaceSource("workspace-1", renderer)
	stalledReliable := newSourceBlockingReliableWriter()
	stalledDatagrams := newSourceBlockingDatagramWriter()
	stalledPump := engine.NewStreamPump(stalledReliable, stalledDatagrams)
	unsubscribeStalled := source.Subscribe(stalledPump)
	defer func() {
		stalledReliable.release()
		stalledDatagrams.release()
		unsubscribeStalled()
		if err := stalledPump.Close(); err != nil {
			t.Fatalf("stalled pump close: %v", err)
		}
	}()
	reconnectReliable := newSourceRecordingReliableWriter()
	reconnectDatagrams := &sourceDatagramWriter{}
	reconnectPump := engine.NewStreamPumpWithPausedDatagrams(reconnectReliable, reconnectDatagrams)
	unsubscribeReconnect := source.Subscribe(reconnectPump)
	defer func() {
		unsubscribeReconnect()
		if err := reconnectPump.Close(); err != nil {
			t.Fatalf("reconnect pump close: %v", err)
		}
	}()

	initialSnapshot := sourceSnapshotAction(t, []remotegrid.WorkspacePane{
		{PaneID: 7, WindowID: 1, Frame: remotegrid.PaneFrame{Columns: 2, Rows: 1}},
	})
	assertSourceReturns(t, "initial snapshot", func() error {
		return source.Handle(initialSnapshot)
	})
	stalledReliable.waitUntilBlocked(t)

	firstOutput := sourceOutputAction(t, 7, "delta-1")
	assertSourceReturns(t, "first output with stalled reliable writer", func() error {
		return source.Handle(firstOutput)
	})

	for sequence := 2; sequence <= outputCount; sequence++ {
		text := "delta-" + strconv.Itoa(sequence)
		action := sourceOutputAction(t, 7, text)
		assertSourceReturns(t, "tmux output "+text, func() error {
			return source.Handle(action)
		})
	}

	agedOutput := sourceExtendedOutputAction(t, 7, tmuxControlMaximumAgeMillis+1000, "delta-"+strconv.Itoa(outputCount))
	assertSourceReturns(t, "tmux output older than CONTROL_MAXIMUM_AGE with stalled writers", func() error {
		return source.Handle(agedOutput)
	})

	retained, err := source.CurrentPayload("workspace-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(retained.Datagrams) != 1 {
		t.Fatalf("retained datagrams = %d, want one latest pane delta", len(retained.Datagrams))
	}
	if got := retained.Datagrams[0].DeltaSequence; got != outputCount {
		t.Fatalf("retained datagram sequence = %d, want %d", got, outputCount)
	}
	if len(reconnectDatagrams.payloads) != 0 {
		t.Fatalf("reconnect datagrams before barrier = %d, want paused pump to emit none", len(reconnectDatagrams.payloads))
	}

	stalledReliable.release()
	stalledDatagrams.waitUntilBlocked(t)

	for sequence := 1; sequence <= oversizedCount; sequence++ {
		text := "oversized-" + strconv.Itoa(sequence)
		action := sourceOutputAction(t, 7, text)
		assertSourceReturns(t, "oversized output "+text+" with stalled writers", func() error {
			return source.Handle(action)
		})
	}
	if err := reconnectPump.Flush(); err != nil {
		t.Fatal(err)
	}
	reconnectReliable.waitForKind(t, "paneDelta")

	var reconnectPayload remoteWorkspacePayload
	assertSourceReturns(t, "reconnect keyframe barrier with stalled writers", func() error {
		var err error
		reconnectPayload, err = source.RequestKeyframes("workspace-1")
		return err
	})
	if got := sourceReliableKinds(t, reconnectPayload.Reliable); !reflect.DeepEqual(got, []string{"snapshot:workspace-1", "keyframe:7:2"}) {
		t.Fatalf("reconnect payload = %v, want fresh barrier", got)
	}
	if len(reconnectPayload.Datagrams) != 0 {
		t.Fatalf("reconnect payload datagrams = %d, want none", len(reconnectPayload.Datagrams))
	}

	afterBarrier, err := source.CurrentPayload("workspace-1")
	if err != nil {
		t.Fatal(err)
	}
	if got := sourceReliableKinds(t, afterBarrier.Reliable); !reflect.DeepEqual(got, []string{"snapshot:workspace-1", "keyframe:7:2"}) {
		t.Fatalf("current payload = %v, want latest snapshot plus fresh keyframe", got)
	}
	if len(afterBarrier.Datagrams) != 0 {
		t.Fatalf("current payload datagrams = %d, want stale retained datagrams purged", len(afterBarrier.Datagrams))
	}
	reconnectPump.ResumeDatagrams()
	if err := reconnectPump.Flush(); err != nil {
		t.Fatal(err)
	}
	if len(reconnectDatagrams.payloads) != 0 {
		t.Fatalf("reconnect datagrams after barrier = %d, want stale datagrams not replayed", len(reconnectDatagrams.payloads))
	}

	assertSourceReturns(t, "close stalled pump", func() error {
		return stalledPump.Close()
	})

	source.mu.Lock()
	_, stalledStillSubscribed := source.subscribers[stalledPump]
	source.mu.Unlock()
	if stalledStillSubscribed {
		t.Fatal("stalled pump remained subscribed after close")
	}
}

type sourceFakeRenderer struct {
	keyframes                  map[int]remotegrid.PaneKeyframe
	deltas                     map[string]remotegrid.PaneDelta
	seedFromInitialRows        bool
	failSeedForInitialRow      string
	seededRows                 map[int][]string
	seededCaptures             map[int]remotegrid.PaneInitialCapture
	failCurrentKeyframe        bool
	blockCurrentKeyframe       bool
	currentKeyframeEntered     chan struct{}
	currentKeyframeRelease     chan struct{}
	currentKeyframeOnce        sync.Once
	currentKeyframeReleaseOnce sync.Once
	appliedMu                  sync.Mutex
	appliedOutputs             []string
}

func (r *sourceFakeRenderer) SeedPane(pane remotegrid.WorkspacePane) (remotegrid.PaneKeyframe, bool, error) {
	if r.seededRows == nil {
		r.seededRows = make(map[int][]string)
	}
	if r.seededCaptures == nil {
		r.seededCaptures = make(map[int]remotegrid.PaneInitialCapture)
	}
	r.seededRows[pane.PaneID] = append([]string(nil), pane.InitialRows...)
	r.seededCaptures[pane.PaneID] = pane.InitialCapture
	if r.failSeedForInitialRow != "" && len(pane.InitialRows) > 0 && pane.InitialRows[0] == r.failSeedForInitialRow {
		return remotegrid.PaneKeyframe{}, false, errors.New("seed failed")
	}
	if r.seedFromInitialRows && len(pane.InitialRows) > 0 {
		return sourceKeyframeFromRows(pane, 1), true, nil
	}
	keyframe, ok := r.keyframes[pane.PaneID]
	return keyframe, ok, nil
}

func (r *sourceFakeRenderer) ApplyOutput(_ int, data []byte) (engine.RenderUpdate, error) {
	r.appliedMu.Lock()
	r.appliedOutputs = append(r.appliedOutputs, string(data))
	r.appliedMu.Unlock()
	delta, ok := r.deltas[string(data)]
	if !ok {
		return engine.RenderUpdate{}, nil
	}
	return engine.RenderUpdate{Delta: &delta}, nil
}

func (r *sourceFakeRenderer) appliedOutputTexts() []string {
	r.appliedMu.Lock()
	defer r.appliedMu.Unlock()
	return append([]string(nil), r.appliedOutputs...)
}

func (r *sourceFakeRenderer) CurrentKeyframe(paneID int) (remotegrid.PaneKeyframe, bool, error) {
	if r.failCurrentKeyframe {
		return remotegrid.PaneKeyframe{}, false, errors.New("CurrentKeyframe must not be called")
	}
	if r.blockCurrentKeyframe {
		r.currentKeyframeOnce.Do(func() {
			close(r.currentKeyframeEntered)
		})
		<-r.currentKeyframeRelease
	}
	keyframe, ok := r.keyframes[paneID]
	return keyframe, ok, nil
}

func (r *sourceFakeRenderer) RemovePane(int) {}

type sourceDatagramWriter struct {
	payloads [][]byte
}

func (w *sourceDatagramWriter) WriteDatagram(payload []byte) error {
	w.payloads = append(w.payloads, append([]byte(nil), payload...))
	return nil
}

func sourceSnapshotAction(t *testing.T, panes []remotegrid.WorkspacePane) tmuxcc.Action {
	t.Helper()

	model := tmuxcc.NewModel("workspace-1")
	if len(panes) == 0 {
		return tmuxcc.WorkspaceSnapshotAction(remotegrid.WorkspaceSnapshot{
			WorkspaceID:      "workspace-1",
			LayoutGeneration: 2,
		})
	}
	windowLines := []string{"@1\tmain\t" + sourceLayout(panes) + "\t0\t1"}
	paneLines := make([]string, 0, len(panes))
	for index, pane := range panes {
		active := "0"
		if index == 0 {
			active = "1"
		}
		paneLines = append(paneLines, "@1\t%"+strconv.Itoa(pane.PaneID)+"\t"+active)
	}
	actions, err := model.ApplyListSnapshot(windowLines, paneLines)
	if err != nil {
		t.Fatal(err)
	}
	if len(actions) != 1 {
		t.Fatalf("snapshot produced %d actions, want 1", len(actions))
	}
	return actions[0]
}

func sourceOutputAction(t *testing.T, paneID int, text string) tmuxcc.Action {
	t.Helper()

	model := tmuxcc.NewModel("workspace-1")
	actions, err := model.ApplyLine("%output %" + strconv.Itoa(paneID) + " " + text)
	if err != nil {
		t.Fatal(err)
	}
	if len(actions) != 1 {
		t.Fatalf("output produced %d actions, want 1", len(actions))
	}
	return actions[0]
}

func sourceExtendedOutputAction(t *testing.T, paneID int, bufferedAgeMillis int, text string) tmuxcc.Action {
	t.Helper()

	model := tmuxcc.NewModel("workspace-1")
	actions, err := model.ApplyLine("%extended-output %" + strconv.Itoa(paneID) + " " + strconv.Itoa(bufferedAgeMillis) + " : " + text)
	if err != nil {
		t.Fatal(err)
	}
	if len(actions) != 1 {
		t.Fatalf("extended output produced %d actions, want 1", len(actions))
	}
	return actions[0]
}

func sourceLayout(panes []remotegrid.WorkspacePane) string {
	if len(panes) == 1 {
		frame := panes[0].Frame
		return "0000," + strconv.Itoa(frame.Columns) + "x" + strconv.Itoa(frame.Rows) + ",0,0,%" + strconv.Itoa(panes[0].PaneID)
	}
	return "0000,2x1,0,0,%7"
}

func sourceKeyframe(paneID int, keyframeID uint64, text string) remotegrid.PaneKeyframe {
	return remotegrid.PaneKeyframe{
		WorkspaceID:                   "workspace-1",
		PaneID:                        paneID,
		PaneGeneration:                1,
		KeyframeID:                    keyframeID,
		GridSize:                      remotegrid.GridSize{Columns: len(text), Rows: 1},
		Rows:                          []remotegrid.GridRow{{Index: 0, RowVersion: keyframeID, Cells: sourceCells(text)}},
		Cursor:                        remotegrid.CursorState{Row: 0, Column: 0, Visible: true, Shape: remotegrid.CursorShapeBlock, CursorVersion: 1},
		ActiveScreen:                  remotegrid.ActiveScreenPrimary,
		DatagramsEnabledAfterKeyframe: true,
	}
}

func sourceKeyframeFromRows(pane remotegrid.WorkspacePane, keyframeID uint64) remotegrid.PaneKeyframe {
	rows := make([]remotegrid.GridRow, pane.Frame.Rows)
	for rowIndex := range rows {
		text := ""
		if rowIndex < len(pane.InitialRows) {
			text = pane.InitialRows[rowIndex]
		}
		rows[rowIndex] = remotegrid.GridRow{Index: rowIndex, RowVersion: keyframeID, Cells: sourceFixedWidthCells(text, pane.Frame.Columns)}
	}
	cursor := remotegrid.CursorState{Row: 0, Column: 0, Visible: true, Shape: remotegrid.CursorShapeBlock, CursorVersion: 1}
	if pane.InitialCapture.Cursor != nil {
		cursor = *pane.InitialCapture.Cursor
		cursor.CursorVersion = 1
	}
	return remotegrid.PaneKeyframe{
		WorkspaceID:                   "workspace-1",
		PaneID:                        pane.PaneID,
		PaneGeneration:                1,
		KeyframeID:                    keyframeID,
		GridSize:                      remotegrid.GridSize{Columns: pane.Frame.Columns, Rows: pane.Frame.Rows},
		Rows:                          rows,
		Cursor:                        cursor,
		ActiveScreen:                  remotegrid.ActiveScreenPrimary,
		DatagramsEnabledAfterKeyframe: true,
	}
}

func sourceDelta(paneID int, sequence uint64, text string) remotegrid.PaneDelta {
	return remotegrid.PaneDelta{
		WorkspaceID:    "workspace-1",
		PaneID:         paneID,
		PaneGeneration: 1,
		BaseKeyframeID: 1,
		DeltaSequence:  sequence,
		RowUpdates: []remotegrid.RowUpdate{{
			RowIndex:   0,
			RowVersion: sequence + 1,
			Update:     remotegrid.FullRow(sourceFixedWidthCells(text, 2)),
		}},
	}
}

func sourceOversizedDelta(paneID int, sequence uint64) remotegrid.PaneDelta {
	delta := sourceDelta(paneID, sequence, "xx")
	delta.RowUpdates[0].Update = remotegrid.FullRow([]remotegrid.GridCell{
		{Text: strings.Repeat("x", engine.MaxDatagramPayloadBytes), Width: 1, Style: remotegrid.NormalCellStyle},
		{Text: " ", Width: 1, Style: remotegrid.NormalCellStyle},
	})
	return delta
}

func newSourceBlockingCurrentKeyframeRenderer() *sourceFakeRenderer {
	renderer := &sourceFakeRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: sourceKeyframe(7, 1, "aa"),
		},
		deltas: map[string]remotegrid.PaneDelta{
			"bb": sourceDelta(7, 1, "bb"),
			"cc": sourceDelta(7, 2, "cc"),
		},
		blockCurrentKeyframe:   true,
		currentKeyframeEntered: make(chan struct{}),
		currentKeyframeRelease: make(chan struct{}),
	}
	return renderer
}

func (r *sourceFakeRenderer) releaseCurrentKeyframe() {
	if r.currentKeyframeRelease == nil {
		return
	}
	r.currentKeyframeReleaseOnce.Do(func() {
		close(r.currentKeyframeRelease)
	})
}

func sourceCells(text string) []remotegrid.GridCell {
	cells := make([]remotegrid.GridCell, 0, len(text))
	for _, ch := range text {
		cells = append(cells, remotegrid.GridCell{Text: string(ch), Width: 1, Style: remotegrid.NormalCellStyle})
	}
	return cells
}

func sourceFixedWidthCells(text string, columns int) []remotegrid.GridCell {
	cells := sourceCells(text)
	if len(cells) > columns {
		cells = cells[:columns]
	}
	for len(cells) < columns {
		cells = append(cells, remotegrid.GridCell{Text: " ", Width: 1, Style: remotegrid.NormalCellStyle})
	}
	return cells
}

func sourceReliableKinds(t *testing.T, messages []remotegrid.WorkspaceMessage) []string {
	t.Helper()

	output, err := marshalWorkspaceMessageLines(messages)
	if err != nil {
		t.Fatal(err)
	}
	lines := bytes.Split(bytes.TrimSpace(output), []byte("\n"))
	if len(lines) == 1 && len(lines[0]) == 0 {
		return nil
	}
	kinds := make([]string, 0, len(lines))
	for _, line := range lines {
		kind := sourceMessageKind(t, line)
		switch kind {
		case "workspaceSnapshot":
			snapshot := decodeWorkspaceMessagePayload(t, line, "workspaceSnapshot")
			kinds = append(kinds, "snapshot:"+snapshot["workspaceID"].(string))
		case "paneKeyframe":
			keyframe := decodeWorkspaceMessagePayload(t, line, "paneKeyframe")
			kinds = append(kinds, "keyframe:"+strconv.Itoa(int(keyframe["paneID"].(float64)))+":"+strconv.Itoa(int(keyframe["keyframeID"].(float64))))
		default:
			kinds = append(kinds, "unknown")
		}
	}
	return kinds
}

func sourceDecodeReliableLines(t *testing.T, output []byte) []remotegrid.WorkspaceMessage {
	t.Helper()

	lines := bytes.Split(bytes.TrimSpace(output), []byte("\n"))
	if len(lines) == 1 && len(lines[0]) == 0 {
		return nil
	}
	messages := make([]remotegrid.WorkspaceMessage, 0, len(lines))
	for _, line := range lines {
		switch sourceMessageKind(t, line) {
		case "workspaceSnapshot":
			var envelope struct {
				WorkspaceSnapshot struct {
					Value remotegrid.WorkspaceSnapshot `json:"_0"`
				} `json:"workspaceSnapshot"`
			}
			if err := json.Unmarshal(line, &envelope); err != nil {
				t.Fatal(err)
			}
			messages = append(messages, remotegrid.WorkspaceSnapshotMessage(envelope.WorkspaceSnapshot.Value))
		case "paneKeyframe":
			var envelope struct {
				PaneKeyframe struct {
					Value remotegrid.PaneKeyframe `json:"_0"`
				} `json:"paneKeyframe"`
			}
			if err := json.Unmarshal(line, &envelope); err != nil {
				t.Fatal(err)
			}
			messages = append(messages, remotegrid.PaneKeyframeMessage(envelope.PaneKeyframe.Value))
		default:
			t.Fatalf("unsupported reliable message line: %s", line)
		}
	}
	return messages
}

func sourceOnlyKeyframe(t *testing.T, messages []remotegrid.WorkspaceMessage) remotegrid.PaneKeyframe {
	t.Helper()

	var keyframes []remotegrid.PaneKeyframe
	for _, message := range messages {
		if keyframe, ok := message.PaneKeyframe(); ok {
			keyframes = append(keyframes, keyframe)
		}
	}
	if len(keyframes) != 1 {
		t.Fatalf("keyframes = %d, want 1", len(keyframes))
	}
	return keyframes[0]
}

func sourceOnlySnapshot(t *testing.T, messages []remotegrid.WorkspaceMessage) remotegrid.WorkspaceSnapshot {
	t.Helper()

	var snapshots []remotegrid.WorkspaceSnapshot
	for _, message := range messages {
		if snapshot, ok := message.WorkspaceSnapshot(); ok {
			snapshots = append(snapshots, snapshot)
		}
	}
	if len(snapshots) != 1 {
		t.Fatalf("snapshots = %d, want 1", len(snapshots))
	}
	return snapshots[0]
}

func sourceKeyframeForPane(t *testing.T, messages []remotegrid.WorkspaceMessage, paneID int) remotegrid.PaneKeyframe {
	t.Helper()

	for _, message := range messages {
		if keyframe, ok := message.PaneKeyframe(); ok && keyframe.PaneID == paneID {
			return keyframe
		}
	}
	t.Fatalf("missing keyframe for pane %d in %v", paneID, sourceReliableKinds(t, messages))
	return remotegrid.PaneKeyframe{}
}

func sourceKeyframeText(keyframe remotegrid.PaneKeyframe) string {
	var buffer bytes.Buffer
	for _, row := range keyframe.Rows {
		for _, cell := range row.Cells {
			buffer.WriteString(cell.Text)
		}
		buffer.WriteByte('\n')
	}
	return buffer.String()
}

func sourceDecodeDelta(t *testing.T, payload []byte) remotegrid.PaneDelta {
	t.Helper()

	var delta remotegrid.PaneDelta
	if err := json.Unmarshal(payload, &delta); err != nil {
		t.Fatal(err)
	}
	return delta
}

func sourceHasSubscriber(source *engineWorkspaceSource, pump *engine.StreamPump) bool {
	source.mu.Lock()
	defer source.mu.Unlock()
	_, ok := source.subscribers[pump]
	return ok
}

func waitForWorkspaceLockReleased(t *testing.T, source *engineWorkspaceSource, description string) {
	t.Helper()

	deadline := time.Now().Add(500 * time.Millisecond)
	for time.Now().Before(deadline) {
		if source.workspaceMu.TryLock() {
			source.workspaceMu.Unlock()
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("workspace lock stayed held while %s", description)
}

func waitForPublishSequenceReserved(t *testing.T, source *engineWorkspaceSource, sequence uint64, description string) {
	t.Helper()

	deadline := time.Now().Add(500 * time.Millisecond)
	for time.Now().Before(deadline) {
		source.workspaceMu.Lock()
		reserved := source.nextPublishSeq
		source.workspaceMu.Unlock()
		if reserved >= sequence {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("publish sequence %d was not reserved while %s", sequence, description)
}

func waitForPendingSourceKeyframe(t *testing.T, source *engineWorkspaceSource, paneID int, paneGeneration uint64, keyframeID uint64) {
	t.Helper()

	key := sourcePaneKey{workspaceID: source.workspaceID, paneID: paneID}
	deadline := time.Now().Add(500 * time.Millisecond)
	for time.Now().Before(deadline) {
		source.pendingMu.Lock()
		pending, ok := source.pendingKeyframes[key]
		source.pendingMu.Unlock()
		if ok && pending.paneGeneration == paneGeneration && pending.keyframeID == keyframeID {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("pending keyframe pane=%d generation=%d keyframe=%d was not reserved", paneID, paneGeneration, keyframeID)
}

type sourceBlockingReliableWriter struct {
	startedOnce sync.Once
	started     chan struct{}
	released    chan struct{}
	releaseOnce sync.Once
}

func newSourceBlockingReliableWriter() *sourceBlockingReliableWriter {
	return &sourceBlockingReliableWriter{
		started:  make(chan struct{}),
		released: make(chan struct{}),
	}
}

func (w *sourceBlockingReliableWriter) Write(payload []byte) (int, error) {
	w.startedOnce.Do(func() {
		close(w.started)
	})
	<-w.released
	return len(payload), nil
}

func (w *sourceBlockingReliableWriter) waitUntilBlocked(t *testing.T) {
	t.Helper()

	select {
	case <-w.started:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for reliable writer to block")
	}
}

func (w *sourceBlockingReliableWriter) release() {
	w.releaseOnce.Do(func() {
		close(w.released)
	})
}

func (w *sourceBlockingReliableWriter) Close() error {
	w.release()
	return nil
}

type sourceRecordingReliableWriter struct {
	mu     sync.Mutex
	buffer bytes.Buffer
	wrote  chan struct{}
}

func newSourceRecordingReliableWriter() *sourceRecordingReliableWriter {
	return &sourceRecordingReliableWriter{wrote: make(chan struct{}, 32)}
}

func (w *sourceRecordingReliableWriter) Write(payload []byte) (int, error) {
	w.mu.Lock()
	n, err := w.buffer.Write(payload)
	w.mu.Unlock()

	select {
	case w.wrote <- struct{}{}:
	default:
	}
	return n, err
}

func (w *sourceRecordingReliableWriter) bytes() []byte {
	w.mu.Lock()
	defer w.mu.Unlock()
	return append([]byte(nil), w.buffer.Bytes()...)
}

func (w *sourceRecordingReliableWriter) waitForKind(t *testing.T, want string) {
	t.Helper()

	deadline := time.After(2 * time.Second)
	for {
		output := w.bytes()
		if sourceReliableLinesContainKind(t, output, want) {
			return
		}
		select {
		case <-w.wrote:
		case <-deadline:
			t.Fatalf("reconnect reliable stream kinds = %v, want %s", sourceReliableLineKinds(t, output), want)
		}
	}
}

type sourceBlockingDatagramWriter struct {
	startedOnce sync.Once
	started     chan struct{}
	released    chan struct{}
	releaseOnce sync.Once
}

func newSourceBlockingDatagramWriter() *sourceBlockingDatagramWriter {
	return &sourceBlockingDatagramWriter{
		started:  make(chan struct{}),
		released: make(chan struct{}),
	}
}

func (w *sourceBlockingDatagramWriter) WriteDatagram(payload []byte) error {
	w.startedOnce.Do(func() {
		close(w.started)
	})
	<-w.released
	return nil
}

func (w *sourceBlockingDatagramWriter) waitUntilBlocked(t *testing.T) {
	t.Helper()

	select {
	case <-w.started:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for datagram writer to block")
	}
}

func (w *sourceBlockingDatagramWriter) release() {
	w.releaseOnce.Do(func() {
		close(w.released)
	})
}

func (w *sourceBlockingDatagramWriter) Close() error {
	w.release()
	return nil
}

func assertSourceReturns(t *testing.T, name string, fn func() error) {
	t.Helper()

	done := make(chan error, 1)
	go func() {
		done <- fn()
	}()

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("%s returned error: %v", name, err)
		}
	case <-time.After(200 * time.Millisecond):
		t.Fatalf("%s did not return while stream pump writer was stalled", name)
	}
}

func sourceReliableLinesContainKind(t *testing.T, output []byte, want string) bool {
	t.Helper()

	for _, kind := range sourceReliableLineKinds(t, output) {
		if kind == want {
			return true
		}
	}
	return false
}

func sourceReliableLineKinds(t *testing.T, output []byte) []string {
	t.Helper()

	lines := bytes.Split(bytes.TrimSpace(output), []byte("\n"))
	if len(lines) == 1 && len(lines[0]) == 0 {
		return nil
	}
	kinds := make([]string, 0, len(lines))
	for _, line := range lines {
		kinds = append(kinds, sourceMessageKind(t, line))
	}
	return kinds
}

func sourceMessageKind(t *testing.T, line []byte) string {
	t.Helper()

	var message map[string]json.RawMessage
	if err := json.Unmarshal(line, &message); err != nil {
		t.Fatal(err)
	}
	if len(message) != 1 {
		t.Fatalf("message case count = %d, want 1 in %s", len(message), string(line))
	}
	for kind := range message {
		return kind
	}
	return ""
}
