//go:build linux && cgo && ghostty_vt

package main

import (
	"fantastty/remote-engine-helper/ghosttyvt"
	"fantastty/remote-engine-helper/internal/engine"
)

func newRemotePaneRenderer(workspaceID string) (engine.PaneRenderer, error) {
	return ghosttyvt.NewRenderer(workspaceID)
}
