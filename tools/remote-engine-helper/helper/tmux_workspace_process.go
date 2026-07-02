package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"fantastty/remote-engine-helper/internal/engine"
	"fantastty/remote-engine-helper/remotegrid"
	"fantastty/remote-engine-helper/tmuxcc"
)

const (
	tmuxListSnapshotTimeout = 2 * time.Second
	tmuxCaptureHistoryRows  = 2000
	tmuxPauseAfterSeconds   = 1
)

type tmuxWorkspaceSourceOptions struct {
	WorkspaceID      string
	SessionName      string
	SocketPath       string
	UseDefaultServer bool
	Renderer         engine.PaneRenderer
	Columns          int
	Rows             int
	Log              io.Writer
}

type tmuxWorkspaceRuntime struct {
	*tmuxControlWorkspaceSource

	cmd                      *exec.Cmd
	stdin                    io.WriteCloser
	done                     chan error
	sessionName              string
	socketPath               string
	log                      io.Writer
	stdinMu                  sync.Mutex
	stateMu                  sync.Mutex
	closed                   bool
	repaintAfterContinue     map[int]struct{}
	dropBufferedAfterRepaint map[int]struct{}
	liveOutputSinceCapture   map[int]struct{}
}

func startTmuxWorkspaceSource(ctx context.Context, opts tmuxWorkspaceSourceOptions) (*tmuxWorkspaceRuntime, error) {
	if opts.WorkspaceID == "" {
		return nil, errors.New("tmux workspace source requires workspace id")
	}
	if opts.SessionName == "" {
		return nil, errors.New("tmux workspace source requires session name")
	}
	if opts.SocketPath == "" && !opts.UseDefaultServer {
		return nil, errors.New("tmux workspace source requires socket path")
	}
	if opts.Renderer == nil {
		return nil, errors.New("tmux workspace source requires renderer")
	}
	if opts.Columns <= 0 {
		opts.Columns = 80
	}
	if opts.Rows <= 0 {
		opts.Rows = 24
	}
	if opts.Log == nil {
		opts.Log = io.Discard
	}

	source := newTmuxControlWorkspaceSource(opts.WorkspaceID, opts.Renderer)
	args := []string{"-f", "/dev/null", "-S", opts.SocketPath, "-C", "new-session", "-A", "-s", opts.SessionName}
	if opts.UseDefaultServer {
		args = []string{"-C", "attach-session", "-t", opts.SessionName}
	}
	cmd := exec.CommandContext(ctx, "tmux", args...)
	cmd.Env = tmuxSmokeEnv(os.Environ())
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	if err := cmd.Start(); err != nil {
		return nil, err
	}
	started := false
	defer func() {
		if !started {
			_ = cmd.Process.Kill()
			_ = cmd.Wait()
		}
	}()

	if _, err := fmt.Fprintf(stdin, "refresh-client -C %d,%d -f pause-after=%d\n", opts.Columns, opts.Rows, tmuxPauseAfterSeconds); err != nil {
		return nil, err
	}
	windowLines, paneLines, err := waitForTmuxListSnapshotLines(opts.SocketPath, opts.SessionName, tmuxListSnapshotTimeout)
	if err != nil {
		return nil, err
	}
	paneInitialCaptures, err := tmuxCapturePaneInitialCapturesByListLines(opts.SocketPath, paneLines)
	if err != nil {
		return nil, err
	}
	if err := source.HandleListSnapshot(windowLines, paneLines, paneInitialCaptures); err != nil {
		return nil, err
	}

	runtime := &tmuxWorkspaceRuntime{
		tmuxControlWorkspaceSource: source,
		cmd:                        cmd,
		stdin:                      stdin,
		done:                       make(chan error, 1),
		sessionName:                opts.SessionName,
		socketPath:                 opts.SocketPath,
		log:                        opts.Log,
		repaintAfterContinue:       make(map[int]struct{}),
		dropBufferedAfterRepaint:   make(map[int]struct{}),
		liveOutputSinceCapture:     make(map[int]struct{}),
	}
	started = true
	fmt.Fprintf(opts.Log, "remote_tmux_source_started=true workspace=%s session=%s socket=%s\n", opts.WorkspaceID, opts.SessionName, opts.SocketPath)
	go runtime.scan(stdout)
	return runtime, nil
}

