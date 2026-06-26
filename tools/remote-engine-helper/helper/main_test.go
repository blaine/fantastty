package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	"fantastty/remote-engine-helper/internal/keyring"
	"fantastty/remote-engine-helper/internal/registry"
)

func TestMain(m *testing.M) {
	tmuxCommandTimeout = 10 * time.Second
	os.Exit(m.Run())
}

func TestVersionLine(t *testing.T) {
	got := versionLine("abc123", "amd64")
	want := "fantastty-helper version=abc123 arch=amd64"
	if got != want {
		t.Fatalf("versionLine = %q, want %q", got, want)
	}
}

func TestParseLaunchOrResumeArgsUsesPositionalWorkspace(t *testing.T) {
	got, err := parseLaunchOrResumeArgs([]string{"workspace-a", "--ttl", "8h", "--key-ttl", "30s"})
	if err != nil {
		t.Fatalf("parseLaunchOrResumeArgs returned error: %v", err)
	}
	if got.workspace != "workspace-a" {
		t.Fatalf("workspace = %q, want workspace-a", got.workspace)
	}
	if got.ttl != 8*time.Hour {
		t.Fatalf("ttl = %s, want 8h", got.ttl)
	}
	if got.keyTTL != 30*time.Second {
		t.Fatalf("keyTTL = %s, want 30s", got.keyTTL)
	}
}

func TestParseLaunchOrResumeArgsAcceptsExternalTmuxSession(t *testing.T) {
	got, err := parseLaunchOrResumeArgs([]string{"workspace-a", "--tmux-session", "0", "--ttl", "8h", "--key-ttl", "30s"})
	if err != nil {
		t.Fatalf("parseLaunchOrResumeArgs returned error: %v", err)
	}
	if got.workspace != "workspace-a" {
		t.Fatalf("workspace = %q, want workspace-a", got.workspace)
	}
	if got.tmuxSession != "0" {
		t.Fatalf("tmuxSession = %q, want 0", got.tmuxSession)
	}
}

func TestParseLaunchOrResumeArgsRejectsWorkspaceFlag(t *testing.T) {
	_, err := parseLaunchOrResumeArgs([]string{"--workspace", "workspace-a", "--ttl", "8h", "--key-ttl", "30s"})
	if err == nil || !strings.Contains(err.Error(), "unknown launch-or-resume flag: --workspace") {
		t.Fatalf("parseLaunchOrResumeArgs error = %v, want unknown --workspace flag", err)
	}
}

func TestParseLaunchOrResumeArgsRequiresWorkspaceTTLAndKeyTTL(t *testing.T) {
	tests := map[string][]string{
		"workspace": {"--ttl", "8h", "--key-ttl", "30s"},
		"ttl":       {"workspace-a", "--key-ttl", "30s"},
		"key ttl":   {"workspace-a", "--ttl", "8h"},
	}

	for name, args := range tests {
		t.Run(name, func(t *testing.T) {
			if _, err := parseLaunchOrResumeArgs(args); err == nil {
				t.Fatalf("parseLaunchOrResumeArgs(%v) succeeded, want error", args)
			}
		})
	}
}

func TestAuthenticatedClientIdleLifecycleExpiresAfterLastDetach(t *testing.T) {
	lifecycle := newAuthenticatedClientIdleLifecycle(20 * time.Millisecond)

	lifecycle.ClientAttached()
	assertNoIdleExpiry(t, lifecycle.Done(), 50*time.Millisecond)
	lifecycle.ClientDetached()
	assertIdleExpiry(t, lifecycle.Done(), 2*time.Second)
}

func TestAuthenticatedClientIdleLifecycleWaitsForAllClientsToDetach(t *testing.T) {
	lifecycle := newAuthenticatedClientIdleLifecycle(20 * time.Millisecond)

	lifecycle.ClientAttached()
	lifecycle.ClientAttached()
	lifecycle.ClientDetached()
	assertNoIdleExpiry(t, lifecycle.Done(), 50*time.Millisecond)
	lifecycle.ClientDetached()
	assertIdleExpiry(t, lifecycle.Done(), 2*time.Second)
}

func TestBootstrapLineExactFields(t *testing.T) {
	expires := time.Date(2026, 6, 19, 23, 4, 5, 0, time.UTC)
	result := registry.LaunchResult{
		Port:           34567,
		Session:        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		Key:            "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
		KeyExpires:     expires,
		PID:            12345,
		QUICAddr:       "127.0.0.1:45678",
		QUICCertSHA256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
	}

	got := bootstrapLine(result, "abc123", runtime.GOARCH)
	want := fmt.Sprintf(
		"FANTASTTY_REMOTE port=34567 session=%s key=%s expires=2026-06-19T23:04:05Z helper_pid=12345 version=abc123 arch=%s quic_addr=127.0.0.1:45678 quic_cert_sha256=%s quic_alpn=fantastty-remote-engine-v1",
		result.Session,
		result.Key,
		runtime.GOARCH,
		result.QUICCertSHA256,
	)
	if got != want {
		t.Fatalf("bootstrapLine = %q, want %q", got, want)
	}
}

func TestTmuxWorkspaceSocketPathIsStableAcrossHelperSessions(t *testing.T) {
	root := t.TempDir()
	first := tmuxWorkspaceSocketPath(root, "workspace-a", "session-a")
	second := tmuxWorkspaceSocketPath(root, "workspace-a", "session-b")
	other := tmuxWorkspaceSocketPath(root, "workspace-b", "session-b")

	if first != second {
		t.Fatalf("socket path changed across helper sessions: %q != %q", first, second)
	}
	if first == other {
		t.Fatalf("different workspaces shared tmux socket path: %q", first)
	}
	if filepath.Dir(first) != root {
		t.Fatalf("socket path dir = %q, want %q", filepath.Dir(first), root)
	}
}

func TestTmuxSendKeysLeavesPrefixWindowNavigationAsPaneInput(t *testing.T) {
	command, err := tmuxSendKeysCommand(7, []byte{0x02, 'n'})
	if err != nil {
		t.Fatalf("tmuxSendKeysCommand error = %v", err)
	}
	if command != "send-keys -t %7 -H 02 6e" {
		t.Fatalf("tmux command = %q, want literal pane input", command)
	}
}

func TestTmuxSendKeysLeavesPrefixPaneNavigationAsPaneInput(t *testing.T) {
	command, err := tmuxSendKeysCommand(7, []byte{0x02, 'o'})
	if err != nil {
		t.Fatalf("tmuxSendKeysCommand error = %v", err)
	}
	if command != "send-keys -t %7 -H 02 6f" {
		t.Fatalf("tmux command = %q, want literal pane input", command)
	}
}

func TestTmuxSendKeysLeavesPrefixNumberedWindowNavigationAsPaneInput(t *testing.T) {
	command, err := tmuxSendKeysCommand(7, []byte{0x02, '1'})
	if err != nil {
		t.Fatalf("tmuxSendKeysCommand error = %v", err)
	}
	if command != "send-keys -t %7 -H 02 31" {
		t.Fatalf("tmux command = %q, want literal pane input", command)
	}
}

