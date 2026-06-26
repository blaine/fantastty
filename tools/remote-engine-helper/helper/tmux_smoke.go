package main

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"fantastty/remote-engine-helper/internal/registry"
	"fantastty/remote-engine-helper/remotegrid"
	"fantastty/remote-engine-helper/tmuxcc"
)

const tmuxSmokeSessionName = "main"

var tmuxCommandTimeout = 2 * time.Second
var runTmuxCommand = runTmuxWithTimeout

var errTmuxControlSnapshotRead = errors.New("tmux control snapshot read")
var errTmuxControlLiveOutputRead = errors.New("tmux control live output read")

func tmuxSmokeProbeTimeout() time.Duration {
	return 2*tmuxCommandTimeout + time.Second
}

type tmuxSmoke struct {
	socketPath  string
	sessionName string
	marker      string
}

func tmuxSmokeEnabled() bool {
	return os.Getenv("FANTASTTY_BOOTSTRAP_TMUX_SMOKE") == "1"
}

func tmuxSmokeSocketPath(runtimeDir, session string) string {
	return filepath.Join(runtimeDir, "tmux-smoke-"+shortID(session)+".sock")
}

func tmuxSmokeMarker(session string) string {
	return "fantastty-remote-grid-smoke-" + shortID(session)
}

func startTmuxSmoke(runtimeDir, session string) (*tmuxSmoke, error) {
	smoke := &tmuxSmoke{
		socketPath:  tmuxSmokeSocketPath(runtimeDir, session),
		sessionName: tmuxSmokeSessionName,
		marker:      tmuxSmokeMarker(session),
	}
	_ = os.Remove(smoke.socketPath)
	script := fmt.Sprintf("printf '%%s\\n' %s; exec sh", shellSingleQuote(smoke.marker))
	if output, err := runTmux(smoke.socketPath, "new-session", "-d", "-s", smoke.sessionName, "sh", "-lc", script); err != nil {
		return nil, fmt.Errorf("start tmux smoke: %w: %s", err, strings.TrimSpace(string(output)))
	}
	return smoke, nil
}

func (s *tmuxSmoke) verify() error {
	deadline := time.Now().Add(2 * time.Second)
	var lastOutput string
	var lastErr error
	for {
		output, err := s.capturePane()
		lastOutput = strings.TrimSpace(output)
		lastErr = err
		if err == nil && strings.Contains(output, s.marker) {
			return nil
		}
		if time.Now().After(deadline) {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if lastErr != nil {
		return fmt.Errorf("tmux smoke capture failed: %w: %s", lastErr, lastOutput)
	}
	return fmt.Errorf("tmux smoke marker %q not visible in capture: %s", s.marker, lastOutput)
}

func (s *tmuxSmoke) verifyLiveOutput() error {
	liveMarker := s.marker + "-live-output"
	ctx, cancel := context.WithTimeout(context.Background(), tmuxCommandTimeout)
	defer cancel()

	tmuxArgs := []string{
		"-f", "/dev/null",
		"-S", s.socketPath,
		"-C", "attach-session", "-t", s.sessionName,
	}
	cmd := exec.CommandContext(ctx, "tmux", tmuxArgs...)
	cmd.Env = tmuxSmokeEnv(os.Environ())
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	if err := cmd.Start(); err != nil {
		return err
	}
	if _, err := fmt.Fprintf(stdin, "refresh-client -C %d,%d\n", len(liveMarker)+1, 1); err != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return err
	}

	sentInput := false
	model := tmuxcc.NewModel("live-output")
	scanErr := tmuxcc.ScanActions(stdout, model, func(action tmuxcc.Action) error {
		if _, ok := action.WorkspaceSnapshot(); ok && !sentInput {
			sentInput = true
			if err := s.sendLiveOutputMarker(liveMarker); err != nil {
				return err
			}
		}
		if output, ok := action.PaneOutput(); ok && bytes.Contains(output.Data, []byte(liveMarker)) {
			return errTmuxControlLiveOutputRead
		}
		return nil
	})
	if scanErr != nil && !errors.Is(scanErr, errTmuxControlLiveOutputRead) {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return fmt.Errorf("tmux live output stream: %w", scanErr)
	}
	if !errors.Is(scanErr, errTmuxControlLiveOutputRead) {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		if !sentInput {
			return errors.New("tmux live output stream ended before layout was ready")
		}
		return fmt.Errorf("tmux live output marker %q was not observed", liveMarker)
	}
	if _, err := fmt.Fprintln(stdin, "detach-client"); err != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return err
	}
	_ = stdin.Close()
	if err := cmd.Wait(); err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return fmt.Errorf("tmux live output stream timed out after %s: %s", tmuxCommandTimeout, strings.TrimSpace(stderr.String()))
		}
		return fmt.Errorf("tmux live output stream: %w: %s", err, strings.TrimSpace(stderr.String()))
	}
	return nil
}