func (r *tmuxWorkspaceRuntime) Close() error {
	if r == nil {
		return nil
	}
	r.stdinMu.Lock()
	if r.closed {
		r.stdinMu.Unlock()
		return nil
	}
	r.closed = true
	if r.stdin != nil {
		_, _ = fmt.Fprintln(r.stdin, "detach-client")
		_ = r.stdin.Close()
	}
	r.stdinMu.Unlock()
	select {
	case err := <-r.done:
		return err
	case <-time.After(2 * time.Second):
		if r.cmd != nil && r.cmd.Process != nil {
			_ = r.cmd.Process.Kill()
		}
		return errors.New("tmux workspace source did not stop")
	}
}

func (r *tmuxWorkspaceRuntime) SendKeys(workspaceID string, paneID int, data []byte) error {
	if r == nil {
		return errors.New("tmux workspace source is unavailable")
	}
	if _, err := r.CurrentPayload(workspaceID); err != nil {
		return err
	}
	r.stdinMu.Lock()
	defer r.stdinMu.Unlock()
	if r.closed {
		return errors.New("tmux workspace source is closed")
	}
	command, err := tmuxSendKeysCommand(paneID, data)
	if err != nil {
		return err
	}
	if command == "" {
		return nil
	}
	fmt.Fprintf(r.log, "remote_tmux_send_keys_started=true workspace=%s pane=%d bytes=%d\n", workspaceID, paneID, len(data))
	_, err = fmt.Fprintln(r.stdin, command)
	if err != nil {
		fmt.Fprintf(r.log, "remote_tmux_send_keys_failed=true workspace=%s pane=%d reason=%s\n", workspaceID, paneID, controlErrorDetail(err))
		return err
	}
	fmt.Fprintf(r.log, "remote_tmux_send_keys_written=true workspace=%s pane=%d bytes=%d\n", workspaceID, paneID, len(data))
	return err
}

func (r *tmuxWorkspaceRuntime) RequestKeyframe(workspaceID string, paneID int) (remoteWorkspacePayload, error) {
	if r == nil {
		return remoteWorkspacePayload{}, errors.New("tmux workspace source is unavailable")
	}
	if r.hasLiveOutputSinceCapture(paneID) {
		payload, err := r.tmuxControlWorkspaceSource.RequestKeyframe(workspaceID, paneID)
		if err == nil && payloadContainsPaneKeyframe(payload, paneID) {
			fmt.Fprintf(r.log, "remote_tmux_request_keyframe_retained_live_output=true workspace=%s pane=%d\n", workspaceID, paneID)
			return payload, nil
		}
	}
	fmt.Fprintf(r.log, "remote_tmux_request_keyframe_repaint_started=true workspace=%s pane=%d\n", workspaceID, paneID)
	captured, err := r.capturePaneKeyframePayload(paneID)
	if err != nil {
		fmt.Fprintf(r.log, "remote_tmux_request_keyframe_repaint_failed=true workspace=%s pane=%d reason=%s\n", workspaceID, paneID, controlErrorDetail(err))
	} else if payloadContainsPaneKeyframe(captured, paneID) {
		fmt.Fprintf(r.log, "remote_tmux_request_keyframe_repaint_completed=true workspace=%s pane=%d\n", workspaceID, paneID)
		return captured, nil
	} else {
		fmt.Fprintf(r.log, "remote_tmux_request_keyframe_repaint_empty=true workspace=%s pane=%d\n", workspaceID, paneID)
	}

	payload, retainedErr := r.tmuxControlWorkspaceSource.RequestKeyframe(workspaceID, paneID)
	if retainedErr != nil {
		if err != nil {
			return remoteWorkspacePayload{}, err
		}
		return payload, retainedErr
	}
	return payload, nil
}

