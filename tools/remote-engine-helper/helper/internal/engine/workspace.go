package engine

import (
	"fmt"
	"io"
	"sort"

	"fantastty/remote-engine-helper/remotegrid"
	"fantastty/remote-engine-helper/tmuxcc"
)

const defaultPendingPaneOutputLimit = 1024

type PaneRenderer interface {
	SeedPane(remotegrid.WorkspacePane) (remotegrid.PaneKeyframe, bool, error)
	ApplyOutput(paneID int, data []byte) (RenderUpdate, error)
	RemovePane(paneID int)
}

type RenderUpdate struct {
	Keyframe    *remotegrid.PaneKeyframe
	Delta       *remotegrid.PaneDelta
	Unsupported *remotegrid.UnsupportedPaneState
}

type Workspace struct {
	workspaceID string
	renderer    PaneRenderer

	reliable  *remotegrid.LatestReliableOutbox
	datagrams *remotegrid.LatestDeltaOutbox
	panes     map[int]paneState
	snapshot  remotegrid.WorkspaceSnapshot
	limit     int
}

type paneState struct {
	pane                  remotegrid.WorkspacePane
	seeded                bool
	paneGeneration        uint64
	rendererGeneration    uint64
	current               *remotegrid.PaneModel
	needsRecoveryKeyframe bool
	pendingOutput         [][]byte
}

func NewWorkspace(workspaceID string, renderer PaneRenderer) *Workspace {
	return &Workspace{
		workspaceID: workspaceID,
		renderer:    renderer,
		reliable:    remotegrid.NewLatestReliableOutbox(),
		datagrams:   remotegrid.NewLatestDeltaOutbox(),
		panes:       make(map[int]paneState),
		limit:       defaultPendingPaneOutputLimit,
	}
}

func (w *Workspace) Handle(action tmuxcc.Action) error {
	if snapshot, ok := action.WorkspaceSnapshot(); ok {
		return w.handleSnapshot(snapshot)
	}
	if output, ok := action.PaneOutput(); ok {
		return w.handleOutput(output)
	}
	return nil
}

func (w *Workspace) HandleStream(reader io.Reader, model *tmuxcc.Model, buffer *tmuxcc.PaneOutputBuffer) error {
	return tmuxcc.ScanBufferedActions(reader, model, buffer, w.Handle)
}

func (w *Workspace) DrainReliable() []remotegrid.WorkspaceMessage {
	return w.reliable.Drain()
}

func (w *Workspace) DrainDatagrams() []remotegrid.PaneDelta {
	return w.datagrams.Drain()
}

func (w *Workspace) PendingReliable() int {
	return w.reliable.Len()
}

func (w *Workspace) PendingDatagrams() int {
	return w.datagrams.Len()
}

func (w *Workspace) RequestKeyframe(paneID int) error {
	keyframe, ok, err := w.RequestKeyframeDraft(paneID)
	if err != nil {
		return err
	}
	if !ok {
		return nil
	}
	w.reliable.Publish(remotegrid.PaneKeyframeMessage(keyframe))
	w.rememberPaneGeneration(paneID, keyframe.PaneGeneration)
	return nil
}

func (w *Workspace) RequestKeyframeDraft(paneID int) (remotegrid.PaneKeyframe, bool, error) {
	draft, ok, err := w.RequestPaneKeyframeDraft(paneID)
	if err != nil || !ok {
		return remotegrid.PaneKeyframe{}, ok, err
	}
	return draft.Materialize(), true, nil
}

func (w *Workspace) RequestPaneKeyframeDraft(paneID int) (remotegrid.PaneKeyframeDraft, bool, error) {
	state, ok := w.panes[paneID]
	if !ok || !state.seeded || state.current == nil || state.needsRecoveryKeyframe {
		return remotegrid.PaneKeyframeDraft{}, false, nil
	}
	draft := state.current.BeginKeyframeDraft()
	w.datagrams.DeletePane(w.workspaceID, paneID)
	return draft, true, nil
}

func (w *Workspace) RequestKeyframes() error {
	keyframes, err := w.RequestKeyframeDrafts()
	if err != nil {
		return err
	}
	for _, keyframe := range keyframes {
		w.reliable.Publish(remotegrid.PaneKeyframeMessage(keyframe))
		w.rememberPaneGeneration(keyframe.PaneID, keyframe.PaneGeneration)
	}
	return nil
}