func (s *tmuxSmoke) sendLiveOutputMarker(marker string) error {
	command := fmt.Sprintf("printf '%%s\\n' %s", shellSingleQuote(marker))
	for _, args := range [][]string{
		{"send-keys", "-t", s.sessionName, "C-u"},
		{"send-keys", "-l", "-t", s.sessionName, command},
		{"send-keys", "-t", s.sessionName, "Enter"},
	} {
		output, err := runTmux(s.socketPath, args...)
		if err != nil {
			return fmt.Errorf("send tmux live output marker: %w: %s", err, strings.TrimSpace(string(output)))
		}
	}
	return nil
}

func (s *tmuxSmoke) cleanup() error {
	output, err := runTmux(s.socketPath, "kill-server")
	removeErr := os.Remove(s.socketPath)
	if err != nil {
		return fmt.Errorf("stop tmux smoke: %w: %s", err, strings.TrimSpace(string(output)))
	}
	if removeErr != nil && !errors.Is(removeErr, os.ErrNotExist) {
		return removeErr
	}
	return nil
}

func (s *tmuxSmoke) capturePane() (string, error) {
	output, err := runTmux(s.socketPath, "capture-pane", "-p", "-S", "-100", "-t", s.sessionName)
	return string(output), err
}

func (s *tmuxSmoke) workspaceMessages(workspaceID string) ([]remotegrid.WorkspaceMessage, error) {
	size := remotegrid.GridSize{Columns: len(s.marker) + 1, Rows: 1}
	if err := s.resizeControlClient(size); err != nil {
		return nil, err
	}
	windowLines, paneLines, err := s.listSnapshotLines()
	if err != nil {
		return nil, err
	}
	model := tmuxcc.NewModel(workspaceID)
	actions, err := model.ApplyListSnapshot(windowLines, paneLines)
	if err != nil {
		return nil, err
	}
	snapshot, err := smokeWorkspaceSnapshot(actions)
	if err != nil {
		return nil, err
	}
	capture, err := s.capturePane()
	if err != nil {
		return nil, err
	}
	return buildSmokeWorkspaceMessagesFromSnapshot(workspaceID, s.marker, snapshot, capture)
}

func (s *tmuxSmoke) listSnapshotLines() ([]string, []string, error) {
	return tmuxListSnapshotLines(s.socketPath, s.sessionName)
}