func (r *tmuxWorkspaceRuntime) RequestKeyframes(workspaceID string) (remoteWorkspacePayload, error) {
	if r == nil {
		return remoteWorkspacePayload{}, errors.New("tmux workspace source is unavailable")
	}
	fmt.Fprintf(r.log, "remote_tmux_request_keyframes_repaint_started=true workspace=%s\n", workspaceID)
	payload, err := r.captureWorkspaceKeyframesPayload()
	if err != nil {
		fmt.Fprintf(r.log, "remote_tmux_request_keyframes_repaint_failed=true workspace=%s reason=%s\n", workspaceID, controlErrorDetail(err))
		return remoteWorkspacePayload{}, err
	}
	fmt.Fprintf(r.log, "remote_tmux_request_keyframes_repaint_completed=true workspace=%s\n", workspaceID)
	return payload, nil
}

func (r *tmuxWorkspaceRuntime) SubscribeKeyframes(workspaceID string, pump *engine.StreamPump) (remoteWorkspacePayload, func(), error) {
	payload, err := r.RequestKeyframes(workspaceID)
	if err != nil {
		return remoteWorkspacePayload{}, func() {}, err
	}
	if pump != nil {
		pump.PublishReliable(payload.Reliable)
		pump.PublishDatagrams(payload.Datagrams)
	}
	return payload, r.Subscribe(pump), nil
}

func (r *tmuxWorkspaceRuntime) ResizePane(workspaceID string, paneID int, columns int, rows int) (remoteWorkspacePayload, error) {
	if r == nil {
		return remoteWorkspacePayload{}, errors.New("tmux workspace source is unavailable")
	}
	if _, err := r.CurrentPayload(workspaceID); err != nil {
		return remoteWorkspacePayload{}, err
	}
	commands, err := tmuxResizePaneCommands(paneID, columns, rows)
	if err != nil {
		return remoteWorkspacePayload{}, err
	}

	r.stdinMu.Lock()
	if r.closed {
		r.stdinMu.Unlock()
		return remoteWorkspacePayload{}, errors.New("tmux workspace source is closed")
	}
	for _, command := range commands {
		if _, err := fmt.Fprintln(r.stdin, command); err != nil {
			r.stdinMu.Unlock()
			return remoteWorkspacePayload{}, err
		}
	}
	r.stdinMu.Unlock()

	windowLines, paneLines, err := waitForTmuxListSnapshotLines(r.socketPath, r.sessionName, tmuxListSnapshotTimeout)
	if err != nil {
		return remoteWorkspacePayload{}, err
	}
	paneInitialCaptures, err := tmuxCapturePaneInitialCapturesByListLines(r.socketPath, paneLines)
	if err != nil {
		return remoteWorkspacePayload{}, err
	}
	if err := r.HandleListSnapshot(windowLines, paneLines, paneInitialCaptures); err != nil {
		return remoteWorkspacePayload{}, err
	}
	return r.CurrentPayload(workspaceID)
}

func (r *tmuxWorkspaceRuntime) NewWindow(workspaceID string) (remoteWorkspacePayload, error) {
	if r == nil {
		return remoteWorkspacePayload{}, errors.New("tmux workspace source is unavailable")
	}
	if _, err := r.CurrentPayload(workspaceID); err != nil {
		return remoteWorkspacePayload{}, err
	}
	r.stdinMu.Lock()
	if r.closed {
		r.stdinMu.Unlock()
		return remoteWorkspacePayload{}, errors.New("tmux workspace source is closed")
	}
	fmt.Fprintf(r.log, "remote_tmux_new_window_started=true workspace=%s\n", workspaceID)
	if _, err := fmt.Fprintln(r.stdin, "new-window"); err != nil {
		r.stdinMu.Unlock()
		fmt.Fprintf(r.log, "remote_tmux_new_window_failed=true workspace=%s reason=%s\n", workspaceID, controlErrorDetail(err))
		return remoteWorkspacePayload{}, err
	}
	r.stdinMu.Unlock()

	windowLines, paneLines, err := waitForTmuxListSnapshotLines(r.socketPath, r.sessionName, tmuxListSnapshotTimeout)
	if err != nil {
		return remoteWorkspacePayload{}, err
	}
	paneInitialCaptures, err := tmuxCapturePaneInitialCapturesByListLines(r.socketPath, paneLines)
	if err != nil {
		return remoteWorkspacePayload{}, err
	}
	if err := r.HandleListSnapshot(windowLines, paneLines, paneInitialCaptures); err != nil {
		return remoteWorkspacePayload{}, err
	}
	fmt.Fprintf(r.log, "remote_tmux_new_window_written=true workspace=%s\n", workspaceID)
	return r.CurrentPayload(workspaceID)
}