func (w *Workspace) RequestKeyframeDrafts() ([]remotegrid.PaneKeyframe, error) {
	drafts, err := w.RequestPaneKeyframeDrafts()
	if err != nil {
		return nil, err
	}
	keyframes := make([]remotegrid.PaneKeyframe, 0, len(drafts))
	for _, draft := range drafts {
		keyframes = append(keyframes, draft.Materialize())
	}
	return keyframes, nil
}

func (w *Workspace) RequestPaneKeyframeDrafts() ([]remotegrid.PaneKeyframeDraft, error) {
	paneIDs := make([]int, 0, len(w.panes))
	for paneID := range w.panes {
		paneIDs = append(paneIDs, paneID)
	}
	sort.Ints(paneIDs)
	drafts := make([]remotegrid.PaneKeyframeDraft, 0, len(paneIDs))
	for _, paneID := range paneIDs {
		draft, ok, err := w.RequestPaneKeyframeDraft(paneID)
		if err != nil {
			return nil, err
		}
		if ok {
			drafts = append(drafts, draft)
		}
	}
	return drafts, nil
}

func (w *Workspace) ResizePane(paneID int, columns int, rows int) error {
	if columns <= 0 || rows <= 0 {
		return fmt.Errorf("engine: invalid pane resize %dx%d", columns, rows)
	}
	if _, ok := w.panes[paneID]; !ok {
		return nil
	}
	if w.snapshot.WorkspaceID == "" {
		return nil
	}

	snapshot := cloneWorkspaceSnapshot(w.snapshot)
	resized := false
	for index := range snapshot.Panes {
		if snapshot.Panes[index].PaneID != paneID {
			continue
		}
		snapshot.Panes[index].Frame.Columns = columns
		snapshot.Panes[index].Frame.Rows = rows
		resized = true
		break
	}
	if !resized {
		return nil
	}
	snapshot.LayoutGeneration++
	return w.handleSnapshot(snapshot)
}

func (w *Workspace) handleSnapshot(snapshot remotegrid.WorkspaceSnapshot) error {
	if snapshot.WorkspaceID != w.workspaceID {
		return nil
	}
	w.snapshot = cloneWorkspaceSnapshot(snapshot)
	w.reliable.Publish(remotegrid.WorkspaceSnapshotMessage(snapshot))

	nextPanes := make(map[int]paneState, len(snapshot.Panes))
	panes := append([]remotegrid.WorkspacePane(nil), snapshot.Panes...)
	sort.Slice(panes, func(i, j int) bool {
		return panes[i].PaneID < panes[j].PaneID
	})
	for _, pane := range panes {
		state := w.panes[pane.PaneID]
		needsSeed := !state.seeded ||
			pane.RepaintFromInitialRows ||
			state.pane.Frame.Columns != pane.Frame.Columns ||
			state.pane.Frame.Rows != pane.Frame.Rows
		state.pane = pane
		if !needsSeed {
			nextPanes[pane.PaneID] = state
			continue
		}
		w.datagrams.DeletePane(w.workspaceID, pane.PaneID)
		keyframe, ok, err := w.renderer.SeedPane(pane)
		if err != nil {
			unsupportedGeneration := state.unsupportedGeneration()
			state.seeded = false
			state.current = nil
			state.needsRecoveryKeyframe = false
			state.paneGeneration = unsupportedGeneration
			w.reliable.Publish(remotegrid.UnsupportedPaneStateMessage(remotegrid.UnsupportedPaneState{
				WorkspaceID:    w.workspaceID,
				PaneID:         pane.PaneID,
				PaneGeneration: unsupportedGeneration,
				Reason:         remotegrid.UnsupportedPaneReasonSnapshotExtractionFailure,
				Fallback:       remotegrid.UnsupportedPaneFallbackBlankWithDiagnostic,
			}))
			nextPanes[pane.PaneID] = state
			continue
		}
		if ok {
			keyframe, state = state.normalizeSeedKeyframe(keyframe)
			current, err := remotegrid.NewPaneModelFromKeyframe(keyframe)
			if err != nil {
				return err
			}
			state.seeded = true
			state.paneGeneration = keyframe.PaneGeneration
			state.current = current
			state.needsRecoveryKeyframe = false
			w.reliable.Publish(remotegrid.PaneKeyframeMessage(keyframe))
			w.panes[pane.PaneID] = state
			if err := w.flushPendingOutput(&state); err != nil {
				return err
			}
			if updated, ok := w.panes[pane.PaneID]; ok {
				state = updated
			}
			state.pane = pane
			state.seeded = true
			state.pendingOutput = nil
		} else {
			state.seeded = false
			state.current = nil
			state.needsRecoveryKeyframe = false
		}
		nextPanes[pane.PaneID] = state
	}

	for paneID := range w.panes {
		if _, ok := nextPanes[paneID]; !ok {
			w.renderer.RemovePane(paneID)
			w.reliable.DeletePane(w.workspaceID, paneID)
			w.datagrams.DeletePane(w.workspaceID, paneID)
		}
	}
	w.panes = nextPanes
	return nil
}

