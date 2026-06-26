package main

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"fantastty/remote-engine-helper/internal/keyring"
	"fantastty/remote-engine-helper/internal/registry"
)

var (
	version = "dev"
	arch    = runtime.GOARCH
)

type readyFile struct {
	PID            int    `json:"pid"`
	Port           int    `json:"port"`
	SocketPath     string `json:"socket_path"`
	HelperVersion  string `json:"helper_version"`
	HelperArch     string `json:"helper_arch"`
	TmuxSmoke      bool   `json:"tmux_smoke"`
	QUICAddr       string `json:"quic_addr"`
	QUICCertSHA256 string `json:"quic_cert_sha256"`
}

type controlHealth struct {
	Port int
	PID  int
}

type authenticatedClientIdleLifecycle struct {
	ttl        time.Duration
	done       chan struct{}
	mu         sync.Mutex
	active     int
	generation int
	timer      *time.Timer
	closed     bool
}

type registryClientLifecycle struct {
	manager *registry.Manager
	session string
	idleTTL time.Duration
	idle    *authenticatedClientIdleLifecycle
}

func newAuthenticatedClientIdleLifecycle(ttl time.Duration) *authenticatedClientIdleLifecycle {
	lifecycle := &authenticatedClientIdleLifecycle{
		ttl:  ttl,
		done: make(chan struct{}),
	}
	lifecycle.mu.Lock()
	lifecycle.scheduleIdleTimerLocked()
	lifecycle.mu.Unlock()
	return lifecycle
}

func (l *authenticatedClientIdleLifecycle) ClientAttached() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return errors.New("session cleanup already started")
	}
	if l.active == 0 {
		l.cancelIdleTimerLocked()
	}
	l.active++
	return nil
}

func (l *authenticatedClientIdleLifecycle) ClientDetached() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return nil
	}
	if l.active == 0 {
		return nil
	}
	l.active--
	if l.active == 0 {
		l.scheduleIdleTimerLocked()
	}
	return nil
}

func (l *authenticatedClientIdleLifecycle) Done() <-chan struct{} {
	return l.done
}

func (l *authenticatedClientIdleLifecycle) Stop() {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.cancelIdleTimerLocked()
}

func (l *authenticatedClientIdleLifecycle) scheduleIdleTimerLocked() {
	l.cancelIdleTimerLocked()
	generation := l.generation
	l.timer = time.AfterFunc(l.ttl, func() {
		l.mu.Lock()
		defer l.mu.Unlock()
		if l.closed || l.active > 0 || generation != l.generation {
			return
		}
		l.closed = true
		close(l.done)
	})
}

func (l *authenticatedClientIdleLifecycle) cancelIdleTimerLocked() {
	l.generation++
	if l.timer != nil {
		l.timer.Stop()
		l.timer = nil
	}
}

func (l *registryClientLifecycle) ClientAttached() error {
	if err := l.idle.ClientAttached(); err != nil {
		return err
	}
	if err := l.manager.ClientAttached(l.session); err != nil {
		_ = l.idle.ClientDetached()
		return err
	}
	return nil
}

func (l *registryClientLifecycle) ClientDetached() error {
	err := l.manager.ClientDetached(l.session, l.idleTTL)
	if idleErr := l.idle.ClientDetached(); err == nil {
		err = idleErr
	}
	return err
}