func (r *tmuxWorkspaceRuntime) SelectWindow(workspaceID string, windowID int) (remoteWorkspacePayload, error) {
	if r == nil {
		return remoteWorkspacePayload{}, errors.New("tmux workspace source is unavailable")
	}
	if _, err := r.CurrentPayload(workspaceID); err != nil {
		return remoteWorkspacePayload{}, err
	}
	if windowID < 0 {
		return remoteWorkspacePayload{}, errors.New("tmux select-window requires window id")
	}

	r.stdinMu.Lock()
	if r.closed {
		r.stdinMu.Unlock()
		return remoteWorkspacePayload{}, errors.New("tmux workspace source is closed")
	}
	fmt.Fprintf(r.log, "remote_tmux_select_window_started=true workspace=%s window=%d\n", workspaceID, windowID)
	if _, err := fmt.Fprintf(r.stdin, "select-window -t @%d\n", windowID); err != nil {
		r.stdinMu.Unlock()
		fmt.Fprintf(r.log, "remote_tmux_select_window_failed=true workspace=%s window=%d reason=%s\n", workspaceID, windowID, controlErrorDetail(err))
		return remoteWorkspacePayload{}, err
	}
	r.stdinMu.Unlock()

	windowLines, paneLines, err := waitForTmuxListSnapshotLines(r.socketPath, r.sessionName, tmuxListSnapshotTimeout)
	if err != nil {
		return remoteWorkspacePayload{}, err
	}
	paneInitialCaptures, err := tmuxCapturePaneInitialCapturesByListLines(r.socketPath, paneLines)
	if err != nil {
		return remoteWorkspacePayload{}, err
	}
	if err := r.HandleListSnapshot(windowLines, paneLines, paneInitialCaptures); err != nil {
		return remoteWorkspacePayload{}, err
	}
	fmt.Fprintf(r.log, "remote_tmux_select_window_written=true workspace=%s window=%d\n", workspaceID, windowID)
	return r.CurrentPayload(workspaceID)
}

func (r *tmuxWorkspaceRuntime) scan(stdout io.Reader) {
	scanErr := r.scanBufferedActions(stdout, r.handleStreamAction)
	waitErr := r.cmd.Wait()
	if scanErr != nil {
		r.done <- scanErr
		return
	}
	r.done <- waitErr
}

func (r *tmuxWorkspaceRuntime) handleStreamAction(action tmuxcc.Action) error {
	if output, ok := action.PaneOutput(); ok {
		if _, drop := r.dropBufferedAfterRepaint[output.PaneID]; drop {
			if output.BufferedAgeMillis > 0 {
				return nil
			}
			delete(r.dropBufferedAfterRepaint, output.PaneID)
		}
		r.rememberLiveOutputSinceCapture(output.PaneID)
	}
	if flow, ok := action.PaneFlow(); ok {
		if flow.Paused {
			r.repaintAfterContinue[flow.PaneID] = struct{}{}
			return r.continuePausedPane(flow.PaneID)
		}
		if _, ok := r.repaintAfterContinue[flow.PaneID]; ok {
			delete(r.repaintAfterContinue, flow.PaneID)
			repainted, err := r.repaintPaneAfterContinue(flow.PaneID)
			if err != nil {
				fmt.Fprintf(r.log, "remote_tmux_continue_repaint_failed=true pane=%d reason=%s\n", flow.PaneID, controlErrorDetail(err))
				return nil
			}
			if repainted {
				r.dropBufferedAfterRepaint[flow.PaneID] = struct{}{}
			}
			return nil
		}
		repainted, err := r.repaintPaneAfterContinue(flow.PaneID)
		if err != nil {
			return err
		}
		if repainted {
			r.dropBufferedAfterRepaint[flow.PaneID] = struct{}{}
		}
		return nil
	}
	return r.source.Handle(action)
}