func (s *tmuxSmoke) resizeControlClient(size remotegrid.GridSize) error {
	ctx, cancel := context.WithTimeout(context.Background(), tmuxCommandTimeout)
	defer cancel()

	tmuxArgs := []string{
		"-f", "/dev/null",
		"-S", s.socketPath,
		"-C", "attach-session", "-t", s.sessionName,
	}
	cmd := exec.CommandContext(ctx, "tmux", tmuxArgs...)
	cmd.Env = tmuxSmokeEnv(os.Environ())
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	if err := cmd.Start(); err != nil {
		return err
	}
	if _, err := fmt.Fprintf(stdin, "refresh-client -C %d,%d\n", size.Columns, size.Rows); err != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return err
	}

	model := tmuxcc.NewModel("resize")
	scanErr := tmuxcc.ScanActions(stdout, model, func(action tmuxcc.Action) error {
		if _, ok := action.WorkspaceSnapshot(); ok {
			return errTmuxControlSnapshotRead
		}
		return nil
	})
	if scanErr != nil && !errors.Is(scanErr, errTmuxControlSnapshotRead) {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return fmt.Errorf("tmux control stream: %w", scanErr)
	}
	if _, err := fmt.Fprintln(stdin, "detach-client"); err != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return err
	}
	_ = stdin.Close()
	if err := cmd.Wait(); err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return fmt.Errorf("tmux control stream timed out after %s: %s", tmuxCommandTimeout, strings.TrimSpace(stderr.String()))
		}
		return fmt.Errorf("tmux control stream: %w: %s", err, strings.TrimSpace(stderr.String()))
	}
	return nil
}

func probeTmuxSmoke(record registry.SessionRecord) error {
	if record.SocketPath == "" {
		return errors.New("registry entry has no control socket")
	}
	conn, err := net.DialTimeout("unix", record.SocketPath, 2*time.Second)
	if err != nil {
		return err
	}
	defer conn.Close()
	if err := conn.SetDeadline(time.Now().Add(tmuxSmokeProbeTimeout())); err != nil {
		return err
	}
	if _, err := fmt.Fprintf(conn, "tmux-smoke %s\n", record.Session); err != nil {
		return err
	}
	line, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil {
		return err
	}
	if !strings.HasPrefix(line, "ok ") {
		return fmt.Errorf("tmux smoke probe rejected: %s", strings.TrimSpace(line))
	}
	marker := parseBootstrapValue(line, "marker")
	if marker == "" {
		return errors.New("tmux smoke probe missing marker")
	}
	expected := tmuxSmokeMarker(record.Session)
	if marker != expected {
		return fmt.Errorf("tmux smoke marker mismatch: got %q want %q", marker, expected)
	}
	if got := parseBootstrapValue(line, "live_output"); got != "true" {
		return fmt.Errorf("tmux smoke live_output = %q, want true", got)
	}
	return nil
}

func runTmux(socketPath string, args ...string) ([]byte, error) {
	return runTmuxWithTimeout(tmuxCommandTimeout, socketPath, args...)
}

func runTmuxWithTimeout(timeout time.Duration, socketPath string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	tmuxArgs := append([]string(nil), args...)
	if socketPath != "" {
		tmuxArgs = append([]string{"-f", "/dev/null", "-S", socketPath}, args...)
	}
	cmd := exec.CommandContext(ctx, "tmux", tmuxArgs...)
	cmd.Env = tmuxSmokeEnv(os.Environ())
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	var output bytes.Buffer
	cmd.Stdout = &output
	cmd.Stderr = &output
	if err := cmd.Start(); err != nil {
		return output.Bytes(), err
	}
	done := make(chan error, 1)
	go func() {
		done <- cmd.Wait()
	}()
	select {
	case err := <-done:
		return output.Bytes(), err
	case <-ctx.Done():
		if cmd.Process != nil {
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		}
		<-done
		return output.Bytes(), fmt.Errorf("tmux command timed out after %s", timeout)
	}
}

func tmuxSmokeEnv(env []string) []string {
	filtered := make([]string, 0, len(env))
	for _, item := range env {
		name, _, ok := strings.Cut(item, "=")
		if !ok {
			filtered = append(filtered, item)
			continue
		}
		if name == "TMUX" || name == "TMUX_PANE" {
			continue
		}
		filtered = append(filtered, item)
	}
	return filtered
}

func nonEmptyLines(output string) []string {
	var lines []string
	for _, line := range strings.Split(output, "\n") {
		if line != "" {
			lines = append(lines, line)
		}
	}
	return lines
}

func shellSingleQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'"
}