func TestStartDaemonReportsMissingTmuxBeforeWaitingForReadyFile(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatalf("chmod runtime dir: %v", err)
	}
	t.Setenv("PATH", t.TempDir())

	_, err := startDaemon(root, registry.StartRequest{
		Workspace: "workspace-a",
		Session:   strings.Repeat("a", 64),
		Expires:   time.Now().Add(time.Minute),
	})
	if err == nil {
		t.Fatal("startDaemon succeeded with tmux missing, want error")
	}
	if !strings.Contains(err.Error(), "tmux") {
		t.Fatalf("startDaemon error = %v, want tmux detail", err)
	}
	if strings.Contains(err.Error(), "daemon did not become ready") {
		t.Fatalf("startDaemon error = %v, want preflight failure before ready-file timeout", err)
	}
}

func TestShutdownKillsPrivateTmuxWorkspaceSession(t *testing.T) {
	root, err := os.MkdirTemp("/tmp", "fantastty-shutdown-")
	if err != nil {
		t.Fatalf("temp runtime dir: %v", err)
	}
	t.Cleanup(func() {
		_ = os.RemoveAll(root)
	})
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatalf("chmod runtime dir: %v", err)
	}
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)

	type tmuxInvocation struct {
		timeout    time.Duration
		socketPath string
		args       []string
	}
	var invocations []tmuxInvocation
	previousRunTmuxCommand := runTmuxCommand
	runTmuxCommand = func(timeout time.Duration, socketPath string, args ...string) ([]byte, error) {
		invocations = append(invocations, tmuxInvocation{
			timeout:    timeout,
			socketPath: socketPath,
			args:       append([]string(nil), args...),
		})
		return nil, nil
	}
	t.Cleanup(func() {
		runTmuxCommand = previousRunTmuxCommand
	})

	store, err := registry.NewStore(root, registry.Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	session := strings.Repeat("a", 64)
	privateSocket := tmuxWorkspaceSocketPath(root, "workspace-a", session)
	if err := os.WriteFile(privateSocket, []byte("stale private tmux socket"), 0o600); err != nil {
		t.Fatalf("write private tmux socket placeholder: %v", err)
	}

	manager := registry.NewManager(store)
	if err := manager.RecordSession(registry.SessionRecord{
		Workspace: "workspace-a",
		Session:   session,
		Expires:   time.Now().Add(time.Minute),
	}); err != nil {
		t.Fatalf("RecordSession: %v", err)
	}

	if err := shutdown([]string{"--session", session}); err != nil {
		t.Fatalf("shutdown: %v", err)
	}

	if len(invocations) != 1 {
		t.Fatalf("tmux invocations = %d, want 1", len(invocations))
	}
	invocation := invocations[0]
	if invocation.timeout != 2*time.Second {
		t.Fatalf("tmux timeout = %s, want 2s", invocation.timeout)
	}
	if invocation.socketPath != tmuxWorkspaceSocketPath(root, "workspace-a", session) {
		t.Fatalf("tmux socket = %q, want private workspace socket", invocation.socketPath)
	}
	if !containsArgSequence(invocation.args, "kill-session", "-t", remoteTmuxSessionName("workspace-a")) {
		t.Fatalf("tmux args = %q, want kill-session for private workspace session", invocation.args)
	}
	if _, err := os.Lstat(privateSocket); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("private tmux socket survived shutdown: %v", err)
	}
}

func TestShutdownKeepsPrivateWorkspaceReachableWhenTmuxKillFails(t *testing.T) {
	root, err := os.MkdirTemp("/tmp", "fantastty-shutdown-")
	if err != nil {
		t.Fatalf("temp runtime dir: %v", err)
	}
	t.Cleanup(func() {
		_ = os.RemoveAll(root)
	})
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatalf("chmod runtime dir: %v", err)
	}
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)

	previousRunTmuxCommand := runTmuxCommand
	runTmuxCommand = func(timeout time.Duration, socketPath string, args ...string) ([]byte, error) {
		if containsArgSequence(args, "kill-session", "-t", remoteTmuxSessionName("workspace-a")) {
			return []byte("session is still live"), errors.New("kill failed")
		}
		if containsArgSequence(args, "has-session", "-t", remoteTmuxSessionName("workspace-a")) {
			return nil, nil
		}
		return nil, nil
	}
	t.Cleanup(func() {
		runTmuxCommand = previousRunTmuxCommand
	})

	store, err := registry.NewStore(root, registry.Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	session := strings.Repeat("b", 64)
	privateSocket := tmuxWorkspaceSocketPath(root, "workspace-a", session)
	if err := os.WriteFile(privateSocket, []byte("private tmux socket"), 0o600); err != nil {
		t.Fatalf("write private tmux socket placeholder: %v", err)
	}
	manager := registry.NewManager(store)
	if err := manager.RecordSession(registry.SessionRecord{
		Workspace: "workspace-a",
		Session:   session,
		Expires:   time.Now().Add(time.Minute),
	}); err != nil {
		t.Fatalf("RecordSession: %v", err)
	}

	err = shutdown([]string{"--session", session})
	if err == nil || !strings.Contains(err.Error(), "kill failed") {
		t.Fatalf("shutdown error = %v, want kill failure", err)
	}
	if _, err := manager.FindSession(session); err != nil {
		t.Fatalf("registry session after failed shutdown: %v", err)
	}
	if _, err := os.Lstat(privateSocket); err != nil {
		t.Fatalf("private tmux socket after failed shutdown: %v", err)
	}
}

func TestCleanupDryRunReportsStalePrivateWorkspaceWithoutRemovingIt(t *testing.T) {
	root := makeRuntimeRoot(t, "fantastty-cleanup-")
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)
	session := strings.Repeat("c", 64)
	privateSocket := tmuxWorkspaceSocketPath(root, "workspace-a", session)
	if err := os.WriteFile(privateSocket, []byte("stale private tmux socket"), 0o600); err != nil {
		t.Fatalf("write private tmux socket placeholder: %v", err)
	}
	recordCleanupSession(t, root, registry.SessionRecord{
		Workspace: "workspace-a",
		Session:   session,
		PID:       999999,
		Expires:   time.Now().Add(-time.Minute),
	})

	var output strings.Builder
	if err := cleanupDryRun([]string{}, &output); err != nil {
		t.Fatalf("cleanupDryRun: %v", err)
	}

	got := output.String()
	if !strings.Contains(got, "action=would-remove") ||
		!strings.Contains(got, "workspace=workspace-a") ||
		!strings.Contains(got, "target="+privateSocket) {
		t.Fatalf("cleanup dry-run output = %q, want removable private workspace socket", got)
	}
	if _, err := os.Lstat(privateSocket); err != nil {
		t.Fatalf("dry-run removed private tmux socket: %v", err)
	}
}

func TestCleanupDryRunRefusesUnsafePrivateWorkspaceSymlink(t *testing.T) {
	root := makeRuntimeRoot(t, "fantastty-cleanup-")
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)
	session := strings.Repeat("d", 64)
	privateSocket := tmuxWorkspaceSocketPath(root, "workspace-a", session)
	target := filepath.Join(root, "outside.sock")
	if err := os.WriteFile(target, []byte("not a socket"), 0o600); err != nil {
		t.Fatalf("write symlink target: %v", err)
	}
	if err := os.Symlink(target, privateSocket); err != nil {
		t.Fatalf("symlink private tmux socket: %v", err)
	}
	recordCleanupSession(t, root, registry.SessionRecord{
		Workspace: "workspace-a",
		Session:   session,
		PID:       999999,
		Expires:   time.Now().Add(-time.Minute),
	})

	var output strings.Builder
	if err := cleanupDryRun([]string{}, &output); err != nil {
		t.Fatalf("cleanupDryRun: %v", err)
	}

	got := output.String()
	if !strings.Contains(got, "action=refuse-unsafe") ||
		!strings.Contains(got, "reason=symlink") ||
		!strings.Contains(got, "target="+privateSocket) {
		t.Fatalf("cleanup dry-run output = %q, want unsafe symlink refusal", got)
	}
	if _, err := os.Lstat(privateSocket); err != nil {
		t.Fatalf("dry-run removed symlink: %v", err)
	}
}