func (r *tmuxWorkspaceRuntime) continuePausedPane(paneID int) error {
	r.stdinMu.Lock()
	defer r.stdinMu.Unlock()
	if r.closed {
		return nil
	}
	_, err := fmt.Fprintf(r.stdin, "refresh-client -A '%%%d:continue'\n", paneID)
	return err
}

func (r *tmuxWorkspaceRuntime) repaintPaneAfterContinue(paneID int) (bool, error) {
	fmt.Fprintf(r.log, "remote_tmux_continue_repaint_started=true pane=%d\n", paneID)
	repainted, err := r.repaintPaneFromCapture(paneID)
	if err != nil {
		return false, err
	}
	if !repainted {
		return false, nil
	}
	fmt.Fprintf(r.log, "remote_tmux_continue_repaint_completed=true pane=%d\n", paneID)
	return true, nil
}

func (r *tmuxWorkspaceRuntime) repaintPaneFromCapture(paneID int) (bool, error) {
	payload, err := r.capturePaneKeyframePayload(paneID)
	if err != nil {
		return false, err
	}
	return payloadContainsPaneKeyframe(payload, paneID), nil
}

func (r *tmuxWorkspaceRuntime) captureWorkspaceKeyframesPayload() (remoteWorkspacePayload, error) {
	windowLines, paneLines, err := waitForTmuxListSnapshotLines(r.socketPath, r.sessionName, tmuxListSnapshotTimeout)
	if err != nil {
		return remoteWorkspacePayload{}, err
	}
	paneInitialCaptures, err := tmuxCapturePaneInitialCapturesByListLines(r.socketPath, paneLines)
	if err != nil {
		return remoteWorkspacePayload{}, err
	}
	payload, err := r.handleListSnapshotPayload(windowLines, paneLines, paneInitialCaptures)
	if err != nil {
		return remoteWorkspacePayload{}, err
	}
	for paneID := range paneInitialCaptures {
		if payloadContainsPaneKeyframe(payload, paneID) {
			r.rememberPaneCaptured(paneID)
		}
	}
	return payload, nil
}

func (r *tmuxWorkspaceRuntime) capturePaneKeyframePayload(paneID int) (remoteWorkspacePayload, error) {
	windowLines, paneLines, err := waitForTmuxListSnapshotLines(r.socketPath, r.sessionName, tmuxListSnapshotTimeout)
	if err != nil {
		return remoteWorkspacePayload{}, err
	}
	capture, err := tmuxCapturePaneInitialCaptureFromListLines(r.socketPath, paneLines, paneID)
	if err != nil {
		return remoteWorkspacePayload{}, err
	}
	paneInitialCaptures := map[int]remotegrid.PaneInitialCapture{
		paneID: capture,
	}
	payload, err := r.handleListSnapshotPayload(windowLines, paneLines, paneInitialCaptures)
	if err != nil {
		return remoteWorkspacePayload{}, err
	}
	if payloadContainsPaneKeyframe(payload, paneID) {
		r.rememberPaneCaptured(paneID)
	}
	return payload, nil
}

func (r *tmuxWorkspaceRuntime) rememberLiveOutputSinceCapture(paneID int) {
	r.stateMu.Lock()
	r.liveOutputSinceCapture[paneID] = struct{}{}
	r.stateMu.Unlock()
}

func (r *tmuxWorkspaceRuntime) rememberPaneCaptured(paneID int) {
	r.stateMu.Lock()
	delete(r.liveOutputSinceCapture, paneID)
	r.stateMu.Unlock()
}

func (r *tmuxWorkspaceRuntime) hasLiveOutputSinceCapture(paneID int) bool {
	r.stateMu.Lock()
	defer r.stateMu.Unlock()
	_, ok := r.liveOutputSinceCapture[paneID]
	return ok
}

func payloadContainsPaneKeyframe(payload remoteWorkspacePayload, paneID int) bool {
	for _, message := range payload.Reliable {
		keyframe, ok := message.PaneKeyframe()
		if ok && keyframe.PaneID == paneID {
			return true
		}
	}
	return false
}

func remoteTmuxSessionName(workspaceID string) string {
	return "fantastty-remote-" + workspaceID
}

