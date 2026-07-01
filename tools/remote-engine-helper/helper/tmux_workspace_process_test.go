package main

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"fantastty/remote-engine-helper/remotegrid"
)

func TestStartTmuxWorkspaceSourceUsesPrivateSocketAndStreamsOutput(t *testing.T) {
	logPath := installFakeTmuxProgram(t, `#!/bin/sh
set -eu
for arg in "$@"; do
  printf '%s\t' "$arg" >>"$FAKE_TMUX_LOG"
done
printf '\n' >>"$FAKE_TMUX_LOG"
case " $* " in
  *" list-windows "*)
    printf '@1\tmain\t0000,2x1,0,0,%%7\t0\t1\n'
    ;;
  *" list-panes "*)
    printf '@1\t%%7\t1\n'
    ;;
  *" -C new-session "*)
    IFS= read -r refresh
    printf 'STDIN:%s\n' "$refresh" >>"$FAKE_TMUX_LOG"
    printf '%%output %%7 bb\n'
    IFS= read -r detach || true
    printf 'STDIN:%s\n' "$detach" >>"$FAKE_TMUX_LOG"
    ;;
esac
`)
	renderer := &sourceFakeRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: sourceKeyframe(7, 1, "aa"),
		},
		deltas: map[string]remotegrid.PaneDelta{
			"bb": sourceDelta(7, 1, "bb"),
		},
	}
	socketPath := filepath.Join(t.TempDir(), "remote-tmux.sock")

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runtime, err := startTmuxWorkspaceSource(ctx, tmuxWorkspaceSourceOptions{
		WorkspaceID: "workspace-1",
		SessionName: "fantastty-remote-workspace-1",
		SocketPath:  socketPath,
		Renderer:    renderer,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	payload := waitForTmuxProcessDatagram(t, runtime, "workspace-1")
	if len(payload.Datagrams) != 1 {
		t.Fatalf("datagrams = %d, want 1", len(payload.Datagrams))
	}

	logData := readTmuxProcessTextFile(t, logPath)
	if !strings.Contains(logData, "-S\t"+socketPath) {
		t.Fatalf("tmux log does not contain private socket %q: %s", socketPath, logData)
	}
	if !strings.Contains(logData, "-C\t") || !strings.Contains(logData, "new-session\t") {
		t.Fatalf("tmux log does not contain control new-session: %s", logData)
	}
	if !strings.Contains(logData, "STDIN:refresh-client -C 80,24") {
		t.Fatalf("tmux log does not contain refresh-client sizing: %s", logData)
	}
	if !strings.Contains(logData, "pause-after=") {
		t.Fatalf("tmux log does not contain pause-after flow control request: %s", logData)
	}
}

func TestStartTmuxWorkspaceSourceCanAttachExternalDefaultServerSession(t *testing.T) {
	logPath := installFakeTmuxProgram(t, `#!/bin/sh
set -eu
for arg in "$@"; do
  printf '%s\t' "$arg" >>"$FAKE_TMUX_LOG"
done
printf '\n' >>"$FAKE_TMUX_LOG"
case " $* " in
  *" list-windows "*)
    printf '@1\tmain\t0000,2x1,0,0,%%7\t0\t1\n'
    ;;
  *" list-panes "*)
    printf '@1\t%%7\t1\n'
    ;;
  *" -C attach-session "*)
    printf '%s\n' "$4" >"$FAKE_TMUX_LOG.attach_target"
    IFS= read -r refresh
    printf 'STDIN:%s\n' "$refresh" >>"$FAKE_TMUX_LOG"
    printf '%%output %%7 bb\n'
    IFS= read -r detach || true
    printf 'STDIN:%s\n' "$detach" >>"$FAKE_TMUX_LOG"
    ;;
esac
`)
	renderer := &sourceFakeRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: sourceKeyframe(7, 1, "aa"),
		},
		deltas: map[string]remotegrid.PaneDelta{
			"bb": sourceDelta(7, 1, "bb"),
		},
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runtime, err := startTmuxWorkspaceSource(ctx, tmuxWorkspaceSourceOptions{
		WorkspaceID:      "workspace-1",
		SessionName:      "0",
		UseDefaultServer: true,
		Renderer:         renderer,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	payload := waitForTmuxProcessDatagram(t, runtime, "workspace-1")
	if len(payload.Datagrams) != 1 {
		t.Fatalf("datagrams = %d, want 1", len(payload.Datagrams))
	}

	logData := readTmuxProcessTextFile(t, logPath)
	if strings.Contains(logData, "-f\t/dev/null\t-S\t") {
		t.Fatalf("tmux log contains private socket flag for external session: %s", logData)
	}
	attachTarget := strings.TrimSpace(readTmuxProcessTextFile(t, logPath+".attach_target"))
	if attachTarget != "0" {
		t.Fatalf("tmux control attach target = %q, want existing session 0; log: %s", attachTarget, logData)
	}
}

func TestStartTmuxWorkspaceSourceSeedsInitialKeyframeFromCapturePane(t *testing.T) {
	logPath := installFakeTmuxProgram(t, `#!/bin/sh
set -eu
for arg in "$@"; do
  printf '%s\t' "$arg" >>"$FAKE_TMUX_LOG"
done
printf '\n' >>"$FAKE_TMUX_LOG"
case " $* " in
  *" list-windows "*)
    printf '@1\tmain\t0000,8x2,0,0,%%7\t0\t1\n'
    ;;
  *" list-panes "*)
    printf '@1\t%%7\t1\n'
    ;;
  *" capture-pane "*)
    printf 'history\nfish\nshell\n'
    ;;
  *" -C new-session "*)
    IFS= read -r refresh
    printf 'STDIN:%s\n' "$refresh" >>"$FAKE_TMUX_LOG"
    IFS= read -r detach || true
    printf 'STDIN:%s\n' "$detach" >>"$FAKE_TMUX_LOG"
    ;;
esac
`)
	renderer := &sourceFakeRenderer{seedFromInitialRows: true}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runtime, err := startTmuxWorkspaceSource(ctx, tmuxWorkspaceSourceOptions{
		WorkspaceID: "workspace-1",
		SessionName: "fantastty-remote-workspace-1",
		SocketPath:  filepath.Join(t.TempDir(), "remote-tmux.sock"),
		Renderer:    renderer,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	payload, err := runtime.CurrentPayload("workspace-1")
	if err != nil {
		t.Fatal(err)
	}
	keyframe := sourceOnlyKeyframe(t, payload.Reliable)
	if got := sourceKeyframeText(keyframe); !strings.Contains(got, "fish") || !strings.Contains(got, "shell") {
		t.Fatalf("initial keyframe text = %q, want capture-pane rows", got)
	}
	if got := renderer.seededRows[7]; !reflect.DeepEqual(got, []string{"fish", "shell"}) {
		t.Fatalf("renderer seeded rows = %q, want capture-pane rows", got)
	}
	logData := readTmuxProcessTextFile(t, logPath)
	if !strings.Contains(logData, "capture-pane\t-peqJN\t-S\t-2000\t-t\t%7") {
		t.Fatalf("tmux log does not contain visible capture-pane seed command: %s", logData)
	}
}

func TestStartTmuxWorkspaceSourceSeedsInitialKeyframeFromVisibleCapturePane(t *testing.T) {
	logPath := installFakeTmuxProgram(t, `#!/bin/sh
set -eu
for arg in "$@"; do
  printf '%s\t' "$arg" >>"$FAKE_TMUX_LOG"
done
printf '\n' >>"$FAKE_TMUX_LOG"
case " $* " in
  *" list-windows "*)
    printf '@1\tclaude\t0000,12x2,0,0,%%7\t0\t1\n'
    ;;
  *" list-panes "*)
    printf '@1\t%%7\t1\n'
    ;;
  *" capture-pane "*)
    case " $* " in
      *" -a "*) printf 'stale-launch\n' ;;
      *) printf 'visible-ui\n' ;;
    esac
    ;;
  *" -C new-session "*)
    IFS= read -r refresh
    printf 'STDIN:%s\n' "$refresh" >>"$FAKE_TMUX_LOG"
    IFS= read -r detach || true
    printf 'STDIN:%s\n' "$detach" >>"$FAKE_TMUX_LOG"
    ;;
esac
`)
	renderer := &sourceFakeRenderer{seedFromInitialRows: true}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runtime, err := startTmuxWorkspaceSource(ctx, tmuxWorkspaceSourceOptions{
		WorkspaceID: "workspace-1",
		SessionName: "fantastty-remote-workspace-1",
		SocketPath:  filepath.Join(t.TempDir(), "remote-tmux.sock"),
		Renderer:    renderer,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	payload, err := runtime.CurrentPayload("workspace-1")
	if err != nil {
		t.Fatal(err)
	}
	keyframe := sourceOnlyKeyframe(t, payload.Reliable)
	if got := sourceKeyframeText(keyframe); !strings.Contains(got, "visible-ui") || strings.Contains(got, "stale-launch") {
		t.Fatalf("initial keyframe text = %q, want visible capture rows", got)
	}
	if got := renderer.seededRows[7]; !reflect.DeepEqual(got, []string{"visible-ui"}) {
		t.Fatalf("renderer seeded rows = %q, want visible capture rows", got)
	}
	logData := readTmuxProcessTextFile(t, logPath)
	if !strings.Contains(logData, "capture-pane\t-peqJN\t-S\t-2000\t-t\t%7") {
		t.Fatalf("tmux log does not contain visible capture-pane seed command: %s", logData)
	}
	if !strings.Contains(logData, "capture-pane\t-peqJN\t-a\t-S\t-2000\t-t\t%7") {
		t.Fatalf("tmux log does not contain best-effort alternate capture-pane command: %s", logData)
	}
}

func TestStartTmuxWorkspaceSourceCapturesPrimaryAlternateAndPaneState(t *testing.T) {
	logPath := installFakeTmuxProgram(t, `#!/bin/sh
set -eu
for arg in "$@"; do
  printf '%s\t' "$arg" >>"$FAKE_TMUX_LOG"
done
printf '\n' >>"$FAKE_TMUX_LOG"
case " $* " in
  *" list-windows "*)
    printf '@1\tclaude\t0000,12x2,0,0,%%7\t0\t1\n'
    ;;
  *" list-panes "*)
    printf '@1\t%%7\t1\t1\t3\t1\t0\t1\t1\n'
    ;;
  *" capture-pane "*)
    case " $* " in
      *" -a "*) printf 'stale-launch\n' ;;
      *) printf 'visible-ui\n' ;;
    esac
    ;;
  *" -C new-session "*)
    IFS= read -r refresh
    printf 'STDIN:%s\n' "$refresh" >>"$FAKE_TMUX_LOG"
    IFS= read -r detach || true
    printf 'STDIN:%s\n' "$detach" >>"$FAKE_TMUX_LOG"
    ;;
esac
`)
	renderer := &sourceFakeRenderer{seedFromInitialRows: true}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runtime, err := startTmuxWorkspaceSource(ctx, tmuxWorkspaceSourceOptions{
		WorkspaceID: "workspace-1",
		SessionName: "fantastty-remote-workspace-1",
		SocketPath:  filepath.Join(t.TempDir(), "remote-tmux.sock"),
		Renderer:    renderer,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	payload, err := runtime.CurrentPayload("workspace-1")
	if err != nil {
		t.Fatal(err)
	}
	keyframe := sourceOnlyKeyframe(t, payload.Reliable)
	if got := sourceKeyframeText(keyframe); !strings.Contains(got, "visible-ui") || strings.Contains(got, "stale-launch") {
		t.Fatalf("initial keyframe text = %q, want visible alternate capture rows", got)
	}
	capture := renderer.seededCaptures[7]
	if capture.ActiveScreen != remotegrid.ActiveScreenAlternate {
		t.Fatalf("seeded active screen = %q, want alternate", capture.ActiveScreen)
	}
	if !reflect.DeepEqual(capture.PrimaryRows, []string{"stale-launch"}) {
		t.Fatalf("seeded primary rows = %q, want stale-launch", capture.PrimaryRows)
	}
	if !reflect.DeepEqual(capture.AlternateRows, []string{"visible-ui"}) {
		t.Fatalf("seeded alternate rows = %q, want visible-ui", capture.AlternateRows)
	}
	if capture.Cursor == nil {
		t.Fatal("seeded cursor = nil, want tmux cursor coordinates")
	}
	if *capture.Cursor != (remotegrid.CursorState{Row: 1, Column: 3, Visible: true, Shape: remotegrid.CursorShapeBlock}) {
		t.Fatalf("seeded cursor = %+v, want row 1 column 3", *capture.Cursor)
	}
	if keyframe.Cursor.Row != 1 || keyframe.Cursor.Column != 3 {
		t.Fatalf("initial keyframe cursor = %+v, want row 1 column 3", keyframe.Cursor)
	}
	if capture.ScrollRegion == nil {
		t.Fatal("seeded scroll region = nil, want tmux scroll region")
	}
	if *capture.ScrollRegion != (remotegrid.ScrollRegion{Upper: 0, Lower: 1}) {
		t.Fatalf("seeded scroll region = %+v, want 0..1", *capture.ScrollRegion)
	}

	logData := readTmuxProcessTextFile(t, logPath)
	if !strings.Contains(logData, "#{alternate_on}") ||
		!strings.Contains(logData, "#{cursor_x}") ||
		!strings.Contains(logData, "#{cursor_y}") ||
		!strings.Contains(logData, "#{scroll_region_upper}") ||
		!strings.Contains(logData, "#{scroll_region_lower}") ||
		!strings.Contains(logData, "#{cursor_flag}") {
		t.Fatalf("tmux log does not contain pane state list-panes format: %s", logData)
	}
	if got := strings.Count(logData, "capture-pane\t-peqJN\t-S\t-2000\t-t\t%7"); got != 1 {
		t.Fatalf("primary capture count = %d, want 1; log=%s", got, logData)
	}
	if got := strings.Count(logData, "capture-pane\t-peqJN\t-a\t-S\t-2000\t-t\t%7"); got != 1 {
		t.Fatalf("alternate capture count = %d, want 1; log=%s", got, logData)
	}
}

func TestStartTmuxWorkspaceSourceMapsVisibleCaptureToActiveAlternateScreen(t *testing.T) {
	installFakeTmuxProgram(t, `#!/bin/sh
set -eu
case " $* " in
  *" list-windows "*)
    printf '@1\tclaude\t0000,12x2,0,0,%%7\t0\t1\n'
    ;;
  *" list-panes "*)
    printf '@1\t%%7\t1\t1\t3\t1\t0\t1\t1\n'
    ;;
  *" capture-pane "*)
    case " $* " in
      *" -a "*) printf 'regular-shell\n' ;;
      *) printf 'visible-tui\n' ;;
    esac
    ;;
  *" -C new-session "*)
    IFS= read -r refresh
    IFS= read -r detach || true
    ;;
esac
`)
	renderer := &sourceFakeRenderer{seedFromInitialRows: true}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runtime, err := startTmuxWorkspaceSource(ctx, tmuxWorkspaceSourceOptions{
		WorkspaceID: "workspace-1",
		SessionName: "fantastty-remote-workspace-1",
		SocketPath:  filepath.Join(t.TempDir(), "remote-tmux.sock"),
		Renderer:    renderer,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	payload, err := runtime.CurrentPayload("workspace-1")
	if err != nil {
		t.Fatal(err)
	}
	keyframe := sourceOnlyKeyframe(t, payload.Reliable)
	if got := sourceKeyframeText(keyframe); !strings.Contains(got, "visible-tui") || strings.Contains(got, "regular-shell") {
		t.Fatalf("initial keyframe text = %q, want visible alternate capture rows", got)
	}
	capture := renderer.seededCaptures[7]
	if !reflect.DeepEqual(capture.PrimaryRows, []string{"regular-shell"}) {
		t.Fatalf("seeded primary rows = %q, want regular-shell", capture.PrimaryRows)
	}
	if !reflect.DeepEqual(capture.AlternateRows, []string{"visible-tui"}) {
		t.Fatalf("seeded alternate rows = %q, want visible-tui", capture.AlternateRows)
	}
}

func TestTmuxPaneStatesFromListLinesCapturesCursorVisibility(t *testing.T) {
	states, err := tmuxPaneStatesFromListLines([]string{"@1\t%7\t1\t0\t3\t1\t0\t1\t0"})
	if err != nil {
		t.Fatal(err)
	}
	if len(states) != 1 {
		t.Fatalf("state count = %d, want 1", len(states))
	}
	cursor := states[0].cursor()
	if cursor == nil {
		t.Fatal("cursor = nil, want captured cursor")
	}
	if cursor.Visible {
		t.Fatalf("cursor visible = true, want false from cursor_flag=0")
	}
	if cursor.Shape != remotegrid.CursorShapeBlock {
		t.Fatalf("cursor shape = %q, want block fallback", cursor.Shape)
	}
}

func TestTmuxPaneStatesFromListLinesTreatsEmptyOptionalRenderStateFieldsAsAbsent(t *testing.T) {
	states, err := tmuxPaneStatesFromListLines([]string{"@1\t%7\t1\t0\t3\t1\t\t\t"})
	if err != nil {
		t.Fatal(err)
	}
	if len(states) != 1 {
		t.Fatalf("state count = %d, want 1", len(states))
	}
	cursor := states[0].cursor()
	if cursor == nil {
		t.Fatal("cursor = nil, want captured cursor coordinates")
	}
	if !cursor.Visible {
		t.Fatal("cursor visible = false, want default visible when cursor_flag is absent")
	}
	if states[0].initialScrollRegion() != nil {
		t.Fatalf("scroll region = %+v, want nil when tmux fields are empty", states[0].initialScrollRegion())
	}
}

func TestTmuxPaneStatesFromListLinesRejectsMalformedRenderStateFields(t *testing.T) {
	tests := []struct {
		name string
		line string
		want string
	}{
		{
			name: "alternate screen flag",
			line: "@1\t%7\t1\tnope\t3\t1\t0\t1\t1",
			want: "alternate_on",
		},
		{
			name: "cursor x",
			line: "@1\t%7\t1\t1\tnope\t1\t0\t1\t1",
			want: "cursor_x",
		},
		{
			name: "cursor y",
			line: "@1\t%7\t1\t1\t3\tnope\t0\t1\t1",
			want: "cursor_y",
		},
		{
			name: "scroll region upper",
			line: "@1\t%7\t1\t1\t3\t1\tnope\t1\t1",
			want: "scroll_region_upper",
		},
		{
			name: "scroll region lower",
			line: "@1\t%7\t1\t1\t3\t1\t0\tnope\t1",
			want: "scroll_region_lower",
		},
		{
			name: "cursor visibility",
			line: "@1\t%7\t1\t1\t3\t1\t0\t1\tnope",
			want: "cursor_flag",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := tmuxPaneStatesFromListLines([]string{tt.line})
			if err == nil {
				t.Fatal("error = nil, want malformed render-state field rejection")
			}
			if !strings.Contains(err.Error(), tt.want) {
				t.Fatalf("error = %q, want field %q", err, tt.want)
			}
		})
	}
}

func TestStartTmuxWorkspaceSourceKeepsBlankVisibleAlternateCaptureWhenActive(t *testing.T) {
	installFakeTmuxProgram(t, `#!/bin/sh
set -eu
for arg in "$@"; do
  printf '%s\t' "$arg" >>"$FAKE_TMUX_LOG"
done
printf '\n' >>"$FAKE_TMUX_LOG"
case " $* " in
  *" list-windows "*)
    printf '@1\tvim\t0000,10x2,0,0,%%7\t0\t1\n'
    ;;
  *" list-panes "*)
    printf '@1\t%%7\t1\t1\t0\t0\t0\t1\n'
    ;;
  *" capture-pane "*)
    case " $* " in
      *" -a "*) printf 'alt-ui\n' ;;
      *) printf '\n\n' ;;
    esac
    ;;
  *" -C new-session "*)
    IFS= read -r refresh
    printf 'STDIN:%s\n' "$refresh" >>"$FAKE_TMUX_LOG"
    IFS= read -r detach || true
    printf 'STDIN:%s\n' "$detach" >>"$FAKE_TMUX_LOG"
    ;;
esac
`)
	renderer := &sourceFakeRenderer{seedFromInitialRows: true}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runtime, err := startTmuxWorkspaceSource(ctx, tmuxWorkspaceSourceOptions{
		WorkspaceID: "workspace-1",
		SessionName: "fantastty-remote-workspace-1",
		SocketPath:  filepath.Join(t.TempDir(), "remote-tmux.sock"),
		Renderer:    renderer,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	payload, err := runtime.CurrentPayload("workspace-1")
	if err != nil {
		t.Fatal(err)
	}
	keyframe := sourceOnlyKeyframe(t, payload.Reliable)
	if got := sourceKeyframeText(keyframe); strings.Contains(got, "alt-ui") {
		t.Fatalf("initial keyframe text = %q, want blank visible alternate capture without regular rows", got)
	}
	if got := renderer.seededRows[7]; !reflect.DeepEqual(got, []string{"", ""}) {
		t.Fatalf("renderer seeded rows = %q, want blank visible alternate capture", got)
	}
}

func TestTmuxWorkspaceRuntimeRequestKeyframeRepaintsMissingPaneFromCapture(t *testing.T) {
	logPath := installFakeTmuxProgram(t, `#!/bin/sh
set -eu
for arg in "$@"; do
  printf '%s\t' "$arg" >>"$FAKE_TMUX_LOG"
done
printf '\n' >>"$FAKE_TMUX_LOG"
case " $* " in
  *" list-windows "*)
    printf '@1\tmain\t0000,8x2,0,0,%%7\t0\t1\n'
    ;;
  *" list-panes "*)
    printf '@1\t%%7\t1\n'
    ;;
  *" capture-pane "*)
    count_file="$FAKE_TMUX_LOG.capture_count"
    count=0
    if [ -f "$count_file" ]; then
      count="$(cat "$count_file")"
    fi
    count=$((count + 1))
    printf '%s' "$count" >"$count_file"
    if [ "$count" -gt 1 ]; then
      printf 'painted\n'
    fi
    ;;
  *" -C new-session "*)
    IFS= read -r refresh
    printf 'STDIN:%s\n' "$refresh" >>"$FAKE_TMUX_LOG"
    IFS= read -r detach || true
    printf 'STDIN:%s\n' "$detach" >>"$FAKE_TMUX_LOG"
    ;;
esac
`)
	renderer := &sourceFakeRenderer{seedFromInitialRows: true}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runtime, err := startTmuxWorkspaceSource(ctx, tmuxWorkspaceSourceOptions{
		WorkspaceID: "workspace-1",
		SessionName: "fantastty-remote-workspace-1",
		SocketPath:  filepath.Join(t.TempDir(), "remote-tmux.sock"),
		Renderer:    renderer,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	payload, err := runtime.RequestKeyframe("workspace-1", 7)
	if err != nil {
		t.Fatal(err)
	}

	if !payloadContainsPaneKeyframe(payload, 7) {
		t.Fatalf("request keyframe payload = %v, want keyframe for pane 7", sourceReliableKinds(t, payload.Reliable))
	}
	if got := sourceKeyframeText(sourceOnlyKeyframe(t, payload.Reliable)); !strings.Contains(got, "painted") {
		t.Fatalf("request keyframe text = %q, want repaint capture", got)
	}
	logData := readTmuxProcessTextFile(t, logPath)
	if got := strings.Count(logData, "capture-pane\t-peqJN\t-S\t-2000\t-t\t%7"); got != 2 {
		t.Fatalf("capture-pane command count = %d, want initial seed plus request repaint; log=%s", got, logData)
	}
}

func TestTmuxWorkspaceRuntimeRequestKeyframeUsesStructuredCaptureFallback(t *testing.T) {
	installFakeTmuxProgram(t, `#!/bin/sh
set -eu
for arg in "$@"; do
  printf '%s\t' "$arg" >>"$FAKE_TMUX_LOG"
done
printf '\n' >>"$FAKE_TMUX_LOG"
case " $* " in
  *" list-windows "*)
    printf '@1\tvim\t0000,11x2,0,0,%%7\t0\t1\n'
    ;;
  *" list-panes "*)
    printf '@1\t%%7\t1\t1\t0\t0\t0\t1\n'
    ;;
  *" capture-pane "*)
    mode="visible"
    case " $* " in *" -a "*) mode="alternate-flag" ;; esac
    count_file="$FAKE_TMUX_LOG.capture_count.$mode"
    count=0
    if [ -f "$count_file" ]; then count="$(cat "$count_file")"; fi
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_file"
    if [ "$mode" = "visible" ]; then
      if [ "$count" -eq 1 ]; then printf 'alt-initial\n'; else printf 'alt-repaint\n'; fi
    else
      if [ "$count" -eq 1 ]; then printf 'initial\n'; else printf '\n\n'; fi
    fi
    ;;
  *" -C new-session "*)
    IFS= read -r refresh
    printf 'STDIN:%s\n' "$refresh" >>"$FAKE_TMUX_LOG"
    IFS= read -r detach || true
    printf 'STDIN:%s\n' "$detach" >>"$FAKE_TMUX_LOG"
    ;;
esac
`)
	renderer := &sourceFakeRenderer{seedFromInitialRows: true}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runtime, err := startTmuxWorkspaceSource(ctx, tmuxWorkspaceSourceOptions{
		WorkspaceID: "workspace-1",
		SessionName: "fantastty-remote-workspace-1",
		SocketPath:  filepath.Join(t.TempDir(), "remote-tmux.sock"),
		Renderer:    renderer,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	payload, err := runtime.RequestKeyframe("workspace-1", 7)
	if err != nil {
		t.Fatal(err)
	}

	if got := sourceKeyframeText(sourceKeyframeForPane(t, payload.Reliable, 7)); !strings.Contains(got, "alt-repaint") {
		t.Fatalf("request keyframe text = %q, want alternate repaint capture", got)
	}
}

func TestTmuxWorkspaceRuntimeRequestKeyframesRecapturesActiveAlternateScreen(t *testing.T) {
	logPath := installFakeTmuxProgram(t, `#!/bin/sh
set -eu
for arg in "$@"; do
  printf '%s\t' "$arg" >>"$FAKE_TMUX_LOG"
done
printf '\n' >>"$FAKE_TMUX_LOG"
case " $* " in
  *" list-windows "*)
    printf '@1\tclaude\t0000,20x2,0,0,%%7\t0\t1\n'
    ;;
  *" list-panes "*)
    count_file="$FAKE_TMUX_LOG.list_panes_count"
    count=0
    if [ -f "$count_file" ]; then count="$(cat "$count_file")"; fi
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_file"
    if [ "$count" -eq 1 ]; then
      printf '@1\t%%7\t1\t0\t0\t0\t0\t1\t1\n'
    else
      printf '@1\t%%7\t1\t1\t0\t0\t0\t1\t1\n'
    fi
    ;;
  *" capture-pane "*)
    mode="visible"
    case " $* " in *" -a "*) mode="alternate-flag" ;; esac
    count_file="$FAKE_TMUX_LOG.capture_count.$mode"
    count=0
    if [ -f "$count_file" ]; then count="$(cat "$count_file")"; fi
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_file"
    if [ "$mode" = "visible" ]; then
      if [ "$count" -eq 1 ]; then printf 'regular-initial\n'; else printf 'alt-current\n'; fi
    else
      if [ "$count" -eq 1 ]; then printf '\n\n'; else printf 'regular-current\n'; fi
    fi
    ;;
  *" -C new-session "*)
    IFS= read -r refresh
    printf 'STDIN:%s\n' "$refresh" >>"$FAKE_TMUX_LOG"
    IFS= read -r detach || true
    printf 'STDIN:%s\n' "$detach" >>"$FAKE_TMUX_LOG"
    ;;
esac
`)
	renderer := &sourceFakeRenderer{seedFromInitialRows: true}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runtime, err := startTmuxWorkspaceSource(ctx, tmuxWorkspaceSourceOptions{
		WorkspaceID: "workspace-1",
		SessionName: "fantastty-remote-workspace-1",
		SocketPath:  filepath.Join(t.TempDir(), "remote-tmux.sock"),
		Renderer:    renderer,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	initial, err := runtime.CurrentPayload("workspace-1")
	if err != nil {
		t.Fatal(err)
	}
	if got := sourceKeyframeText(sourceKeyframeForPane(t, initial.Reliable, 7)); !strings.Contains(got, "regular-initial") {
		t.Fatalf("initial keyframe text = %q, want regular screen before tmux flips", got)
	}

	payload, err := runtime.RequestKeyframes("workspace-1")
	if err != nil {
		t.Fatal(err)
	}

	keyframe := sourceKeyframeForPane(t, payload.Reliable, 7)
	if got := sourceKeyframeText(keyframe); !strings.Contains(got, "alt-current") || strings.Contains(got, "regular-current") || strings.Contains(got, "regular-initial") {
		t.Fatalf("request keyframes text = %q, want current visible alternate screen", got)
	}
	capture := renderer.seededCaptures[7]
	if capture.ActiveScreen != remotegrid.ActiveScreenAlternate {
		t.Fatalf("recaptured active screen = %q, want alternate", capture.ActiveScreen)
	}
	logData := readTmuxProcessTextFile(t, logPath)
	if got := strings.Count(logData, "capture-pane\t-peqJN\t-S\t-2000\t-t\t%7"); got != 2 {
		t.Fatalf("visible capture count = %d, want initial seed plus full-keyframe recapture; log=%s", got, logData)
	}
	if got := strings.Count(logData, "capture-pane\t-peqJN\t-a\t-S\t-2000\t-t\t%7"); got != 2 {
		t.Fatalf("alternate-flag capture count = %d, want initial seed plus full-keyframe recapture; log=%s", got, logData)
	}
}

func TestTmuxWorkspaceRuntimeSubscribeKeyframesRecapturesActiveAlternateScreen(t *testing.T) {
	installFakeTmuxProgram(t, `#!/bin/sh
set -eu
case " $* " in
  *" list-windows "*)
    printf '@1\tclaude\t0000,20x2,0,0,%%7\t0\t1\n'
    ;;
  *" list-panes "*)
    count_file="$FAKE_TMUX_LOG.list_panes_count"
    count=0
    if [ -f "$count_file" ]; then count="$(cat "$count_file")"; fi
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_file"
    if [ "$count" -eq 1 ]; then
      printf '@1\t%%7\t1\t0\t0\t0\t0\t1\t1\n'
    else
      printf '@1\t%%7\t1\t1\t0\t0\t0\t1\t1\n'
    fi
    ;;
  *" capture-pane "*)
    mode="visible"
    case " $* " in *" -a "*) mode="alternate-flag" ;; esac
    count_file="$FAKE_TMUX_LOG.capture_count.$mode"
    count=0
    if [ -f "$count_file" ]; then count="$(cat "$count_file")"; fi
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_file"
    if [ "$mode" = "visible" ]; then
      if [ "$count" -eq 1 ]; then printf 'regular-initial\n'; else printf 'alt-current\n'; fi
    else
      if [ "$count" -eq 1 ]; then printf '\n\n'; else printf 'regular-current\n'; fi
    fi
    ;;
  *" -C new-session "*)
    IFS= read -r refresh
    IFS= read -r detach || true
    ;;
esac
`)
	renderer := &sourceFakeRenderer{seedFromInitialRows: true}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runtime, err := startTmuxWorkspaceSource(ctx, tmuxWorkspaceSourceOptions{
		WorkspaceID: "workspace-1",
		SessionName: "fantastty-remote-workspace-1",
		SocketPath:  filepath.Join(t.TempDir(), "remote-tmux.sock"),
		Renderer:    renderer,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	payload, unsubscribe, err := runtime.SubscribeKeyframes("workspace-1", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer unsubscribe()

	keyframe := sourceKeyframeForPane(t, payload.Reliable, 7)
	if got := sourceKeyframeText(keyframe); !strings.Contains(got, "alt-current") || strings.Contains(got, "regular-current") || strings.Contains(got, "regular-initial") {
		t.Fatalf("subscribe keyframes text = %q, want current visible alternate screen", got)
	}
}

func TestTmuxWorkspaceRuntimeRequestKeyframeRecapturesStalePane(t *testing.T) {
	logPath := installFakeTmuxProgram(t, `#!/bin/sh
set -eu
for arg in "$@"; do
  printf '%s\t' "$arg" >>"$FAKE_TMUX_LOG"
done
printf '\n' >>"$FAKE_TMUX_LOG"
case " $* " in
  *" list-windows "*)
    printf '@1\tmain\t0000,8x2,0,0,%%7\t0\t1\n'
    ;;
  *" list-panes "*)
    printf '@1\t%%7\t1\n'
    ;;
  *" capture-pane "*)
    count_file="$FAKE_TMUX_LOG.capture_count"
    count=0
    if [ -f "$count_file" ]; then
      count="$(cat "$count_file")"
    fi
    count=$((count + 1))
    printf '%s' "$count" >"$count_file"
    if [ "$count" -eq 1 ]; then
      printf 'stale\n'
    else
      printf 'fresh\n'
    fi
    ;;
  *" -C new-session "*)
    IFS= read -r refresh
    printf 'STDIN:%s\n' "$refresh" >>"$FAKE_TMUX_LOG"
    IFS= read -r detach || true
    printf 'STDIN:%s\n' "$detach" >>"$FAKE_TMUX_LOG"
    ;;
esac
`)
	renderer := &sourceFakeRenderer{seedFromInitialRows: true}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runtime, err := startTmuxWorkspaceSource(ctx, tmuxWorkspaceSourceOptions{
		WorkspaceID: "workspace-1",
		SessionName: "fantastty-remote-workspace-1",
		SocketPath:  filepath.Join(t.TempDir(), "remote-tmux.sock"),
		Renderer:    renderer,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	payload, err := runtime.RequestKeyframe("workspace-1", 7)
	if err != nil {
		t.Fatal(err)
	}

	if !payloadContainsPaneKeyframe(payload, 7) {
		t.Fatalf("request keyframe payload = %v, want keyframe for pane 7", sourceReliableKinds(t, payload.Reliable))
	}
	if got := sourceKeyframeText(sourceOnlyKeyframe(t, payload.Reliable)); !strings.Contains(got, "fresh") || strings.Contains(got, "stale") {
		t.Fatalf("request keyframe text = %q, want fresh capture", got)
	}
	logData := readTmuxProcessTextFile(t, logPath)
	if got := strings.Count(logData, "capture-pane\t-peqJN\t-S\t-2000\t-t\t%7"); got != 2 {
		t.Fatalf("capture-pane command count = %d, want initial seed plus request recapture; log=%s", got, logData)
	}
}

func TestTmuxWorkspaceRuntimeRequestKeyframeKeepsRetainedLiveOutputOverStaleCapture(t *testing.T) {
	logPath := installFakeTmuxProgram(t, `#!/bin/sh
set -eu
for arg in "$@"; do
  printf '%s\t' "$arg" >>"$FAKE_TMUX_LOG"
done
printf '\n' >>"$FAKE_TMUX_LOG"
case " $* " in
  *" list-windows "*)
    printf '@1\tmain\t0000,2x1,0,0,%%7\t0\t1\n'
    ;;
  *" list-panes "*)
    printf '@1\t%%7\t1\n'
    ;;
  *" capture-pane "*)
    printf 'aa\n'
    ;;
  *" -C new-session "*)
    IFS= read -r refresh
    printf 'STDIN:%s\n' "$refresh" >>"$FAKE_TMUX_LOG"
    printf '%%output %%7 zz\n'
    IFS= read -r detach || true
    printf 'STDIN:%s\n' "$detach" >>"$FAKE_TMUX_LOG"
    ;;
esac
`)
	renderer := &sourceFakeRenderer{
		seedFromInitialRows: true,
		deltas: map[string]remotegrid.PaneDelta{
			"zz": sourceDelta(7, 1, "zz"),
		},
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runtime, err := startTmuxWorkspaceSource(ctx, tmuxWorkspaceSourceOptions{
		WorkspaceID: "workspace-1",
		SessionName: "fantastty-remote-workspace-1",
		SocketPath:  filepath.Join(t.TempDir(), "remote-tmux.sock"),
		Renderer:    renderer,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	_ = waitForTmuxProcessDatagram(t, runtime, "workspace-1")
	payload, err := runtime.RequestKeyframe("workspace-1", 7)
	if err != nil {
		t.Fatal(err)
	}

	if got := sourceKeyframeText(sourceKeyframeForPane(t, payload.Reliable, 7)); got != "zz\n" {
		t.Fatalf("request keyframe text = %q, want retained live output over stale capture", got)
	}
	logData := readTmuxProcessTextFile(t, logPath)
	if got := strings.Count(logData, "capture-pane\t-peqJN\t-S\t-2000\t-t\t%7"); got != 1 {
		t.Fatalf("capture-pane command count = %d, want only initial seed capture; log=%s", got, logData)
	}
}

func TestTmuxWorkspaceSourceRepaintsPausedPaneAfterContinue(t *testing.T) {
	logPath := installFakeTmuxProgram(t, `#!/bin/sh
set -eu
for arg in "$@"; do
  printf '%s\t' "$arg" >>"$FAKE_TMUX_LOG"
done
printf '\n' >>"$FAKE_TMUX_LOG"
case " $* " in
  *" list-windows "*)
    printf '@1\tmain\tabcd,4x1,0,0{2x1,0,0,%%7,2x1,2,0,%%8}\t0\t1\n'
    ;;
  *" list-panes "*)
    printf '@1\t%%7\t1\n'
    printf '@1\t%%8\t0\n'
    ;;
  *" capture-pane "*)
    target=""
    previous=""
    for arg in "$@"; do
      if [ "$previous" = "-t" ]; then target="$arg"; fi
      previous="$arg"
    done
    count_file="$FAKE_TMUX_LOG.capture_count.${target#%}"
    count=0
    if [ -f "$count_file" ]; then count="$(cat "$count_file")"; fi
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_file"
    if [ "$target" = "%7" ]; then
      if [ "$count" -eq 1 ]; then
        printf 'in\n'
      elif [ ! -f "$FAKE_TMUX_LOG.continued" ]; then
        printf 'pa\n'
      else
        printf 'li\n'
      fi
    else
      printf 'ot\n'
    fi
    ;;
  *" -C new-session "*)
    while IFS= read -r line; do
      printf 'STDIN:%s\n' "$line" >>"$FAKE_TMUX_LOG"
      case "$line" in
        "refresh-client -A '%7:continue'")
          : >"$FAKE_TMUX_LOG.continued"
          printf '%%continue %%7\n'
          printf '%%extended-output %%7 1500 : pa\\012\n'
          printf '%%extended-output %%7 0 : li\\012\n'
          ;;
        refresh-client*) printf '%%pause %%7\n' ;;
        detach-client) break ;;
      esac
    done
    ;;
esac
`)
	renderer := &sourceFakeRenderer{
		seedFromInitialRows: true,
		deltas: map[string]remotegrid.PaneDelta{
			"pa\n": sourceDelta(7, 2, "pa"),
			"li\n": sourceDelta(7, 3, "li"),
		},
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runtime, err := startTmuxWorkspaceSource(ctx, tmuxWorkspaceSourceOptions{
		WorkspaceID: "workspace-1",
		SessionName: "fantastty-remote-workspace-1",
		SocketPath:  filepath.Join(t.TempDir(), "remote-tmux.sock"),
		Renderer:    renderer,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	payload := waitForTmuxProcessPaneKeyframeTextWithLog(t, runtime, "workspace-1", 7, "li\n", logPath)
	if got := sourceKeyframeText(sourceKeyframeForPane(t, payload.Reliable, 7)); got != "li\n" {
		t.Fatalf("paused keyframe text = %q, want post-continue capture-pane repaint", got)
	}
	payload = waitForTmuxProcessDatagramWithLog(t, runtime, "workspace-1", logPath)
	if got := payload.Datagrams[len(payload.Datagrams)-1].DeltaSequence; got != 3 {
		t.Fatalf("post-continue datagram sequence = %d, want streamed output delta", got)
	}
	if got := renderer.appliedOutputTexts(); stringSliceContains(got, "pa\n") {
		t.Fatalf("applied outputs = %q, want buffered duplicate output dropped before live output", got)
	}
	logData := readTmuxProcessTextFile(t, logPath)
	if got := strings.Count(logData, "capture-pane\t-peqJN\t-S\t-2000\t-t\t%7"); got != 2 {
		t.Fatalf("capture-pane command count = %d, want initial seed plus continue repaint; log=%s", got, logData)
	}
	continueIndex := strings.Index(logData, "STDIN:refresh-client -A '%7:continue'\n")
	repaintIndex := strings.LastIndex(logData, "capture-pane\t-peqJN\t-S\t-2000\t-t\t%7")
	if continueIndex < 0 || repaintIndex < continueIndex {
		t.Fatalf("paused pane repaint happened before continue command; log=%s", logData)
	}
	if got := strings.Count(logData, "capture-pane\t-peqJN\t-S\t-2000\t-t\t%8"); got != 1 {
		t.Fatalf("other pane capture-pane command count = %d, want only initial seed; log=%s", got, logData)
	}
}

func TestTmuxWorkspaceSourceContinuesPaneAfterPause(t *testing.T) {
	logPath := installFakeTmuxProgram(t, `#!/bin/sh
set -eu
for arg in "$@"; do
  printf '%s\t' "$arg" >>"$FAKE_TMUX_LOG"
done
printf '\n' >>"$FAKE_TMUX_LOG"
case " $* " in
  *" list-windows "*)
    printf '@1\tmain\t0000,7x1,0,0,%%7\t0\t1\n'
    ;;
  *" list-panes "*)
    printf '@1\t%%7\t1\n'
    ;;
  *" capture-pane "*)
    printf 'initial\n'
    ;;
  *" -C new-session "*)
    while IFS= read -r line; do
      printf 'STDIN:%s\n' "$line" >>"$FAKE_TMUX_LOG"
      case "$line" in
        "refresh-client -A '%7:continue'") printf '%%continue %%7\n' ;;
        refresh-client*) printf '%%pause %%7\n' ;;
        detach-client) break ;;
      esac
    done
    ;;
esac
`)
	renderer := &sourceFakeRenderer{seedFromInitialRows: true}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runtime, err := startTmuxWorkspaceSource(ctx, tmuxWorkspaceSourceOptions{
		WorkspaceID: "workspace-1",
		SessionName: "fantastty-remote-workspace-1",
		SocketPath:  filepath.Join(t.TempDir(), "remote-tmux.sock"),
		Renderer:    renderer,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	waitForTmuxProcessLog(t, logPath, func(logData string) bool {
		return strings.Contains(logData, "STDIN:refresh-client -A '%7:continue'\n")
	}, "pause-after continue command")
}

func TestTmuxWorkspaceSourceContinuesPaneBeforeRepaint(t *testing.T) {
	logPath := installFakeTmuxProgram(t, `#!/bin/sh
set -eu
for arg in "$@"; do
  printf '%s\t' "$arg" >>"$FAKE_TMUX_LOG"
done
printf '\n' >>"$FAKE_TMUX_LOG"
case " $* " in
  *" list-windows "*)
    printf '@1\tmain\t0000,7x1,0,0,%%7\t0\t1\n'
    ;;
  *" list-panes "*)
    printf '@1\t%%7\t1\n'
    ;;
  *" capture-pane "*)
    count_file="$FAKE_TMUX_LOG.capture_count"
    count=0
    if [ -f "$count_file" ]; then count="$(cat "$count_file")"; fi
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_file"
    if [ "$count" -eq 1 ]; then
      printf 'initial\n'
    else
      printf 'capture failed\n' >&2
      exit 1
    fi
    ;;
  *" -C new-session "*)
    while IFS= read -r line; do
      printf 'STDIN:%s\n' "$line" >>"$FAKE_TMUX_LOG"
      case "$line" in
        "refresh-client -A '%7:continue'") printf '%%continue %%7\n' ;;
        refresh-client*) printf '%%pause %%7\n' ;;
        detach-client) break ;;
      esac
    done
    ;;
esac
`)
	renderer := &sourceFakeRenderer{seedFromInitialRows: true}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runtime, err := startTmuxWorkspaceSource(ctx, tmuxWorkspaceSourceOptions{
		WorkspaceID: "workspace-1",
		SessionName: "fantastty-remote-workspace-1",
		SocketPath:  filepath.Join(t.TempDir(), "remote-tmux.sock"),
		Renderer:    renderer,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	waitForTmuxProcessLog(t, logPath, func(logData string) bool {
		return strings.Contains(logData, "STDIN:refresh-client -A '%7:continue'\n")
	}, "pause-after continue command before repaint")
}

func TestTmuxWorkspaceSourceKeepsScanningWhenContinueRepaintFails(t *testing.T) {
	logPath := installFakeTmuxProgram(t, `#!/bin/sh
set -eu
for arg in "$@"; do
  printf '%s\t' "$arg" >>"$FAKE_TMUX_LOG"
done
printf '\n' >>"$FAKE_TMUX_LOG"
case " $* " in
  *" list-windows "*)
    printf '@1\tmain\t0000,7x1,0,0,%%7\t0\t1\n'
    ;;
  *" list-panes "*)
    printf '@1\t%%7\t1\n'
    ;;
  *" capture-pane "*)
    count_file="$FAKE_TMUX_LOG.capture_count"
    count=0
    if [ -f "$count_file" ]; then count="$(cat "$count_file")"; fi
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_file"
    if [ "$count" -eq 1 ]; then
      printf 'initial\n'
    else
      printf 'capture failed\n' >&2
      exit 1
    fi
    ;;
  *" -C new-session "*)
    while IFS= read -r line; do
      printf 'STDIN:%s\n' "$line" >>"$FAKE_TMUX_LOG"
      case "$line" in
        "refresh-client -A '%7:continue'")
          printf '%%continue %%7\n'
          printf '%%extended-output %%7 0 : ok\\012\n'
          ;;
        refresh-client*) printf '%%pause %%7\n' ;;
        detach-client) break ;;
      esac
    done
    ;;
esac
`)
	renderer := &sourceFakeRenderer{
		seedFromInitialRows: true,
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runtimeLog := appendTmuxProcessLog(t, logPath)
	runtime, err := startTmuxWorkspaceSource(ctx, tmuxWorkspaceSourceOptions{
		WorkspaceID: "workspace-1",
		SessionName: "fantastty-remote-workspace-1",
		SocketPath:  filepath.Join(t.TempDir(), "remote-tmux.sock"),
		Renderer:    renderer,
		Log:         runtimeLog,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	waitForTmuxProcessLog(t, logPath, func(logData string) bool {
		return strings.Contains(logData, "remote_tmux_continue_repaint_failed=true pane=7")
	}, "continue repaint failure log")
	waitForAppliedOutput(t, renderer, "ok\n")
}

func TestTmuxWorkspaceSourceDropsBufferedOutputAfterContinueRepaint(t *testing.T) {
	logPath := installFakeTmuxProgram(t, `#!/bin/sh
set -eu
for arg in "$@"; do
  printf '%s\t' "$arg" >>"$FAKE_TMUX_LOG"
done
printf '\n' >>"$FAKE_TMUX_LOG"
case " $* " in
  *" list-windows "*)
    printf '@1\tmain\t0000,2x1,0,0,%%7\t0\t1\n'
    ;;
  *" list-panes "*)
    printf '@1\t%%7\t1\n'
    ;;
  *" capture-pane "*)
    count_file="$FAKE_TMUX_LOG.capture_count"
    count=0
    if [ -f "$count_file" ]; then count="$(cat "$count_file")"; fi
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_file"
    if [ "$count" -eq 1 ]; then
      printf 'initial\n'
    else
      printf 'fb\n'
    fi
    ;;
  *" -C new-session "*)
    while IFS= read -r line; do
      printf 'STDIN:%s\n' "$line" >>"$FAKE_TMUX_LOG"
      case "$line" in
        "refresh-client -A '%7:continue'")
          printf '%%continue %%7\n'
          printf '%%extended-output %%7 1500 : fb\\012\n'
          printf '%%extended-output %%7 0 : ok\\012\n'
          ;;
        refresh-client*) printf '%%pause %%7\n' ;;
        detach-client) break ;;
      esac
    done
    ;;
esac
`)
	renderer := &sourceFakeRenderer{
		seedFromInitialRows: true,
		deltas: map[string]remotegrid.PaneDelta{
			"fb\n": sourceDelta(7, 2, "fb"),
			"ok\n": sourceDelta(7, 3, "ok"),
		},
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runtimeLog := appendTmuxProcessLog(t, logPath)
	runtime, err := startTmuxWorkspaceSource(ctx, tmuxWorkspaceSourceOptions{
		WorkspaceID: "workspace-1",
		SessionName: "fantastty-remote-workspace-1",
		SocketPath:  filepath.Join(t.TempDir(), "remote-tmux.sock"),
		Renderer:    renderer,
		Log:         runtimeLog,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	payload := waitForTmuxProcessPaneKeyframeTextWithLog(t, runtime, "workspace-1", 7, "fb\n", logPath)
	if got := sourceKeyframeText(sourceKeyframeForPane(t, payload.Reliable, 7)); got != "fb\n" {
		t.Fatalf("fallback keyframe text = %q, want continue repaint capture", got)
	}
	payload = waitForTmuxProcessDatagramWithLog(t, runtime, "workspace-1", logPath)
	if got := payload.Datagrams[len(payload.Datagrams)-1].DeltaSequence; got != 3 {
		t.Fatalf("post-continue datagram sequence = %d, want live output delta", got)
	}
	if got := renderer.appliedOutputTexts(); stringSliceContains(got, "fb\n") {
		t.Fatalf("applied outputs = %q, want buffered fallback output dropped before live output", got)
	}
}

func TestTmuxWorkspaceSourceKeepsBufferedOutputWhenContinueRepaintPublishesUnsupportedState(t *testing.T) {
	logPath := installFakeTmuxProgram(t, `#!/bin/sh
set -eu
for arg in "$@"; do
  printf '%s\t' "$arg" >>"$FAKE_TMUX_LOG"
done
printf '\n' >>"$FAKE_TMUX_LOG"
case " $* " in
  *" list-windows "*)
    printf '@1\tmain\t0000,11x1,0,0,%%7\t0\t1\n'
    ;;
  *" list-panes "*)
    printf '@1\t%%7\t1\n'
    ;;
  *" capture-pane "*)
    count_file="$FAKE_TMUX_LOG.capture_count"
    count=0
    if [ -f "$count_file" ]; then count="$(cat "$count_file")"; fi
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_file"
    if [ "$count" -eq 1 ]; then
      printf 'initial\n'
    elif [ "$count" -eq 2 ]; then
      printf 'capture failed\n' >&2
      exit 1
    elif [ "$count" -eq 3 ]; then
      printf 'unsupported\n'
    else
      printf 'seed\n'
    fi
    ;;
  *" -C new-session "*)
    while IFS= read -r line; do
      printf 'STDIN:%s\n' "$line" >>"$FAKE_TMUX_LOG"
      case "$line" in
        "refresh-client -A '%7:continue'")
          continue_count_file="$FAKE_TMUX_LOG.continue_count"
          continue_count=0
          if [ -f "$continue_count_file" ]; then continue_count="$(cat "$continue_count_file")"; fi
          continue_count=$((continue_count + 1))
          printf '%s\n' "$continue_count" >"$continue_count_file"
          printf '%%continue %%7\n'
          if [ "$continue_count" -eq 1 ]; then
            printf '%%extended-output %%7 1500 : gap\\012\n'
            printf '%%pause %%7\n'
          fi
          ;;
        refresh-client*) printf '%%pause %%7\n' ;;
        detach-client) break ;;
      esac
    done
    ;;
esac
`)
	renderer := &sourceFakeRenderer{
		seedFromInitialRows:   true,
		failSeedForInitialRow: "unsupported",
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runtimeLog := appendTmuxProcessLog(t, logPath)
	runtime, err := startTmuxWorkspaceSource(ctx, tmuxWorkspaceSourceOptions{
		WorkspaceID: "workspace-1",
		SessionName: "fantastty-remote-workspace-1",
		SocketPath:  filepath.Join(t.TempDir(), "remote-tmux.sock"),
		Renderer:    renderer,
		Log:         runtimeLog,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	waitForTmuxProcessLog(t, logPath, func(logData string) bool {
		return strings.Contains(logData, "remote_tmux_continue_repaint_started=true pane=7")
	}, "continue repaint before unsupported state")
	waitForAppliedOutput(t, renderer, "gap\n")
}

func TestStartTmuxWorkspaceSourceWaitsForPrivateSocketSnapshot(t *testing.T) {
	_ = installFakeTmuxProgram(t, `#!/bin/sh
set -eu
for arg in "$@"; do
  printf '%s\t' "$arg" >>"$FAKE_TMUX_LOG"
done
printf '\n' >>"$FAKE_TMUX_LOG"
case " $* " in
  *" list-windows "*)
    count_file="$FAKE_TMUX_LOG.count"
    count=0
    if [ -f "$count_file" ]; then count="$(cat "$count_file")"; fi
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_file"
    if [ "$count" -eq 1 ]; then
      printf 'socket not ready\n' >&2
      exit 1
    fi
    printf '@1\tmain\t0000,2x1,0,0,%%7\t0\t1\n'
    ;;
  *" list-panes "*)
    printf '@1\t%%7\t1\n'
    ;;
  *" -C new-session "*)
    IFS= read -r refresh
    printf 'STDIN:%s\n' "$refresh" >>"$FAKE_TMUX_LOG"
    IFS= read -r detach || true
    ;;
esac
`)
	renderer := &sourceFakeRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			7: sourceKeyframe(7, 1, "aa"),
		},
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runtime, err := startTmuxWorkspaceSource(ctx, tmuxWorkspaceSourceOptions{
		WorkspaceID: "workspace-1",
		SessionName: "fantastty-remote-workspace-1",
		SocketPath:  filepath.Join(t.TempDir(), "remote-tmux.sock"),
		Renderer:    renderer,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	payload, err := runtime.CurrentPayload("workspace-1")
	if err != nil {
		t.Fatal(err)
	}
	if got := sourceReliableKinds(t, payload.Reliable); !reflect.DeepEqual(got, []string{"snapshot:workspace-1", "keyframe:7:1"}) {
		t.Fatalf("reliable payload = %v, want snapshot and keyframe", got)
	}
}

func TestTmuxWorkspaceSourceSendKeysWritesHexInputToControlMode(t *testing.T) {
	logPath := installFakeTmuxProgram(t, `#!/bin/sh
set -eu
for arg in "$@"; do
  printf '%s\t' "$arg" >>"$FAKE_TMUX_LOG"
done
printf '\n' >>"$FAKE_TMUX_LOG"
case " $* " in
  *" list-windows "*)
    printf '@1\tmain\t0000,2x1,0,0,%%0\t0\t1\n'
    ;;
  *" list-panes "*)
    printf '@1\t%%0\t1\n'
    ;;
  *" -C new-session "*)
    while IFS= read -r line; do
      printf 'STDIN:%s\n' "$line" >>"$FAKE_TMUX_LOG"
      [ "$line" = "detach-client" ] && break
    done
    ;;
esac
`)
	renderer := &sourceFakeRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			0: sourceKeyframe(0, 1, "aa"),
		},
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runtime, err := startTmuxWorkspaceSource(ctx, tmuxWorkspaceSourceOptions{
		WorkspaceID: "workspace-1",
		SessionName: "fantastty-remote-workspace-1",
		SocketPath:  filepath.Join(t.TempDir(), "remote-tmux.sock"),
		Renderer:    renderer,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	if err := runtime.SendKeys("workspace-1", 0, []byte("hi\n")); err != nil {
		t.Fatal(err)
	}

	waitForTmuxProcessLog(t, logPath, func(logData string) bool {
		return strings.Contains(logData, "STDIN:send-keys -t %0 -H 68 69\n") &&
			strings.Contains(logData, "STDIN:send-keys -t %0 Enter\n")
	}, "hex send-keys command followed by Enter")
}

func TestTmuxWorkspaceSourceLeavesSplitPrefixAsPaneInput(t *testing.T) {
	logPath := installFakeTmuxProgram(t, `#!/bin/sh
set -eu
for arg in "$@"; do
  printf '%s\t' "$arg" >>"$FAKE_TMUX_LOG"
done
printf '\n' >>"$FAKE_TMUX_LOG"
case " $* " in
  *" list-windows "*)
    printf '@1\tmain\t0000,2x1,0,0,%%0\t0\t1\n'
    ;;
  *" list-panes "*)
    printf '@1\t%%0\t1\n'
    ;;
  *" -C new-session "*)
    while IFS= read -r line; do
      printf 'STDIN:%s\n' "$line" >>"$FAKE_TMUX_LOG"
      [ "$line" = "detach-client" ] && break
    done
    ;;
esac
`)
	renderer := &sourceFakeRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			0: sourceKeyframe(0, 1, "aa"),
		},
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runtime, err := startTmuxWorkspaceSource(ctx, tmuxWorkspaceSourceOptions{
		WorkspaceID: "workspace-1",
		SessionName: "fantastty-remote-workspace-1",
		SocketPath:  filepath.Join(t.TempDir(), "remote-tmux.sock"),
		Renderer:    renderer,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	if err := runtime.SendKeys("workspace-1", 0, []byte{0x02}); err != nil {
		t.Fatal(err)
	}
	if err := runtime.SendKeys("workspace-1", 0, []byte("n")); err != nil {
		t.Fatal(err)
	}

	waitForTmuxProcessLog(t, logPath, func(logData string) bool {
		return strings.Contains(logData, "STDIN:send-keys -t %0 -H 02\n") &&
			strings.Contains(logData, "STDIN:send-keys -t %0 -H 6e\n") &&
			!strings.Contains(logData, "STDIN:next-window\n")
	}, "split tmux prefix remains pane input")
}

func TestTmuxWorkspaceSourceNewWindowWritesTmuxControlCommand(t *testing.T) {
	logPath := installFakeTmuxProgram(t, `#!/bin/sh
set -eu
for arg in "$@"; do
  printf '%s\t' "$arg" >>"$FAKE_TMUX_LOG"
done
printf '\n' >>"$FAKE_TMUX_LOG"
case " $* " in
  *" list-windows "*)
    printf '@1\tmain\t0000,2x1,0,0,%%0\t0\t1\n'
    ;;
  *" list-panes "*)
    printf '@1\t%%0\t1\n'
    ;;
  *" -C new-session "*)
    while IFS= read -r line; do
      printf 'STDIN:%s\n' "$line" >>"$FAKE_TMUX_LOG"
      [ "$line" = "detach-client" ] && break
    done
    ;;
esac
`)
	renderer := &sourceFakeRenderer{
		keyframes: map[int]remotegrid.PaneKeyframe{
			0: sourceKeyframe(0, 1, "aa"),
		},
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runtime, err := startTmuxWorkspaceSource(ctx, tmuxWorkspaceSourceOptions{
		WorkspaceID: "workspace-1",
		SessionName: "fantastty-remote-workspace-1",
		SocketPath:  filepath.Join(t.TempDir(), "remote-tmux.sock"),
		Renderer:    renderer,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	if _, err := runtime.NewWindow("workspace-1"); err != nil {
		t.Fatal(err)
	}

	waitForTmuxProcessLog(t, logPath, func(logData string) bool {
		return strings.Contains(logData, "STDIN:new-window\n")
	}, "new-window control command")
}

func TestTmuxWorkspaceSourceSelectWindowWritesTmuxControlCommandAndPublishesSnapshot(t *testing.T) {
	logPath := installFakeTmuxProgram(t, `#!/bin/sh
set -eu
for arg in "$@"; do
  printf '%s\t' "$arg" >>"$FAKE_TMUX_LOG"
done
printf '\n' >>"$FAKE_TMUX_LOG"
state_file="$FAKE_TMUX_LOG.selected"
case " $* " in
  *" list-windows "*)
    if [ -f "$state_file" ]; then
      printf '@1\tmain\t0000,2x1,0,0,%%7\t0\t0\n'
      printf '@2\tlogs\t0000,2x1,0,0,%%8\t1\t0\n'
      printf '@3\tlast\t0000,2x1,0,0,%%9\t2\t1\n'
    else
      printf '@1\tmain\t0000,2x1,0,0,%%7\t0\t0\n'
      printf '@2\tlogs\t0000,2x1,0,0,%%8\t1\t1\n'
      printf '@3\tlast\t0000,2x1,0,0,%%9\t2\t0\n'
    fi
    ;;
  *" list-panes "*)
    if [ -f "$state_file" ]; then
      printf '@1\t%%7\t0\n'
      printf '@2\t%%8\t0\n'
      printf '@3\t%%9\t1\n'
    else
      printf '@1\t%%7\t0\n'
      printf '@2\t%%8\t1\n'
      printf '@3\t%%9\t0\n'
    fi
    ;;
  *" capture-pane "*)
    printf 'pane\n'
    ;;
  *" -C new-session "*)
    while IFS= read -r line; do
      printf 'STDIN:%s\n' "$line" >>"$FAKE_TMUX_LOG"
      case "$line" in
        "select-window -t @3") printf selected >"$state_file" ;;
        detach-client) break ;;
      esac
    done
    ;;
esac
`)
	renderer := &sourceFakeRenderer{seedFromInitialRows: true}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runtime, err := startTmuxWorkspaceSource(ctx, tmuxWorkspaceSourceOptions{
		WorkspaceID: "workspace-1",
		SessionName: "fantastty-remote-workspace-1",
		SocketPath:  filepath.Join(t.TempDir(), "remote-tmux.sock"),
		Renderer:    renderer,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	payload, err := runtime.SelectWindow("workspace-1", 3)
	if err != nil {
		t.Fatal(err)
	}

	logData := readTmuxProcessTextFile(t, logPath)
	if !strings.Contains(logData, "STDIN:select-window -t @3\n") {
		t.Fatalf("tmux log does not contain select-window command: %s", logData)
	}
	snapshot := sourceOnlySnapshot(t, payload.Reliable)
	for _, window := range snapshot.Windows {
		if window.WindowID == 3 && window.IsActive {
			return
		}
	}
	t.Fatalf("select-window payload did not mark window 3 active: %+v", snapshot.Windows)
}

func TestTmuxSendKeysCommandCoalescesCRLFIntoOneEnter(t *testing.T) {
	command, err := tmuxSendKeysCommand(3, []byte("hi\r\nthere\ragain\n"))
	if err != nil {
		t.Fatal(err)
	}

	want := strings.Join([]string{
		"send-keys -t %3 -H 68 69",
		"send-keys -t %3 Enter",
		"send-keys -t %3 -H 74 68 65 72 65",
		"send-keys -t %3 Enter",
		"send-keys -t %3 -H 61 67 61 69 6e",
		"send-keys -t %3 Enter",
	}, "\n")
	if command != want {
		t.Fatalf("tmux send keys command = %q, want %q", command, want)
	}
}

func TestTmuxWorkspaceSourceResizePaneWritesTmuxResizeAndPublishesFreshSnapshot(t *testing.T) {
	logPath := installFakeTmuxProgram(t, `#!/bin/sh
set -eu
for arg in "$@"; do
  printf '%s\t' "$arg" >>"$FAKE_TMUX_LOG"
done
printf '\n' >>"$FAKE_TMUX_LOG"
state_file="$FAKE_TMUX_LOG.resized"
case " $* " in
  *" list-windows "*)
    count_file="$FAKE_TMUX_LOG.list_windows_count"
    count=0
    if [ -f "$count_file" ]; then count="$(cat "$count_file")"; fi
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_file"
    if [ "$count" -eq 1 ]; then
      printf '@1\tmain\t0000,2x1,0,0,%%7\t0\t1\n'
    elif [ -f "$state_file" ]; then
      printf '@1\tmain\t0000,100x30,0,0,%%7\t0\t1\n'
    else
      printf 'resize not applied yet\n' >&2
      exit 1
    fi
    ;;
  *" list-panes "*)
    printf '@1\t%%7\t1\n'
    ;;
  *" capture-pane "*)
    if [ -f "$state_file" ]; then
      printf 'resized\n'
    else
      printf 'initial\n'
    fi
    ;;
  *" -C new-session "*)
    while IFS= read -r line; do
      printf 'STDIN:%s\n' "$line" >>"$FAKE_TMUX_LOG"
      case "$line" in
        resize-pane*) printf resized >"$state_file" ;;
        detach-client) break ;;
      esac
    done
    ;;
esac
`)
	renderer := &sourceFakeRenderer{seedFromInitialRows: true}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runtime, err := startTmuxWorkspaceSource(ctx, tmuxWorkspaceSourceOptions{
		WorkspaceID: "workspace-1",
		SessionName: "fantastty-remote-workspace-1",
		SocketPath:  filepath.Join(t.TempDir(), "remote-tmux.sock"),
		Renderer:    renderer,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	payload, err := runtime.ResizePane("workspace-1", 7, 100, 30)
	if err != nil {
		t.Fatal(err)
	}

	if got := sourceReliableKinds(t, payload.Reliable); !reflect.DeepEqual(got, []string{"snapshot:workspace-1", "keyframe:7:1"}) {
		t.Fatalf("resize payload = %v, want fresh snapshot and keyframe", got)
	}
	keyframe := sourceOnlyKeyframe(t, payload.Reliable)
	if keyframe.GridSize != (remotegrid.GridSize{Columns: 100, Rows: 30}) {
		t.Fatalf("resize keyframe size = %+v, want 100x30", keyframe.GridSize)
	}
	if got := sourceKeyframeText(keyframe); !strings.Contains(got, "resized") {
		t.Fatalf("resize keyframe text = %q, want captured resized row", got)
	}

	logData := readTmuxProcessTextFile(t, logPath)
	if !strings.Contains(logData, "STDIN:refresh-client -C 100,30") {
		t.Fatalf("tmux log does not contain refresh-client resize: %s", logData)
	}
	if !strings.Contains(logData, "STDIN:resize-pane -t %7 -x 100 -y 30") {
		t.Fatalf("tmux log does not contain resize-pane command: %s", logData)
	}
}

func readTmuxProcessTextFile(t *testing.T, path string) string {
	t.Helper()

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func appendTmuxProcessLog(t *testing.T, path string) *os.File {
	t.Helper()

	file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = file.Close()
	})
	return file
}

func waitForTmuxProcessLog(t *testing.T, logPath string, matches func(string) bool, description string) {
	t.Helper()

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if logData := readTmuxProcessTextFile(t, logPath); matches(logData) {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("tmux log does not contain %s: %s", description, readTmuxProcessTextFile(t, logPath))
}

func waitForTmuxProcessDatagram(t *testing.T, source remoteWorkspaceSource, workspaceID string) remoteWorkspacePayload {
	t.Helper()

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		payload, err := source.CurrentPayload(workspaceID)
		if err != nil {
			t.Fatal(err)
		}
		if len(payload.Datagrams) > 0 {
			return payload
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for tmux datagram")
	return remoteWorkspacePayload{}
}

func waitForTmuxProcessDatagramWithLog(t *testing.T, source remoteWorkspaceSource, workspaceID string, logPath string) remoteWorkspacePayload {
	t.Helper()

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		payload, err := source.CurrentPayload(workspaceID)
		if err != nil {
			t.Fatal(err)
		}
		if len(payload.Datagrams) > 0 {
			return payload
		}
		time.Sleep(20 * time.Millisecond)
	}
	payload, err := source.CurrentPayload(workspaceID)
	if err != nil {
		t.Fatal(err)
	}
	t.Fatalf("timed out waiting for tmux datagram; reliable=%v; log=%s", sourceReliableKinds(t, payload.Reliable), readTmuxProcessTextFile(t, logPath))
	return remoteWorkspacePayload{}
}

func stringSliceContains(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func waitForAppliedOutput(t *testing.T, renderer *sourceFakeRenderer, text string) {
	t.Helper()

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if stringSliceContains(renderer.appliedOutputTexts(), text) {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for renderer output %q; got %q", text, renderer.appliedOutputTexts())
}

func waitForTmuxProcessKeyframeText(t *testing.T, source remoteWorkspaceSource, workspaceID string, text string) remoteWorkspacePayload {
	t.Helper()

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		payload, err := source.CurrentPayload(workspaceID)
		if err != nil {
			t.Fatal(err)
		}
		keyframe := sourceOnlyKeyframe(t, payload.Reliable)
		if sourceKeyframeText(keyframe) == text {
			return payload
		}
		time.Sleep(20 * time.Millisecond)
	}
	payload, err := source.CurrentPayload(workspaceID)
	if err != nil {
		t.Fatal(err)
	}
	t.Fatalf("timed out waiting for tmux keyframe text %q; last payload=%v", text, sourceReliableKinds(t, payload.Reliable))
	return remoteWorkspacePayload{}
}

func waitForTmuxProcessPaneKeyframeText(t *testing.T, source remoteWorkspaceSource, workspaceID string, paneID int, text string) remoteWorkspacePayload {
	t.Helper()

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		payload, err := source.CurrentPayload(workspaceID)
		if err != nil {
			t.Fatal(err)
		}
		keyframe := sourceKeyframeForPane(t, payload.Reliable, paneID)
		if sourceKeyframeText(keyframe) == text {
			return payload
		}
		time.Sleep(20 * time.Millisecond)
	}
	payload, err := source.CurrentPayload(workspaceID)
	if err != nil {
		t.Fatal(err)
	}
	t.Fatalf("timed out waiting for tmux pane %d keyframe text %q; last payload=%v", paneID, text, sourceReliableKinds(t, payload.Reliable))
	return remoteWorkspacePayload{}
}

func waitForTmuxProcessPaneKeyframeTextWithLog(t *testing.T, source remoteWorkspaceSource, workspaceID string, paneID int, text string, logPath string) remoteWorkspacePayload {
	t.Helper()

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		payload, err := source.CurrentPayload(workspaceID)
		if err != nil {
			t.Fatal(err)
		}
		keyframe := sourceKeyframeForPane(t, payload.Reliable, paneID)
		if sourceKeyframeText(keyframe) == text {
			return payload
		}
		time.Sleep(20 * time.Millisecond)
	}
	payload, err := source.CurrentPayload(workspaceID)
	if err != nil {
		t.Fatal(err)
	}
	t.Fatalf("timed out waiting for tmux pane %d keyframe text %q; last payload=%v; log=%s", paneID, text, sourceReliableKinds(t, payload.Reliable), readTmuxProcessTextFile(t, logPath))
	return remoteWorkspacePayload{}
}