func TestCleanupDryRunPreservesLivePrivateSession(t *testing.T) {
	root := makeRuntimeRoot(t, "fantastty-cleanup-")
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)
	session := strings.Repeat("e", 64)
	privateSocket := tmuxWorkspaceSocketPath(root, "workspace-a", session)
	if err := os.WriteFile(privateSocket, []byte("live private tmux socket"), 0o600); err != nil {
		t.Fatalf("write private tmux socket placeholder: %v", err)
	}
	recordCleanupSession(t, root, registry.SessionRecord{
		Workspace: "workspace-a",
		Session:   session,
		PID:       os.Getpid(),
		Expires:   time.Now().Add(time.Minute),
	})

	var output strings.Builder
	if err := cleanupDryRun([]string{}, &output); err != nil {
		t.Fatalf("cleanupDryRun: %v", err)
	}

	got := output.String()
	if !strings.Contains(got, "action=preserve-live") ||
		!strings.Contains(got, "workspace=workspace-a") ||
		!strings.Contains(got, "target="+privateSocket) {
		t.Fatalf("cleanup dry-run output = %q, want live session preservation", got)
	}
	if _, err := os.Lstat(privateSocket); err != nil {
		t.Fatalf("dry-run removed live private tmux socket: %v", err)
	}
}

func TestCleanupDryRunRefusesUnsafePrivateWorkspacePermissions(t *testing.T) {
	root := makeRuntimeRoot(t, "fantastty-cleanup-")
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)
	session := strings.Repeat("f", 64)
	privateSocket := tmuxWorkspaceSocketPath(root, "workspace-a", session)
	if err := os.WriteFile(privateSocket, []byte("group-readable private tmux socket"), 0o644); err != nil {
		t.Fatalf("write private tmux socket placeholder: %v", err)
	}
	recordCleanupSession(t, root, registry.SessionRecord{
		Workspace: "workspace-a",
		Session:   session,
		PID:       999999,
		Expires:   time.Now().Add(-time.Minute),
	})

	var output strings.Builder
	if err := cleanupDryRun([]string{}, &output); err != nil {
		t.Fatalf("cleanupDryRun: %v", err)
	}

	got := output.String()
	if !strings.Contains(got, "action=refuse-unsafe") ||
		!strings.Contains(got, "reason=permissions") ||
		!strings.Contains(got, "target="+privateSocket) {
		t.Fatalf("cleanup dry-run output = %q, want unsafe permission refusal", got)
	}
	if _, err := os.Lstat(privateSocket); err != nil {
		t.Fatalf("dry-run removed unsafe private tmux socket: %v", err)
	}
}

func TestCleanupDryRunIgnoresUnregisteredNonFantasttySocket(t *testing.T) {
	root := makeRuntimeRoot(t, "fantastty-cleanup-")
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)
	otherSocket := filepath.Join(root, "tmux-default.sock")
	if err := os.WriteFile(otherSocket, []byte("not managed by Fantastty registry"), 0o600); err != nil {
		t.Fatalf("write non-Fantastty socket: %v", err)
	}

	var output strings.Builder
	if err := cleanupDryRun([]string{}, &output); err != nil {
		t.Fatalf("cleanupDryRun: %v", err)
	}

	if got := output.String(); strings.Contains(got, otherSocket) {
		t.Fatalf("cleanup dry-run mentioned non-Fantastty socket %q in %q", otherSocket, got)
	}
	if _, err := os.Lstat(otherSocket); err != nil {
		t.Fatalf("dry-run removed non-Fantastty socket: %v", err)
	}
}

func assertNoIdleExpiry(t *testing.T, done <-chan struct{}, duration time.Duration) {
	t.Helper()
	select {
	case <-done:
		t.Fatalf("idle lifecycle expired within %s", duration)
	case <-time.After(duration):
	}
}

func assertIdleExpiry(t *testing.T, done <-chan struct{}, timeout time.Duration) {
	t.Helper()
	select {
	case <-done:
	case <-time.After(timeout):
		t.Fatalf("idle lifecycle did not expire within %s", timeout)
	}
}

func TestProbeControlSocketRejectsMismatchedPort(t *testing.T) {
	socketPath := fmt.Sprintf("%s/fh-%d.sock", os.TempDir(), time.Now().UnixNano())
	defer os.Remove(socketPath)
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("listen unix: %v", err)
	}
	defer listener.Close()

	served := make(chan struct{})
	go func() {
		defer close(served)
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		_, _ = bufio.NewReader(conn).ReadString('\n')
		fmt.Fprintln(conn, "ok port=3333 pid=4242")
	}()

	record := registry.SessionRecord{
		Session:    "session-a",
		SocketPath: socketPath,
		Port:       4444,
		PID:        4242,
	}
	err = probeControlSocket(record)
	<-served
	if err == nil || !strings.Contains(err.Error(), "control socket port mismatch") {
		t.Fatalf("probeControlSocket error = %v, want port mismatch", err)
	}
}

func TestProbeUDPHealthUsesAdvertisedPort(t *testing.T) {
	conn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 0})
	if err != nil {
		t.Fatalf("listen udp: %v", err)
	}
	defer conn.Close()

	served := make(chan struct{})
	go func() {
		defer close(served)
		buf := make([]byte, 256)
		_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		n, addr, err := conn.ReadFromUDP(buf)
		if err != nil {
			t.Errorf("ReadFromUDP: %v", err)
			return
		}
		if got := strings.TrimSpace(string(buf[:n])); got != "health session-a" {
			t.Errorf("UDP request = %q, want health session-a", got)
			return
		}
		_, _ = conn.WriteToUDP([]byte("ok\n"), addr)
	}()

	port := conn.LocalAddr().(*net.UDPAddr).Port
	if err := probeUDPHealth("session-a", port); err != nil {
		t.Fatalf("probeUDPHealth: %v", err)
	}
	<-served
}