func tmuxSendKeysCommand(paneID int, data []byte) (string, error) {
	if paneID < 0 {
		return "", errors.New("tmux send-keys requires paneID")
	}
	if len(data) == 0 {
		return "", nil
	}
	commands := make([]string, 0, 1)
	hexBytes := make([]string, 0, len(data))
	flushHexBytes := func() {
		if len(hexBytes) == 0 {
			return
		}
		commands = append(commands, fmt.Sprintf("send-keys -t %%%d -H %s", paneID, strings.Join(hexBytes, " ")))
		hexBytes = hexBytes[:0]
	}
	for i := 0; i < len(data); i++ {
		switch data[i] {
		case '\r', '\n':
			flushHexBytes()
			if data[i] == '\r' && i+1 < len(data) && data[i+1] == '\n' {
				i++
			}
			commands = append(commands, fmt.Sprintf("send-keys -t %%%d Enter", paneID))
		default:
			hexBytes = append(hexBytes, fmt.Sprintf("%02x", data[i]))
		}
	}
	flushHexBytes()
	return strings.Join(commands, "\n"), nil
}

func tmuxResizePaneCommands(paneID int, columns int, rows int) ([]string, error) {
	if paneID < 0 {
		return nil, errors.New("tmux resize-pane requires paneID")
	}
	if columns <= 0 || rows <= 0 {
		return nil, errors.New("tmux resize-pane requires positive columns and rows")
	}
	return []string{
		fmt.Sprintf("refresh-client -C %d,%d", columns, rows),
		fmt.Sprintf("resize-pane -t %%%d -x %d -y %d", paneID, columns, rows),
	}, nil
}

func tmuxListSnapshotLines(socketPath string, sessionName string) ([]string, []string, error) {
	windowOutput, err := runTmux(
		socketPath,
		"list-windows",
		"-t", sessionName,
		"-F", "#{window_id}\t#{window_name}\t#{window_layout}\t#{window_index}\t#{window_active}",
	)
	if err != nil {
		return nil, nil, fmt.Errorf("list tmux windows: %w: %s", err, strings.TrimSpace(string(windowOutput)))
	}
	paneOutput, err := runTmux(
		socketPath,
		"list-panes",
		"-s",
		"-t", sessionName,
		"-F", "#{window_id}\t#{pane_id}\t#{pane_active}\t#{alternate_on}\t#{cursor_x}\t#{cursor_y}\t#{scroll_region_upper}\t#{scroll_region_lower}\t#{cursor_flag}",
	)
	if err != nil {
		return nil, nil, fmt.Errorf("list tmux panes: %w: %s", err, strings.TrimSpace(string(paneOutput)))
	}
	return nonEmptyLines(string(windowOutput)), nonEmptyLines(string(paneOutput)), nil
}

func tmuxCapturePaneRowsByListLines(socketPath string, paneLines []string) (map[int][]string, error) {
	captures, err := tmuxCapturePaneInitialCapturesByListLines(socketPath, paneLines)
	if err != nil {
		return nil, err
	}
	rows := make(map[int][]string, len(captures))
	for paneID, capture := range captures {
		rows[paneID] = selectedInitialCaptureRows(capture)
	}
	return rows, nil
}

func tmuxCapturePaneInitialCapturesByListLines(socketPath string, paneLines []string) (map[int]remotegrid.PaneInitialCapture, error) {
	states, err := tmuxPaneStatesFromListLines(paneLines)
	if err != nil {
		return nil, err
	}
	captures := make(map[int]remotegrid.PaneInitialCapture, len(states))
	for _, state := range states {
		visibleRows, err := tmuxCapturePaneRows(socketPath, state.paneID)
		if err != nil {
			return nil, err
		}
		alternateFlagRows, err := tmuxCapturePaneAlternateRows(socketPath, state.paneID)
		if err != nil {
			return nil, err
		}
		captures[state.paneID] = tmuxPaneInitialCaptureFromRows(state, visibleRows, alternateFlagRows)
	}
	return captures, nil
}

