package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"fantastty/remote-engine-helper/internal/engine"
	"fantastty/remote-engine-helper/internal/keyring"
	"fantastty/remote-engine-helper/internal/registry"
	"fantastty/remote-engine-helper/remotegrid"
	"github.com/quic-go/quic-go"
)

func TestRemoteQUICAttachConsumesKeyAndStreamsWorkspaceMessages(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)

	store, err := registry.NewStore(root, registry.Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := registry.NewManager(store)
	result, err := manager.LaunchOrResume("workspace-a", time.Minute, time.Minute, func(registry.StartRequest) (registry.StartResult, error) {
		return registry.StartResult{PID: os.Getpid(), Port: 1, SocketPath: "/tmp/fantastty-quic-test.sock"}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume: %v", err)
	}

	source := remoteWorkspacePayloadSource(func(workspaceID string) (remoteWorkspacePayload, error) {
		messages, err := buildSmokeWorkspaceMessages(workspaceID, "quic-smoke")
		if err != nil {
			return remoteWorkspacePayload{}, err
		}
		return remoteWorkspacePayload{
			Reliable: messages,
			Datagrams: []remotegrid.PaneDelta{{
				WorkspaceID:    workspaceID,
				PaneID:         smokeWorkspacePaneID,
				PaneGeneration: 1,
				BaseKeyframeID: 1,
				DeltaSequence:  1,
				RowUpdates: []remotegrid.RowUpdate{{
					RowIndex:   0,
					RowVersion: 2,
					Update: remotegrid.FullRow([]remotegrid.GridCell{
						{Text: "q", Width: 1, Style: remotegrid.NormalCellStyle},
					}),
				}},
			}},
		}, nil
	})
	server := startRemoteQUICTestServer(t, store.Root(), "workspace-a", result.Session, source)
	defer server.Close()

	lines := readRemoteQUICTestReliablePayload(t, server, result.Session, result.Key, 2)
	assertWorkspaceMessageCases(t, strings.Join(lines, "\n")+"\n", "workspace-a")
	if _, err := manager.ConsumeKey(result.Session, result.Key); !errors.Is(err, keyring.ErrInvalidKey) {
		t.Fatalf("key survived QUIC attach: %v", err)
	}
}

func TestRemoteQUICConnectionStaysOpenAndServesKeyframeRequests(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)

	store, err := registry.NewStore(root, registry.Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := registry.NewManager(store)
	result, err := manager.LaunchOrResume("workspace-a", time.Minute, time.Minute, func(registry.StartRequest) (registry.StartResult, error) {
		return registry.StartResult{PID: os.Getpid(), Port: 1, SocketPath: "/tmp/fantastty-quic-test.sock"}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume: %v", err)
	}

	var sourceCalls atomic.Int64
	source := remoteWorkspacePayloadSource(func(workspaceID string) (remoteWorkspacePayload, error) {
		call := sourceCalls.Add(1)
		messages, err := buildSmokeWorkspaceMessages(workspaceID, fmt.Sprintf("quic-smoke-%d", call))
		return remoteWorkspacePayload{Reliable: messages}, err
	})
	server := startRemoteQUICTestServer(t, store.Root(), "workspace-a", result.Session, source)
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := quic.DialAddr(ctx, server.Addr(), remoteQUICTestTLSConfig(t, server.CertSHA256()), &quic.Config{EnableDatagrams: true})
	if err != nil {
		t.Fatalf("DialAddr: %v", err)
	}
	defer conn.CloseWithError(0, "")

	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		t.Fatalf("OpenStreamSync: %v", err)
	}
	if _, err := fmt.Fprintf(stream, `{"session":%q,"key":%q}`+"\n", result.Session, result.Key); err != nil {
		t.Fatalf("write attach: %v", err)
	}

	reader := bufio.NewReader(stream)
	first := readRemoteQUICTestReliableLines(t, reader, 2)
	if gotCalls := sourceCalls.Load(); len(first) != 2 || gotCalls != 1 {
		t.Fatalf("initial reliable payload lines=%d sourceCalls=%d, want lines=2 sourceCalls=1", len(first), gotCalls)
	}
	if _, err := manager.ConsumeKey(result.Session, result.Key); !errors.Is(err, keyring.ErrInvalidKey) {
		t.Fatalf("key survived initial QUIC attach: %v", err)
	}

	if _, err := fmt.Fprintf(
		stream,
		`{"type":"requestKeyframe","workspaceID":"workspace-a","paneID":%d,"reason":"malformedDelta"}`+"\n",
		smokeWorkspacePaneID,
	); err != nil {
		t.Fatalf("write keyframe request: %v", err)
	}
	second := readRemoteQUICTestReliableLines(t, reader, 2)
	if gotCalls := sourceCalls.Load(); len(second) != 2 || gotCalls != 2 {
		t.Fatalf("keyframe request payload lines=%d sourceCalls=%d, want lines=2 sourceCalls=2", len(second), gotCalls)
	}
}

func TestRemoteQUICReliableLogWriterRecordsWrittenMessageKinds(t *testing.T) {
	messages, err := buildSmokeWorkspaceMessages("workspace-a", "quic-smoke")
	if err != nil {
		t.Fatal(err)
	}
	var stream bytes.Buffer
	var log bytes.Buffer
	writer := remoteQUICReliableLogWriter{
		writer:             &stream,
		log:                &log,
		connectionSequence: 3,
	}

	for _, message := range messages {
		line, err := json.Marshal(message)
		if err != nil {
			t.Fatal(err)
		}
		line = append(line, '\n')
		if _, err := writer.Write(line); err != nil {
			t.Fatal(err)
		}
	}

	assertWorkspaceMessageCases(t, stream.String(), "workspace-a")
	logText := log.String()
	if !strings.Contains(logText, "remote_quic_reliable_write_completed=true connection_sequence=3 kind=workspaceSnapshot") {
		t.Fatalf("reliable log = %s, want workspace snapshot write", logText)
	}
	if !strings.Contains(logText, "remote_quic_reliable_write_completed=true connection_sequence=3 kind=paneKeyframe") {
		t.Fatalf("reliable log = %s, want pane keyframe write", logText)
	}
}

func TestRemoteQUICConnectionStreamsLiveSourceDatagrams(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)

	store, err := registry.NewStore(root, registry.Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := registry.NewManager(store)
	result, err := manager.LaunchOrResume("workspace-a", time.Minute, time.Minute, func(registry.StartRequest) (registry.StartResult, error) {
		return registry.StartResult{PID: os.Getpid(), Port: 1, SocketPath: "/tmp/fantastty-quic-test.sock"}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume: %v", err)
	}

	messages, err := buildSmokeWorkspaceMessages("workspace-a", "quic-smoke")
	if err != nil {
		t.Fatal(err)
	}
	source := newRemoteQUICTestLiveSource(remoteWorkspacePayload{Reliable: messages})
	server := startRemoteQUICTestServer(t, store.Root(), "workspace-a", result.Session, source)
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := quic.DialAddr(ctx, server.Addr(), remoteQUICTestTLSConfig(t, server.CertSHA256()), &quic.Config{EnableDatagrams: true})
	if err != nil {
		t.Fatalf("DialAddr: %v", err)
	}
	defer conn.CloseWithError(0, "")

	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		t.Fatalf("OpenStreamSync: %v", err)
	}
	if _, err := fmt.Fprintf(stream, `{"session":%q,"key":%q}`+"\n", result.Session, result.Key); err != nil {
		t.Fatalf("write attach: %v", err)
	}
	reader := bufio.NewReader(stream)
	if lines := readRemoteQUICTestReliableLines(t, reader, 2); len(lines) != 2 {
		t.Fatalf("initial reliable lines = %d, want 2", len(lines))
	}

	source.Publish(remoteWorkspacePayload{Datagrams: []remotegrid.PaneDelta{{
		WorkspaceID:    "workspace-a",
		PaneID:         smokeWorkspacePaneID,
		PaneGeneration: 1,
		BaseKeyframeID: 1,
		DeltaSequence:  9,
		RowUpdates: []remotegrid.RowUpdate{{
			RowIndex:   0,
			RowVersion: 10,
			Update: remotegrid.FullRow([]remotegrid.GridCell{
				{Text: "z", Width: 1, Style: remotegrid.NormalCellStyle},
			}),
		}},
	}}})

	datagram, err := conn.ReceiveDatagram(ctx)
	if err != nil {
		t.Fatalf("ReceiveDatagram: %v", err)
	}
	var delta remotegrid.PaneDelta
	if err := json.Unmarshal(datagram, &delta); err != nil {
		t.Fatalf("datagram JSON: %v", err)
	}
	if delta.WorkspaceID != "workspace-a" || delta.PaneID != smokeWorkspacePaneID || delta.DeltaSequence != 9 {
		t.Fatalf("live datagram = workspace %q pane %d sequence %d, want workspace-a pane %d sequence 9", delta.WorkspaceID, delta.PaneID, delta.DeltaSequence, smokeWorkspacePaneID)
	}
}

func TestRemoteQUICAttachRequestsFreshKeyframesBeforeDatagrams(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)

	store, err := registry.NewStore(root, registry.Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := registry.NewManager(store)
	result, err := manager.LaunchOrResume("workspace-a", time.Minute, time.Minute, func(registry.StartRequest) (registry.StartResult, error) {
		return registry.StartResult{PID: os.Getpid(), Port: 1, SocketPath: "/tmp/fantastty-quic-test.sock"}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume: %v", err)
	}

	staleMessages, err := buildSmokeWorkspaceMessages("workspace-a", "stale")
	if err != nil {
		t.Fatal(err)
	}
	freshMessages, err := buildSmokeWorkspaceMessages("workspace-a", "fresh")
	if err != nil {
		t.Fatal(err)
	}
	source := &remoteQUICAttachBarrierSource{
		current: remoteWorkspacePayload{
			Reliable: staleMessages,
			Datagrams: []remotegrid.PaneDelta{{
				WorkspaceID:    "workspace-a",
				PaneID:         smokeWorkspacePaneID,
				PaneGeneration: 1,
				BaseKeyframeID: 1,
				DeltaSequence:  77,
			}},
		},
		keyframes: remoteWorkspacePayload{Reliable: freshMessages},
	}
	server := startRemoteQUICTestServer(t, store.Root(), "workspace-a", result.Session, source)
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := quic.DialAddr(ctx, server.Addr(), remoteQUICTestTLSConfig(t, server.CertSHA256()), &quic.Config{EnableDatagrams: true})
	if err != nil {
		t.Fatalf("DialAddr: %v", err)
	}
	defer conn.CloseWithError(0, "")

	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		t.Fatalf("OpenStreamSync: %v", err)
	}
	if _, err := fmt.Fprintf(stream, `{"session":%q,"key":%q}`+"\n", result.Session, result.Key); err != nil {
		t.Fatalf("write attach: %v", err)
	}
	reader := bufio.NewReader(stream)
	lines := readRemoteQUICTestReliableLines(t, reader, 2)
	reliablePayload := []byte(lines[1])
	if !remoteJSONTextContainsMarker(reliablePayload, "fresh") {
		t.Fatalf("attach reliable payload did not contain fresh keyframe: %s", reliablePayload)
	}
	if got := source.calls(); !reflect.DeepEqual(got, []string{"requestKeyframes:workspace-a", "subscribe"}) {
		t.Fatalf("attach calls = %v, want RequestKeyframes before live subscribe", got)
	}

	datagramCtx, cancelDatagram := context.WithTimeout(ctx, 200*time.Millisecond)
	defer cancelDatagram()
	datagram, err := conn.ReceiveDatagram(datagramCtx)
	if err == nil {
		t.Fatalf("attach replayed retained datagram before fresh keyframe barrier: %s", datagram)
	}
	if !remoteProbeTimeout(err) {
		t.Fatalf("ReceiveDatagram error = %v, want timeout with no retained datagram", err)
	}
}

func TestRemoteQUICAttachDeliversUpdatePublishedDuringAttachCutover(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)

	store, err := registry.NewStore(root, registry.Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := registry.NewManager(store)
	result, err := manager.LaunchOrResume("workspace-a", time.Minute, time.Minute, func(registry.StartRequest) (registry.StartResult, error) {
		return registry.StartResult{PID: os.Getpid(), Port: 1, SocketPath: "/tmp/fantastty-quic-test.sock"}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume: %v", err)
	}

	freshMessages, err := buildSmokeWorkspaceMessages("workspace-a", "fresh")
	if err != nil {
		t.Fatal(err)
	}
	source := &remoteQUICAttachCutoverSource{
		keyframes: remoteWorkspacePayload{Reliable: freshMessages},
		cutover: remoteWorkspacePayload{
			Datagrams: []remotegrid.PaneDelta{{
				WorkspaceID:    "workspace-a",
				PaneID:         smokeWorkspacePaneID,
				PaneGeneration: 1,
				BaseKeyframeID: 1,
				DeltaSequence:  9,
				RowUpdates: []remotegrid.RowUpdate{{
					RowIndex:   0,
					RowVersion: 9,
					Update:     remotegrid.FullRow(sourceCells("cutover-update")),
				}},
			}},
		},
		subscribers: make(map[*engine.StreamPump]struct{}),
	}
	server := startRemoteQUICTestServer(t, store.Root(), "workspace-a", result.Session, source)
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := quic.DialAddr(ctx, server.Addr(), remoteQUICTestTLSConfig(t, server.CertSHA256()), &quic.Config{EnableDatagrams: true})
	if err != nil {
		t.Fatalf("DialAddr: %v", err)
	}
	defer conn.CloseWithError(0, "")

	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		t.Fatalf("OpenStreamSync: %v", err)
	}
	if _, err := fmt.Fprintf(stream, `{"session":%q,"key":%q}`+"\n", result.Session, result.Key); err != nil {
		t.Fatalf("write attach: %v", err)
	}
	reader := bufio.NewReader(stream)
	lines := readRemoteQUICTestReliableLines(t, reader, 2)
	if remoteQUICTestLineIndexContaining(lines, "fresh") < 0 {
		t.Fatalf("attach reliable payload did not contain fresh keyframe: %v", lines)
	}

	datagram, err := conn.ReceiveDatagram(ctx)
	if err != nil {
		t.Fatalf("ReceiveDatagram: %v", err)
	}
	if !remoteJSONTextContainsMarker(datagram, "cutover-update") {
		t.Fatalf("cutover datagram = %s, want cutover-update marker", datagram)
	}
	assertNoRemoteQUICTestReliableLineWithin(t, stream, reader, 100*time.Millisecond)
}

func TestRemoteQUICAttachReportsSubscribeKeyframesError(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)

	store, err := registry.NewStore(root, registry.Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := registry.NewManager(store)
	result, err := manager.LaunchOrResume("workspace-a", time.Minute, time.Minute, func(registry.StartRequest) (registry.StartResult, error) {
		return registry.StartResult{PID: os.Getpid(), Port: 1, SocketPath: "/tmp/fantastty-quic-test.sock"}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume: %v", err)
	}

	source := remoteQUICSubscribeKeyframesErrorSource{err: errors.New("fresh keyframe unavailable")}
	server := startRemoteQUICTestServer(t, store.Root(), "workspace-a", result.Session, source)
	defer server.Close()

	errorLine := readRemoteQUICTestError(t, server, result.Session, result.Key)
	if !strings.Contains(errorLine, "fresh keyframe unavailable") {
		t.Fatalf("subscribe keyframes error = %q, want fresh keyframe unavailable", errorLine)
	}
}

func TestRemoteQUICReconnectProbeRequestsFreshKeyframesBeforeRetainedDatagrams(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)

	store, err := registry.NewStore(root, registry.Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := registry.NewManager(store)
	first, err := manager.LaunchOrResume("workspace-a", time.Minute, time.Minute, func(registry.StartRequest) (registry.StartResult, error) {
		return registry.StartResult{PID: os.Getpid(), Port: 1, SocketPath: "/tmp/fantastty-quic-test.sock"}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume first: %v", err)
	}
	second, err := manager.LaunchOrResume("workspace-a", time.Minute, time.Minute, func(registry.StartRequest) (registry.StartResult, error) {
		return registry.StartResult{PID: os.Getpid(), Port: 1, SocketPath: "/tmp/fantastty-quic-test.sock"}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume second: %v", err)
	}
	if second.Session != first.Session {
		t.Fatalf("second launch session = %s, want %s", second.Session, first.Session)
	}

	initialMessages, err := buildSmokeWorkspaceMessages("workspace-a", "initial")
	if err != nil {
		t.Fatal(err)
	}
	marker := "fantastty-reconnect"
	source := newRemoteQUICReconnectProbeSource(remoteWorkspacePayload{Reliable: initialMessages}, marker)
	server := startRemoteQUICTestServer(t, store.Root(), "workspace-a", first.Session, source)
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	result, err := requestRemoteQUICReconnectProbe(ctx, server.Addr(), server.CertSHA256(), first.Session, first.Key, second.Key, marker)
	if err != nil {
		t.Fatal(err)
	}
	if result.WorkspaceID != "workspace-a" || result.PaneID != smokeWorkspacePaneID {
		t.Fatalf("probe target = workspace %q pane %d, want workspace-a pane %d", result.WorkspaceID, result.PaneID, smokeWorkspacePaneID)
	}

	if got := source.countCalls("requestKeyframes:workspace-a"); got != 2 {
		t.Fatalf("RequestKeyframes calls = %d, want initial attach plus reconnect", got)
	}
	if got := source.calls(); !remoteQUICTestSubsequence(got, []string{
		"requestKeyframes:workspace-a",
		fmt.Sprintf("sendKeys:workspace-a:%d", smokeWorkspacePaneID),
		"requestKeyframes:workspace-a",
	}) {
		t.Fatalf("probe calls = %v, want sendKeys before reconnect RequestKeyframes", got)
	}
}

func TestRemoteQUICSendKeysRequestForwardsPaneInput(t *testing.T) {
	source := &remoteQUICInputTestSource{}
	var request remoteClientRequest
	if err := json.Unmarshal(
		[]byte(`{"type":"sendKeys","workspaceID":"workspace-a","paneID":0,"data":"aGkK"}`),
		&request,
	); err != nil {
		t.Fatal(err)
	}

	err := handleRemoteClientRequest(request, remoteQUICServerOptions{
		WorkspaceID: "workspace-a",
		Source:      source,
	}, nil)
	if err != nil {
		t.Fatal(err)
	}

	if len(source.sent) != 1 {
		t.Fatalf("sent input count = %d, want 1", len(source.sent))
	}
	if got := source.sent[0]; got.workspaceID != "workspace-a" || got.paneID != 0 || string(got.data) != "hi\n" {
		t.Fatalf("sent input = workspace %q pane %d data %q, want workspace-a pane 0 data hi newline", got.workspaceID, got.paneID, string(got.data))
	}
}

func TestRemoteQUICResizePaneRequestForwardsPaneResize(t *testing.T) {
	source := &remoteQUICInputTestSource{}
	var request remoteClientRequest
	if err := json.Unmarshal(
		[]byte(`{"type":"resizePane","workspaceID":"workspace-a","paneID":0,"columns":100,"rows":30}`),
		&request,
	); err != nil {
		t.Fatal(err)
	}

	err := handleRemoteClientRequest(request, remoteQUICServerOptions{
		WorkspaceID: "workspace-a",
		Source:      source,
	}, nil)
	if err != nil {
		t.Fatal(err)
	}

	if len(source.resized) != 1 {
		t.Fatalf("resize count = %d, want 1", len(source.resized))
	}
	if got := source.resized[0]; got.workspaceID != "workspace-a" || got.paneID != 0 || got.columns != 100 || got.rows != 30 {
		t.Fatalf("resize = workspace %q pane %d size %dx%d, want workspace-a pane 0 size 100x30", got.workspaceID, got.paneID, got.columns, got.rows)
	}
}

func TestRemoteQUICNewWindowRequestForwardsTmuxControlAction(t *testing.T) {
	source := &remoteQUICInputTestSource{}
	var request remoteClientRequest
	if err := json.Unmarshal(
		[]byte(`{"type":"newWindow","workspaceID":"workspace-a"}`),
		&request,
	); err != nil {
		t.Fatal(err)
	}

	err := handleRemoteClientRequest(request, remoteQUICServerOptions{
		WorkspaceID: "workspace-a",
		Source:      source,
	}, nil)
	if err != nil {
		t.Fatal(err)
	}

	if !equalStrings(source.newWindows, []string{"workspace-a"}) {
		t.Fatalf("new window requests = %v, want workspace-a", source.newWindows)
	}
	if len(source.sent) != 0 {
		t.Fatalf("pane input count = %d, want 0", len(source.sent))
	}
}

func TestRemoteQUICSelectWindowRequestForwardsTmuxControlAction(t *testing.T) {
	source := &remoteQUICInputTestSource{}
	var request remoteClientRequest
	if err := json.Unmarshal(
		[]byte(`{"type":"selectWindow","workspaceID":"workspace-a","windowID":3}`),
		&request,
	); err != nil {
		t.Fatal(err)
	}

	err := handleRemoteClientRequest(request, remoteQUICServerOptions{
		WorkspaceID: "workspace-a",
		Source:      source,
	}, nil)
	if err != nil {
		t.Fatal(err)
	}

	if len(source.selectedWindows) != 1 {
		t.Fatalf("select-window count = %d, want 1", len(source.selectedWindows))
	}
	if got := source.selectedWindows[0]; got.workspaceID != "workspace-a" || got.windowID != 3 {
		t.Fatalf("selected window = workspace %q window %d, want workspace-a window 3", got.workspaceID, got.windowID)
	}
	if len(source.sent) != 0 {
		t.Fatalf("pane input count = %d, want 0", len(source.sent))
	}
}

func TestRemoteQUICNewWindowRequestPublishesReturnedSnapshot(t *testing.T) {
	source := &remoteQUICInputTestSource{
		newWindowPayload: remoteWorkspacePayload{
			Reliable: []remotegrid.WorkspaceMessage{
				remotegrid.WorkspaceSnapshotMessage(remotegrid.WorkspaceSnapshot{
					WorkspaceID:      "workspace-a",
					LayoutGeneration: 3,
					Windows: []remotegrid.WorkspaceWindow{
						{WindowID: 1, Title: "main", IsActive: false},
						{WindowID: 2, Title: "zsh", IsActive: true},
					},
					Panes: []remotegrid.WorkspacePane{
						{PaneID: 9, WindowID: 2, IsActive: true, Frame: remotegrid.PaneFrame{Columns: 80, Rows: 24}},
					},
				}),
			},
		},
	}
	var request remoteClientRequest
	if err := json.Unmarshal(
		[]byte(`{"type":"newWindow","workspaceID":"workspace-a"}`),
		&request,
	); err != nil {
		t.Fatal(err)
	}

	var reliable bytes.Buffer
	pump := engine.NewStreamPump(&reliable, nil)
	t.Cleanup(func() {
		if err := pump.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	err := handleRemoteClientRequest(request, remoteQUICServerOptions{
		WorkspaceID: "workspace-a",
		Source:      source,
	}, pump)
	if err != nil {
		t.Fatal(err)
	}
	if err := pump.Flush(); err != nil {
		t.Fatalf("Flush: %v", err)
	}

	output := reliable.String()
	if !strings.Contains(output, `"workspaceID":"workspace-a"`) ||
		!strings.Contains(output, `"layoutGeneration":3`) ||
		!strings.Contains(output, `"windowID":2`) {
		t.Fatalf("reliable output = %s, want new-window snapshot", output)
	}
}

func TestRemoteInputProbeTargetFromSnapshotUsesActivePane(t *testing.T) {
	snapshot := remotegrid.WorkspaceSnapshotMessage(remotegrid.WorkspaceSnapshot{
		WorkspaceID:      "workspace-a",
		LayoutGeneration: 1,
		Windows: []remotegrid.WorkspaceWindow{
			{WindowID: 1, Title: "main", IsActive: true},
		},
		Panes: []remotegrid.WorkspacePane{
			{PaneID: 7, WindowID: 1, IsActive: false, Frame: remotegrid.PaneFrame{Columns: 80, Rows: 24}},
			{PaneID: 0, WindowID: 1, IsActive: true, Frame: remotegrid.PaneFrame{Columns: 80, Rows: 24}},
		},
	})
	line, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatal(err)
	}

	target, err := remoteInputProbeTargetFromSnapshot(append(line, '\n'))
	if err != nil {
		t.Fatal(err)
	}

	if target.WorkspaceID != "workspace-a" || target.PaneID != 0 {
		t.Fatalf("target = workspace %q pane %d, want workspace-a pane 0", target.WorkspaceID, target.PaneID)
	}
}

func TestRemoteJSONTextContainsMarkerAcrossGridCells(t *testing.T) {
	delta := remotegrid.PaneDelta{
		WorkspaceID:    "workspace-a",
		PaneID:         7,
		PaneGeneration: 1,
		BaseKeyframeID: 1,
		DeltaSequence:  1,
		RowUpdates: []remotegrid.RowUpdate{{
			RowIndex:   0,
			RowVersion: 2,
			Update: remotegrid.FullRow([]remotegrid.GridCell{
				{Text: "fan", Width: 1, Style: remotegrid.NormalCellStyle},
				{Text: "tastty", Width: 1, Style: remotegrid.NormalCellStyle},
				{Text: "-input", Width: 1, Style: remotegrid.NormalCellStyle},
			}),
		}},
	}
	payload, err := json.Marshal(delta)
	if err != nil {
		t.Fatal(err)
	}

	if !remoteJSONTextContainsMarker(payload, "fantastty-input") {
		t.Fatalf("marker was not found in delta payload: %s", payload)
	}
	if remoteJSONTextContainsMarker(payload, "not-present") {
		t.Fatalf("unexpected marker match in delta payload: %s", payload)
	}
}

func TestRemoteJSONTextContainsMarkerAcrossCompactFullRowText(t *testing.T) {
	delta := remotegrid.PaneDelta{
		WorkspaceID:    "workspace-a",
		PaneID:         7,
		PaneGeneration: 1,
		BaseKeyframeID: 1,
		DeltaSequence:  1,
		RowUpdates: []remotegrid.RowUpdate{{
			RowIndex:   0,
			RowVersion: 2,
			Update:     remotegrid.FullRow(sourceCells("fantastty-input")),
		}},
	}
	payload, err := remotegrid.MarshalCompactPaneDelta(delta)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(payload), "fullRowText") {
		t.Fatalf("compact payload = %s, want fullRowText encoding", payload)
	}

	if !remoteJSONTextContainsMarker(payload, "fantastty-input") {
		t.Fatalf("marker was not found in compact delta payload: %s", payload)
	}
	if remoteJSONTextContainsMarker(payload, "not-present") {
		t.Fatalf("unexpected marker match in compact delta payload: %s", payload)
	}
}

func TestRemoteQUICAttachRejectsReplayedKey(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)

	store, err := registry.NewStore(root, registry.Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := registry.NewManager(store)
	result, err := manager.LaunchOrResume("workspace-a", time.Minute, time.Minute, func(registry.StartRequest) (registry.StartResult, error) {
		return registry.StartResult{PID: os.Getpid(), Port: 1, SocketPath: "/tmp/fantastty-quic-test.sock"}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume: %v", err)
	}

	source := remoteWorkspacePayloadSource(func(workspaceID string) (remoteWorkspacePayload, error) {
		messages, err := buildSmokeWorkspaceMessages(workspaceID, "quic-smoke")
		return remoteWorkspacePayload{
			Reliable: messages,
			Datagrams: []remotegrid.PaneDelta{{
				WorkspaceID:    workspaceID,
				PaneID:         smokeWorkspacePaneID,
				PaneGeneration: 1,
				BaseKeyframeID: 1,
				DeltaSequence:  1,
			}},
		}, err
	})
	server := startRemoteQUICTestServer(t, store.Root(), "workspace-a", result.Session, source)
	defer server.Close()

	readRemoteQUICTestReliablePayload(t, server, result.Session, result.Key, 2)
	errorLine := readRemoteQUICTestError(t, server, result.Session, result.Key)
	if !strings.Contains(errorLine, "invalid one-time key") {
		t.Fatalf("replay error = %q, want invalid one-time key", errorLine)
	}
}

func TestRemoteQUICAttachRejectsSessionIDWithoutKey(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)

	store, err := registry.NewStore(root, registry.Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := registry.NewManager(store)
	result, err := manager.LaunchOrResume("workspace-a", time.Minute, time.Minute, func(registry.StartRequest) (registry.StartResult, error) {
		return registry.StartResult{PID: os.Getpid(), Port: 1, SocketPath: "/tmp/fantastty-quic-test.sock"}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume: %v", err)
	}

	var sourceCalls atomic.Int64
	source := remoteWorkspacePayloadSource(func(workspaceID string) (remoteWorkspacePayload, error) {
		sourceCalls.Add(1)
		messages, err := buildSmokeWorkspaceMessages(workspaceID, "quic-smoke")
		return remoteWorkspacePayload{Reliable: messages}, err
	})
	server := startRemoteQUICTestServer(t, store.Root(), "workspace-a", result.Session, source)
	defer server.Close()

	errorLine := readRemoteQUICTestRejectedAttach(t, server, fmt.Sprintf(`{"session":%q}`, result.Session))
	if !strings.Contains(errorLine, "attach request requires session and key") {
		t.Fatalf("session-only attach error = %q, want missing key rejection", errorLine)
	}
	if got := sourceCalls.Load(); got != 0 {
		t.Fatalf("source calls after rejected session-only attach = %d, want 0", got)
	}
	readRemoteQUICTestReliablePayload(t, server, result.Session, result.Key, 2)
	if got := sourceCalls.Load(); got != 1 {
		t.Fatalf("source calls after valid attach = %d, want 1", got)
	}
}

func TestRemoteQUICAttachRejectsKeyForAnotherWorkspace(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)

	store, err := registry.NewStore(root, registry.Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := registry.NewManager(store)
	sessionA, err := manager.LaunchOrResume("workspace-a", time.Minute, time.Minute, func(registry.StartRequest) (registry.StartResult, error) {
		return registry.StartResult{PID: os.Getpid(), Port: 1, SocketPath: "/tmp/fantastty-quic-a.sock"}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume A: %v", err)
	}
	sessionB, err := manager.LaunchOrResume("workspace-b", time.Minute, time.Minute, func(registry.StartRequest) (registry.StartResult, error) {
		return registry.StartResult{PID: os.Getpid(), Port: 2, SocketPath: "/tmp/fantastty-quic-b.sock"}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume B: %v", err)
	}

	var sourceCalls atomic.Int64
	source := remoteWorkspacePayloadSource(func(workspaceID string) (remoteWorkspacePayload, error) {
		sourceCalls.Add(1)
		messages, err := buildSmokeWorkspaceMessages(workspaceID, "quic-smoke")
		return remoteWorkspacePayload{Reliable: messages}, err
	})
	server := startRemoteQUICTestServer(t, store.Root(), "workspace-a", sessionA.Session, source)
	defer server.Close()

	errorLine := readRemoteQUICTestError(t, server, sessionB.Session, sessionB.Key)
	if !strings.Contains(errorLine, "attach key belongs to another remote session") {
		t.Fatalf("wrong-workspace attach error = %q, want remote session rejection", errorLine)
	}
	if got := sourceCalls.Load(); got != 0 {
		t.Fatalf("source calls after rejected wrong-workspace attach = %d, want 0", got)
	}
	if _, err := manager.ConsumeKey(sessionB.Session, sessionB.Key); !errors.Is(err, keyring.ErrInvalidKey) {
		t.Fatalf("wrong-workspace key survived QUIC attach: %v", err)
	}
	if _, err := manager.ConsumeKey(sessionA.Session, sessionA.Key); err != nil {
		t.Fatalf("unrelated workspace key was affected by rejected attach: %v", err)
	}
}

func TestRemoteQUICAttachRejectsWrongSessionAndBurnsKey(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)

	store, err := registry.NewStore(root, registry.Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := registry.NewManager(store)
	sessionA, err := manager.LaunchOrResume("workspace-a", time.Minute, time.Minute, func(registry.StartRequest) (registry.StartResult, error) {
		return registry.StartResult{PID: os.Getpid(), Port: 1, SocketPath: "/tmp/fantastty-quic-a.sock"}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume A: %v", err)
	}
	sessionB, err := manager.LaunchOrResume("workspace-b", time.Minute, time.Minute, func(registry.StartRequest) (registry.StartResult, error) {
		return registry.StartResult{PID: os.Getpid(), Port: 2, SocketPath: "/tmp/fantastty-quic-b.sock"}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume B: %v", err)
	}

	var sourceCalls atomic.Int64
	source := remoteWorkspacePayloadSource(func(workspaceID string) (remoteWorkspacePayload, error) {
		sourceCalls.Add(1)
		messages, err := buildSmokeWorkspaceMessages(workspaceID, "quic-smoke")
		return remoteWorkspacePayload{Reliable: messages}, err
	})
	server := startRemoteQUICTestServer(t, store.Root(), "workspace-a", sessionA.Session, source)
	defer server.Close()

	errorLine := readRemoteQUICTestError(t, server, sessionA.Session, sessionB.Key)
	if !strings.Contains(errorLine, "one-time key belongs to a different session") {
		t.Fatalf("wrong-session attach error = %q, want wrong-session rejection", errorLine)
	}
	if got := sourceCalls.Load(); got != 0 {
		t.Fatalf("source calls after rejected wrong-session attach = %d, want 0", got)
	}
	if _, err := manager.ConsumeKey(sessionB.Session, sessionB.Key); !errors.Is(err, keyring.ErrInvalidKey) {
		t.Fatalf("wrong-session key survived QUIC attach: %v", err)
	}
	if _, err := manager.ConsumeKey(sessionA.Session, sessionA.Key); err != nil {
		t.Fatalf("unrelated workspace key was affected by rejected attach: %v", err)
	}
}

func TestRemoteQUICAttachRejectsExpiredKeyAndBurnsIt(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)

	store, err := registry.NewStore(root, registry.Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := registry.NewManager(store)
	session := strings.Repeat("1", 64)
	key := strings.Repeat("2", 64)
	if err := manager.RecordSession(registry.SessionRecord{
		Workspace:  "workspace-a",
		Session:    session,
		PID:        os.Getpid(),
		Port:       1,
		SocketPath: "/tmp/fantastty-quic-expired.sock",
		Expires:    time.Now().Add(time.Minute),
		Keys: []keyring.Entry{{
			Key:       key,
			Session:   session,
			ExpiresAt: time.Now().Add(-time.Second),
		}},
	}); err != nil {
		t.Fatalf("RecordSession: %v", err)
	}

	var sourceCalls atomic.Int64
	source := remoteWorkspacePayloadSource(func(workspaceID string) (remoteWorkspacePayload, error) {
		sourceCalls.Add(1)
		messages, err := buildSmokeWorkspaceMessages(workspaceID, "quic-smoke")
		return remoteWorkspacePayload{Reliable: messages}, err
	})
	server := startRemoteQUICTestServer(t, store.Root(), "workspace-a", session, source)
	defer server.Close()

	errorLine := readRemoteQUICTestError(t, server, session, key)
	if !strings.Contains(errorLine, "one-time key expired") {
		t.Fatalf("expired-key attach error = %q, want expired-key rejection", errorLine)
	}
	if got := sourceCalls.Load(); got != 0 {
		t.Fatalf("source calls after rejected expired-key attach = %d, want 0", got)
	}
	if _, err := manager.ConsumeKey(session, key); !errors.Is(err, keyring.ErrInvalidKey) {
		t.Fatalf("expired key survived QUIC attach: %v", err)
	}
}

func TestRemoteQUICLifecycleNotifiedOnlyAroundAuthenticatedClient(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)

	store, err := registry.NewStore(root, registry.Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := registry.NewManager(store)
	result, err := manager.LaunchOrResume("workspace-a", time.Minute, time.Minute, func(registry.StartRequest) (registry.StartResult, error) {
		return registry.StartResult{PID: os.Getpid(), Port: 1, SocketPath: "/tmp/fantastty-quic-test.sock"}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume: %v", err)
	}

	lifecycle := &remoteQUICTestClientLifecycle{}
	messages, err := buildSmokeWorkspaceMessages("workspace-a", "quic-smoke")
	if err != nil {
		t.Fatal(err)
	}
	server := startRemoteQUICTestServerWithLifecycle(
		t,
		store.Root(),
		"workspace-a",
		result.Session,
		remoteWorkspacePayloadSource(func(string) (remoteWorkspacePayload, error) {
			return remoteWorkspacePayload{Reliable: messages}, nil
		}),
		lifecycle,
	)
	defer server.Close()

	if errorLine := readRemoteQUICTestError(t, server, result.Session, "not-a-valid-key"); !strings.Contains(errorLine, "invalid one-time key") {
		t.Fatalf("invalid attach error = %q, want invalid one-time key", errorLine)
	}
	if attached, detached := lifecycle.counts(); attached != 0 || detached != 0 {
		t.Fatalf("lifecycle after rejected attach = attached %d detached %d, want 0/0", attached, detached)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := quic.DialAddr(ctx, server.Addr(), remoteQUICTestTLSConfig(t, server.CertSHA256()), &quic.Config{EnableDatagrams: true})
	if err != nil {
		t.Fatalf("DialAddr: %v", err)
	}
	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		t.Fatalf("OpenStreamSync: %v", err)
	}
	if _, err := fmt.Fprintf(stream, `{"session":%q,"key":%q}`+"\n", result.Session, result.Key); err != nil {
		t.Fatalf("write attach: %v", err)
	}
	reader := bufio.NewReader(stream)
	if lines := readRemoteQUICTestReliableLines(t, reader, 2); len(lines) != 2 {
		t.Fatalf("initial reliable lines = %d, want 2", len(lines))
	}
	if attached, detached := lifecycle.counts(); attached != 1 || detached != 0 {
		t.Fatalf("lifecycle after authenticated attach = attached %d detached %d, want 1/0", attached, detached)
	}
	if err := conn.CloseWithError(0, ""); err != nil {
		t.Fatalf("CloseWithError: %v", err)
	}
	lifecycle.waitForDetached(t, 1)
	if attached, detached := lifecycle.counts(); attached != 1 || detached != 1 {
		t.Fatalf("lifecycle after disconnect = attached %d detached %d, want 1/1", attached, detached)
	}
}

func TestRemoteQUICAcceptsClientRequestsOnAdditionalStreams(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)

	store, err := registry.NewStore(root, registry.Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := registry.NewManager(store)
	result, err := manager.LaunchOrResume("workspace-a", time.Minute, time.Minute, func(registry.StartRequest) (registry.StartResult, error) {
		return registry.StartResult{PID: os.Getpid(), Port: 1, SocketPath: "/tmp/fantastty-quic-test.sock"}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume: %v", err)
	}

	messages, err := buildSmokeWorkspaceMessages("workspace-a", "quic-smoke")
	if err != nil {
		t.Fatal(err)
	}
	source := newRemoteQUICStreamRequestTestSource(remoteWorkspacePayload{Reliable: messages})
	server := startRemoteQUICTestServer(t, store.Root(), "workspace-a", result.Session, source)
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := quic.DialAddr(ctx, server.Addr(), remoteQUICTestTLSConfig(t, server.CertSHA256()), &quic.Config{EnableDatagrams: true})
	if err != nil {
		t.Fatalf("DialAddr: %v", err)
	}
	defer conn.CloseWithError(0, "")

	attachStream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		t.Fatalf("OpenStreamSync attach: %v", err)
	}
	if _, err := fmt.Fprintf(attachStream, `{"session":%q,"key":%q}`+"\n", result.Session, result.Key); err != nil {
		t.Fatalf("write attach: %v", err)
	}
	reader := bufio.NewReader(attachStream)
	if lines := readRemoteQUICTestReliableLines(t, reader, 2); len(lines) != 2 {
		t.Fatalf("initial reliable lines = %d, want 2", len(lines))
	}

	requestStream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		t.Fatalf("OpenStreamSync request: %v", err)
	}
	if err := writeRemoteClientRequest(requestStream, remoteClientRequest{
		Type:        "sendKeys",
		WorkspaceID: "workspace-a",
		PaneID:      smokeWorkspacePaneID,
		Data:        []byte("hi\n"),
	}); err != nil {
		t.Fatalf("write request: %v", err)
	}

	select {
	case got := <-source.sent:
		if got.workspaceID != "workspace-a" || got.paneID != smokeWorkspacePaneID || string(got.data) != "hi\n" {
			t.Fatalf("sent input = workspace %q pane %d data %q", got.workspaceID, got.paneID, string(got.data))
		}
	case <-ctx.Done():
		t.Fatal("timed out waiting for additional-stream sendKeys")
	}
}

func TestRemoteQUICRejectsAdditionalStreamsAfterPrimaryDetach(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)

	store, err := registry.NewStore(root, registry.Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := registry.NewManager(store)
	result, err := manager.LaunchOrResume("workspace-a", time.Minute, time.Minute, func(registry.StartRequest) (registry.StartResult, error) {
		return registry.StartResult{PID: os.Getpid(), Port: 1, SocketPath: "/tmp/fantastty-quic-test.sock"}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume: %v", err)
	}

	messages, err := buildSmokeWorkspaceMessages("workspace-a", "quic-smoke")
	if err != nil {
		t.Fatal(err)
	}
	source := newRemoteQUICStreamRequestTestSource(remoteWorkspacePayload{Reliable: messages})
	lifecycle := &remoteQUICTestClientLifecycle{}
	server := startRemoteQUICTestServerWithLifecycle(t, store.Root(), "workspace-a", result.Session, source, lifecycle)
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := quic.DialAddr(ctx, server.Addr(), remoteQUICTestTLSConfig(t, server.CertSHA256()), &quic.Config{EnableDatagrams: true})
	if err != nil {
		t.Fatalf("DialAddr: %v", err)
	}
	defer conn.CloseWithError(0, "")

	attachStream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		t.Fatalf("OpenStreamSync attach: %v", err)
	}
	if _, err := fmt.Fprintf(attachStream, `{"session":%q,"key":%q}`+"\n", result.Session, result.Key); err != nil {
		t.Fatalf("write attach: %v", err)
	}
	reader := bufio.NewReader(attachStream)
	if lines := readRemoteQUICTestReliableLines(t, reader, 2); len(lines) != 2 {
		t.Fatalf("initial reliable lines = %d, want 2", len(lines))
	}
	if err := attachStream.Close(); err != nil {
		t.Fatalf("close attach stream: %v", err)
	}
	lifecycle.waitForDetached(t, 1)

	requestStream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		return
	}
	defer requestStream.Close()
	if err := writeRemoteClientRequest(requestStream, remoteClientRequest{
		Type:        "sendKeys",
		WorkspaceID: "workspace-a",
		PaneID:      smokeWorkspacePaneID,
		Data:        []byte("after-detach\n"),
	}); err != nil {
		return
	}

	select {
	case got := <-source.sent:
		t.Fatalf("received request after primary stream detached: workspace %q pane %d data %q", got.workspaceID, got.paneID, string(got.data))
	case <-time.After(300 * time.Millisecond):
	}
}

func TestRemoteQUICLineInputDoesNotRequestSettledPaneKeyframe(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)

	store, err := registry.NewStore(root, registry.Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := registry.NewManager(store)
	result, err := manager.LaunchOrResume("workspace-a", time.Minute, time.Minute, func(registry.StartRequest) (registry.StartResult, error) {
		return registry.StartResult{PID: os.Getpid(), Port: 1, SocketPath: "/tmp/fantastty-quic-test.sock"}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume: %v", err)
	}

	initial, err := buildSmokeWorkspaceMessages("workspace-a", "initial")
	if err != nil {
		t.Fatal(err)
	}
	settled, err := buildSmokeWorkspaceMessages("workspace-a", "after-input")
	if err != nil {
		t.Fatal(err)
	}
	settled = remoteQUICTestWithKeyframeID(settled, 2)
	source := &remoteQUICSettledKeyframeSource{
		initial: remoteWorkspacePayload{Reliable: initial},
		settled: remoteWorkspacePayload{Reliable: settled},
		afterKeyframe: remoteWorkspacePayload{
			Datagrams: []remotegrid.PaneDelta{{
				WorkspaceID:    "workspace-a",
				PaneID:         smokeWorkspacePaneID,
				PaneGeneration: 1,
				BaseKeyframeID: 2,
				DeltaSequence:  9,
				RowUpdates: []remotegrid.RowUpdate{{
					RowIndex:   0,
					RowVersion: 9,
					Update:     remotegrid.FullRow(sourceCells("after-keyframe-delta")),
				}},
			}},
		},
		sent:              make(chan remoteQUICInputTestSend, 1),
		requestedKeyframe: make(chan struct{}, 1),
		subscribers:       make(map[*engine.StreamPump]struct{}),
	}
	server := startRemoteQUICTestServer(t, store.Root(), "workspace-a", result.Session, source)
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := quic.DialAddr(ctx, server.Addr(), remoteQUICTestTLSConfig(t, server.CertSHA256()), &quic.Config{EnableDatagrams: true})
	if err != nil {
		t.Fatalf("DialAddr: %v", err)
	}
	defer conn.CloseWithError(0, "")

	attachStream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		t.Fatalf("OpenStreamSync attach: %v", err)
	}
	if _, err := fmt.Fprintf(attachStream, `{"session":%q,"key":%q}`+"\n", result.Session, result.Key); err != nil {
		t.Fatalf("write attach: %v", err)
	}
	reader := bufio.NewReader(attachStream)
	if lines := readRemoteQUICTestReliableLines(t, reader, 2); len(lines) != 2 {
		t.Fatalf("initial reliable lines = %d, want 2", len(lines))
	}

	requestStream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		t.Fatalf("OpenStreamSync request: %v", err)
	}
	if err := writeRemoteClientRequest(requestStream, remoteClientRequest{
		Type:        "sendKeys",
		WorkspaceID: "workspace-a",
		PaneID:      smokeWorkspacePaneID,
		Data:        []byte("hi\n"),
	}); err != nil {
		t.Fatalf("write request: %v", err)
	}
	select {
	case got := <-source.sent:
		if got.workspaceID != "workspace-a" || got.paneID != smokeWorkspacePaneID || string(got.data) != "hi\n" {
			t.Fatalf("sent input = workspace %q pane %d data %q", got.workspaceID, got.paneID, string(got.data))
		}
	case <-ctx.Done():
		t.Fatal("timed out waiting for sendKeys")
	}

	assertNoRemoteQUICTestReliableLineWithin(t, attachStream, reader, 300*time.Millisecond)
	select {
	case <-source.requestedKeyframe:
		t.Fatal("line-input sendKeys requested settled keyframe recovery")
	default:
	}
}

func TestRemoteQUICReadsAttachStreamRequestsWhileInitialOutputIsBlocked(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)

	store, err := registry.NewStore(root, registry.Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := registry.NewManager(store)
	result, err := manager.LaunchOrResume("workspace-a", time.Minute, time.Minute, func(registry.StartRequest) (registry.StartResult, error) {
		return registry.StartResult{PID: os.Getpid(), Port: 1, SocketPath: "/tmp/fantastty-quic-test.sock"}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume: %v", err)
	}

	source := newRemoteQUICStreamRequestTestSource(remoteWorkspacePayload{
		Reliable: []remotegrid.WorkspaceMessage{
			remotegrid.WorkspaceSnapshotMessage(remotegrid.WorkspaceSnapshot{
				WorkspaceID:      "workspace-a",
				LayoutGeneration: 1,
			}),
			remotegrid.PaneKeyframeMessage(largeRemoteQUICPaneKeyframe("workspace-a")),
		},
	})
	server := startRemoteQUICTestServer(t, store.Root(), "workspace-a", result.Session, source)
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := quic.DialAddr(ctx, server.Addr(), remoteQUICTestTLSConfig(t, server.CertSHA256()), &quic.Config{EnableDatagrams: true})
	if err != nil {
		t.Fatalf("DialAddr: %v", err)
	}
	defer conn.CloseWithError(0, "")

	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		t.Fatalf("OpenStreamSync attach: %v", err)
	}
	if _, err := fmt.Fprintf(stream, `{"session":%q,"key":%q}`+"\n", result.Session, result.Key); err != nil {
		t.Fatalf("write attach: %v", err)
	}
	if err := writeRemoteClientRequest(stream, remoteClientRequest{
		Type:        "sendKeys",
		WorkspaceID: "workspace-a",
		PaneID:      smokeWorkspacePaneID,
		Data:        []byte("hi\n"),
	}); err != nil {
		t.Fatalf("write request: %v", err)
	}

	select {
	case got := <-source.sent:
		if got.workspaceID != "workspace-a" || got.paneID != smokeWorkspacePaneID || string(got.data) != "hi\n" {
			t.Fatalf("sent input = workspace %q pane %d data %q", got.workspaceID, got.paneID, string(got.data))
		}
	case <-ctx.Done():
		t.Fatal("timed out waiting for same-stream sendKeys while initial output was blocked")
	}
}

func TestRemoteQUICIgnoresClientRequestsAsDatagrams(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)

	store, err := registry.NewStore(root, registry.Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := registry.NewManager(store)
	result, err := manager.LaunchOrResume("workspace-a", time.Minute, time.Minute, func(registry.StartRequest) (registry.StartResult, error) {
		return registry.StartResult{PID: os.Getpid(), Port: 1, SocketPath: "/tmp/fantastty-quic-test.sock"}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume: %v", err)
	}

	messages, err := buildSmokeWorkspaceMessages("workspace-a", "quic-smoke")
	if err != nil {
		t.Fatal(err)
	}
	source := newRemoteQUICStreamRequestTestSource(remoteWorkspacePayload{Reliable: messages})
	server := startRemoteQUICTestServer(t, store.Root(), "workspace-a", result.Session, source)
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := quic.DialAddr(ctx, server.Addr(), remoteQUICTestTLSConfig(t, server.CertSHA256()), &quic.Config{EnableDatagrams: true})
	if err != nil {
		t.Fatalf("DialAddr: %v", err)
	}
	defer conn.CloseWithError(0, "")

	attachStream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		t.Fatalf("OpenStreamSync attach: %v", err)
	}
	if _, err := fmt.Fprintf(attachStream, `{"session":%q,"key":%q}`+"\n", result.Session, result.Key); err != nil {
		t.Fatalf("write attach: %v", err)
	}
	reader := bufio.NewReader(attachStream)
	if lines := readRemoteQUICTestReliableLines(t, reader, 2); len(lines) != 2 {
		t.Fatalf("initial reliable lines = %d, want 2", len(lines))
	}

	request, err := json.Marshal(remoteClientRequest{
		Type:        "sendKeys",
		WorkspaceID: "workspace-a",
		PaneID:      smokeWorkspacePaneID,
		Data:        []byte("hi\n"),
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := conn.SendDatagram(request); err != nil {
		t.Fatalf("SendDatagram: %v", err)
	}

	requestStream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		t.Fatalf("OpenStreamSync request: %v", err)
	}
	if err := writeRemoteClientRequest(requestStream, remoteClientRequest{
		Type:        "sendKeys",
		WorkspaceID: "workspace-a",
		PaneID:      smokeWorkspacePaneID,
		Data:        []byte("stream\n"),
	}); err != nil {
		t.Fatalf("write stream request: %v", err)
	}

	select {
	case got := <-source.sent:
		if got.workspaceID != "workspace-a" || got.paneID != smokeWorkspacePaneID || string(got.data) != "stream\n" {
			t.Fatalf("sent input = workspace %q pane %d data %q, want reliable stream request only", got.workspaceID, got.paneID, string(got.data))
		}
	case <-ctx.Done():
		t.Fatal("timed out waiting for stream request after DATAGRAM request")
	}
}

func TestRemoteQUICAcceptsClientRequestsOnUnidirectionalStreams(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)

	store, err := registry.NewStore(root, registry.Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := registry.NewManager(store)
	result, err := manager.LaunchOrResume("workspace-a", time.Minute, time.Minute, func(registry.StartRequest) (registry.StartResult, error) {
		return registry.StartResult{PID: os.Getpid(), Port: 1, SocketPath: "/tmp/fantastty-quic-test.sock"}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume: %v", err)
	}

	messages, err := buildSmokeWorkspaceMessages("workspace-a", "quic-smoke")
	if err != nil {
		t.Fatal(err)
	}
	source := newRemoteQUICStreamRequestTestSource(remoteWorkspacePayload{Reliable: messages})
	server := startRemoteQUICTestServer(t, store.Root(), "workspace-a", result.Session, source)
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := quic.DialAddr(ctx, server.Addr(), remoteQUICTestTLSConfig(t, server.CertSHA256()), &quic.Config{EnableDatagrams: true})
	if err != nil {
		t.Fatalf("DialAddr: %v", err)
	}
	defer conn.CloseWithError(0, "")

	attachStream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		t.Fatalf("OpenStreamSync attach: %v", err)
	}
	if _, err := fmt.Fprintf(attachStream, `{"session":%q,"key":%q}`+"\n", result.Session, result.Key); err != nil {
		t.Fatalf("write attach: %v", err)
	}
	reader := bufio.NewReader(attachStream)
	if lines := readRemoteQUICTestReliableLines(t, reader, 2); len(lines) != 2 {
		t.Fatalf("initial reliable lines = %d, want 2", len(lines))
	}

	requestStream, err := conn.OpenUniStreamSync(ctx)
	if err != nil {
		t.Fatalf("OpenUniStreamSync request: %v", err)
	}
	if err := writeRemoteClientRequest(requestStream, remoteClientRequest{
		Type:        "sendKeys",
		WorkspaceID: "workspace-a",
		PaneID:      smokeWorkspacePaneID,
		Data:        []byte("hi\n"),
	}); err != nil {
		t.Fatalf("write request: %v", err)
	}
	if err := requestStream.Close(); err != nil {
		t.Fatalf("close request stream: %v", err)
	}

	select {
	case got := <-source.sent:
		if got.workspaceID != "workspace-a" || got.paneID != smokeWorkspacePaneID || string(got.data) != "hi\n" {
			t.Fatalf("sent input = workspace %q pane %d data %q", got.workspaceID, got.paneID, string(got.data))
		}
	case <-ctx.Done():
		t.Fatal("timed out waiting for unidirectional-stream sendKeys")
	}
}

func startRemoteQUICTestServer(
	t *testing.T,
	runtimeDir string,
	workspaceID string,
	session string,
	source remoteWorkspaceSource,
) *remoteQUICServer {
	t.Helper()
	return startRemoteQUICTestServerWithLifecycle(t, runtimeDir, workspaceID, session, source, nil)
}

func startRemoteQUICTestServerWithLifecycle(
	t *testing.T,
	runtimeDir string,
	workspaceID string,
	session string,
	source remoteWorkspaceSource,
	lifecycle authenticatedClientLifecycle,
) *remoteQUICServer {
	t.Helper()

	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	server, err := startRemoteQUICServer(ctx, remoteQUICServerOptions{
		ListenAddr:    "127.0.0.1:0",
		AdvertiseHost: "127.0.0.1",
		RuntimeDir:    runtimeDir,
		WorkspaceID:   workspaceID,
		Session:       session,
		Source:        source,
		Lifecycle:     lifecycle,
		Log:           testLogWriter{t: t},
	})
	if err != nil {
		t.Fatalf("startRemoteQUICServer: %v", err)
	}
	return server
}

func readRemoteQUICTestReliablePayload(t *testing.T, server *remoteQUICServer, session string, key string, count int) []string {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := quic.DialAddr(ctx, server.Addr(), remoteQUICTestTLSConfig(t, server.CertSHA256()), &quic.Config{EnableDatagrams: true})
	if err != nil {
		t.Fatalf("DialAddr: %v", err)
	}
	defer conn.CloseWithError(0, "")

	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		t.Fatalf("OpenStreamSync: %v", err)
	}
	if _, err := fmt.Fprintf(stream, `{"session":%q,"key":%q}`+"\n", session, key); err != nil {
		t.Fatalf("write attach: %v", err)
	}

	reader := bufio.NewReader(stream)
	return readRemoteQUICTestReliableLines(t, reader, count)
}

func readRemoteQUICTestReliableLines(t *testing.T, reader *bufio.Reader, count int) []string {
	t.Helper()

	var lines []string
	linec := make(chan string, count)
	errc := make(chan error, 1)
	go func() {
		for i := 0; i < count; i++ {
			line, err := reader.ReadString('\n')
			if err != nil {
				errc <- err
				return
			}
			linec <- strings.TrimSuffix(line, "\n")
		}
	}()
	for len(lines) < count {
		select {
		case line := <-linec:
			lines = append(lines, line)
		case err := <-errc:
			t.Fatalf("read reliable line: %v; lines=%v", err, lines)
		case <-time.After(2 * time.Second):
			t.Fatalf("timed out reading reliable lines: got %d, want %d; lines=%v", len(lines), count, lines)
		}
	}
	return lines
}

func readRemoteQUICTestReliableLinesUntil(t *testing.T, reader *bufio.Reader, marker string, limit int) []string {
	t.Helper()

	var lines []string
	for len(lines) < limit {
		lines = append(lines, readRemoteQUICTestReliableLines(t, reader, 1)...)
		if remoteQUICTestLineIndexContaining(lines, marker) >= 0 {
			return lines
		}
	}
	t.Fatalf("reliable lines did not contain %q after %d lines: %v", marker, limit, lines)
	return nil
}

func assertNoRemoteQUICTestReliableLineWithin(t *testing.T, stream *quic.Stream, reader *bufio.Reader, timeout time.Duration) {
	t.Helper()

	if err := stream.SetReadDeadline(time.Now().Add(timeout)); err != nil {
		t.Fatalf("SetReadDeadline: %v", err)
	}
	line, err := reader.ReadString('\n')
	if err == nil {
		t.Fatalf("unexpected reliable line: %s", strings.TrimSuffix(line, "\n"))
	}
	if !remoteProbeTimeout(err) {
		t.Fatalf("read reliable line: %v", err)
	}
}

func remoteQUICTestLineIndexContaining(lines []string, marker string) int {
	for index, line := range lines {
		if remoteJSONTextContainsMarker([]byte(line), marker) || strings.Contains(line, marker) {
			return index
		}
	}
	return -1
}

func remoteQUICTestWithKeyframeID(messages []remotegrid.WorkspaceMessage, keyframeID uint64) []remotegrid.WorkspaceMessage {
	rewritten := append([]remotegrid.WorkspaceMessage(nil), messages...)
	for index, message := range rewritten {
		keyframe, ok := message.PaneKeyframe()
		if !ok {
			continue
		}
		keyframe.KeyframeID = keyframeID
		for rowIndex := range keyframe.Rows {
			keyframe.Rows[rowIndex].RowVersion = keyframeID
		}
		rewritten[index] = remotegrid.PaneKeyframeMessage(keyframe)
	}
	return rewritten
}

func readRemoteQUICTestError(t *testing.T, server *remoteQUICServer, session string, key string) string {
	t.Helper()

	return readRemoteQUICTestRejectedAttach(t, server, fmt.Sprintf(`{"session":%q,"key":%q}`, session, key))
}

func readRemoteQUICTestRejectedAttach(t *testing.T, server *remoteQUICServer, request string) string {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := quic.DialAddr(ctx, server.Addr(), remoteQUICTestTLSConfig(t, server.CertSHA256()), &quic.Config{EnableDatagrams: true})
	if err != nil {
		t.Fatalf("DialAddr: %v", err)
	}
	defer conn.CloseWithError(0, "")

	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		t.Fatalf("OpenStreamSync: %v", err)
	}
	if _, err := fmt.Fprintln(stream, request); err != nil {
		t.Fatalf("write attach: %v", err)
	}
	reader := bufio.NewReader(stream)
	line, err := reader.ReadString('\n')
	if err != nil {
		t.Fatalf("read error line: %v", err)
	}
	assertRemoteQUICTestNoLineAfterRejectedAttach(t, stream, reader)
	return strings.TrimSpace(line)
}

func assertRemoteQUICTestNoLineAfterRejectedAttach(t *testing.T, stream *quic.Stream, reader *bufio.Reader) {
	t.Helper()

	if err := stream.SetReadDeadline(time.Now().Add(100 * time.Millisecond)); err != nil {
		t.Fatalf("SetReadDeadline: %v", err)
	}
	line, err := reader.ReadString('\n')
	if err == nil {
		t.Fatalf("rejected attach streamed unexpected payload after error: %s", strings.TrimSpace(line))
	}
	if errors.Is(err, io.EOF) || remoteProbeTimeout(err) {
		return
	}
	t.Fatalf("read after rejected attach: %v", err)
}

func largeRemoteQUICPaneKeyframe(workspaceID string) remotegrid.PaneKeyframe {
	const rows = 1800
	const columns = 80
	style := remotegrid.NormalCellStyle
	style.Bold = true

	gridRows := make([]remotegrid.GridRow, 0, rows)
	for row := 0; row < rows; row++ {
		cells := make([]remotegrid.GridCell, 0, columns)
		for column := 0; column < columns; column++ {
			cells = append(cells, remotegrid.GridCell{
				Text:  "x",
				Width: 1,
				Style: style,
			})
		}
		gridRows = append(gridRows, remotegrid.GridRow{
			Index:      row,
			RowVersion: uint64(row + 1),
			Cells:      cells,
		})
	}

	return remotegrid.PaneKeyframe{
		WorkspaceID:    workspaceID,
		PaneID:         smokeWorkspacePaneID,
		PaneGeneration: 1,
		KeyframeID:     1,
		GridSize:       remotegrid.GridSize{Columns: columns, Rows: rows},
		Rows:           gridRows,
		Cursor:         remotegrid.CursorState{Visible: true, Shape: remotegrid.CursorShapeBlock, CursorVersion: 1},
		ActiveScreen:   remotegrid.ActiveScreenPrimary,
	}
}

func TestRemoteQUICDatagramWriterCloseClosesConnectionWithBlockedSend(t *testing.T) {
	conn := newRemoteQUICCloseableDatagramConn()
	writer := &remoteQUICDatagramWriter{conn: conn}

	done := make(chan error, 1)
	go func() {
		done <- writer.WriteDatagram([]byte("blocked"))
	}()
	conn.waitUntilSendBlocked(t)
	if err := writer.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("WriteDatagram after close: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("datagram writer close did not unblock blocked send")
	}
	if !conn.isClosed() {
		t.Fatal("datagram writer close did not close QUIC connection")
	}
}

func TestRemoteQUICDatagramWriterCoalescesWhileSendBlocked(t *testing.T) {
	conn := newRemoteQUICBlockingDatagramConn()
	writer := &remoteQUICDatagramWriter{conn: conn}
	t.Cleanup(func() {
		conn.release()
		if err := writer.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	firstDone := make(chan error, 1)
	go func() {
		firstDone <- writer.WriteDatagram([]byte("first"))
	}()
	conn.waitUntilSendBlocked(t)

	assertRemoteQUICTaskReturns(t, "stale datagram write while SendDatagram is blocked", func() error {
		return writer.WriteDatagram([]byte("stale"))
	})
	assertRemoteQUICTaskReturns(t, "latest datagram write while SendDatagram is blocked", func() error {
		return writer.WriteDatagram([]byte("latest"))
	})

	conn.release()
	if err := <-firstDone; err != nil {
		t.Fatalf("first WriteDatagram: %v", err)
	}
	payloads := conn.waitForPayloads(t, 2)
	if string(payloads[0]) != "first" {
		t.Fatalf("first sent datagram = %q, want first", payloads[0])
	}
	if string(payloads[1]) != "latest" {
		t.Fatalf("second sent datagram = %q, want coalesced latest payload", payloads[1])
	}
	if len(payloads) != 2 {
		t.Fatalf("sent datagrams = %d, want first plus coalesced latest", len(payloads))
	}
}

func TestRemoteQUICDatagramWriterKeepsLatestPayloadPerPaneWhileSendBlocked(t *testing.T) {
	conn := newRemoteQUICBlockingDatagramConn()
	writer := &remoteQUICDatagramWriter{conn: conn}
	t.Cleanup(func() {
		conn.release()
		if err := writer.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	firstA := remoteQUICTestPaneDelta("workspace-a", 7, 1, "a1")
	firstDone := make(chan error, 1)
	go func() {
		firstDone <- writer.WriteLatestDatagram(firstA, remoteQUICMustCompactDelta(t, firstA))
	}()
	conn.waitUntilSendBlocked(t)

	paneB := remoteQUICTestPaneDelta("workspace-a", 8, 1, "b1")
	assertRemoteQUICTaskReturns(t, "pane B datagram write while SendDatagram is blocked", func() error {
		return writer.WriteLatestDatagram(paneB, remoteQUICMustCompactDelta(t, paneB))
	})
	secondA := remoteQUICTestPaneDelta("workspace-a", 7, 2, "a2")
	assertRemoteQUICTaskReturns(t, "pane A replacement datagram write while SendDatagram is blocked", func() error {
		return writer.WriteLatestDatagram(secondA, remoteQUICMustCompactDelta(t, secondA))
	})

	conn.release()
	if err := <-firstDone; err != nil {
		t.Fatalf("first WriteLatestDatagram: %v", err)
	}
	payloads := conn.waitForPayloads(t, 3)
	got := remoteQUICDatagramIdentities(t, payloads)
	want := []string{"7:1", "8:1", "7:2"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("sent datagrams = %v, want %v", got, want)
	}
}

func TestRemoteQUICDatagramWriterMergesSamePaneRowsWhileSendBlocked(t *testing.T) {
	conn := newRemoteQUICBlockingDatagramConn()
	writer := &remoteQUICDatagramWriter{conn: conn}
	t.Cleanup(func() {
		conn.release()
		if err := writer.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	first := remoteQUICTestPaneDeltaForRow("workspace-a", 7, 1, 0, "a1")
	firstDone := make(chan error, 1)
	go func() {
		firstDone <- writer.WriteLatestDatagram(first, remoteQUICMustCompactDelta(t, first))
	}()
	conn.waitUntilSendBlocked(t)

	row0 := remoteQUICTestPaneDeltaForRow("workspace-a", 7, 2, 0, "a2")
	assertRemoteQUICTaskReturns(t, "row 0 datagram write while SendDatagram is blocked", func() error {
		return writer.WriteLatestDatagram(row0, remoteQUICMustCompactDelta(t, row0))
	})
	row1 := remoteQUICTestPaneDeltaForRow("workspace-a", 7, 3, 1, "b3")
	assertRemoteQUICTaskReturns(t, "row 1 datagram write while SendDatagram is blocked", func() error {
		return writer.WriteLatestDatagram(row1, remoteQUICMustCompactDelta(t, row1))
	})

	conn.release()
	if err := <-firstDone; err != nil {
		t.Fatalf("first WriteLatestDatagram: %v", err)
	}
	payloads := conn.waitForPayloads(t, 2)
	merged := remoteQUICDecodeDelta(t, payloads[1])
	if merged.DeltaSequence != 3 {
		t.Fatalf("merged delta sequence = %d, want latest sequence 3", merged.DeltaSequence)
	}
	if got := remoteQUICRowTexts(merged); !reflect.DeepEqual(got, map[int]string{0: "a2", 1: "b3"}) {
		t.Fatalf("merged rows = %v, want row 0 and row 1 updates", got)
	}
}

func TestRemoteQUICDatagramWriterFoldsSameRowSpanWhileSendBlocked(t *testing.T) {
	conn := newRemoteQUICBlockingDatagramConn()
	writer := &remoteQUICDatagramWriter{conn: conn}
	t.Cleanup(func() {
		conn.release()
		if err := writer.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	blocker := remoteQUICTestPaneDelta("workspace-a", 8, 1, "zz")
	firstDone := make(chan error, 1)
	go func() {
		firstDone <- writer.WriteLatestDatagram(blocker, remoteQUICMustCompactDelta(t, blocker))
	}()
	conn.waitUntilSendBlocked(t)

	fullRow := remoteQUICTestPaneDeltaForRow("workspace-a", 7, 1, 0, "aa")
	fullRow.RowUpdates[0].RowVersion = 2
	assertRemoteQUICTaskReturns(t, "full-row datagram write while SendDatagram is blocked", func() error {
		return writer.WriteLatestDatagram(fullRow, remoteQUICMustCompactDelta(t, fullRow))
	})
	span := remotegrid.PaneDelta{
		WorkspaceID:    "workspace-a",
		PaneID:         7,
		PaneGeneration: 1,
		BaseKeyframeID: 1,
		DeltaSequence:  2,
		RowUpdates: []remotegrid.RowUpdate{{
			RowIndex:   0,
			RowVersion: 3,
			Update:     remotegrid.Span(2, 1, []remotegrid.GridCell{{Text: "b", Width: 1, Style: remotegrid.NormalCellStyle}}, nil),
		}},
	}
	assertRemoteQUICTaskReturns(t, "dependent span datagram write while SendDatagram is blocked", func() error {
		return writer.WriteLatestDatagram(span, remoteQUICMustCompactDelta(t, span))
	})

	conn.release()
	if err := <-firstDone; err != nil {
		t.Fatalf("first WriteLatestDatagram: %v", err)
	}
	payloads := conn.waitForPayloads(t, 2)
	merged := remoteQUICDecodeDelta(t, payloads[1])
	if merged.DeltaSequence != 2 {
		t.Fatalf("merged delta sequence = %d, want latest sequence 2", merged.DeltaSequence)
	}
	if got := remoteQUICRowTexts(merged); !reflect.DeepEqual(got, map[int]string{0: "ab"}) {
		t.Fatalf("merged rows = %v, want dependent span folded into full row", got)
	}
}

func TestRemoteQUICDatagramWriterPromotesPendingDependentSpanAfterTooLarge(t *testing.T) {
	conn := newRemoteQUICBlockingTooLargeThenRecordingDatagramConn()
	fallbacks := make(chan remotegrid.PaneDelta, 4)
	writer := &remoteQUICDatagramWriter{
		conn: conn,
		onDatagramTooLarge: func(delta remotegrid.PaneDelta) {
			fallbacks <- delta
		},
	}
	t.Cleanup(func() {
		conn.release()
		if err := writer.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	fullRow := remoteQUICTestPaneDeltaForRow("workspace-a", 7, 1, 0, "aa")
	fullRow.RowUpdates[0].RowVersion = 2
	firstDone := make(chan error, 1)
	go func() {
		firstDone <- writer.WriteLatestDatagram(fullRow, remoteQUICMustCompactDelta(t, fullRow))
	}()
	conn.waitUntilSendBlocked(t)

	span := remotegrid.PaneDelta{
		WorkspaceID:    "workspace-a",
		PaneID:         7,
		PaneGeneration: 1,
		BaseKeyframeID: 1,
		DeltaSequence:  2,
		RowUpdates: []remotegrid.RowUpdate{{
			RowIndex:   0,
			RowVersion: 3,
			Update:     remotegrid.Span(2, 1, []remotegrid.GridCell{{Text: "b", Width: 1, Style: remotegrid.NormalCellStyle}}, nil),
		}},
	}
	assertRemoteQUICTaskReturns(t, "dependent span datagram write while first SendDatagram is in flight", func() error {
		return writer.WriteLatestDatagram(span, remoteQUICMustCompactDelta(t, span))
	})

	conn.release()
	if err := <-firstDone; err != nil {
		t.Fatalf("first WriteLatestDatagram: %v", err)
	}
	gotFallbacks := remoteQUICWaitForFallbacks(t, fallbacks, 2)
	if got := []uint64{gotFallbacks[0].DeltaSequence, gotFallbacks[1].DeltaSequence}; !reflect.DeepEqual(got, []uint64{1, 2}) {
		t.Fatalf("fallback sequences = %v, want full row then dependent span", got)
	}
	conn.assertSendCount(t, 1)
}

func TestRemoteQUICDatagramWriterPromotesLateDependentSpanAfterTooLarge(t *testing.T) {
	conn := newRemoteQUICBlockingTooLargeThenRecordingDatagramConn()
	callbackStarted := make(chan struct{})
	allowCallback := make(chan struct{})
	var callbackStartedOnce sync.Once
	fallbacks := make(chan remotegrid.PaneDelta, 4)
	writer := &remoteQUICDatagramWriter{
		conn: conn,
		onDatagramTooLarge: func(delta remotegrid.PaneDelta) {
			callbackStartedOnce.Do(func() {
				close(callbackStarted)
				<-allowCallback
			})
			fallbacks <- delta
		},
	}
	t.Cleanup(func() {
		conn.release()
		select {
		case <-allowCallback:
		default:
			close(allowCallback)
		}
		if err := writer.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	fullRow := remoteQUICTestPaneDeltaForRow("workspace-a", 7, 1, 0, "aa")
	fullRow.RowUpdates[0].RowVersion = 2
	firstDone := make(chan error, 1)
	go func() {
		firstDone <- writer.WriteLatestDatagram(fullRow, remoteQUICMustCompactDelta(t, fullRow))
	}()
	conn.waitUntilSendBlocked(t)
	conn.release()
	select {
	case <-callbackStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for too-large fallback callback to start")
	}

	span := remotegrid.PaneDelta{
		WorkspaceID:    "workspace-a",
		PaneID:         7,
		PaneGeneration: 1,
		BaseKeyframeID: 1,
		DeltaSequence:  2,
		RowUpdates: []remotegrid.RowUpdate{{
			RowIndex:   0,
			RowVersion: 3,
			Update:     remotegrid.Span(2, 1, []remotegrid.GridCell{{Text: "b", Width: 1, Style: remotegrid.NormalCellStyle}}, nil),
		}},
	}
	assertRemoteQUICTaskReturns(t, "late dependent span datagram write while fallback callback is blocked", func() error {
		return writer.WriteLatestDatagram(span, remoteQUICMustCompactDelta(t, span))
	})
	close(allowCallback)
	if err := <-firstDone; err != nil {
		t.Fatalf("first WriteLatestDatagram: %v", err)
	}
	gotFallbacks := remoteQUICWaitForFallbacks(t, fallbacks, 2)
	if got := []uint64{gotFallbacks[0].DeltaSequence, gotFallbacks[1].DeltaSequence}; !reflect.DeepEqual(got, []uint64{1, 2}) {
		t.Fatalf("fallback sequences = %v, want full row then late dependent span", got)
	}
	conn.assertSendCount(t, 1)
}

func TestRemoteQUICDatagramWriterPromotesAsyncTooLargeToReliableFallback(t *testing.T) {
	conn := &remoteQUICTooLargeDatagramConn{sent: make(chan []byte, 1)}
	fallback := make(chan remotegrid.PaneDelta, 1)
	writer := &remoteQUICDatagramWriter{
		conn: conn,
		onDatagramTooLarge: func(delta remotegrid.PaneDelta) {
			fallback <- delta
		},
	}
	t.Cleanup(func() {
		if err := writer.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	delta := remoteQUICTestPaneDelta("workspace-a", 7, 4, "aa")
	if err := writer.WriteLatestDatagram(delta, remoteQUICMustCompactDelta(t, delta)); err != nil {
		t.Fatalf("WriteLatestDatagram: %v", err)
	}

	select {
	case got := <-fallback:
		if got.PaneID != 7 || got.DeltaSequence != 4 {
			t.Fatalf("fallback delta = pane %d sequence %d, want pane 7 sequence 4", got.PaneID, got.DeltaSequence)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for async datagram-too-large reliable fallback")
	}
}

func TestRemoteQUICAsyncTooLargeFallbackWritesReliablePaneDeltaAfterBarrierFlush(t *testing.T) {
	conn := &remoteQUICTooLargeDatagramConn{sent: make(chan []byte, 1)}
	reliable := newSourceRecordingReliableWriter()
	writer := &remoteQUICDatagramWriter{conn: conn}
	pump := engine.NewStreamPump(reliable, writer)
	writer.onDatagramTooLarge = pump.PublishReliableDeltaFallback
	t.Cleanup(func() {
		if err := pump.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	})

	pump.PublishReliable([]remotegrid.WorkspaceMessage{
		remotegrid.PaneKeyframeMessage(remoteQUICTestPaneKeyframe("workspace-a", 7, 1, "ok")),
	})
	if err := pump.Flush(); err != nil {
		t.Fatalf("Flush keyframe: %v", err)
	}
	reliable.waitForKind(t, "paneKeyframe")

	delta := remoteQUICTestPaneDelta("workspace-a", 7, 4, "aa")
	pump.PublishDatagrams([]remotegrid.PaneDelta{delta})
	if err := pump.Flush(); err != nil {
		t.Fatalf("Flush datagram: %v", err)
	}
	reliable.waitForKind(t, "paneDelta")
}

func TestStreamPumpCloseUnblocksRemoteQUICDatagramWriter(t *testing.T) {
	conn := newRemoteQUICCloseableDatagramConn()
	writer := &remoteQUICDatagramWriter{conn: conn}
	pump := engine.NewStreamPump(io.Discard, writer)
	pump.PublishReliable([]remotegrid.WorkspaceMessage{
		remotegrid.PaneKeyframeMessage(remoteQUICTestPaneKeyframe("workspace-a", smokeWorkspacePaneID, 1, "ok")),
	})
	pump.PublishDatagrams([]remotegrid.PaneDelta{
		remoteQUICTestPaneDelta("workspace-a", smokeWorkspacePaneID, 1, "hi"),
	})
	conn.waitUntilSendBlocked(t)

	done := make(chan error, 1)
	go func() {
		done <- pump.Close()
	}()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("pump close: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("pump close did not unblock remote QUIC datagram writer")
	}
	if !conn.isClosed() {
		t.Fatal("pump close did not close QUIC datagram connection")
	}
}

func remoteQUICTestPaneKeyframe(workspaceID string, paneID int, keyframeID uint64, text string) remotegrid.PaneKeyframe {
	return remotegrid.PaneKeyframe{
		WorkspaceID:                   workspaceID,
		PaneID:                        paneID,
		PaneGeneration:                1,
		KeyframeID:                    keyframeID,
		GridSize:                      remotegrid.GridSize{Columns: len(text), Rows: 1},
		Rows:                          []remotegrid.GridRow{{Index: 0, RowVersion: keyframeID, Cells: remoteQUICTestCells(text)}},
		Cursor:                        remotegrid.CursorState{Visible: true, Shape: remotegrid.CursorShapeBlock, CursorVersion: 1},
		ActiveScreen:                  remotegrid.ActiveScreenPrimary,
		DatagramsEnabledAfterKeyframe: true,
	}
}

func remoteQUICTestPaneDelta(workspaceID string, paneID int, sequence uint64, text string) remotegrid.PaneDelta {
	return remoteQUICTestPaneDeltaForRow(workspaceID, paneID, sequence, 0, text)
}

func remoteQUICTestPaneDeltaForRow(workspaceID string, paneID int, sequence uint64, row int, text string) remotegrid.PaneDelta {
	return remotegrid.PaneDelta{
		WorkspaceID:    workspaceID,
		PaneID:         paneID,
		PaneGeneration: 1,
		BaseKeyframeID: 1,
		DeltaSequence:  sequence,
		RowUpdates: []remotegrid.RowUpdate{{
			RowIndex:   row,
			RowVersion: sequence + 1,
			Update:     remotegrid.FullRow(remoteQUICTestCells(text)),
		}},
	}
}

func remoteQUICDecodeDelta(t *testing.T, payload []byte) remotegrid.PaneDelta {
	t.Helper()

	var delta remotegrid.PaneDelta
	if err := json.Unmarshal(payload, &delta); err != nil {
		t.Fatalf("datagram JSON: %v", err)
	}
	return delta
}

func remoteQUICRowTexts(delta remotegrid.PaneDelta) map[int]string {
	rows := make(map[int]string, len(delta.RowUpdates))
	for _, update := range delta.RowUpdates {
		payload, err := json.Marshal(update.Update)
		if err != nil {
			panic(err)
		}
		var body struct {
			FullRow struct {
				Cells []remotegrid.GridCell `json:"_0"`
			} `json:"fullRow"`
		}
		if err := json.Unmarshal(payload, &body); err != nil {
			panic(err)
		}
		var text strings.Builder
		for _, cell := range body.FullRow.Cells {
			text.WriteString(cell.Text)
		}
		rows[update.RowIndex] = text.String()
	}
	return rows
}

func remoteQUICTestCells(text string) []remotegrid.GridCell {
	cells := make([]remotegrid.GridCell, 0, len(text))
	for _, ch := range text {
		cells = append(cells, remotegrid.GridCell{Text: string(ch), Width: 1, Style: remotegrid.NormalCellStyle})
	}
	return cells
}

func remoteQUICTestTLSConfig(t *testing.T, certSHA string) *tls.Config {
	t.Helper()
	return &tls.Config{
		InsecureSkipVerify: true,
		NextProtos:         []string{remoteQUICALPN},
		VerifyPeerCertificate: func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
			if len(rawCerts) == 0 {
				return errors.New("missing peer certificate")
			}
			cert, err := x509.ParseCertificate(rawCerts[0])
			if err != nil {
				return err
			}
			spki := sha256.Sum256(cert.RawSubjectPublicKeyInfo)
			if got := hex.EncodeToString(spki[:]); got != certSHA {
				return fmt.Errorf("SPKI SHA256 = %s, want %s", got, certSHA)
			}
			return nil
		},
	}
}

type testLogWriter struct {
	t *testing.T
}

func (w testLogWriter) Write(payload []byte) (int, error) {
	w.t.Log(strings.TrimSpace(string(payload)))
	return len(payload), nil
}

var errRemoteQUICDatagramConnClosed = errors.New("remote quic datagram connection closed")

type remoteQUICCloseableDatagramConn struct {
	startedOnce sync.Once
	started     chan struct{}
	closed      chan struct{}
	closeOnce   sync.Once
	mu          sync.Mutex
	closedFlag  bool
}

func newRemoteQUICCloseableDatagramConn() *remoteQUICCloseableDatagramConn {
	return &remoteQUICCloseableDatagramConn{
		started: make(chan struct{}),
		closed:  make(chan struct{}),
	}
}

func (c *remoteQUICCloseableDatagramConn) SendDatagram([]byte) error {
	c.startedOnce.Do(func() {
		close(c.started)
	})
	<-c.closed
	return errRemoteQUICDatagramConnClosed
}

func (c *remoteQUICCloseableDatagramConn) CloseWithError(quic.ApplicationErrorCode, string) error {
	c.closeOnce.Do(func() {
		c.mu.Lock()
		c.closedFlag = true
		c.mu.Unlock()
		close(c.closed)
	})
	return nil
}

func (c *remoteQUICCloseableDatagramConn) waitUntilSendBlocked(t *testing.T) {
	t.Helper()

	select {
	case <-c.started:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for datagram send to block")
	}
}

func (c *remoteQUICCloseableDatagramConn) isClosed() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.closedFlag
}

type remoteQUICBlockingDatagramConn struct {
	startedOnce sync.Once
	started     chan struct{}
	released    chan struct{}
	releaseOnce sync.Once
	payloads    chan []byte
}

func newRemoteQUICBlockingDatagramConn() *remoteQUICBlockingDatagramConn {
	return &remoteQUICBlockingDatagramConn{
		started:  make(chan struct{}),
		released: make(chan struct{}),
		payloads: make(chan []byte, 8),
	}
}

func (c *remoteQUICBlockingDatagramConn) SendDatagram(payload []byte) error {
	c.payloads <- append([]byte(nil), payload...)
	c.startedOnce.Do(func() {
		close(c.started)
	})
	<-c.released
	return nil
}

func (c *remoteQUICBlockingDatagramConn) CloseWithError(quic.ApplicationErrorCode, string) error {
	c.release()
	return nil
}

func (c *remoteQUICBlockingDatagramConn) waitUntilSendBlocked(t *testing.T) {
	t.Helper()

	select {
	case <-c.started:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for datagram send to block")
	}
}

func (c *remoteQUICBlockingDatagramConn) release() {
	c.releaseOnce.Do(func() {
		close(c.released)
	})
}

func (c *remoteQUICBlockingDatagramConn) waitForPayloads(t *testing.T, count int) [][]byte {
	t.Helper()

	payloads := make([][]byte, 0, count)
	deadline := time.After(2 * time.Second)
	for len(payloads) < count {
		select {
		case payload := <-c.payloads:
			payloads = append(payloads, payload)
		case <-deadline:
			t.Fatalf("sent datagrams = %d, want %d", len(payloads), count)
		}
	}
	select {
	case payload := <-c.payloads:
		payloads = append(payloads, payload)
	default:
	}
	return payloads
}

type remoteQUICTooLargeDatagramConn struct {
	sent chan []byte
}

func (c *remoteQUICTooLargeDatagramConn) SendDatagram(payload []byte) error {
	c.sent <- append([]byte(nil), payload...)
	return &quic.DatagramTooLargeError{MaxDatagramPayloadSize: 1}
}

func (c *remoteQUICTooLargeDatagramConn) CloseWithError(quic.ApplicationErrorCode, string) error {
	return nil
}

type remoteQUICBlockingTooLargeThenRecordingDatagramConn struct {
	startedOnce sync.Once
	started     chan struct{}
	released    chan struct{}
	releaseOnce sync.Once
	payloads    chan []byte
	mu          sync.Mutex
	sends       int
}

func newRemoteQUICBlockingTooLargeThenRecordingDatagramConn() *remoteQUICBlockingTooLargeThenRecordingDatagramConn {
	return &remoteQUICBlockingTooLargeThenRecordingDatagramConn{
		started:  make(chan struct{}),
		released: make(chan struct{}),
		payloads: make(chan []byte, 8),
	}
}

func (c *remoteQUICBlockingTooLargeThenRecordingDatagramConn) SendDatagram(payload []byte) error {
	c.payloads <- append([]byte(nil), payload...)
	c.mu.Lock()
	c.sends++
	sendNumber := c.sends
	c.mu.Unlock()
	if sendNumber == 1 {
		c.startedOnce.Do(func() {
			close(c.started)
		})
		<-c.released
		return &quic.DatagramTooLargeError{MaxDatagramPayloadSize: 1}
	}
	return nil
}

func (c *remoteQUICBlockingTooLargeThenRecordingDatagramConn) CloseWithError(quic.ApplicationErrorCode, string) error {
	c.release()
	return nil
}

func (c *remoteQUICBlockingTooLargeThenRecordingDatagramConn) waitUntilSendBlocked(t *testing.T) {
	t.Helper()

	select {
	case <-c.started:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for datagram send to block")
	}
}

func (c *remoteQUICBlockingTooLargeThenRecordingDatagramConn) release() {
	c.releaseOnce.Do(func() {
		close(c.released)
	})
}

func (c *remoteQUICBlockingTooLargeThenRecordingDatagramConn) assertSendCount(t *testing.T, want int) {
	t.Helper()

	time.Sleep(100 * time.Millisecond)
	c.mu.Lock()
	got := c.sends
	c.mu.Unlock()
	if got != want {
		t.Fatalf("SendDatagram calls = %d, want %d", got, want)
	}
}

func remoteQUICWaitForFallbacks(t *testing.T, fallbacks <-chan remotegrid.PaneDelta, count int) []remotegrid.PaneDelta {
	t.Helper()

	got := make([]remotegrid.PaneDelta, 0, count)
	deadline := time.After(2 * time.Second)
	for len(got) < count {
		select {
		case delta := <-fallbacks:
			got = append(got, delta)
		case <-deadline:
			t.Fatalf("fallbacks = %d, want %d", len(got), count)
		}
	}
	return got
}

func remoteQUICMustCompactDelta(t *testing.T, delta remotegrid.PaneDelta) []byte {
	t.Helper()

	payload, err := remotegrid.MarshalCompactPaneDelta(delta)
	if err != nil {
		t.Fatalf("MarshalCompactPaneDelta: %v", err)
	}
	return payload
}

func remoteQUICDatagramIdentities(t *testing.T, payloads [][]byte) []string {
	t.Helper()

	identities := make([]string, 0, len(payloads))
	for _, payload := range payloads {
		var delta remotegrid.PaneDelta
		if err := json.Unmarshal(payload, &delta); err != nil {
			t.Fatalf("datagram JSON: %v", err)
		}
		identities = append(identities, fmt.Sprintf("%d:%d", delta.PaneID, delta.DeltaSequence))
	}
	return identities
}

func assertRemoteQUICTaskReturns(t *testing.T, name string, fn func() error) {
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
		t.Fatalf("%s did not return", name)
	}
}

type remoteQUICTestLiveSource struct {
	mu          sync.Mutex
	current     remoteWorkspacePayload
	subscribers map[*engine.StreamPump]struct{}
}

func newRemoteQUICTestLiveSource(current remoteWorkspacePayload) *remoteQUICTestLiveSource {
	return &remoteQUICTestLiveSource{
		current:     current,
		subscribers: make(map[*engine.StreamPump]struct{}),
	}
}

func (s *remoteQUICTestLiveSource) CurrentPayload(string) (remoteWorkspacePayload, error) {
	return s.current, nil
}

func (s *remoteQUICTestLiveSource) RequestKeyframe(string, int) (remoteWorkspacePayload, error) {
	return s.current, nil
}

func (s *remoteQUICTestLiveSource) RequestKeyframes(string) (remoteWorkspacePayload, error) {
	return remoteWorkspacePayload{Reliable: s.current.Reliable}, nil
}

func (s *remoteQUICTestLiveSource) SendKeys(string, int, []byte) error {
	return nil
}

func (s *remoteQUICTestLiveSource) ResizePane(string, int, int, int) (remoteWorkspacePayload, error) {
	return s.current, nil
}

func (s *remoteQUICTestLiveSource) NewWindow(string) (remoteWorkspacePayload, error) {
	return s.current, nil
}

func (s *remoteQUICTestLiveSource) SelectWindow(string, int) (remoteWorkspacePayload, error) {
	return s.current, nil
}

func (s *remoteQUICTestLiveSource) Subscribe(pump *engine.StreamPump) func() {
	s.mu.Lock()
	s.subscribers[pump] = struct{}{}
	s.mu.Unlock()
	return func() {
		s.mu.Lock()
		delete(s.subscribers, pump)
		s.mu.Unlock()
	}
}

func (s *remoteQUICTestLiveSource) SubscribeKeyframes(workspaceID string, pump *engine.StreamPump) (remoteWorkspacePayload, func(), error) {
	payload, err := s.RequestKeyframes(workspaceID)
	if err != nil {
		return remoteWorkspacePayload{}, func() {}, err
	}
	queueInitialPayload(pump, payload)
	unsubscribe := s.Subscribe(pump)
	return payload, unsubscribe, nil
}

func (s *remoteQUICTestLiveSource) Publish(payload remoteWorkspacePayload) {
	s.mu.Lock()
	subscribers := make([]*engine.StreamPump, 0, len(s.subscribers))
	for subscriber := range s.subscribers {
		subscribers = append(subscribers, subscriber)
	}
	s.mu.Unlock()

	for _, subscriber := range subscribers {
		subscriber.PublishReliable(payload.Reliable)
		subscriber.PublishDatagrams(payload.Datagrams)
	}
}

type remoteQUICSettledKeyframeSource struct {
	mu                sync.Mutex
	initial           remoteWorkspacePayload
	settled           remoteWorkspacePayload
	afterKeyframe     remoteWorkspacePayload
	sent              chan remoteQUICInputTestSend
	requestedKeyframe chan struct{}
	subscribers       map[*engine.StreamPump]struct{}
}

func (s *remoteQUICSettledKeyframeSource) CurrentPayload(string) (remoteWorkspacePayload, error) {
	return s.initial, nil
}

func (s *remoteQUICSettledKeyframeSource) RequestKeyframe(string, int) (remoteWorkspacePayload, error) {
	if s.requestedKeyframe != nil {
		select {
		case s.requestedKeyframe <- struct{}{}:
		default:
		}
	}

	s.mu.Lock()
	payload := s.settled
	afterKeyframe := s.afterKeyframe
	subscribers := make([]*engine.StreamPump, 0, len(s.subscribers))
	for subscriber := range s.subscribers {
		subscribers = append(subscribers, subscriber)
	}
	s.mu.Unlock()

	publishPayloadToSubscribers(afterKeyframe, subscribers)
	return payload, nil
}

func (s *remoteQUICSettledKeyframeSource) RequestKeyframes(string) (remoteWorkspacePayload, error) {
	return s.initial, nil
}

func (s *remoteQUICSettledKeyframeSource) SendKeys(workspaceID string, paneID int, data []byte) error {
	s.sent <- remoteQUICInputTestSend{workspaceID: workspaceID, paneID: paneID, data: append([]byte(nil), data...)}
	return nil
}

func (s *remoteQUICSettledKeyframeSource) ResizePane(string, int, int, int) (remoteWorkspacePayload, error) {
	return s.settled, nil
}

func (s *remoteQUICSettledKeyframeSource) NewWindow(string) (remoteWorkspacePayload, error) {
	return s.settled, nil
}

func (s *remoteQUICSettledKeyframeSource) SelectWindow(string, int) (remoteWorkspacePayload, error) {
	return s.settled, nil
}

func (s *remoteQUICSettledKeyframeSource) Subscribe(pump *engine.StreamPump) func() {
	if pump == nil {
		return func() {}
	}
	s.mu.Lock()
	if s.subscribers == nil {
		s.subscribers = make(map[*engine.StreamPump]struct{})
	}
	s.subscribers[pump] = struct{}{}
	s.mu.Unlock()
	return func() {
		s.mu.Lock()
		delete(s.subscribers, pump)
		s.mu.Unlock()
	}
}

func (s *remoteQUICSettledKeyframeSource) SubscribeKeyframes(workspaceID string, pump *engine.StreamPump) (remoteWorkspacePayload, func(), error) {
	payload, err := s.RequestKeyframes(workspaceID)
	if err != nil {
		return remoteWorkspacePayload{}, func() {}, err
	}
	queueInitialPayload(pump, payload)
	unsubscribe := s.Subscribe(pump)
	return payload, unsubscribe, nil
}

type remoteQUICAttachBarrierSource struct {
	mu        sync.Mutex
	current   remoteWorkspacePayload
	keyframes remoteWorkspacePayload
	events    []string
}

func (s *remoteQUICAttachBarrierSource) CurrentPayload(workspaceID string) (remoteWorkspacePayload, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.events = append(s.events, "current:"+workspaceID)
	return s.current, nil
}

func (s *remoteQUICAttachBarrierSource) RequestKeyframe(workspaceID string, paneID int) (remoteWorkspacePayload, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.events = append(s.events, fmt.Sprintf("requestKeyframe:%s:%d", workspaceID, paneID))
	return s.keyframes, nil
}

func (s *remoteQUICAttachBarrierSource) RequestKeyframes(workspaceID string) (remoteWorkspacePayload, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.events = append(s.events, "requestKeyframes:"+workspaceID)
	return s.keyframes, nil
}

func (s *remoteQUICAttachBarrierSource) SendKeys(string, int, []byte) error {
	return nil
}

func (s *remoteQUICAttachBarrierSource) ResizePane(string, int, int, int) (remoteWorkspacePayload, error) {
	return remoteWorkspacePayload{}, nil
}

func (s *remoteQUICAttachBarrierSource) NewWindow(string) (remoteWorkspacePayload, error) {
	return remoteWorkspacePayload{}, nil
}

func (s *remoteQUICAttachBarrierSource) SelectWindow(string, int) (remoteWorkspacePayload, error) {
	return remoteWorkspacePayload{}, nil
}

func (s *remoteQUICAttachBarrierSource) Subscribe(*engine.StreamPump) func() {
	s.mu.Lock()
	s.events = append(s.events, "subscribe")
	s.mu.Unlock()
	return func() {}
}

func (s *remoteQUICAttachBarrierSource) SubscribeKeyframes(workspaceID string, pump *engine.StreamPump) (remoteWorkspacePayload, func(), error) {
	s.mu.Lock()
	s.events = append(s.events, "requestKeyframes:"+workspaceID)
	payload := s.keyframes
	s.events = append(s.events, "subscribe")
	s.mu.Unlock()
	queueInitialPayload(pump, payload)
	return payload, func() {}, nil
}

func (s *remoteQUICAttachBarrierSource) calls() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.events...)
}

type remoteQUICAttachCutoverSource struct {
	mu          sync.Mutex
	keyframes   remoteWorkspacePayload
	cutover     remoteWorkspacePayload
	subscribers map[*engine.StreamPump]struct{}
}

func (s *remoteQUICAttachCutoverSource) CurrentPayload(string) (remoteWorkspacePayload, error) {
	return s.keyframes, nil
}

func (s *remoteQUICAttachCutoverSource) RequestKeyframe(string, int) (remoteWorkspacePayload, error) {
	return s.keyframes, nil
}

func (s *remoteQUICAttachCutoverSource) RequestKeyframes(string) (remoteWorkspacePayload, error) {
	s.mu.Lock()
	payload := s.keyframes
	cutover := s.cutover
	subscribers := make([]*engine.StreamPump, 0, len(s.subscribers))
	for subscriber := range s.subscribers {
		subscribers = append(subscribers, subscriber)
	}
	s.mu.Unlock()

	publishPayloadToSubscribers(cutover, subscribers)
	return payload, nil
}

func (s *remoteQUICAttachCutoverSource) SendKeys(string, int, []byte) error {
	return nil
}

func (s *remoteQUICAttachCutoverSource) ResizePane(string, int, int, int) (remoteWorkspacePayload, error) {
	return remoteWorkspacePayload{}, nil
}

func (s *remoteQUICAttachCutoverSource) NewWindow(string) (remoteWorkspacePayload, error) {
	return remoteWorkspacePayload{}, nil
}

func (s *remoteQUICAttachCutoverSource) SelectWindow(string, int) (remoteWorkspacePayload, error) {
	return remoteWorkspacePayload{}, nil
}

func (s *remoteQUICAttachCutoverSource) Subscribe(pump *engine.StreamPump) func() {
	s.mu.Lock()
	s.subscribers[pump] = struct{}{}
	s.mu.Unlock()

	return func() {
		s.mu.Lock()
		delete(s.subscribers, pump)
		s.mu.Unlock()
	}
}

func (s *remoteQUICAttachCutoverSource) SubscribeKeyframes(workspaceID string, pump *engine.StreamPump) (remoteWorkspacePayload, func(), error) {
	payload, err := s.RequestKeyframes(workspaceID)
	if err != nil {
		return remoteWorkspacePayload{}, func() {}, err
	}
	queueInitialPayload(pump, payload)
	unsubscribe := s.Subscribe(pump)
	if pump != nil {
		publishPayloadToSubscribers(s.cutover, []*engine.StreamPump{pump})
	}
	return payload, unsubscribe, nil
}

type remoteQUICSubscribeKeyframesErrorSource struct {
	err error
}

func (s remoteQUICSubscribeKeyframesErrorSource) CurrentPayload(string) (remoteWorkspacePayload, error) {
	return remoteWorkspacePayload{}, nil
}

func (s remoteQUICSubscribeKeyframesErrorSource) RequestKeyframe(string, int) (remoteWorkspacePayload, error) {
	return remoteWorkspacePayload{}, nil
}

func (s remoteQUICSubscribeKeyframesErrorSource) RequestKeyframes(string) (remoteWorkspacePayload, error) {
	return remoteWorkspacePayload{}, s.err
}

func (s remoteQUICSubscribeKeyframesErrorSource) SendKeys(string, int, []byte) error {
	return nil
}

func (s remoteQUICSubscribeKeyframesErrorSource) ResizePane(string, int, int, int) (remoteWorkspacePayload, error) {
	return remoteWorkspacePayload{}, nil
}

func (s remoteQUICSubscribeKeyframesErrorSource) NewWindow(string) (remoteWorkspacePayload, error) {
	return remoteWorkspacePayload{}, nil
}

func (s remoteQUICSubscribeKeyframesErrorSource) SelectWindow(string, int) (remoteWorkspacePayload, error) {
	return remoteWorkspacePayload{}, nil
}

func (s remoteQUICSubscribeKeyframesErrorSource) Subscribe(*engine.StreamPump) func() {
	return func() {}
}

func (s remoteQUICSubscribeKeyframesErrorSource) SubscribeKeyframes(workspaceID string, pump *engine.StreamPump) (remoteWorkspacePayload, func(), error) {
	payload, err := s.RequestKeyframes(workspaceID)
	if err != nil {
		return remoteWorkspacePayload{}, func() {}, err
	}
	queueInitialPayload(pump, payload)
	unsubscribe := s.Subscribe(pump)
	return payload, unsubscribe, nil
}

type remoteQUICReconnectProbeSource struct {
	mu          sync.Mutex
	current     remoteWorkspacePayload
	marker      string
	events      []string
	subscribers map[*engine.StreamPump]struct{}
}

func newRemoteQUICReconnectProbeSource(current remoteWorkspacePayload, marker string) *remoteQUICReconnectProbeSource {
	return &remoteQUICReconnectProbeSource{
		current:     current,
		marker:      marker,
		subscribers: make(map[*engine.StreamPump]struct{}),
	}
}

func (s *remoteQUICReconnectProbeSource) CurrentPayload(workspaceID string) (remoteWorkspacePayload, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.events = append(s.events, "current:"+workspaceID)
	return s.current, nil
}

func (s *remoteQUICReconnectProbeSource) RequestKeyframe(workspaceID string, paneID int) (remoteWorkspacePayload, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.events = append(s.events, fmt.Sprintf("requestKeyframe:%s:%d", workspaceID, paneID))
	return remoteWorkspacePayload{Reliable: s.current.Reliable}, nil
}

func (s *remoteQUICReconnectProbeSource) RequestKeyframes(workspaceID string) (remoteWorkspacePayload, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.events = append(s.events, "requestKeyframes:"+workspaceID)
	return remoteWorkspacePayload{Reliable: s.current.Reliable}, nil
}

func (s *remoteQUICReconnectProbeSource) SendKeys(workspaceID string, paneID int, data []byte) error {
	if !bytes.Contains(data, []byte(s.marker)) {
		return fmt.Errorf("sendKeys data = %q, want marker %q", data, s.marker)
	}
	messages, err := buildSmokeWorkspaceMessages(workspaceID, s.marker)
	if err != nil {
		return err
	}
	payload := remoteWorkspacePayload{
		Reliable: messages,
		Datagrams: []remotegrid.PaneDelta{{
			WorkspaceID:    workspaceID,
			PaneID:         paneID,
			PaneGeneration: 1,
			BaseKeyframeID: 1,
			DeltaSequence:  99,
			RowUpdates: []remotegrid.RowUpdate{{
				RowIndex:   0,
				RowVersion: 100,
				Update:     remotegrid.FullRow(sourceCells(s.marker)),
			}},
		}},
	}

	s.mu.Lock()
	s.current = payload
	s.events = append(s.events, fmt.Sprintf("sendKeys:%s:%d", workspaceID, paneID))
	subscribers := make([]*engine.StreamPump, 0, len(s.subscribers))
	for subscriber := range s.subscribers {
		subscribers = append(subscribers, subscriber)
	}
	s.mu.Unlock()

	publishPayloadToSubscribers(remoteWorkspacePayload{Datagrams: payload.Datagrams}, subscribers)
	return nil
}

func (s *remoteQUICReconnectProbeSource) ResizePane(string, int, int, int) (remoteWorkspacePayload, error) {
	return remoteWorkspacePayload{}, nil
}

func (s *remoteQUICReconnectProbeSource) NewWindow(string) (remoteWorkspacePayload, error) {
	return remoteWorkspacePayload{}, nil
}

func (s *remoteQUICReconnectProbeSource) SelectWindow(string, int) (remoteWorkspacePayload, error) {
	return remoteWorkspacePayload{}, nil
}

func (s *remoteQUICReconnectProbeSource) Subscribe(pump *engine.StreamPump) func() {
	s.mu.Lock()
	s.events = append(s.events, "subscribe")
	s.subscribers[pump] = struct{}{}
	s.mu.Unlock()
	return func() {
		s.mu.Lock()
		s.events = append(s.events, "unsubscribe")
		delete(s.subscribers, pump)
		s.mu.Unlock()
	}
}

func (s *remoteQUICReconnectProbeSource) SubscribeKeyframes(workspaceID string, pump *engine.StreamPump) (remoteWorkspacePayload, func(), error) {
	payload, err := s.RequestKeyframes(workspaceID)
	if err != nil {
		return remoteWorkspacePayload{}, func() {}, err
	}
	queueInitialPayload(pump, payload)
	unsubscribe := s.Subscribe(pump)
	return payload, unsubscribe, nil
}

func (s *remoteQUICReconnectProbeSource) calls() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.events...)
}

func (s *remoteQUICReconnectProbeSource) countCalls(want string) int {
	count := 0
	for _, call := range s.calls() {
		if call == want {
			count++
		}
	}
	return count
}

func remoteQUICTestSubsequence(got []string, want []string) bool {
	index := 0
	for _, call := range got {
		if index < len(want) && call == want[index] {
			index++
		}
	}
	return index == len(want)
}

type remoteQUICInputTestSource struct {
	sent             []remoteQUICInputTestSend
	resized          []remoteQUICResizeTestRequest
	newWindows       []string
	selectedWindows  []remoteQUICSelectWindowTestRequest
	newWindowPayload remoteWorkspacePayload
}

type remoteQUICInputTestSend struct {
	workspaceID string
	paneID      int
	data        []byte
}

type remoteQUICResizeTestRequest struct {
	workspaceID string
	paneID      int
	columns     int
	rows        int
}

type remoteQUICSelectWindowTestRequest struct {
	workspaceID string
	windowID    int
}

func (s *remoteQUICInputTestSource) CurrentPayload(string) (remoteWorkspacePayload, error) {
	return remoteWorkspacePayload{}, nil
}

func (s *remoteQUICInputTestSource) RequestKeyframe(string, int) (remoteWorkspacePayload, error) {
	return remoteWorkspacePayload{}, nil
}

func (s *remoteQUICInputTestSource) RequestKeyframes(string) (remoteWorkspacePayload, error) {
	return remoteWorkspacePayload{}, nil
}

func (s *remoteQUICInputTestSource) SendKeys(workspaceID string, paneID int, data []byte) error {
	s.sent = append(s.sent, remoteQUICInputTestSend{
		workspaceID: workspaceID,
		paneID:      paneID,
		data:        append([]byte(nil), data...),
	})
	return nil
}

func (s *remoteQUICInputTestSource) ResizePane(workspaceID string, paneID int, columns int, rows int) (remoteWorkspacePayload, error) {
	s.resized = append(s.resized, remoteQUICResizeTestRequest{
		workspaceID: workspaceID,
		paneID:      paneID,
		columns:     columns,
		rows:        rows,
	})
	return remoteWorkspacePayload{}, nil
}

func (s *remoteQUICInputTestSource) NewWindow(workspaceID string) (remoteWorkspacePayload, error) {
	s.newWindows = append(s.newWindows, workspaceID)
	return s.newWindowPayload, nil
}

func (s *remoteQUICInputTestSource) SelectWindow(workspaceID string, windowID int) (remoteWorkspacePayload, error) {
	s.selectedWindows = append(s.selectedWindows, remoteQUICSelectWindowTestRequest{
		workspaceID: workspaceID,
		windowID:    windowID,
	})
	return remoteWorkspacePayload{}, nil
}

func (s *remoteQUICInputTestSource) Subscribe(*engine.StreamPump) func() {
	return func() {}
}

func (s *remoteQUICInputTestSource) SubscribeKeyframes(workspaceID string, pump *engine.StreamPump) (remoteWorkspacePayload, func(), error) {
	payload, err := s.RequestKeyframes(workspaceID)
	if err != nil {
		return remoteWorkspacePayload{}, func() {}, err
	}
	queueInitialPayload(pump, payload)
	unsubscribe := s.Subscribe(pump)
	return payload, unsubscribe, nil
}

type remoteQUICStreamRequestTestSource struct {
	payload remoteWorkspacePayload
	sent    chan remoteQUICInputTestSend
}

func newRemoteQUICStreamRequestTestSource(payload remoteWorkspacePayload) *remoteQUICStreamRequestTestSource {
	return &remoteQUICStreamRequestTestSource{
		payload: payload,
		sent:    make(chan remoteQUICInputTestSend, 1),
	}
}

func (s *remoteQUICStreamRequestTestSource) CurrentPayload(string) (remoteWorkspacePayload, error) {
	return s.payload, nil
}

func (s *remoteQUICStreamRequestTestSource) RequestKeyframe(string, int) (remoteWorkspacePayload, error) {
	return s.payload, nil
}

func (s *remoteQUICStreamRequestTestSource) RequestKeyframes(string) (remoteWorkspacePayload, error) {
	return s.payload, nil
}

func (s *remoteQUICStreamRequestTestSource) SendKeys(workspaceID string, paneID int, data []byte) error {
	s.sent <- remoteQUICInputTestSend{workspaceID: workspaceID, paneID: paneID, data: append([]byte(nil), data...)}
	return nil
}

func (s *remoteQUICStreamRequestTestSource) ResizePane(string, int, int, int) (remoteWorkspacePayload, error) {
	return s.payload, nil
}

func (s *remoteQUICStreamRequestTestSource) NewWindow(string) (remoteWorkspacePayload, error) {
	return s.payload, nil
}

func (s *remoteQUICStreamRequestTestSource) SelectWindow(string, int) (remoteWorkspacePayload, error) {
	return s.payload, nil
}

func (s *remoteQUICStreamRequestTestSource) Subscribe(*engine.StreamPump) func() {
	return func() {}
}

func (s *remoteQUICStreamRequestTestSource) SubscribeKeyframes(_ string, pump *engine.StreamPump) (remoteWorkspacePayload, func(), error) {
	queueInitialPayload(pump, s.payload)
	return s.payload, func() {}, nil
}

type remoteQUICTestClientLifecycle struct {
	mu       sync.Mutex
	attached int
	detached int
	done     chan struct{}
}

func (l *remoteQUICTestClientLifecycle) ClientAttached() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.attached++
	return nil
}

func (l *remoteQUICTestClientLifecycle) ClientDetached() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.detached++
	if l.done != nil {
		close(l.done)
		l.done = nil
	}
	return nil
}

func (l *remoteQUICTestClientLifecycle) counts() (int, int) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.attached, l.detached
}

func (l *remoteQUICTestClientLifecycle) waitForDetached(t *testing.T, want int) {
	t.Helper()
	l.mu.Lock()
	if l.detached >= want {
		l.mu.Unlock()
		return
	}
	l.done = make(chan struct{})
	done := l.done
	l.mu.Unlock()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		_, detached := l.counts()
		t.Fatalf("detached callbacks = %d, want %d", detached, want)
	}
}