func TestAttachProbeBurnsKeyWhenUDPHealthFails(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatalf("chmod runtime dir: %v", err)
	}
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)

	socketPath := fmt.Sprintf("%s/fh-%d.sock", os.TempDir(), time.Now().UnixNano())
	defer os.Remove(socketPath)
	unixListener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("listen unix: %v", err)
	}
	defer unixListener.Close()

	udpConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 0})
	if err != nil {
		t.Fatalf("listen udp: %v", err)
	}
	defer udpConn.Close()
	port := udpConn.LocalAddr().(*net.UDPAddr).Port

	store, err := registry.NewStore(root, registry.Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := registry.NewManager(store)
	result, err := manager.LaunchOrResume("workspace-a", time.Minute, time.Minute, func(registry.StartRequest) (registry.StartResult, error) {
		return registry.StartResult{PID: os.Getpid(), Port: port, SocketPath: socketPath, TmuxSmoke: true}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume: %v", err)
	}

	controlServed := make(chan struct{})
	go func() {
		defer close(controlServed)
		conn, err := unixListener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		_, _ = bufio.NewReader(conn).ReadString('\n')
		fmt.Fprintf(conn, "ok port=%d pid=%d\n", port, os.Getpid())
	}()

	udpServed := make(chan struct{})
	go func() {
		defer close(udpServed)
		buf := make([]byte, 256)
		_ = udpConn.SetReadDeadline(time.Now().Add(2 * time.Second))
		n, addr, err := udpConn.ReadFromUDP(buf)
		if err != nil {
			t.Errorf("ReadFromUDP: %v", err)
			return
		}
		if got := strings.TrimSpace(string(buf[:n])); got != "health "+result.Session {
			t.Errorf("UDP request = %q, want health %s", got, result.Session)
			return
		}
		_, _ = udpConn.WriteToUDP([]byte("no\n"), addr)
	}()

	err = attachProbe([]string{"--session", result.Session, "--key", result.Key})
	<-controlServed
	<-udpServed
	if err == nil || !strings.Contains(err.Error(), "udp health probe rejected") {
		t.Fatalf("attachProbe error = %v, want UDP health failure", err)
	}
	if _, err := manager.ConsumeKey(result.Session, result.Key); !errors.Is(err, keyring.ErrInvalidKey) {
		t.Fatalf("key survived failed UDP attach probe: %v", err)
	}
}

func TestMessageProbeBurnsKeyChecksHealthAndPrintsWorkspaceMessages(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatalf("chmod runtime dir: %v", err)
	}
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)

	socketPath := fmt.Sprintf("%s/fh-%d.sock", os.TempDir(), time.Now().UnixNano())
	defer os.Remove(socketPath)
	unixListener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("listen unix: %v", err)
	}
	defer unixListener.Close()
	if listener, ok := unixListener.(*net.UnixListener); ok {
		if err := listener.SetDeadline(time.Now().Add(2 * time.Second)); err != nil {
			t.Fatalf("SetDeadline: %v", err)
		}
	}

	udpConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 0})
	if err != nil {
		t.Fatalf("listen udp: %v", err)
	}
	defer udpConn.Close()
	port := udpConn.LocalAddr().(*net.UDPAddr).Port

	store, err := registry.NewStore(root, registry.Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := registry.NewManager(store)
	result, err := manager.LaunchOrResume("workspace-a", time.Minute, time.Minute, func(registry.StartRequest) (registry.StartResult, error) {
		return registry.StartResult{PID: os.Getpid(), Port: port, SocketPath: socketPath, TmuxSmoke: true}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume: %v", err)
	}

	messages, err := buildSmokeWorkspaceMessages("workspace-a", "fantastty-remote-grid-smoke-"+shortID(result.Session))
	if err != nil {
		t.Fatalf("buildSmokeWorkspaceMessages: %v", err)
	}
	expectedOutput, err := marshalWorkspaceMessageLines(messages)
	if err != nil {
		t.Fatalf("marshalWorkspaceMessageLines: %v", err)
	}

	controlDone := make(chan []string, 1)
	go func() {
		var commands []string
		defer func() {
			controlDone <- commands
		}()
		for len(commands) < 2 {
			conn, err := unixListener.Accept()
			if err != nil {
				return
			}
			func() {
				defer conn.Close()
				line, err := bufio.NewReader(conn).ReadString('\n')
				if err != nil {
					return
				}
				command := strings.TrimSpace(line)
				commands = append(commands, command)
				switch command {
				case "health " + result.Session:
					fmt.Fprintf(conn, "ok port=%d pid=%d\n", port, os.Getpid())
				case "workspace-messages " + result.Session:
					_, _ = conn.Write(expectedOutput)
				default:
					fmt.Fprintln(conn, "error")
				}
			}()
		}
	}()

	udpServed := make(chan struct{})
	go serveOneUDPHealth(t, udpConn, result.Session, udpServed)

	stdout := captureStdout(t, func() error {
		return messageProbe([]string{"--session", result.Session, "--key", result.Key})
	})
	<-udpServed
	commands := <-controlDone
	if !equalStrings(commands, []string{"health " + result.Session, "workspace-messages " + result.Session}) {
		t.Fatalf("control commands = %v, want health then workspace messages", commands)
	}
	if stdout != string(expectedOutput) {
		t.Fatalf("messageProbe stdout = %q, want %q", stdout, string(expectedOutput))
	}
	assertWorkspaceMessageCases(t, stdout, "workspace-a")
	if _, err := manager.ConsumeKey(result.Session, result.Key); !errors.Is(err, keyring.ErrInvalidKey) {
		t.Fatalf("key survived message probe: %v", err)
	}
}

func TestMessageProbeWrongSessionBurnsKey(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatalf("chmod runtime dir: %v", err)
	}
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)

	store, err := registry.NewStore(root, registry.Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := registry.NewManager(store)
	sessionA, err := manager.LaunchOrResume("workspace-a", time.Minute, time.Minute, func(registry.StartRequest) (registry.StartResult, error) {
		return registry.StartResult{PID: os.Getpid(), Port: 1, SocketPath: "/tmp/fantastty-message-a.sock"}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume A: %v", err)
	}
	sessionB, err := manager.LaunchOrResume("workspace-b", time.Minute, time.Minute, func(registry.StartRequest) (registry.StartResult, error) {
		return registry.StartResult{PID: os.Getpid(), Port: 2, SocketPath: "/tmp/fantastty-message-b.sock"}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume B: %v", err)
	}

	err = messageProbe([]string{"--session", sessionA.Session, "--key", sessionB.Key})
	if !errors.Is(err, keyring.ErrWrongSession) {
		t.Fatalf("messageProbe error = %v, want ErrWrongSession", err)
	}
	if _, err := manager.ConsumeKey(sessionB.Session, sessionB.Key); !errors.Is(err, keyring.ErrInvalidKey) {
		t.Fatalf("key survived wrong-session message probe: %v", err)
	}
}

func TestWorkspaceMessagesControlCommandRejectsDisabledSmoke(t *testing.T) {
	var output bytes.Buffer

	handleControlCommand(&output, "workspace-a", "session-a", 1234, nil, "workspace-messages session-a")

	if got := strings.TrimSpace(output.String()); got != "error workspace_messages=disabled" {
		t.Fatalf("workspace-messages response = %q, want disabled error", got)
	}
}

func TestWorkspaceMessagesControlCommandReadsTmuxControlStream(t *testing.T) {
	marker := "fantastty-remote-grid-smoke-session-a"
	logPath := installFakeTmuxProgram(t, `#!/bin/sh
set -eu
for arg in "$@"; do
  printf '%s\t' "$arg" >>"$FAKE_TMUX_LOG"
done
printf '\n' >>"$FAKE_TMUX_LOG"
case " $* " in
  *" capture-pane "*)
    printf '%s\n' "$FAKE_TMUX_MARKER"
    ;;
  *" list-windows "*)
    printf '@0\tmain\te15d,%sx1,0,0,0\t0\t1\n' "$FAKE_TMUX_COLUMNS"
    ;;
  *" list-panes "*)
    printf '@0\t%%0\t1\n'
    ;;
  *" -C attach-session "*)
    IFS= read -r refresh
    printf 'STDIN:%s\n' "$refresh" >>"$FAKE_TMUX_LOG"
    printf '%%session-changed $0 main\n'
    printf '%%layout-change @0 e15d,%sx1,0,0,0 e15d,%sx1,0,0,0 *\n' "$FAKE_TMUX_COLUMNS" "$FAKE_TMUX_COLUMNS"
    IFS= read -r detach
    printf 'STDIN:%s\n' "$detach" >>"$FAKE_TMUX_LOG"
    printf '%%exit\n'
    ;;
esac
`)
	t.Setenv("FAKE_TMUX_MARKER", marker)
	t.Setenv("FAKE_TMUX_COLUMNS", strconv.Itoa(len(marker)+1))
	smoke := &tmuxSmoke{
		socketPath:  filepath.Join(t.TempDir(), "tmux-smoke.sock"),
		sessionName: "main",
		marker:      marker,
	}

	var output bytes.Buffer
	handleControlCommand(&output, "workspace-a", "session-a", 1234, smoke, "workspace-messages session-a")

	assertWorkspaceMessageCases(t, output.String(), "workspace-a")
	data, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read fake tmux log: %v", err)
	}
	log := string(data)
	if !strings.Contains(log, "-C\tattach-session\t-t\tmain") {
		t.Fatalf("tmux log missing control-mode attach: %s", log)
	}
	if !strings.Contains(log, "STDIN:refresh-client -C "+strconv.Itoa(len(marker)+1)+",1") {
		t.Fatalf("tmux log missing refresh-client sizing command: %s", log)
	}
	if !strings.Contains(log, "STDIN:detach-client") {
		t.Fatalf("tmux log missing detach-client command: %s", log)
	}
	if !strings.Contains(log, "list-windows\t-t\tmain") {
		t.Fatalf("tmux log missing list-windows seed command: %s", log)
	}
	if !strings.Contains(log, "list-panes\t-a\t-t\tmain") {
		t.Fatalf("tmux log missing list-panes seed command: %s", log)
	}
}

func TestTmuxSmokeControlCommandVerifiesLiveOutputAfterAttach(t *testing.T) {
	marker := "fantastty-remote-grid-smoke-session-a"
	liveMarker := marker + "-live-output"
	logPath := installFakeTmuxProgram(t, `#!/bin/sh
set -eu
for arg in "$@"; do
  printf '%s\t' "$arg" >>"$FAKE_TMUX_LOG"
done
printf '\n' >>"$FAKE_TMUX_LOG"
case " $* " in
  *" capture-pane "*)
    printf '%s\n' "$FAKE_TMUX_MARKER"
    ;;
  *" -C attach-session "*)
    IFS= read -r refresh
    printf 'STDIN:%s\n' "$refresh" >>"$FAKE_TMUX_LOG"
    printf '%%layout-change @0 e15d,%sx1,0,0,%%0 e15d,%sx1,0,0,%%0 *\n' "$FAKE_TMUX_COLUMNS" "$FAKE_TMUX_COLUMNS"
    printf '%%output %%0 %s\\012\n' "$FAKE_TMUX_LIVE_MARKER"
    IFS= read -r detach
    printf 'STDIN:%s\n' "$detach" >>"$FAKE_TMUX_LOG"
    printf '%%exit\n'
    ;;
esac
`)
	t.Setenv("FAKE_TMUX_MARKER", marker)
	t.Setenv("FAKE_TMUX_LIVE_MARKER", liveMarker)
	t.Setenv("FAKE_TMUX_COLUMNS", strconv.Itoa(len(liveMarker)+1))
	smoke := &tmuxSmoke{
		socketPath:  filepath.Join(t.TempDir(), "tmux-smoke.sock"),
		sessionName: "main",
		marker:      marker,
	}

	var output bytes.Buffer
	handleControlCommand(&output, "workspace-a", "session-a", 1234, smoke, "tmux-smoke session-a")

	if got, want := strings.TrimSpace(output.String()), "ok marker="+marker+" live_output=true"; got != want {
		t.Fatalf("tmux-smoke response = %q, want %q", got, want)
	}
	invocations := readFakeTmuxLog(t, logPath)
	var sawControlAttach, sawClear, sawLiteralSend, sawEnter bool
	for _, args := range invocations {
		if containsArg(args, "-C") && containsArg(args, "attach-session") {
			sawControlAttach = true
		}
		if containsArg(args, "send-keys") && containsArg(args, "C-u") {
			sawClear = true
		}
		if containsArg(args, "send-keys") && containsArg(args, "-l") {
			for _, arg := range args {
				if strings.Contains(arg, liveMarker) {
					sawLiteralSend = true
				}
			}
		}
		if containsArg(args, "send-keys") && containsArg(args, "Enter") {
			sawEnter = true
		}
	}
	if !sawControlAttach {
		t.Fatalf("tmux log missing control-mode attach: %v", invocations)
	}
	logData, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read fake tmux log: %v", err)
	}
	if !strings.Contains(string(logData), "STDIN:refresh-client -C "+strconv.Itoa(len(liveMarker)+1)+",1") {
		t.Fatalf("tmux log missing live output refresh-client sizing command: %s", logData)
	}
	if !sawClear || !sawLiteralSend || !sawEnter {
		t.Fatalf("tmux log missing live output send-keys sequence: %v", invocations)
	}
}