func tmuxCapturePaneInitialCaptureFromListLines(socketPath string, paneLines []string, paneID int) (remotegrid.PaneInitialCapture, error) {
	states, err := tmuxPaneStatesFromListLines(paneLines)
	if err != nil {
		return remotegrid.PaneInitialCapture{}, err
	}
	for _, state := range states {
		if state.paneID != paneID {
			continue
		}
		visibleRows, err := tmuxCapturePaneRows(socketPath, state.paneID)
		if err != nil {
			return remotegrid.PaneInitialCapture{}, err
		}
		alternateFlagRows, err := tmuxCapturePaneAlternateRows(socketPath, state.paneID)
		if err != nil {
			return remotegrid.PaneInitialCapture{}, err
		}
		return tmuxPaneInitialCaptureFromRows(state, visibleRows, alternateFlagRows), nil
	}
	return remotegrid.PaneInitialCapture{}, fmt.Errorf("capture tmux pane %%%d: pane not found in list snapshot", paneID)
}

func tmuxPaneInitialCaptureFromRows(state tmuxPaneState, visibleRows []string, alternateFlagRows []string) remotegrid.PaneInitialCapture {
	capture := remotegrid.PaneInitialCapture{
		PrimaryRows:   visibleRows,
		AlternateRows: alternateFlagRows,
		ActiveScreen:  state.activeScreen(),
		Cursor:        state.cursor(),
		ScrollRegion:  state.initialScrollRegion(),
	}
	if state.alternateOn {
		capture.PrimaryRows = alternateFlagRows
		capture.AlternateRows = visibleRows
	}
	return capture
}

func paneInitialCapturesFromRows(rowsByPane map[int][]string) map[int]remotegrid.PaneInitialCapture {
	if len(rowsByPane) == 0 {
		return nil
	}
	captures := make(map[int]remotegrid.PaneInitialCapture, len(rowsByPane))
	for paneID, rows := range rowsByPane {
		captures[paneID] = remotegrid.PaneInitialCapture{
			PrimaryRows:  append([]string(nil), rows...),
			ActiveScreen: remotegrid.ActiveScreenPrimary,
		}
	}
	return captures
}

func tmuxCapturePaneRows(socketPath string, paneID int) ([]string, error) {
	output, err := runTmux(
		socketPath,
		"capture-pane",
		"-peqJN",
		"-S", fmt.Sprintf("-%d", tmuxCaptureHistoryRows),
		"-t", fmt.Sprintf("%%%d", paneID),
	)
	if err != nil {
		return nil, fmt.Errorf("capture tmux pane %%%d: %w: %s", paneID, err, strings.TrimSpace(string(output)))
	}
	return splitTmuxCaptureRows(string(output)), nil
}

func tmuxCapturePaneAlternateRows(socketPath string, paneID int) ([]string, error) {
	output, err := runTmux(
		socketPath,
		"capture-pane",
		"-peqJN",
		"-a",
		"-S", fmt.Sprintf("-%d", tmuxCaptureHistoryRows),
		"-t", fmt.Sprintf("%%%d", paneID),
	)
	if err != nil {
		return nil, nil
	}
	return splitTmuxCaptureRows(string(output)), nil
}

type tmuxPaneState struct {
	paneID        int
	alternateOn   bool
	cursorX       *int
	cursorY       *int
	cursorVisible *bool
	scrollRegion  *remotegrid.ScrollRegion
}

func (s tmuxPaneState) activeScreen() remotegrid.ActiveScreen {
	if s.alternateOn {
		return remotegrid.ActiveScreenAlternate
	}
	return remotegrid.ActiveScreenPrimary
}

func (s tmuxPaneState) cursor() *remotegrid.CursorState {
	if s.cursorX == nil || s.cursorY == nil {
		return nil
	}
	visible := true
	if s.cursorVisible != nil {
		visible = *s.cursorVisible
	}
	return &remotegrid.CursorState{
		Row:     *s.cursorY,
		Column:  *s.cursorX,
		Visible: visible,
		// tmux exposes cursor coordinates and visibility here, but not enough
		// portable style state; live VT output corrects shape after attach.
		Shape: remotegrid.CursorShapeBlock,
	}
}

func (s tmuxPaneState) initialScrollRegion() *remotegrid.ScrollRegion {
	if s.scrollRegion == nil {
		return nil
	}
	scrollRegion := *s.scrollRegion
	return &scrollRegion
}