func (w *Workspace) handleOutput(output tmuxcc.OutputEvent) error {
	state, ok := w.panes[output.PaneID]
	if !ok {
		return nil
	}
	if !state.seeded {
		state.pendingOutput = appendBoundedOutput(state.pendingOutput, output.Data, w.limit)
		w.panes[output.PaneID] = state
		return nil
	}
	return w.publishOutput(output.PaneID, output.Data)
}

func (w *Workspace) flushPendingOutput(state *paneState) error {
	for _, data := range state.pendingOutput {
		if err := w.publishOutput(state.pane.PaneID, data); err != nil {
			return err
		}
	}
	state.pendingOutput = nil
	return nil
}

func (w *Workspace) publishOutput(paneID int, data []byte) error {
	update, err := w.renderer.ApplyOutput(paneID, data)
	if err != nil {
		return err
	}
	if update.Unsupported != nil {
		unsupported := *update.Unsupported
		state, ok := w.panes[paneID]
		if ok {
			unsupported.PaneGeneration = state.unsupportedGeneration()
			state.paneGeneration = unsupported.PaneGeneration
			state.needsRecoveryKeyframe = state.current != nil
			w.panes[paneID] = state
		}
		w.datagrams.DeletePane(w.workspaceID, paneID)
		w.reliable.Publish(remotegrid.UnsupportedPaneStateMessage(unsupported))
	}
	if update.Keyframe != nil {
		keyframe := *update.Keyframe
		if state, ok := w.panes[paneID]; ok {
			keyframe, state = state.normalizeRendererKeyframe(keyframe)
			state.needsRecoveryKeyframe = false
			w.panes[paneID] = state
		}
		current, err := remotegrid.NewPaneModelFromKeyframe(keyframe)
		if err != nil {
			return err
		}
		w.datagrams.DeletePane(w.workspaceID, paneID)
		w.reliable.Publish(remotegrid.PaneKeyframeMessage(keyframe))
		w.rememberCurrentPaneState(paneID, current)
		w.rememberPaneGeneration(paneID, keyframe.PaneGeneration)
	}
	if update.Delta != nil {
		delta, keyframe, ok, err := w.applyCurrentPaneDelta(paneID, *update.Delta)
		if err != nil {
			return err
		}
		if keyframe != nil {
			w.datagrams.DeletePane(w.workspaceID, paneID)
			w.reliable.Publish(remotegrid.PaneKeyframeMessage(*keyframe))
			return nil
		}
		if ok {
			w.datagrams.Publish(delta)
		}
	}
	return nil
}

func (s paneState) unsupportedGeneration() uint64 {
	if s.paneGeneration == 0 {
		return 1
	}
	if s.seeded {
		return s.paneGeneration + 1
	}
	return s.paneGeneration
}

func (s paneState) normalizeSeedKeyframe(keyframe remotegrid.PaneKeyframe) (remotegrid.PaneKeyframe, paneState) {
	rendererGeneration := keyframe.PaneGeneration
	targetGeneration := s.seedGeneration()
	if keyframe.PaneGeneration < targetGeneration {
		keyframe.PaneGeneration = targetGeneration
	}
	s.rendererGeneration = rendererGeneration
	s.paneGeneration = keyframe.PaneGeneration
	return keyframe, s
}

func (s paneState) seedGeneration() uint64 {
	if s.paneGeneration == 0 {
		return 1
	}
	if s.seeded {
		return s.paneGeneration + 1
	}
	return s.paneGeneration
}