func TestTmuxSmokeStartVerifyAndCleanupUsesPrivateSocket(t *testing.T) {
	root := t.TempDir()
	session := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	marker := "fantastty-remote-grid-smoke-" + shortID(session)
	logPath := installFakeTmux(t, marker)

	smoke, err := startTmuxSmoke(root, session)
	if err != nil {
		t.Fatalf("startTmuxSmoke: %v", err)
	}
	if smoke.socketPath != filepath.Join(root, "tmux-smoke-"+shortID(session)+".sock") {
		t.Fatalf("socketPath = %q, want private socket under runtime dir", smoke.socketPath)
	}
	if smoke.sessionName != "main" {
		t.Fatalf("sessionName = %q, want main", smoke.sessionName)
	}
	if smoke.marker != marker {
		t.Fatalf("marker = %q, want %q", smoke.marker, marker)
	}

	if err := smoke.verify(); err != nil {
		t.Fatalf("verify: %v", err)
	}
	if err := smoke.cleanup(); err != nil {
		t.Fatalf("cleanup: %v", err)
	}

	invocations := readFakeTmuxLog(t, logPath)
	wantCommands := map[string]bool{
		"new-session":  false,
		"capture-pane": false,
		"kill-server":  false,
	}
	for _, args := range invocations {
		socket := argAfter(args, "-S")
		if socket == "" {
			t.Fatalf("tmux invocation omitted -S: %q", args)
		}
		if socket != smoke.socketPath {
			t.Fatalf("tmux socket = %q, want %q in %q", socket, smoke.socketPath, args)
		}
		for command := range wantCommands {
			if containsArg(args, command) {
				wantCommands[command] = true
			}
		}
	}
	for command, seen := range wantCommands {
		if !seen {
			t.Fatalf("tmux command %q was not invoked; invocations=%v", command, invocations)
		}
	}
}

