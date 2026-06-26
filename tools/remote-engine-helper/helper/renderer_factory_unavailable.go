//go:build !linux || !cgo || !ghostty_vt

package main

import (
	"errors"

	"fantastty/remote-engine-helper/internal/engine"
)

var errRemoteRendererUnavailable = errors.New("remote renderer requires linux cgo build with ghostty_vt tag")

func newRemotePaneRenderer(string) (engine.PaneRenderer, error) {
	return nil, errRemoteRendererUnavailable
}
