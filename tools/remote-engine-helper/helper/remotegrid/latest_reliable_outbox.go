package remotegrid

import (
	"sort"
	"sync"
)

type LatestReliableOutbox struct {
	mu                sync.Mutex
	snapshots         map[string]WorkspaceSnapshot
	knownPanes        map[string]map[int]struct{}
	keyframes         map[latestReliablePaneKey]PaneKeyframe
	deltas            map[latestReliablePaneKey]PaneDelta
	unsupportedStates map[latestReliablePaneKey]UnsupportedPaneState
}

type latestReliablePaneKey struct {
	workspaceID string
	paneID      int
}

func NewLatestReliableOutbox() *LatestReliableOutbox {
	return &LatestReliableOutbox{
		snapshots:         make(map[string]WorkspaceSnapshot),
		knownPanes:        make(map[string]map[int]struct{}),
		keyframes:         make(map[latestReliablePaneKey]PaneKeyframe),
		deltas:            make(map[latestReliablePaneKey]PaneDelta),
		unsupportedStates: make(map[latestReliablePaneKey]UnsupportedPaneState),
	}
}

func (o *LatestReliableOutbox) Publish(message WorkspaceMessage) bool {
	return o.publish(message, true)
}

func (o *LatestReliableOutbox) PublishOwned(message WorkspaceMessage) bool {
	return o.publish(message, false)
}

func (o *LatestReliableOutbox) publish(message WorkspaceMessage, cloneInput bool) bool {
	o.mu.Lock()
	defer o.mu.Unlock()

	switch message.kind {
	case workspaceMessageWorkspaceSnapshot:
		if message.workspaceSnapshot == nil {
			return false
		}
		snapshot := *message.workspaceSnapshot
		if cloneInput {
			snapshot = cloneWorkspaceSnapshot(snapshot)
		}
		if current, ok := o.snapshots[snapshot.WorkspaceID]; ok && current.LayoutGeneration > snapshot.LayoutGeneration {
			return false
		}
		o.snapshots[snapshot.WorkspaceID] = snapshot
		o.knownPanes[snapshot.WorkspaceID] = paneSet(snapshot.Panes)
		o.pruneUnknownPanesLocked(snapshot.WorkspaceID)
		return true
	case workspaceMessagePaneKeyframe:
		if message.keyframe == nil {
			return false
		}
		keyframe := *message.keyframe
		if cloneInput {
			keyframe = ClonePaneKeyframe(keyframe)
		}
		key := latestReliablePaneKey{workspaceID: keyframe.WorkspaceID, paneID: keyframe.PaneID}
		if !o.paneKnownLocked(key) {
			return false
		}
		if unsupported, ok := o.unsupportedStates[key]; ok && unsupported.PaneGeneration > keyframe.PaneGeneration {
			return false
		}
		current, ok := o.keyframes[key]
		if ok && paneKeyframeNewerThan(current, keyframe) {
			return false
		}
		o.keyframes[key] = keyframe
		delete(o.deltas, key)
		delete(o.unsupportedStates, key)
		return true
	case workspaceMessagePaneDelta:
		if message.delta == nil {
			return false
		}
		delta := *message.delta
		if cloneInput {
			delta = clonePaneDelta(delta)
		}
		if !o.acceptsDeltaAgainstReliableLocked(delta) {
			return false
		}
		key := latestReliablePaneKey{workspaceID: delta.WorkspaceID, paneID: delta.PaneID}
		current, ok := o.deltas[key]
		if ok {
			if identityCompare := compareDeltaIdentity(delta, current); identityCompare < 0 {
				return false
			} else if identityCompare == 0 && delta.DeltaSequence <= current.DeltaSequence {
				return false
			}
		}
		o.deltas[key] = delta
		return true
	case workspaceMessageUnsupportedPaneState:
		if message.unsupportedPaneState == nil {
			return false
		}
		state := *message.unsupportedPaneState
		key := latestReliablePaneKey{workspaceID: state.WorkspaceID, paneID: state.PaneID}
		if !o.paneKnownLocked(key) {
			return false
		}
		if keyframe, ok := o.keyframes[key]; ok && keyframe.PaneGeneration >= state.PaneGeneration {
			return false
		}
		current, ok := o.unsupportedStates[key]
		if ok && current.PaneGeneration > state.PaneGeneration {
			return false
		}
		o.unsupportedStates[key] = state
		delete(o.keyframes, key)
		delete(o.deltas, key)
		return true
	}
	return false
}