func tmuxPaneStatesFromListLines(paneLines []string) ([]tmuxPaneState, error) {
	states := make([]tmuxPaneState, 0, len(paneLines))
	for _, line := range paneLines {
		fields := strings.Split(line, "\t")
		if len(fields) < 3 {
			return nil, fmt.Errorf("tmux list-panes line has %d fields, want at least 3", len(fields))
		}
		if !strings.HasPrefix(fields[1], "%") {
			return nil, fmt.Errorf("tmux list-panes pane id %q, want %%N", fields[1])
		}
		paneID, err := strconv.Atoi(strings.TrimPrefix(fields[1], "%"))
		if err != nil {
			return nil, fmt.Errorf("tmux list-panes pane id %q: %w", fields[1], err)
		}
		alternateOn := false
		if len(fields) >= 4 && fields[3] != "" {
			alternate, err := strconv.Atoi(fields[3])
			if err != nil {
				return nil, fmt.Errorf("tmux list-panes alternate_on %q: %w", fields[3], err)
			}
			alternateOn = alternate != 0
		}
		var cursorX *int
		var cursorY *int
		if len(fields) >= 6 && (fields[4] != "" || fields[5] != "") {
			if fields[4] == "" || fields[5] == "" {
				return nil, fmt.Errorf("tmux list-panes cursor coordinates incomplete: cursor_x=%q cursor_y=%q", fields[4], fields[5])
			}
			x, err := strconv.Atoi(fields[4])
			if err != nil {
				return nil, fmt.Errorf("tmux list-panes cursor_x %q: %w", fields[4], err)
			}
			y, err := strconv.Atoi(fields[5])
			if err != nil {
				return nil, fmt.Errorf("tmux list-panes cursor_y %q: %w", fields[5], err)
			}
			cursorX = &x
			cursorY = &y
		}
		var scrollRegion *remotegrid.ScrollRegion
		if len(fields) >= 8 && (fields[6] != "" || fields[7] != "") {
			if fields[6] == "" || fields[7] == "" {
				return nil, fmt.Errorf("tmux list-panes scroll region incomplete: scroll_region_upper=%q scroll_region_lower=%q", fields[6], fields[7])
			}
			upper, err := strconv.Atoi(fields[6])
			if err != nil {
				return nil, fmt.Errorf("tmux list-panes scroll_region_upper %q: %w", fields[6], err)
			}
			lower, err := strconv.Atoi(fields[7])
			if err != nil {
				return nil, fmt.Errorf("tmux list-panes scroll_region_lower %q: %w", fields[7], err)
			}
			scrollRegion = &remotegrid.ScrollRegion{Upper: upper, Lower: lower}
		}
		var cursorVisible *bool
		if len(fields) >= 9 && fields[8] != "" {
			flag, err := strconv.Atoi(fields[8])
			if err != nil {
				return nil, fmt.Errorf("tmux list-panes cursor_flag %q: %w", fields[8], err)
			}
			visible := flag != 0
			cursorVisible = &visible
		}
		states = append(states, tmuxPaneState{paneID: paneID, alternateOn: alternateOn, cursorX: cursorX, cursorY: cursorY, cursorVisible: cursorVisible, scrollRegion: scrollRegion})
	}
	return states, nil
}

func splitTmuxCaptureRows(output string) []string {
	output = strings.TrimSuffix(output, "\n")
	if output == "" {
		return nil
	}
	rows := strings.Split(output, "\n")
	for index, row := range rows {
		rows[index] = strings.TrimSuffix(row, "\r")
	}
	return rows
}

func waitForTmuxListSnapshotLines(socketPath string, sessionName string, timeout time.Duration) ([]string, []string, error) {
	deadline := time.Now().Add(timeout)
	var lastErr error
	for {
		windowLines, paneLines, err := tmuxListSnapshotLines(socketPath, sessionName)
		if err == nil {
			return windowLines, paneLines, nil
		}
		lastErr = err
		if !time.Now().Before(deadline) {
			return nil, nil, lastErr
		}
		time.Sleep(25 * time.Millisecond)
	}
}