func TestAttachProbeChecksTmuxSmokeWhenOptedIn(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatalf("chmod runtime dir: %v", err)
	}
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)
	t.Setenv("FANTASTTY_BOOTSTRAP_TMUX_SMOKE", "1")

	socketPath := fmt.Sprintf("%s/fh-%d.sock", os.TempDir(), time.Now().UnixNano())
	defer os.Remove(socketPath)
	unixListener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("listen unix: %v", err)
	}
	defer unixListener.Close()
	if listener, ok := unixListener.(*net.UnixListener); ok {
		if err := listener.SetDeadline(time.Now().Add(2 * time.Second)); err != nil {
			t.Fatalf("SetDeadline: %v", err)
		}
	}

	udpConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 0})
	if err != nil {
		t.Fatalf("listen udp: %v", err)
	}
	defer udpConn.Close()
	port := udpConn.LocalAddr().(*net.UDPAddr).Port

	store, err := registry.NewStore(root, registry.Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := registry.NewManager(store)
	result, err := manager.LaunchOrResume("workspace-a", time.Minute, time.Minute, func(registry.StartRequest) (registry.StartResult, error) {
		return registry.StartResult{PID: os.Getpid(), Port: port, SocketPath: socketPath, TmuxSmoke: true}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume: %v", err)
	}
	marker := "fantastty-remote-grid-smoke-" + shortID(result.Session)

	controlDone := make(chan int, 1)
	go func() {
		healthSeen := false
		smokeProbes := 0
		defer func() {
			controlDone <- smokeProbes
		}()
		for {
			conn, err := unixListener.Accept()
			if err != nil {
				return
			}
			func() {
				defer conn.Close()
				line, err := bufio.NewReader(conn).ReadString('\n')
				if err != nil {
					return
				}
				switch strings.TrimSpace(line) {
				case "health " + result.Session:
					healthSeen = true
					fmt.Fprintf(conn, "ok port=%d pid=%d\n", port, os.Getpid())
				case "tmux-smoke " + result.Session:
					smokeProbes++
					fmt.Fprintf(conn, "ok marker=%s live_output=true\n", marker)
				default:
					fmt.Fprintln(conn, "error")
				}
			}()
			if healthSeen && smokeProbes == 1 {
				return
			}
		}
	}()

	udpServed := make(chan struct{})
	go func() {
		defer close(udpServed)
		buf := make([]byte, 256)
		_ = udpConn.SetReadDeadline(time.Now().Add(2 * time.Second))
		n, addr, err := udpConn.ReadFromUDP(buf)
		if err != nil {
			t.Errorf("ReadFromUDP: %v", err)
			return
		}
		if got := strings.TrimSpace(string(buf[:n])); got != "health "+result.Session {
			t.Errorf("UDP request = %q, want health %s", got, result.Session)
			return
		}
		_, _ = udpConn.WriteToUDP([]byte("ok\n"), addr)
	}()

	if err := attachProbe([]string{"--session", result.Session, "--key", result.Key}); err != nil {
		t.Fatalf("attachProbe: %v", err)
	}
	<-udpServed
	if got := <-controlDone; got != 1 {
		t.Fatalf("tmux smoke probes = %d, want 1", got)
	}
}

func TestAttachProbeChecksTmuxSmokeWhenSessionWasLaunchedWithSmoke(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatalf("chmod runtime dir: %v", err)
	}
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)

	socketPath := fmt.Sprintf("%s/fh-%d.sock", os.TempDir(), time.Now().UnixNano())
	defer os.Remove(socketPath)
	unixListener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("listen unix: %v", err)
	}
	defer unixListener.Close()

	udpConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 0})
	if err != nil {
		t.Fatalf("listen udp: %v", err)
	}
	defer udpConn.Close()
	port := udpConn.LocalAddr().(*net.UDPAddr).Port

	store, err := registry.NewStore(root, registry.Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := registry.NewManager(store)
	result, err := manager.LaunchOrResume("workspace-a", time.Minute, time.Minute, func(registry.StartRequest) (registry.StartResult, error) {
		return registry.StartResult{PID: os.Getpid(), Port: port, SocketPath: socketPath, TmuxSmoke: true}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume: %v", err)
	}
	marker := "fantastty-remote-grid-smoke-" + shortID(result.Session)

	controlDone := make(chan int, 1)
	go func() {
		healthSeen := false
		smokeProbes := 0
		defer func() {
			controlDone <- smokeProbes
		}()
		for {
			conn, err := unixListener.Accept()
			if err != nil {
				return
			}
			func() {
				defer conn.Close()
				line, err := bufio.NewReader(conn).ReadString('\n')
				if err != nil {
					return
				}
				switch strings.TrimSpace(line) {
				case "health " + result.Session:
					healthSeen = true
					fmt.Fprintf(conn, "ok port=%d pid=%d\n", port, os.Getpid())
				case "tmux-smoke " + result.Session:
					smokeProbes++
					fmt.Fprintf(conn, "ok marker=%s live_output=true\n", marker)
				default:
					fmt.Fprintln(conn, "error")
				}
			}()
			if healthSeen && smokeProbes == 1 {
				return
			}
		}
	}()

	udpServed := make(chan struct{})
	go serveOneUDPHealth(t, udpConn, result.Session, udpServed)

	if err := attachProbe([]string{"--session", result.Session, "--key", result.Key}); err != nil {
		t.Fatalf("attachProbe: %v", err)
	}
	<-udpServed
	if got := <-controlDone; got != 1 {
		t.Fatalf("tmux smoke probes = %d, want 1", got)
	}
}

func TestProbeTmuxSmokeAllowsLiveOutputVerificationTime(t *testing.T) {
	socketPath := fmt.Sprintf("%s/fh-%d.sock", os.TempDir(), time.Now().UnixNano())
	defer os.Remove(socketPath)
	unixListener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("listen unix: %v", err)
	}
	defer unixListener.Close()

	session := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	marker := "fantastty-remote-grid-smoke-" + shortID(session)
	served := make(chan struct{})
	go func() {
		defer close(served)
		conn, err := unixListener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		line, err := bufio.NewReader(conn).ReadString('\n')
		if err != nil {
			t.Errorf("ReadString: %v", err)
			return
		}
		if got := strings.TrimSpace(line); got != "tmux-smoke "+session {
			t.Errorf("probe command = %q, want tmux-smoke %s", got, session)
			return
		}
		time.Sleep(2200 * time.Millisecond)
		fmt.Fprintf(conn, "ok marker=%s live_output=true\n", marker)
	}()

	err = probeTmuxSmoke(registry.SessionRecord{
		Session:    session,
		SocketPath: socketPath,
	})
	<-served
	if err != nil {
		t.Fatalf("probeTmuxSmoke: %v", err)
	}
}