func main() {
	if len(os.Args) == 2 && os.Args[1] == "--version" {
		fmt.Println(versionLine(version, arch))
		return
	}
	if len(os.Args) < 2 {
		usageAndExit()
	}

	var err error
	switch os.Args[1] {
	case "launch-or-resume":
		err = launchOrResume(os.Args[2:])
	case "attach-probe":
		err = attachProbe(os.Args[2:])
	case "message-probe":
		err = messageProbe(os.Args[2:])
	case "quic-probe":
		err = quicProbe(os.Args[2:])
	case "quic-reconnect-probe":
		err = quicReconnectProbe(os.Args[2:])
	case "input-probe":
		err = inputProbe(os.Args[2:])
	case "shutdown":
		err = shutdown(os.Args[2:])
	case "cleanup-dry-run":
		err = cleanupDryRun(os.Args[2:], os.Stdout)
	case "serve":
		err = serve(os.Args[2:])
	default:
		usageAndExit()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func usageAndExit() {
	fmt.Fprintln(os.Stderr, "usage: fantastty-helper --version | launch-or-resume | attach-probe | message-probe | quic-probe | quic-reconnect-probe | input-probe | shutdown | cleanup-dry-run")
	os.Exit(2)
}

func versionLine(v, goarch string) string {
	return fmt.Sprintf("fantastty-helper version=%s arch=%s", v, goarch)
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

func bootstrapLine(result registry.LaunchResult, v, goarch string) string {
	lineVersion := firstNonEmpty(result.HelperVersion, v)
	lineArch := firstNonEmpty(result.HelperArch, goarch)
	return fmt.Sprintf(
		"FANTASTTY_REMOTE port=%d session=%s key=%s expires=%s helper_pid=%d version=%s arch=%s quic_addr=%s quic_cert_sha256=%s quic_alpn=%s",
		result.Port,
		result.Session,
		result.Key,
		result.KeyExpires.UTC().Format(time.RFC3339),
		result.PID,
		lineVersion,
		lineArch,
		result.QUICAddr,
		result.QUICCertSHA256,
		remoteQUICALPN,
	)
}

func launchOrResume(args []string) error {
	parsed, err := parseLaunchOrResumeArgs(args)
	if err != nil {
		return err
	}

	store, err := openStore()
	if err != nil {
		return err
	}
	manager := registry.NewManagerWithHelperIdentity(store, version, arch)
	if err := manager.PruneExpired(); err != nil {
		return err
	}
	result, err := manager.LaunchOrResumeTmuxSession(parsed.workspace, parsed.tmuxSession, parsed.ttl, parsed.keyTTL, func(req registry.StartRequest) (registry.StartResult, error) {
		return startDaemon(store.Root(), req)
	})
	if err != nil {
		return err
	}
	fmt.Println(bootstrapLine(result, version, arch))
	return nil
}

type launchOrResumeArgs struct {
	workspace   string
	tmuxSession string
	ttl         time.Duration
	keyTTL      time.Duration
}

func parseLaunchOrResumeArgs(args []string) (launchOrResumeArgs, error) {
	var parsed launchOrResumeArgs
	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch arg {
		case "--ttl":
			if i+1 >= len(args) {
				return parsed, errors.New("launch-or-resume requires value for --ttl")
			}
			ttl, err := time.ParseDuration(args[i+1])
			if err != nil {
				return parsed, err
			}
			parsed.ttl = ttl
			i++
		case "--key-ttl":
			if i+1 >= len(args) {
				return parsed, errors.New("launch-or-resume requires value for --key-ttl")
			}
			keyTTL, err := time.ParseDuration(args[i+1])
			if err != nil {
				return parsed, err
			}
			parsed.keyTTL = keyTTL
			i++
		case "--tmux-session":
			if i+1 >= len(args) {
				return parsed, errors.New("launch-or-resume requires value for --tmux-session")
			}
			parsed.tmuxSession = args[i+1]
			i++
		default:
			if strings.HasPrefix(arg, "-") {
				return parsed, fmt.Errorf("unknown launch-or-resume flag: %s", arg)
			}
			if parsed.workspace != "" {
				return parsed, errors.New("launch-or-resume accepts one workspace")
			}
			parsed.workspace = arg
		}
	}
	if parsed.workspace == "" {
		return parsed, errors.New("launch-or-resume requires workspace")
	}
	if parsed.ttl <= 0 {
		return parsed, errors.New("launch-or-resume requires positive --ttl")
	}
	if parsed.keyTTL <= 0 {
		return parsed, errors.New("launch-or-resume requires positive --key-ttl")
	}
	return parsed, nil
}

func openRemoteQUICLog(runtimeDir string, session string) (io.Writer, func()) {
	if runtimeDir == "" || session == "" {
		return io.Discard, func() {}
	}
	if err := os.MkdirAll(runtimeDir, 0o700); err != nil {
		return io.Discard, func() {}
	}
	path := filepath.Join(runtimeDir, "quic-"+session+".log")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return io.Discard, func() {}
	}
	return file, func() {
		_ = file.Close()
	}
}

func attachProbe(args []string) error {
	fs := flag.NewFlagSet("attach-probe", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	session := fs.String("session", "", "session id")
	key := fs.String("key", "", "one-time key")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *session == "" || *key == "" {
		return errors.New("attach-probe requires --session and --key")
	}

	record, err := consumeAttachKey(*session, *key)
	if err != nil {
		return err
	}
	if err := probeControlSocket(record); err != nil {
		return err
	}
	if err := probeUDPHealth(record.Session, record.Port); err != nil {
		return err
	}
	if record.TmuxSmoke {
		if err := probeTmuxSmoke(record); err != nil {
			return err
		}
	}
	fmt.Println("attach-probe: ok")
	return nil
}

func messageProbe(args []string) error {
	fs := flag.NewFlagSet("message-probe", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	session := fs.String("session", "", "session id")
	key := fs.String("key", "", "one-time key")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *session == "" || *key == "" {
		return errors.New("message-probe requires --session and --key")
	}

	record, err := consumeAttachKey(*session, *key)
	if err != nil {
		return err
	}
	if err := probeControlSocket(record); err != nil {
		return err
	}
	if err := probeUDPHealth(record.Session, record.Port); err != nil {
		return err
	}
	messages, err := requestWorkspaceMessages(record)
	if err != nil {
		return err
	}
	_, err = os.Stdout.Write(messages)
	return err
}

func quicProbe(args []string) error {
	log.SetOutput(io.Discard)

	fs := flag.NewFlagSet("quic-probe", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	addr := fs.String("addr", "", "remote QUIC address")
	certSHA := fs.String("cert-sha256", "", "remote QUIC SPKI SHA256")
	session := fs.String("session", "", "session id")
	key := fs.String("key", "", "one-time key")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *addr == "" || *certSHA == "" || *session == "" || *key == "" {
		return errors.New("quic-probe requires --addr, --cert-sha256, --session, and --key")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	output, err := requestRemoteQUICPayload(ctx, *addr, *certSHA, *session, *key)
	if err != nil {
		return err
	}
	_, err = os.Stdout.Write(output)
	return err
}

func quicReconnectProbe(args []string) error {
	log.SetOutput(io.Discard)

	fs := flag.NewFlagSet("quic-reconnect-probe", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	addr := fs.String("addr", "", "remote QUIC address")
	certSHA := fs.String("cert-sha256", "", "remote QUIC SPKI SHA256")
	session := fs.String("session", "", "session id")
	firstKey := fs.String("first-key", "", "first one-time key")
	secondKey := fs.String("second-key", "", "second one-time key")
	marker := fs.String("marker", "", "input marker")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *addr == "" || *certSHA == "" || *session == "" || *firstKey == "" || *secondKey == "" || *marker == "" {
		return errors.New("quic-reconnect-probe requires --addr, --cert-sha256, --session, --first-key, --second-key, and --marker")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	result, err := requestRemoteQUICReconnectProbe(ctx, *addr, *certSHA, *session, *firstKey, *secondKey, *marker)
	if err != nil {
		return err
	}
	fmt.Printf("quic-reconnect-probe: ok marker=%s pane=%d workspace=%s\n", *marker, result.PaneID, result.WorkspaceID)
	return nil
}

func inputProbe(args []string) error {
	log.SetOutput(io.Discard)

	fs := flag.NewFlagSet("input-probe", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	addr := fs.String("addr", "", "remote QUIC address")
	certSHA := fs.String("cert-sha256", "", "remote QUIC SPKI SHA256")
	session := fs.String("session", "", "session id")
	key := fs.String("key", "", "one-time key")
	marker := fs.String("marker", "", "input marker")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *addr == "" || *certSHA == "" || *session == "" || *key == "" || *marker == "" {
		return errors.New("input-probe requires --addr, --cert-sha256, --session, --key, and --marker")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	result, err := requestRemoteQUICInputProbe(ctx, *addr, *certSHA, *session, *key, *marker)
	if err != nil {
		return err
	}
	fmt.Printf("input-probe: ok marker=%s pane=%d workspace=%s\n", *marker, result.PaneID, result.WorkspaceID)
	return nil
}

func consumeAttachKey(session, key string) (registry.SessionRecord, error) {
	store, err := openStore()
	if err != nil {
		return registry.SessionRecord{}, err
	}
	manager := registry.NewManager(store)
	keyOwner, keyOwnerErr := manager.FindKeyOwner(key)
	record, err := manager.FindSession(session)
	if err != nil {
		if keyOwnerErr != nil && !errors.Is(keyOwnerErr, keyring.ErrInvalidKey) {
			return registry.SessionRecord{}, keyOwnerErr
		}
		if keyOwnerErr == nil && keyOwner.Session != session {
			_, err := manager.ConsumeKey(session, key)
			return registry.SessionRecord{}, err
		}
		return registry.SessionRecord{}, err
	}
	if keyOwnerErr != nil {
		return registry.SessionRecord{}, keyOwnerErr
	}
	if tmuxSmokeEnabled() && !record.TmuxSmoke {
		if _, err := manager.ConsumeKey(session, key); err != nil {
			return registry.SessionRecord{}, err
		}
		return registry.SessionRecord{}, errors.New("tmux smoke requested for session launched without tmux smoke")
	}
	return manager.ConsumeKey(session, key)
}

func shutdown(args []string) error {
	fs := flag.NewFlagSet("shutdown", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	session := fs.String("session", "", "session id")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *session == "" {
		return errors.New("shutdown requires --session")
	}

	store, err := openStore()
	if err != nil {
		return err
	}
	manager := registry.NewManager(store)
	record, err := manager.FindSession(*session)
	if errors.Is(err, registry.ErrSessionNotFound) {
		return nil
	}
	if err != nil {
		return err
	}
	if record.PID > 0 {
		_ = syscall.Kill(record.PID, syscall.SIGTERM)
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if !processAlive(record.PID) {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if record.TmuxSession == "" {
		if err := killPrivateTmuxWorkspaceSession(store.Root(), record.Workspace, record.Session); err != nil {
			return err
		}
	}
	return manager.RemoveSession(*session, record.PID)
}

func cleanupDryRun(args []string, output io.Writer) error {
	fs := flag.NewFlagSet("cleanup-dry-run", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return errors.New("cleanup-dry-run accepts no positional arguments")
	}

	store, err := openStore()
	if err != nil {
		return err
	}
	manager := registry.NewManager(store)
	records, err := manager.ListSessions()
	if err != nil {
		return err
	}
	for _, record := range records {
		if record.Workspace == "" {
			continue
		}
		path := tmuxWorkspaceSocketPath(store.Root(), record.Workspace, record.Session)
		action, reason := cleanupDryRunAction(record, path)
		fmt.Fprintf(
			output,
			"cleanup-dry-run session=%s workspace=%s action=%s target=%s reason=%s\n",
			record.Session,
			record.Workspace,
			action,
			path,
			reason,
		)
	}
	return nil
}

func cleanupDryRunAction(record registry.SessionRecord, path string) (string, string) {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		if processAlive(record.PID) {
			return "preserve-live", "helper-pid-live"
		}
		return "would-remove", "stale-registry-record"
	}
	if err != nil {
		return "refuse-unsafe", "stat-failed"
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return "refuse-unsafe", "symlink"
	}
	if info.Mode().Perm()&0o077 != 0 {
		return "refuse-unsafe", "permissions"
	}
	if fileOwnerUID(info) != os.Geteuid() {
		return "refuse-unsafe", "owner"
	}
	if filepath.Base(path) != filepath.Base(tmuxWorkspaceSocketPath(filepath.Dir(path), record.Workspace, record.Session)) {
		return "refuse-unsafe", "unexpected-name"
	}
	if processAlive(record.PID) {
		return "preserve-live", "helper-pid-live"
	}
	return "would-remove", "stale-private-workspace"
}

func fileOwnerUID(info os.FileInfo) int {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return -1
	}
	return int(stat.Uid)
}

func killPrivateTmuxWorkspaceSession(root, workspace, session string) error {
	if workspace == "" {
		return nil
	}
	socketPath := tmuxWorkspaceSocketPath(root, workspace, session)
	sessionName := remoteTmuxSessionName(workspace)
	output, killErr := runTmuxCommand(
		2*time.Second,
		socketPath,
		"kill-session",
		"-t", sessionName,
	)
	if killErr != nil && privateTmuxWorkspaceSessionExists(socketPath, sessionName) {
		return fmt.Errorf("kill private tmux workspace session: %w: %s", killErr, strings.TrimSpace(string(output)))
	}
	return removePrivateTmuxSocket(socketPath)
}

func privateTmuxWorkspaceSessionExists(socketPath, sessionName string) bool {
	_, err := runTmuxCommand(
		2*time.Second,
		socketPath,
		"has-session",
		"-t", sessionName,
	)
	return err == nil
}

func removePrivateTmuxSocket(path string) error {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return errors.New("unsafe private tmux socket path")
	}
	return os.Remove(path)
}

func serve(args []string) error {
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	workspace := fs.String("workspace", "", "workspace id")
	session := fs.String("session", "", "session id")
	tmuxSession := fs.String("tmux-session", "", "external tmux session name")
	ttl := fs.Duration("ttl", 0, "session ttl")
	runtimeDir := fs.String("runtime-dir", "", "runtime dir")
	readyPath := fs.String("ready-file", "", "ready file")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *workspace == "" || *session == "" || *ttl <= 0 || *runtimeDir == "" || *readyPath == "" {
		return errors.New("serve requires --workspace, --session, --ttl, --runtime-dir, and --ready-file")
	}

	store, err := registry.NewStore(*runtimeDir, registry.Options{UID: os.Geteuid()})
	if err != nil {
		return err
	}
	manager := registry.NewManager(store)

	socketPath := filepath.Join(store.Root(), "ctl-"+shortID(*session)+".sock")
	if err := store.ValidateSocketPath(socketPath); err != nil {
		return err
	}
	_ = os.Remove(socketPath)
	unixListener, err := net.Listen("unix", socketPath)
	if err != nil {
		return err
	}
	defer unixListener.Close()
	defer os.Remove(socketPath)
	if err := os.Chmod(socketPath, 0o600); err != nil {
		return err
	}

	var smoke *tmuxSmoke
	var source remoteWorkspaceSource
	quicLog, closeQUICLog := openRemoteQUICLog(store.Root(), *session)
	defer closeQUICLog()
	if tmuxSmokeEnabled() {
		smokePath := tmuxSmokeSocketPath(store.Root(), *session)
		if err := store.ValidateSocketPath(smokePath); err != nil {
			return err
		}
		smoke, err = startTmuxSmoke(store.Root(), *session)
		if err != nil {
			return err
		}
		defer func() {
			_ = smoke.cleanup()
		}()
		source = smokeRemoteWorkspacePayloadSource(smoke)
	} else {
		renderer, err := newRemotePaneRenderer(*workspace)
		if err != nil {
			return err
		}
		tmuxSocketPath := tmuxWorkspaceSocketPath(store.Root(), *workspace, *session)
		tmuxSessionName := remoteTmuxSessionName(*workspace)
		useDefaultServer := false
		if *tmuxSession != "" {
			tmuxSocketPath = ""
			tmuxSessionName = *tmuxSession
			useDefaultServer = true
		} else if err := store.ValidateSocketPath(tmuxSocketPath); err != nil {
			return err
		}
		tmuxRuntime, err := startTmuxWorkspaceSource(context.Background(), tmuxWorkspaceSourceOptions{
			WorkspaceID:      *workspace,
			SessionName:      tmuxSessionName,
			SocketPath:       tmuxSocketPath,
			UseDefaultServer: useDefaultServer,
			Renderer:         renderer,
			Log:              quicLog,
		})
		if err != nil {
			return err
		}
		defer func() {
			_ = tmuxRuntime.Close()
		}()
		source = tmuxRuntime
	}

	quicCtx, stopQUIC := context.WithCancel(context.Background())
	defer stopQUIC()
	idleLifecycle := newAuthenticatedClientIdleLifecycle(*ttl)
	defer idleLifecycle.Stop()
	clientLifecycle := &registryClientLifecycle{
		manager: manager,
		session: *session,
		idleTTL: *ttl,
		idle:    idleLifecycle,
	}
	quicServer, err := startRemoteQUICServer(quicCtx, remoteQUICServerOptions{
		ListenAddr:    "0.0.0.0:0",
		AdvertiseHost: os.Getenv("FANTASTTY_REMOTE_ADVERTISE_HOST"),
		RuntimeDir:    store.Root(),
		WorkspaceID:   *workspace,
		Session:       *session,
		Source:        source,
		Lifecycle:     clientLifecycle,
		Log:           quicLog,
	})
	if err != nil {
		return err
	}
	defer quicServer.Close()

	udpAddr, err := net.ResolveUDPAddr("udp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	udpConn, err := net.ListenUDP("udp", udpAddr)
	if err != nil {
		return err
	}
	defer udpConn.Close()
	port := udpConn.LocalAddr().(*net.UDPAddr).Port

	if err := writeReadyFile(*readyPath, readyFile{
		PID:            os.Getpid(),
		Port:           port,
		SocketPath:     socketPath,
		HelperVersion:  version,
		HelperArch:     arch,
		TmuxSmoke:      smoke != nil,
		QUICAddr:       quicServer.Addr(),
		QUICCertSHA256: quicServer.CertSHA256(),
	}); err != nil {
		return err
	}

	done := make(chan struct{})
	go serveUnixControl(unixListener, *workspace, *session, port, smoke, done)
	go serveUDPHealth(udpConn, *session, done)

	signals := make(chan os.Signal, 2)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT)
	select {
	case <-idleLifecycle.Done():
	case <-signals:
	}
	close(done)
	stopQUIC()
	return manager.RemoveSession(*session, os.Getpid())
}

func openStore() (*registry.Store, error) {
	root := registry.DefaultRuntimeDir()
	return registry.NewStore(root, registry.Options{UID: os.Geteuid()})
}

func tmuxWorkspaceSocketPath(root, workspace, _ string) string {
	sum := sha256.Sum256([]byte(workspace))
	return filepath.Join(root, "tmux-workspace-"+hex.EncodeToString(sum[:16])+".sock")
}

func preflightServeRequirements() error {
	if _, err := exec.LookPath("tmux"); err != nil {
		return fmt.Errorf("required command tmux is unavailable: %w", err)
	}
	return nil
}

func startDaemon(runtimeDir string, req registry.StartRequest) (registry.StartResult, error) {
	exe, err := os.Executable()
	if err != nil {
		return registry.StartResult{}, err
	}
	readyPath := filepath.Join(runtimeDir, "ready-"+shortID(req.Session)+".json")
	_ = os.Remove(readyPath)
	ttl := time.Until(req.Expires)
	if ttl <= 0 {
		return registry.StartResult{}, errors.New("session ttl already expired")
	}
	if err := preflightServeRequirements(); err != nil {
		return registry.StartResult{}, err
	}

	devNull, err := os.OpenFile(os.DevNull, os.O_RDWR, 0)
	if err != nil {
		return registry.StartResult{}, err
	}
	defer devNull.Close()

	args := []string{
		"serve",
		"--workspace", req.Workspace,
		"--session", req.Session,
		"--ttl", ttl.String(),
		"--runtime-dir", runtimeDir,
		"--ready-file", readyPath,
	}
	if req.TmuxSession != "" {
		args = append(args, "--tmux-session", req.TmuxSession)
	}
	cmd := exec.Command(exe, args...)
	cmd.Env = append(os.Environ(), "FANTASTTY_REMOTE_RUNTIME_DIR="+runtimeDir)
	cmd.Stdin = devNull
	cmd.Stdout = devNull
	cmd.Stderr = devNull
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return registry.StartResult{}, err
	}
	pid := cmd.Process.Pid
	if err := cmd.Process.Release(); err != nil {
		return registry.StartResult{}, err
	}

	ready, err := waitForReadyFile(readyPath, 3*time.Second)
	if err != nil {
		_ = syscall.Kill(pid, syscall.SIGTERM)
		return registry.StartResult{}, err
	}
	if ready.PID != pid {
		_ = syscall.Kill(pid, syscall.SIGTERM)
		return registry.StartResult{}, fmt.Errorf("daemon pid mismatch: ready=%d child=%d", ready.PID, pid)
	}
	return registry.StartResult{
		PID:            ready.PID,
		Port:           ready.Port,
		SocketPath:     ready.SocketPath,
		HelperVersion:  ready.HelperVersion,
		HelperArch:     ready.HelperArch,
		TmuxSmoke:      ready.TmuxSmoke,
		QUICAddr:       ready.QUICAddr,
		QUICCertSHA256: ready.QUICCertSHA256,
	}, nil
}

func waitForReadyFile(path string, timeout time.Duration) (readyFile, error) {
	deadline := time.Now().Add(timeout)
	var lastErr error
	for time.Now().Before(deadline) {
		data, err := os.ReadFile(path)
		if err == nil {
			var ready readyFile
			if err := json.Unmarshal(data, &ready); err != nil {
				return readyFile{}, err
			}
			_ = os.Remove(path)
			return ready, nil
		}
		lastErr = err
		time.Sleep(25 * time.Millisecond)
	}
	if lastErr == nil {
		lastErr = os.ErrNotExist
	}
	return readyFile{}, fmt.Errorf("daemon did not become ready: %w", lastErr)
}

func writeReadyFile(path string, ready readyFile) error {
	data, err := json.Marshal(ready)
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func serveUnixControl(listener net.Listener, workspace, session string, port int, smoke *tmuxSmoke, done <-chan struct{}) {
	go func() {
		<-done
		_ = listener.Close()
	}()
	for {
		conn, err := listener.Accept()
		if err != nil {
			select {
			case <-done:
				return
			default:
				continue
			}
		}
		go handleUnixControl(conn, workspace, session, port, smoke)
	}
}

func handleUnixControl(conn net.Conn, workspace, session string, port int, smoke *tmuxSmoke) {
	defer conn.Close()
	unixConn, ok := conn.(*net.UnixConn)
	if !ok {
		return
	}
	cred, err := registry.PeerCredentialFromUnixConn(unixConn)
	if err != nil {
		return
	}
	if err := registry.ValidatePeerCredential(cred, os.Geteuid()); err != nil {
		return
	}
	_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
	line, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil {
		return
	}
	if err := conn.SetDeadline(time.Time{}); err != nil {
		return
	}
	command := strings.TrimSpace(line)
	handleControlCommand(conn, workspace, session, port, smoke, command)
}

func handleControlCommand(w io.Writer, workspace, session string, port int, smoke *tmuxSmoke, command string) {
	if command == "health "+session {
		fmt.Fprintf(w, "ok port=%d pid=%d\n", port, os.Getpid())
		return
	}
	if command == "tmux-smoke "+session {
		if smoke == nil {
			fmt.Fprintln(w, "error tmux_smoke=disabled")
			return
		}
		if err := smoke.verify(); err != nil {
			fmt.Fprintf(w, "error tmux_smoke=unverified detail=%s\n", strings.ReplaceAll(err.Error(), " ", "_"))
			return
		}
		if err := smoke.verifyLiveOutput(); err != nil {
			fmt.Fprintf(w, "error tmux_smoke=live_output_unverified detail=%s\n", controlErrorDetail(err))
			return
		}
		fmt.Fprintf(w, "ok marker=%s live_output=true\n", smoke.marker)
		return
	}
	if command == "workspace-messages "+session {
		if smoke == nil {
			fmt.Fprintln(w, "error workspace_messages=disabled")
			return
		}
		if err := smoke.verify(); err != nil {
			fmt.Fprintf(w, "error workspace_messages=unverified detail=%s\n", controlErrorDetail(err))
			return
		}
		messages, err := smoke.workspaceMessages(workspace)
		if err != nil {
			fmt.Fprintf(w, "error workspace_messages=build_failed detail=%s\n", controlErrorDetail(err))
			return
		}
		output, err := marshalWorkspaceMessageLines(messages)
		if err != nil {
			fmt.Fprintf(w, "error workspace_messages=marshal_failed detail=%s\n", controlErrorDetail(err))
			return
		}
		_, _ = w.Write(output)
		return
	}
	fmt.Fprintln(w, "error")
}

func serveUDPHealth(conn *net.UDPConn, session string, done <-chan struct{}) {
	buf := make([]byte, 512)
	for {
		_ = conn.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
		n, addr, err := conn.ReadFromUDP(buf)
		if err != nil {
			select {
			case <-done:
				return
			default:
				continue
			}
		}
		if strings.TrimSpace(string(buf[:n])) == "health "+session {
			_, _ = conn.WriteToUDP([]byte("ok\n"), addr)
		}
	}
}

func probeControlSocket(record registry.SessionRecord) error {
	if record.SocketPath == "" {
		return errors.New("registry entry has no control socket")
	}
	conn, err := net.DialTimeout("unix", record.SocketPath, 2*time.Second)
	if err != nil {
		return err
	}
	defer conn.Close()
	if err := conn.SetDeadline(time.Now().Add(2 * time.Second)); err != nil {
		return err
	}
	if _, err := fmt.Fprintf(conn, "health %s\n", record.Session); err != nil {
		return err
	}
	line, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil {
		return err
	}
	if !strings.HasPrefix(line, "ok ") {
		return fmt.Errorf("health probe rejected: %s", strings.TrimSpace(line))
	}
	health, err := parseControlHealth(line)
	if err != nil {
		return err
	}
	if health.Port != record.Port {
		return fmt.Errorf("control socket port mismatch: got %d want %d", health.Port, record.Port)
	}
	if record.PID > 0 && health.PID != record.PID {
		return fmt.Errorf("control socket pid mismatch: got %d want %d", health.PID, record.PID)
	}
	return nil
}

func parseControlHealth(line string) (controlHealth, error) {
	line = strings.TrimSpace(line)
	if !strings.HasPrefix(line, "ok ") {
		return controlHealth{}, fmt.Errorf("health probe rejected: %s", line)
	}
	portText := parseBootstrapValue(line, "port")
	if portText == "" {
		return controlHealth{}, errors.New("health probe missing port")
	}
	port, err := strconv.Atoi(portText)
	if err != nil {
		return controlHealth{}, fmt.Errorf("health probe invalid port: %w", err)
	}
	pidText := parseBootstrapValue(line, "pid")
	if pidText == "" {
		return controlHealth{}, errors.New("health probe missing pid")
	}
	pid, err := strconv.Atoi(pidText)
	if err != nil {
		return controlHealth{}, fmt.Errorf("health probe invalid pid: %w", err)
	}
	return controlHealth{Port: port, PID: pid}, nil
}

func probeUDPHealth(session string, port int) error {
	if port <= 0 {
		return fmt.Errorf("invalid udp health port: %d", port)
	}
	conn, err := net.DialTimeout("udp", fmt.Sprintf("127.0.0.1:%d", port), 2*time.Second)
	if err != nil {
		return err
	}
	defer conn.Close()
	if err := conn.SetDeadline(time.Now().Add(2 * time.Second)); err != nil {
		return err
	}
	if _, err := fmt.Fprintf(conn, "health %s\n", session); err != nil {
		return err
	}
	buf := make([]byte, 512)
	n, err := conn.Read(buf)
	if err != nil {
		return err
	}
	if got := strings.TrimSpace(string(buf[:n])); got != "ok" {
		return fmt.Errorf("udp health probe rejected: %s", got)
	}
	return nil
}

func requestWorkspaceMessages(record registry.SessionRecord) ([]byte, error) {
	if record.SocketPath == "" {
		return nil, errors.New("registry entry has no control socket")
	}
	conn, err := net.DialTimeout("unix", record.SocketPath, 2*time.Second)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	if err := conn.SetDeadline(time.Now().Add(2 * time.Second)); err != nil {
		return nil, err
	}
	if _, err := fmt.Fprintf(conn, "workspace-messages %s\n", record.Session); err != nil {
		return nil, err
	}
	output, err := io.ReadAll(conn)
	if err != nil {
		return nil, err
	}
	if strings.HasPrefix(string(output), "error ") {
		return nil, fmt.Errorf("workspace messages rejected: %s", strings.TrimSpace(string(output)))
	}
	if len(output) == 0 {
		return nil, errors.New("workspace messages response was empty")
	}
	return output, nil
}

func controlErrorDetail(err error) string {
	return strings.NewReplacer(" ", "_", "\n", "_", "\r", "_", "\t", "_").Replace(err.Error())
}

func processAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

func shortID(session string) string {
	if len(session) <= 16 {
		return session
	}
	return session[:16]
}

func parseBootstrapValue(line, key string) string {
	for _, field := range strings.Fields(line) {
		before, after, ok := strings.Cut(field, "=")
		if ok && before == key {
			return after
		}
	}
	return ""
}

func parsePID(line string) (int, error) {
	pid := parseBootstrapValue(line, "helper_pid")
	if pid == "" {
		return 0, errors.New("missing helper_pid")
	}
	return strconv.Atoi(pid)
}