func (s paneState) normalizeRendererKeyframe(keyframe remotegrid.PaneKeyframe) (remotegrid.PaneKeyframe, paneState) {
	rendererGeneration := keyframe.PaneGeneration
	targetGeneration := s.paneGeneration
	if targetGeneration == 0 {
		targetGeneration = rendererGeneration
	}
	if s.rendererGeneration != 0 && rendererGeneration > s.rendererGeneration {
		targetGeneration = s.paneGeneration + (rendererGeneration - s.rendererGeneration)
	}
	if targetGeneration == 0 {
		targetGeneration = 1
	}
	keyframe.PaneGeneration = targetGeneration
	s.rendererGeneration = rendererGeneration
	s.paneGeneration = targetGeneration
	return keyframe, s
}

func (s paneState) normalizeRendererDelta(delta remotegrid.PaneDelta) (remotegrid.PaneDelta, bool) {
	if s.rendererGeneration != 0 && delta.PaneGeneration != s.rendererGeneration {
		return remotegrid.PaneDelta{}, false
	}
	if s.paneGeneration != 0 {
		delta.PaneGeneration = s.paneGeneration
	}
	return delta, true
}

func (w *Workspace) rememberPaneGeneration(paneID int, paneGeneration uint64) {
	if paneGeneration == 0 {
		return
	}
	state, ok := w.panes[paneID]
	if !ok {
		return
	}
	if paneGeneration > state.paneGeneration {
		state.paneGeneration = paneGeneration
	}
	w.panes[paneID] = state
}

func (w *Workspace) rememberCurrentPaneState(paneID int, current *remotegrid.PaneModel) {
	state, ok := w.panes[paneID]
	if !ok {
		return
	}
	state.current = current
	state.needsRecoveryKeyframe = false
	w.panes[paneID] = state
}

func (w *Workspace) forgetCurrentPaneState(paneID int) {
	state, ok := w.panes[paneID]
	if !ok {
		return
	}
	state.current = nil
	state.needsRecoveryKeyframe = false
	w.panes[paneID] = state
}

func (w *Workspace) applyCurrentPaneDelta(paneID int, delta remotegrid.PaneDelta) (remotegrid.PaneDelta, *remotegrid.PaneKeyframe, bool, error) {
	state, ok := w.panes[paneID]
	if !ok || state.current == nil {
		return remotegrid.PaneDelta{}, nil, false, nil
	}
	delta, ok = state.normalizeRendererDelta(delta)
	if !ok {
		return remotegrid.PaneDelta{}, nil, false, nil
	}
	if state.needsRecoveryKeyframe {
		delta.PaneGeneration = state.current.PaneGeneration()
	}
	normalized, ok, err := state.current.ApplyDelta(delta)
	if err != nil {
		return remotegrid.PaneDelta{}, nil, false, err
	}
	if ok && state.needsRecoveryKeyframe {
		keyframe := state.current.Keyframe()
		keyframe.PaneGeneration = state.paneGeneration
		current, err := remotegrid.NewPaneModelFromKeyframe(keyframe)
		if err != nil {
			return remotegrid.PaneDelta{}, nil, false, err
		}
		state.current = current
		state.needsRecoveryKeyframe = false
		w.panes[paneID] = state
		return remotegrid.PaneDelta{}, &keyframe, true, nil
	}
	w.panes[paneID] = state
	return normalized, nil, ok, nil
}

func appendBoundedOutput(pending [][]byte, data []byte, limit int) [][]byte {
	if limit <= 0 {
		limit = defaultPendingPaneOutputLimit
	}
	next := append([]byte(nil), data...)
	if len(pending) >= limit {
		copy(pending, pending[1:])
		pending[len(pending)-1] = next
		return pending
	}
	return append(pending, next)
}

func cloneWorkspaceSnapshot(snapshot remotegrid.WorkspaceSnapshot) remotegrid.WorkspaceSnapshot {
	snapshot.Windows = append([]remotegrid.WorkspaceWindow(nil), snapshot.Windows...)
	snapshot.Panes = append([]remotegrid.WorkspacePane(nil), snapshot.Panes...)
	for index := range snapshot.Panes {
		snapshot.Panes[index] = remotegrid.CloneWorkspacePane(snapshot.Panes[index])
	}
	return snapshot
}