func TestAttachProbeBurnsKeyWhenSmokeRequestedForNonSmokeSession(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatalf("chmod runtime dir: %v", err)
	}
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)
	t.Setenv("FANTASTTY_BOOTSTRAP_TMUX_SMOKE", "1")

	store, err := registry.NewStore(root, registry.Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := registry.NewManager(store)
	result, err := manager.LaunchOrResume("workspace-a", time.Minute, time.Minute, func(registry.StartRequest) (registry.StartResult, error) {
		return registry.StartResult{PID: os.Getpid(), Port: 1, SocketPath: "/tmp/fantastty-no-smoke.sock"}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume: %v", err)
	}

	err = attachProbe([]string{"--session", result.Session, "--key", result.Key})
	if err == nil || !strings.Contains(err.Error(), "tmux smoke requested for session launched without tmux smoke") {
		t.Fatalf("attachProbe error = %v, want smoke mismatch", err)
	}
	if _, err := manager.ConsumeKey(result.Session, result.Key); !errors.Is(err, keyring.ErrInvalidKey) {
		t.Fatalf("key survived smoke mismatch: %v", err)
	}
}

func TestAttachProbeSmokeMismatchStillBurnsWrongSessionKey(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatalf("chmod runtime dir: %v", err)
	}
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)
	t.Setenv("FANTASTTY_BOOTSTRAP_TMUX_SMOKE", "1")

	store, err := registry.NewStore(root, registry.Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := registry.NewManager(store)
	sessionA, err := manager.LaunchOrResume("workspace-a", time.Minute, time.Minute, func(registry.StartRequest) (registry.StartResult, error) {
		return registry.StartResult{PID: os.Getpid(), Port: 1, SocketPath: "/tmp/fantastty-no-smoke-a.sock"}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume A: %v", err)
	}
	sessionB, err := manager.LaunchOrResume("workspace-b", time.Minute, time.Minute, func(registry.StartRequest) (registry.StartResult, error) {
		return registry.StartResult{PID: os.Getpid(), Port: 2, SocketPath: "/tmp/fantastty-no-smoke-b.sock"}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume B: %v", err)
	}

	err = attachProbe([]string{"--session", sessionA.Session, "--key", sessionB.Key})
	if !errors.Is(err, keyring.ErrWrongSession) {
		t.Fatalf("attachProbe error = %v, want ErrWrongSession", err)
	}
	if _, err := manager.ConsumeKey(sessionB.Session, sessionB.Key); !errors.Is(err, keyring.ErrInvalidKey) {
		t.Fatalf("key survived wrong-session smoke mismatch: %v", err)
	}
}

func TestAttachProbeExpiredKeyReportsExpiredBeforeSmokeMismatch(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatalf("chmod runtime dir: %v", err)
	}
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)
	t.Setenv("FANTASTTY_BOOTSTRAP_TMUX_SMOKE", "1")

	store, err := registry.NewStore(root, registry.Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := registry.NewManager(store)
	session := strings.Repeat("a", 64)
	key := strings.Repeat("b", 64)
	if err := manager.RecordSession(registry.SessionRecord{
		Workspace:  "workspace-a",
		Session:    session,
		PID:        os.Getpid(),
		Port:       1,
		SocketPath: "/tmp/fantastty-no-smoke-expired.sock",
		Expires:    time.Now().Add(time.Minute),
		Keys: []keyring.Entry{{
			Key:       key,
			Session:   session,
			ExpiresAt: time.Now().Add(-time.Second),
		}},
	}); err != nil {
		t.Fatalf("RecordSession: %v", err)
	}

	err = attachProbe([]string{"--session", session, "--key", key})
	if !errors.Is(err, keyring.ErrExpiredKey) {
		t.Fatalf("attachProbe error = %v, want ErrExpiredKey", err)
	}
	if _, err := manager.ConsumeKey(session, key); !errors.Is(err, keyring.ErrInvalidKey) {
		t.Fatalf("expired key survived attach probe: %v", err)
	}
}

func TestAttachProbeExpiredKeyReportsExpiredForNormalSession(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatalf("chmod runtime dir: %v", err)
	}
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)

	store, err := registry.NewStore(root, registry.Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := registry.NewManager(store)
	session := strings.Repeat("d", 64)
	key := strings.Repeat("e", 64)
	if err := manager.RecordSession(registry.SessionRecord{
		Workspace:  "workspace-a",
		Session:    session,
		PID:        os.Getpid(),
		Port:       1,
		SocketPath: "/tmp/fantastty-no-smoke-expired-normal.sock",
		Expires:    time.Now().Add(time.Minute),
		Keys: []keyring.Entry{{
			Key:       key,
			Session:   session,
			ExpiresAt: time.Now().Add(-time.Second),
		}},
	}); err != nil {
		t.Fatalf("RecordSession: %v", err)
	}

	err = attachProbe([]string{"--session", session, "--key", key})
	if !errors.Is(err, keyring.ErrExpiredKey) {
		t.Fatalf("attachProbe error = %v, want ErrExpiredKey", err)
	}
	if _, err := manager.ConsumeKey(session, key); !errors.Is(err, keyring.ErrInvalidKey) {
		t.Fatalf("expired key survived attach probe: %v", err)
	}
}