func (o *LatestReliableOutbox) AcceptsDelta(delta PaneDelta) bool {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.acceptsDeltaAgainstReliableLocked(delta)
}

func (o *LatestReliableOutbox) acceptsDeltaAgainstReliableLocked(delta PaneDelta) bool {
	key := latestReliablePaneKey{workspaceID: delta.WorkspaceID, paneID: delta.PaneID}
	if !o.paneKnownLocked(key) {
		return false
	}
	if unsupported, ok := o.unsupportedStates[key]; ok && unsupported.PaneGeneration >= delta.PaneGeneration {
		return false
	}
	if keyframe, ok := o.keyframes[key]; ok {
		if keyframe.PaneGeneration != delta.PaneGeneration {
			return false
		}
		if keyframe.KeyframeID != delta.BaseKeyframeID {
			return false
		}
		return true
	}
	return false
}

func (o *LatestReliableOutbox) Drain() []WorkspaceMessage {
	o.mu.Lock()
	defer o.mu.Unlock()

	messages := o.snapshotLocked()

	o.snapshots = make(map[string]WorkspaceSnapshot)
	o.keyframes = make(map[latestReliablePaneKey]PaneKeyframe)
	o.deltas = make(map[latestReliablePaneKey]PaneDelta)
	o.unsupportedStates = make(map[latestReliablePaneKey]UnsupportedPaneState)
	return messages
}

func (o *LatestReliableOutbox) Snapshot() []WorkspaceMessage {
	o.mu.Lock()
	defer o.mu.Unlock()

	return o.snapshotLocked()
}

func (o *LatestReliableOutbox) DeletePane(workspaceID string, paneID int) {
	o.mu.Lock()
	defer o.mu.Unlock()
	key := latestReliablePaneKey{workspaceID: workspaceID, paneID: paneID}
	delete(o.keyframes, key)
	delete(o.deltas, key)
	delete(o.unsupportedStates, key)
}

func (o *LatestReliableOutbox) Len() int {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.lenLocked()
}

func (o *LatestReliableOutbox) lenLocked() int {
	return len(o.snapshots) + len(o.keyframes) + len(o.deltas) + len(o.unsupportedStates)
}

func (o *LatestReliableOutbox) snapshotLocked() []WorkspaceMessage {
	messages := make([]WorkspaceMessage, 0, o.lenLocked())
	for _, workspaceID := range sortedWorkspaceIDs(o.snapshots) {
		messages = append(messages, WorkspaceSnapshotMessage(cloneWorkspaceSnapshot(o.snapshots[workspaceID])))
	}
	for _, key := range sortedReliablePaneKeys(o.keyframes) {
		messages = append(messages, PaneKeyframeMessage(ClonePaneKeyframe(o.keyframes[key])))
	}
	for _, key := range sortedReliablePaneKeys(o.deltas) {
		messages = append(messages, PaneDeltaMessage(clonePaneDelta(o.deltas[key])))
	}
	for _, key := range sortedReliablePaneKeys(o.unsupportedStates) {
		messages = append(messages, UnsupportedPaneStateMessage(o.unsupportedStates[key]))
	}
	return messages
}

func (o *LatestReliableOutbox) paneKnownLocked(key latestReliablePaneKey) bool {
	panes, ok := o.knownPanes[key.workspaceID]
	if !ok {
		return true
	}
	_, ok = panes[key.paneID]
	return ok
}

