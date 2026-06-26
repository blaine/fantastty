package main

import (
	"bufio"
	"fmt"
	"io"
	"strings"
	"sync"

	"fantastty/remote-engine-helper/internal/engine"
	"fantastty/remote-engine-helper/remotegrid"
	"fantastty/remote-engine-helper/tmuxcc"
)

type tmuxControlWorkspaceSource struct {
	source  *engineWorkspaceSource
	model   *tmuxcc.Model
	buffer  *tmuxcc.PaneOutputBuffer
	modelMu sync.Mutex
}

func newTmuxControlWorkspaceSource(workspaceID string, renderer engine.PaneRenderer) *tmuxControlWorkspaceSource {
	return &tmuxControlWorkspaceSource{
		source: newEngineWorkspaceSource(workspaceID, renderer),
		model:  tmuxcc.NewModel(workspaceID),
		buffer: tmuxcc.NewPaneOutputBuffer(),
	}
}

func (s *tmuxControlWorkspaceSource) HandleListSnapshot(windowLines []string, paneLines []string, paneInitialCaptures map[int]remotegrid.PaneInitialCapture) error {
	_, err := s.handleListSnapshotPayload(windowLines, paneLines, paneInitialCaptures)
	return err
}

func (s *tmuxControlWorkspaceSource) handleListSnapshotPayload(windowLines []string, paneLines []string, paneInitialCaptures map[int]remotegrid.PaneInitialCapture) (remoteWorkspacePayload, error) {
	s.modelMu.Lock()
	actions, err := s.model.ApplyListSnapshot(windowLines, paneLines)
	if err != nil {
		s.modelMu.Unlock()
		return remoteWorkspacePayload{}, err
	}
	actions = s.buffer.Filter(actions)
	s.modelMu.Unlock()

	var payload remoteWorkspacePayload
	for _, action := range actions {
		action = attachPaneInitialCaptures(action, paneInitialCaptures)
		accepted, err := s.source.handlePayload(action)
		if err != nil {
			return remoteWorkspacePayload{}, err
		}
		payload.Reliable = append(payload.Reliable, accepted.Reliable...)
		payload.Datagrams = append(payload.Datagrams, accepted.Datagrams...)
	}
	return payload, nil
}

func (s *tmuxControlWorkspaceSource) HandleStream(reader io.Reader) error {
	return s.scanBufferedActions(reader, s.source.Handle)
}

func (s *tmuxControlWorkspaceSource) scanBufferedActions(reader io.Reader, handle func(tmuxcc.Action) error) error {
	buffered := bufio.NewReader(reader)
	lineNumber := 0

	for {
		line, err := buffered.ReadString('\n')
		if err != nil {
			if err == io.EOF {
				if line == "" {
					return nil
				}
			} else {
				return fmt.Errorf("tmuxcc: read line %d: %w", lineNumber+1, err)
			}
		}

		lineNumber++
		line = strings.TrimSuffix(line, "\n")
		actions, applyErr := s.applyBufferedLine(line)
		if applyErr != nil {
			return fmt.Errorf("tmuxcc: line %d: %w", lineNumber, applyErr)
		}
		for _, action := range actions {
			if handleErr := handle(action); handleErr != nil {
				return fmt.Errorf("tmuxcc: line %d: %w", lineNumber, handleErr)
			}
		}

		if err == io.EOF {
			return nil
		}
	}
}

func (s *tmuxControlWorkspaceSource) applyBufferedLine(line string) ([]tmuxcc.Action, error) {
	s.modelMu.Lock()
	defer s.modelMu.Unlock()

	actions, err := s.model.ApplyLine(line)
	if err != nil {
		return nil, err
	}
	return s.buffer.Filter(actions), nil
}

func (s *tmuxControlWorkspaceSource) CurrentPayload(workspaceID string) (remoteWorkspacePayload, error) {
	return s.source.CurrentPayload(workspaceID)
}

func (s *tmuxControlWorkspaceSource) RequestKeyframe(workspaceID string, paneID int) (remoteWorkspacePayload, error) {
	return s.source.RequestKeyframe(workspaceID, paneID)
}

func (s *tmuxControlWorkspaceSource) RequestKeyframes(workspaceID string) (remoteWorkspacePayload, error) {
	return s.source.RequestKeyframes(workspaceID)
}

func (s *tmuxControlWorkspaceSource) ResizePane(workspaceID string, paneID int, columns int, rows int) (remoteWorkspacePayload, error) {
	return s.source.ResizePane(workspaceID, paneID, columns, rows)
}

func (s *tmuxControlWorkspaceSource) Subscribe(pump *engine.StreamPump) func() {
	return s.source.Subscribe(pump)
}

func (s *tmuxControlWorkspaceSource) SubscribeKeyframes(workspaceID string, pump *engine.StreamPump) (remoteWorkspacePayload, func(), error) {
	return s.source.SubscribeKeyframes(workspaceID, pump)
}

func attachPaneInitialCaptures(action tmuxcc.Action, paneInitialCaptures map[int]remotegrid.PaneInitialCapture) tmuxcc.Action {
	if len(paneInitialCaptures) == 0 {
		return action
	}
	snapshot, ok := action.WorkspaceSnapshot()
	if !ok {
		return action
	}
	for index := range snapshot.Panes {
		capture, ok := paneInitialCaptures[snapshot.Panes[index].PaneID]
		if !ok {
			continue
		}
		snapshot.Panes[index].InitialCapture = clonePaneInitialCapture(capture)
		snapshot.Panes[index].InitialRows = visibleSeedRows(selectedInitialCaptureRows(capture), snapshot.Panes[index].Frame.Rows)
		snapshot.Panes[index].RepaintFromInitialRows = true
	}
	return tmuxcc.WorkspaceSnapshotAction(snapshot)
}

func selectedInitialCaptureRows(capture remotegrid.PaneInitialCapture) []string {
	if capture.ActiveScreen == remotegrid.ActiveScreenAlternate {
		return capture.AlternateRows
	}
	if len(capture.PrimaryRows) > 0 {
		return capture.PrimaryRows
	}
	return capture.AlternateRows
}

func clonePaneInitialCapture(capture remotegrid.PaneInitialCapture) remotegrid.PaneInitialCapture {
	next := remotegrid.PaneInitialCapture{
		PrimaryRows:   append([]string(nil), capture.PrimaryRows...),
		AlternateRows: append([]string(nil), capture.AlternateRows...),
		ActiveScreen:  capture.ActiveScreen,
	}
	if capture.Cursor != nil {
		cursor := *capture.Cursor
		next.Cursor = &cursor
	}
	if capture.ScrollRegion != nil {
		scrollRegion := *capture.ScrollRegion
		next.ScrollRegion = &scrollRegion
	}
	return next
}

func visibleSeedRows(rows []string, visibleRows int) []string {
	if visibleRows <= 0 || len(rows) <= visibleRows {
		return append([]string(nil), rows...)
	}
	return append([]string(nil), rows[len(rows)-visibleRows:]...)
}
