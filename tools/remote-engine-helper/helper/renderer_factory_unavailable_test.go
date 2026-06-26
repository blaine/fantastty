//go:build !linux || !cgo || !ghostty_vt

package main

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestRemotePaneRendererUnavailableWithoutGhosttyVTBuild(t *testing.T) {
	renderer, err := newRemotePaneRenderer("workspace-1")
	if renderer != nil {
		t.Fatalf("renderer = %#v, want nil", renderer)
	}
	if !errors.Is(err, errRemoteRendererUnavailable) {
		t.Fatalf("newRemotePaneRenderer error = %v, want renderer unavailable", err)
	}
}

func TestServeRequiresRendererWithoutSmoke(t *testing.T) {
	t.Setenv("FANTASTTY_BOOTSTRAP_TMUX_SMOKE", "")
	root, err := os.MkdirTemp("/tmp", "fantastty-renderer-unavailable.")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(root)
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}

	err = serve([]string{
		"--workspace", "workspace-1",
		"--session", "session-1",
		"--ttl", "1s",
		"--runtime-dir", root,
		"--ready-file", filepath.Join(root, "ready.json"),
	})
	if !errors.Is(err, errRemoteRendererUnavailable) {
		t.Fatalf("serve error = %v, want renderer unavailable", err)
	}
}