func (o *LatestReliableOutbox) pruneUnknownPanesLocked(workspaceID string) {
	panes := o.knownPanes[workspaceID]
	for key := range o.keyframes {
		if key.workspaceID != workspaceID {
			continue
		}
		if _, ok := panes[key.paneID]; !ok {
			delete(o.keyframes, key)
		}
	}
	for key := range o.unsupportedStates {
		if key.workspaceID != workspaceID {
			continue
		}
		if _, ok := panes[key.paneID]; !ok {
			delete(o.unsupportedStates, key)
		}
	}
	for key := range o.deltas {
		if key.workspaceID != workspaceID {
			continue
		}
		if _, ok := panes[key.paneID]; !ok {
			delete(o.deltas, key)
		}
	}
}

func paneKeyframeNewerThan(current PaneKeyframe, next PaneKeyframe) bool {
	if current.PaneGeneration != next.PaneGeneration {
		return current.PaneGeneration > next.PaneGeneration
	}
	return current.KeyframeID > next.KeyframeID
}

func sortedWorkspaceIDs(snapshots map[string]WorkspaceSnapshot) []string {
	workspaceIDs := make([]string, 0, len(snapshots))
	for workspaceID := range snapshots {
		workspaceIDs = append(workspaceIDs, workspaceID)
	}
	sort.Strings(workspaceIDs)
	return workspaceIDs
}

func sortedReliablePaneKeys[T any](messages map[latestReliablePaneKey]T) []latestReliablePaneKey {
	keys := make([]latestReliablePaneKey, 0, len(messages))
	for key := range messages {
		keys = append(keys, key)
	}
	sort.Slice(keys, func(i, j int) bool {
		if keys[i].workspaceID != keys[j].workspaceID {
			return keys[i].workspaceID < keys[j].workspaceID
		}
		return keys[i].paneID < keys[j].paneID
	})
	return keys
}

func cloneWorkspaceSnapshot(snapshot WorkspaceSnapshot) WorkspaceSnapshot {
	next := snapshot
	next.Windows = cloneWorkspaceWindows(snapshot.Windows)
	next.Panes = cloneWorkspacePanes(snapshot.Panes)
	return next
}

func cloneWorkspaceWindows(windows []WorkspaceWindow) []WorkspaceWindow {
	next := make([]WorkspaceWindow, len(windows))
	for i, window := range windows {
		next[i] = window
		if window.Index != nil {
			index := *window.Index
			next[i].Index = &index
		}
	}
	return next
}

func cloneWorkspacePanes(panes []WorkspacePane) []WorkspacePane {
	next := make([]WorkspacePane, len(panes))
	for index, pane := range panes {
		next[index] = CloneWorkspacePane(pane)
	}
	return next
}

func CloneWorkspacePane(pane WorkspacePane) WorkspacePane {
	next := pane
	next.InitialRows = append([]string(nil), pane.InitialRows...)
	next.InitialCapture = ClonePaneInitialCapture(pane.InitialCapture)
	return next
}

func ClonePaneInitialCapture(capture PaneInitialCapture) PaneInitialCapture {
	next := PaneInitialCapture{
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

func paneSet(panes []WorkspacePane) map[int]struct{} {
	set := make(map[int]struct{}, len(panes))
	for _, pane := range panes {
		set[pane.PaneID] = struct{}{}
	}
	return set
}

func ClonePaneKeyframe(keyframe PaneKeyframe) PaneKeyframe {
	next := keyframe
	next.Rows = CloneGridRows(keyframe.Rows)
	return next
}

func CloneGridRows(rows []GridRow) []GridRow {
	next := make([]GridRow, len(rows))
	for i, row := range rows {
		next[i] = row
		next[i].Cells = cloneCells(row.Cells)
	}
	return next
}