func TestAttachProbeBurnsKeyWhenTargetSessionIsMissing(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatalf("chmod runtime dir: %v", err)
	}
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)
	t.Setenv("FANTASTTY_BOOTSTRAP_TMUX_SMOKE", "1")

	store, err := registry.NewStore(root, registry.Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := registry.NewManager(store)
	sessionB, err := manager.LaunchOrResume("workspace-b", time.Minute, time.Minute, func(registry.StartRequest) (registry.StartResult, error) {
		return registry.StartResult{PID: os.Getpid(), Port: 2, SocketPath: "/tmp/fantastty-no-smoke-b.sock"}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume B: %v", err)
	}

	missingSession := strings.Repeat("0", 64)
	err = attachProbe([]string{"--session", missingSession, "--key", sessionB.Key})
	if !errors.Is(err, keyring.ErrWrongSession) {
		t.Fatalf("attachProbe error = %v, want ErrWrongSession", err)
	}
	if _, err := manager.ConsumeKey(sessionB.Session, sessionB.Key); !errors.Is(err, keyring.ErrInvalidKey) {
		t.Fatalf("key survived missing-session attach probe: %v", err)
	}
}

func TestAttachProbeInvalidKeyMissingSessionReturnsSessionNotFound(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatalf("chmod runtime dir: %v", err)
	}
	t.Setenv("FANTASTTY_REMOTE_RUNTIME_DIR", root)
	t.Setenv("FANTASTTY_BOOTSTRAP_TMUX_SMOKE", "1")

	store, err := registry.NewStore(root, registry.Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := registry.NewManager(store)
	result, err := manager.LaunchOrResume("workspace-a", time.Minute, time.Minute, func(registry.StartRequest) (registry.StartResult, error) {
		return registry.StartResult{PID: os.Getpid(), Port: 1, SocketPath: "/tmp/fantastty-no-smoke-a.sock"}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume: %v", err)
	}

	missingSession := strings.Repeat("0", 64)
	invalidKey := strings.Repeat("c", 64)
	err = attachProbe([]string{"--session", missingSession, "--key", invalidKey})
	if !errors.Is(err, registry.ErrSessionNotFound) {
		t.Fatalf("attachProbe error = %v, want ErrSessionNotFound", err)
	}
	if _, err := manager.ConsumeKey(result.Session, result.Key); err != nil {
		t.Fatalf("unrelated key was affected by invalid missing-session probe: %v", err)
	}
}

func TestRunTmuxWithTimeoutUsesEmptyConfigAndSanitizesTmuxEnv(t *testing.T) {
	t.Setenv("TMUX", "/tmp/existing-tmux,123,0")
	t.Setenv("TMUX_PANE", "%1")
	logPath := installFakeTmuxProgram(t, `#!/bin/sh
set -eu
for arg in "$@"; do
  printf '%s\t' "$arg" >>"$FAKE_TMUX_LOG"
done
printf '\nTMUX=%s\nTMUX_PANE=%s\n' "${TMUX-}" "${TMUX_PANE-}" >>"$FAKE_TMUX_LOG"
`)
	socketPath := filepath.Join(t.TempDir(), "tmux-smoke.sock")

	if _, err := runTmuxWithTimeout(tmuxCommandTimeout, socketPath, "capture-pane"); err != nil {
		t.Fatalf("runTmuxWithTimeout: %v", err)
	}

	data, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read fake tmux log: %v", err)
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	args := strings.Split(lines[0], "\t")
	if args[len(args)-1] == "" {
		args = args[:len(args)-1]
	}
	if got := argAfter(args, "-f"); got != "/dev/null" {
		t.Fatalf("tmux config flag = %q, want /dev/null in args %q", got, args)
	}
	if got := argAfter(args, "-S"); got != socketPath {
		t.Fatalf("tmux socket = %q, want %q in args %q", got, socketPath, args)
	}
	for _, line := range lines[1:] {
		if line != "TMUX=" && line != "TMUX_PANE=" {
			t.Fatalf("tmux subprocess inherited tmux environment: %q", line)
		}
	}
}

func TestRunTmuxWithTimeoutStopsHungCommand(t *testing.T) {
	installFakeTmuxProgram(t, `#!/bin/sh
set -eu
sleep 5
`)
	start := time.Now()

	_, err := runTmuxWithTimeout(100*time.Millisecond, filepath.Join(t.TempDir(), "tmux.sock"), "capture-pane")

	if err == nil || !strings.Contains(err.Error(), "timed out") {
		t.Fatalf("runTmuxWithTimeout error = %v, want timeout", err)
	}
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Fatalf("runTmuxWithTimeout took %s, want under 1s", elapsed)
	}
}

func TestTmuxSmokeCleanupRemovesSocketAfterKillTimeout(t *testing.T) {
	previousTimeout := tmuxCommandTimeout
	tmuxCommandTimeout = 100 * time.Millisecond
	t.Cleanup(func() {
		tmuxCommandTimeout = previousTimeout
	})
	installFakeTmuxProgram(t, `#!/bin/sh
set -eu
sleep 5
`)
	socketPath := filepath.Join(t.TempDir(), "tmux-smoke.sock")
	if err := os.WriteFile(socketPath, []byte("stale"), 0o600); err != nil {
		t.Fatalf("write socket placeholder: %v", err)
	}
	smoke := &tmuxSmoke{socketPath: socketPath, sessionName: "main", marker: "marker"}

	err := smoke.cleanup()

	if err == nil || !strings.Contains(err.Error(), "timed out") {
		t.Fatalf("cleanup error = %v, want timeout", err)
	}
	if _, err := os.Lstat(socketPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("socket still exists after cleanup timeout: %v", err)
	}
}

func installFakeTmux(t *testing.T, capture string) string {
	t.Helper()
	script := `#!/bin/sh
set -eu
: "${FAKE_TMUX_LOG:?}"
has_socket=0
for arg in "$@"; do
  if [ "$arg" = "-S" ]; then
    has_socket=1
  fi
done
if [ "$has_socket" -ne 1 ]; then
  echo "tmux smoke command omitted -S" >&2
  exit 97
fi
for arg in "$@"; do
  printf '%s\t' "$arg" >>"$FAKE_TMUX_LOG"
done
printf '\n' >>"$FAKE_TMUX_LOG"
	case " $* " in
	  *" capture-pane "*) printf '%s\n' "${FAKE_TMUX_CAPTURE:-}" ;;
	esac
	`
	logPath := installFakeTmuxProgram(t, script)
	t.Setenv("FAKE_TMUX_CAPTURE", capture)
	return logPath
}

func installFakeTmuxProgram(t *testing.T, script string) string {
	t.Helper()
	dir := t.TempDir()
	logPath := filepath.Join(dir, "tmux.log")
	scriptPath := filepath.Join(dir, "tmux")
	if err := os.WriteFile(scriptPath, []byte(script), 0o700); err != nil {
		t.Fatalf("write fake tmux: %v", err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("FAKE_TMUX_LOG", logPath)
	return logPath
}

func serveOneUDPHealth(t *testing.T, conn *net.UDPConn, session string, done chan<- struct{}) {
	t.Helper()
	defer close(done)
	buf := make([]byte, 256)
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	n, addr, err := conn.ReadFromUDP(buf)
	if err != nil {
		t.Errorf("ReadFromUDP: %v", err)
		return
	}
	if got := strings.TrimSpace(string(buf[:n])); got != "health "+session {
		t.Errorf("UDP request = %q, want health %s", got, session)
		return
	}
	_, _ = conn.WriteToUDP([]byte("ok\n"), addr)
}

func captureStdout(t *testing.T, run func() error) string {
	t.Helper()
	original := os.Stdout
	readEnd, writeEnd, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe stdout: %v", err)
	}
	os.Stdout = writeEnd
	err = run()
	if closeErr := writeEnd.Close(); closeErr != nil {
		t.Fatalf("close stdout writer: %v", closeErr)
	}
	os.Stdout = original
	output, readErr := io.ReadAll(readEnd)
	if readErr != nil {
		t.Fatalf("read stdout: %v", readErr)
	}
	if err != nil {
		t.Fatalf("run: %v", err)
	}
	return string(output)
}

func equalStrings(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for i := range left {
		if left[i] != right[i] {
			return false
		}
	}
	return true
}

func assertWorkspaceMessageCases(t *testing.T, output string, workspaceID string) {
	t.Helper()
	lines := bytes.Split(bytes.TrimSpace([]byte(output)), []byte("\n"))
	if len(lines) != 2 {
		t.Fatalf("workspace message line count = %d, want 2", len(lines))
	}
	for i, line := range lines {
		var envelope map[string]map[string]map[string]any
		if err := json.Unmarshal(line, &envelope); err != nil {
			t.Fatalf("line %d JSON: %v", i, err)
		}
		var caseName string
		if i == 0 {
			caseName = "workspaceSnapshot"
		} else {
			caseName = "paneKeyframe"
		}
		payload, ok := envelope[caseName]["_0"]
		if !ok {
			t.Fatalf("line %d missing %s payload: %#v", i, caseName, envelope)
		}
		if got, _ := payload["workspaceID"].(string); got != workspaceID {
			t.Fatalf("line %d workspaceID = %q, want %q", i, got, workspaceID)
		}
	}
}

func readFakeTmuxLog(t *testing.T, path string) [][]string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fake tmux log: %v", err)
	}
	var invocations [][]string
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		if line == "" {
			continue
		}
		fields := strings.Split(line, "\t")
		if fields[len(fields)-1] == "" {
			fields = fields[:len(fields)-1]
		}
		invocations = append(invocations, fields)
	}
	return invocations
}

func makeRuntimeRoot(t *testing.T, pattern string) string {
	t.Helper()
	root, err := os.MkdirTemp("/tmp", pattern)
	if err != nil {
		t.Fatalf("temp runtime dir: %v", err)
	}
	t.Cleanup(func() {
		_ = os.RemoveAll(root)
	})
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatalf("chmod runtime dir: %v", err)
	}
	return root
}

func recordCleanupSession(t *testing.T, root string, record registry.SessionRecord) {
	t.Helper()
	store, err := registry.NewStore(root, registry.Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := registry.NewManager(store)
	if err := manager.RecordSession(record); err != nil {
		t.Fatalf("RecordSession: %v", err)
	}
}

func containsArg(args []string, want string) bool {
	for _, arg := range args {
		if arg == want {
			return true
		}
	}
	return false
}

func containsArgSequence(args []string, sequence ...string) bool {
	if len(sequence) == 0 {
		return true
	}
	for index := 0; index <= len(args)-len(sequence); index++ {
		if reflect.DeepEqual(args[index:index+len(sequence)], sequence) {
			return true
		}
	}
	return false
}

func argAfter(args []string, flag string) string {
	for i := 0; i < len(args)-1; i++ {
		if args[i] == flag {
			return args[i+1]
		}
	}
	return ""
}
