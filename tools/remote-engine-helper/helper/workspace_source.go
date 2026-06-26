package main

import (
	"errors"
	"sync"

	"fantastty/remote-engine-helper/internal/engine"
	"fantastty/remote-engine-helper/remotegrid"
	"fantastty/remote-engine-helper/tmuxcc"
)

var errWorkspaceSourceMismatch = errors.New("workspace source mismatch")

type engineWorkspaceSource struct {
	workspaceID string
	workspace   *engine.Workspace
	reliable    *remotegrid.LatestReliableOutbox
	datagrams   *remotegrid.LatestDeltaOutbox

	workspaceMu      sync.Mutex
	publishMu        sync.Mutex
	publishCond      *sync.Cond
	nextPublishSeq   uint64
	readyPublishSeq  uint64
	mu               sync.Mutex
	pendingMu        sync.Mutex
	subscribers      map[*engine.StreamPump]struct{}
	pendingKeyframes map[sourcePaneKey]sourcePendingKeyframe
}

type sourcePaneKey struct {
	workspaceID string
	paneID      int
}

type sourcePendingKeyframe struct {
	paneGeneration uint64
	keyframeID     uint64
}

func newEngineWorkspaceSource(workspaceID string, renderer engine.PaneRenderer) *engineWorkspaceSource {
	source := &engineWorkspaceSource{
		workspaceID:      workspaceID,
		workspace:        engine.NewWorkspace(workspaceID, renderer),
		reliable:         remotegrid.NewLatestReliableOutbox(),
		datagrams:        remotegrid.NewLatestDeltaOutbox(),
		subscribers:      make(map[*engine.StreamPump]struct{}),
		pendingKeyframes: make(map[sourcePaneKey]sourcePendingKeyframe),
	}
	source.publishCond = sync.NewCond(&source.publishMu)
	return source
}

func (s *engineWorkspaceSource) Handle(action tmuxcc.Action) error {
	_, err := s.handlePayload(action)
	return err
}

func (s *engineWorkspaceSource) handlePayload(action tmuxcc.Action) (remoteWorkspacePayload, error) {
	s.workspaceMu.Lock()
	if err := s.workspace.Handle(action); err != nil {
		s.workspaceMu.Unlock()
		return remoteWorkspacePayload{}, err
	}
	payload := s.drainWorkspace()
	publishSeq := s.reservePublishSequenceLocked()
	s.workspaceMu.Unlock()
	return s.publishPayload(publishSeq, payload), nil
}

func (s *engineWorkspaceSource) reservePublishSequenceLocked() uint64 {
	seq := s.nextPublishSeq
	s.nextPublishSeq++
	return seq
}

func (s *engineWorkspaceSource) publishPayload(seq uint64, payload remoteWorkspacePayload) remoteWorkspacePayload {
	s.publishMu.Lock()
	s.waitForPublishTurnLocked(seq)
	s.mu.Lock()
	accepted := s.retainPayloadLocked(payload)
	subscribers := s.subscribersLocked()
	s.mu.Unlock()

	publishPayloadToSubscribers(accepted, subscribers)
	s.advancePublishTurnLocked()
	s.publishMu.Unlock()
	return accepted
}

func (s *engineWorkspaceSource) waitForPublishTurnLocked(seq uint64) {
	for s.readyPublishSeq != seq {
		s.publishCond.Wait()
	}
}

func (s *engineWorkspaceSource) advancePublishTurnLocked() {
	s.readyPublishSeq++
	s.publishCond.Broadcast()
}

func (s *engineWorkspaceSource) CurrentPayload(workspaceID string) (remoteWorkspacePayload, error) {
	if workspaceID != s.workspaceID {
		return remoteWorkspacePayload{}, errWorkspaceSourceMismatch
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	return remoteWorkspacePayload{
		Reliable:  s.reliable.Snapshot(),
		Datagrams: s.retainedDatagramsLocked(),
	}, nil
}

func (s *engineWorkspaceSource) RequestKeyframe(workspaceID string, paneID int) (remoteWorkspacePayload, error) {
	if workspaceID != s.workspaceID {
		return remoteWorkspacePayload{}, errWorkspaceSourceMismatch
	}

	s.workspaceMu.Lock()
	draft, ok, err := s.workspace.RequestPaneKeyframeDraft(paneID)
	if err != nil {
		s.workspaceMu.Unlock()
		return remoteWorkspacePayload{}, err
	}
	payload := remoteWorkspacePayload{Datagrams: s.workspace.DrainDatagrams()}
	if ok {
		s.rememberPendingKeyframeDraft(draft)
	}
	publishSeq := s.reservePublishSequenceLocked()
	s.workspaceMu.Unlock()
	if ok {
		payload.Reliable = append(payload.Reliable, remotegrid.PaneKeyframeMessage(draft.Materialize()))
	}

	s.publishMu.Lock()
	s.waitForPublishTurnLocked(publishSeq)
	s.mu.Lock()
	accepted := s.retainPayloadLocked(payload)
	if len(accepted.Reliable) == 0 && len(payload.Reliable) > 0 {
		accepted.Reliable = s.reliable.Snapshot()
	}
	subscribers := s.subscribersLocked()
	s.mu.Unlock()

	publishPayloadToSubscribers(accepted, subscribers)
	s.advancePublishTurnLocked()
	s.publishMu.Unlock()
	return accepted, nil
}

func (s *engineWorkspaceSource) RequestKeyframes(workspaceID string) (remoteWorkspacePayload, error) {
	if workspaceID != s.workspaceID {
		return remoteWorkspacePayload{}, errWorkspaceSourceMismatch
	}

	s.workspaceMu.Lock()
	drafts, err := s.workspace.RequestPaneKeyframeDrafts()
	if err != nil {
		s.workspaceMu.Unlock()
		return remoteWorkspacePayload{}, err
	}
	fresh := remoteWorkspacePayload{Datagrams: s.workspace.DrainDatagrams()}
	s.rememberPendingKeyframeDrafts(drafts)
	publishSeq := s.reservePublishSequenceLocked()
	s.workspaceMu.Unlock()
	for _, draft := range drafts {
		fresh.Reliable = append(fresh.Reliable, remotegrid.PaneKeyframeMessage(draft.Materialize()))
	}

	s.publishMu.Lock()
	s.waitForPublishTurnLocked(publishSeq)
	s.mu.Lock()
	accepted := s.retainPayloadLocked(fresh)
	payload := remoteWorkspacePayload{Reliable: s.reliable.Snapshot()}
	subscribers := s.subscribersLocked()
	s.mu.Unlock()

	publishPayloadToSubscribers(accepted, subscribers)
	s.advancePublishTurnLocked()
	s.publishMu.Unlock()
	return payload, nil
}

func (s *engineWorkspaceSource) ResizePane(workspaceID string, paneID int, columns int, rows int) (remoteWorkspacePayload, error) {
	if workspaceID != s.workspaceID {
		return remoteWorkspacePayload{}, errWorkspaceSourceMismatch
	}

	s.workspaceMu.Lock()
	if err := s.workspace.ResizePane(paneID, columns, rows); err != nil {
		s.workspaceMu.Unlock()
		return remoteWorkspacePayload{}, err
	}
	payload := s.drainWorkspace()
	publishSeq := s.reservePublishSequenceLocked()
	s.workspaceMu.Unlock()
	return s.publishPayload(publishSeq, payload), nil
}

func (s *engineWorkspaceSource) Subscribe(pump *engine.StreamPump) func() {
	if pump == nil {
		return func() {}
	}

	s.mu.Lock()
	s.subscribers[pump] = struct{}{}
	s.mu.Unlock()

	return s.subscriberCleanup(pump)
}

func (s *engineWorkspaceSource) SubscribeKeyframes(workspaceID string, pump *engine.StreamPump) (remoteWorkspacePayload, func(), error) {
	if workspaceID != s.workspaceID {
		return remoteWorkspacePayload{}, func() {}, errWorkspaceSourceMismatch
	}

	s.workspaceMu.Lock()
	drafts, err := s.workspace.RequestPaneKeyframeDrafts()
	if err != nil {
		s.workspaceMu.Unlock()
		return remoteWorkspacePayload{}, func() {}, err
	}
	fresh := remoteWorkspacePayload{Datagrams: s.workspace.DrainDatagrams()}
	s.rememberPendingKeyframeDrafts(drafts)
	publishSeq := s.reservePublishSequenceLocked()
	s.workspaceMu.Unlock()
	for _, draft := range drafts {
		fresh.Reliable = append(fresh.Reliable, remotegrid.PaneKeyframeMessage(draft.Materialize()))
	}

	s.publishMu.Lock()
	s.waitForPublishTurnLocked(publishSeq)
	s.mu.Lock()
	accepted := s.retainPayloadLocked(fresh)
	payload := remoteWorkspacePayload{
		Reliable:  s.reliable.Snapshot(),
		Datagrams: s.retainedDatagramsLocked(),
	}
	existingSubscribers := s.subscribersLocked()
	s.mu.Unlock()

	publishPayloadToSubscribers(accepted, existingSubscribers)
	if pump != nil {
		pump.PublishReliable(payload.Reliable)
		pump.PublishDatagrams(payload.Datagrams)
		s.mu.Lock()
		s.subscribers[pump] = struct{}{}
		s.mu.Unlock()
	}
	s.advancePublishTurnLocked()
	s.publishMu.Unlock()

	unsubscribe := func() {}
	if pump != nil {
		unsubscribe = s.subscriberCleanup(pump)
	}
	return payload, unsubscribe, nil
}

func (s *engineWorkspaceSource) subscriberCleanup(pump *engine.StreamPump) func() {
	unregisterClose := pump.OnClose(func() {
		s.removeSubscriber(pump)
	})
	return func() {
		unregisterClose()
		s.removeSubscriber(pump)
	}
}

func (s *engineWorkspaceSource) removeSubscriber(pump *engine.StreamPump) {
	s.mu.Lock()
	delete(s.subscribers, pump)
	s.mu.Unlock()
}

func (s *engineWorkspaceSource) drainWorkspace() remoteWorkspacePayload {
	return remoteWorkspacePayload{
		Reliable:  s.workspace.DrainReliable(),
		Datagrams: s.workspace.DrainDatagrams(),
	}
}

func (s *engineWorkspaceSource) retainPayloadLocked(payload remoteWorkspacePayload) remoteWorkspacePayload {
	var accepted remoteWorkspacePayload
	for _, message := range payload.Reliable {
		if !s.reliable.PublishOwned(message) {
			continue
		}
		s.clearPendingKeyframesForReliable(message)
		if snapshot, ok := message.WorkspaceSnapshot(); ok {
			s.deleteDatagramsOutsideSnapshot(snapshot)
		}
		if _, ok := message.PaneKeyframe(); ok {
			s.deleteDatagramsInvalidatedByReliable(message)
		}
		if _, ok := message.UnsupportedPaneState(); ok {
			s.deleteDatagramsInvalidatedByReliable(message)
		}
		accepted.Reliable = append(accepted.Reliable, message)
	}
	for _, delta := range payload.Datagrams {
		if !s.reliable.AcceptsDelta(delta) && !s.pendingKeyframeAcceptsDelta(delta) {
			continue
		}
		if s.datagrams.Publish(delta) {
			accepted.Datagrams = append(accepted.Datagrams, delta)
		}
	}
	return accepted
}

func (s *engineWorkspaceSource) retainedDatagramsLocked() []remotegrid.PaneDelta {
	var datagrams []remotegrid.PaneDelta
	for _, delta := range s.datagrams.Snapshot() {
		if s.reliable.AcceptsDelta(delta) {
			datagrams = append(datagrams, delta)
		}
	}
	return datagrams
}

func (s *engineWorkspaceSource) rememberPendingKeyframeDrafts(drafts []remotegrid.PaneKeyframeDraft) {
	for _, draft := range drafts {
		s.rememberPendingKeyframeDraft(draft)
	}
}

func (s *engineWorkspaceSource) rememberPendingKeyframeDraft(draft remotegrid.PaneKeyframeDraft) {
	key := sourcePaneKey{workspaceID: draft.WorkspaceID(), paneID: draft.PaneID()}
	next := sourcePendingKeyframe{paneGeneration: draft.PaneGeneration(), keyframeID: draft.KeyframeID()}
	s.pendingMu.Lock()
	if current, ok := s.pendingKeyframes[key]; !ok || sourcePendingKeyframeAccepts(current, next) {
		s.pendingKeyframes[key] = next
	}
	s.pendingMu.Unlock()
}

func sourcePendingKeyframeAccepts(current sourcePendingKeyframe, next sourcePendingKeyframe) bool {
	if current.paneGeneration != next.paneGeneration {
		return next.paneGeneration > current.paneGeneration
	}
	return next.keyframeID >= current.keyframeID
}

func (s *engineWorkspaceSource) pendingKeyframeAcceptsDelta(delta remotegrid.PaneDelta) bool {
	key := sourcePaneKey{workspaceID: delta.WorkspaceID, paneID: delta.PaneID}
	s.pendingMu.Lock()
	pending, ok := s.pendingKeyframes[key]
	s.pendingMu.Unlock()
	return ok &&
		delta.PaneGeneration == pending.paneGeneration &&
		delta.BaseKeyframeID == pending.keyframeID
}

func (s *engineWorkspaceSource) clearPendingKeyframesForReliable(message remotegrid.WorkspaceMessage) {
	s.pendingMu.Lock()
	defer s.pendingMu.Unlock()

	if snapshot, ok := message.WorkspaceSnapshot(); ok {
		panes := make(map[int]struct{}, len(snapshot.Panes))
		for _, pane := range snapshot.Panes {
			panes[pane.PaneID] = struct{}{}
		}
		for key := range s.pendingKeyframes {
			if key.workspaceID != snapshot.WorkspaceID {
				continue
			}
			if _, ok := panes[key.paneID]; !ok {
				delete(s.pendingKeyframes, key)
			}
		}
		return
	}
	if keyframe, ok := message.PaneKeyframe(); ok {
		key := sourcePaneKey{workspaceID: keyframe.WorkspaceID, paneID: keyframe.PaneID}
		pending, ok := s.pendingKeyframes[key]
		if ok && sourceKeyframeCoversPending(keyframe, pending) {
			delete(s.pendingKeyframes, key)
		}
		return
	}
	if state, ok := message.UnsupportedPaneState(); ok {
		key := sourcePaneKey{workspaceID: state.WorkspaceID, paneID: state.PaneID}
		pending, ok := s.pendingKeyframes[key]
		if ok && state.PaneGeneration >= pending.paneGeneration {
			delete(s.pendingKeyframes, key)
		}
	}
}

func sourceKeyframeCoversPending(keyframe remotegrid.PaneKeyframe, pending sourcePendingKeyframe) bool {
	if keyframe.PaneGeneration != pending.paneGeneration {
		return keyframe.PaneGeneration > pending.paneGeneration
	}
	return keyframe.KeyframeID >= pending.keyframeID
}

func (s *engineWorkspaceSource) deleteDatagramsOutsideSnapshot(snapshot remotegrid.WorkspaceSnapshot) {
	panes := make(map[int]struct{}, len(snapshot.Panes))
	for _, pane := range snapshot.Panes {
		panes[pane.PaneID] = struct{}{}
	}
	for _, delta := range s.datagrams.Snapshot() {
		if delta.WorkspaceID != snapshot.WorkspaceID {
			continue
		}
		if _, ok := panes[delta.PaneID]; !ok {
			s.datagrams.DeletePane(delta.WorkspaceID, delta.PaneID)
		}
	}
}

func (s *engineWorkspaceSource) deleteDatagramsInvalidatedByReliable(message remotegrid.WorkspaceMessage) {
	for _, delta := range s.datagrams.Snapshot() {
		if sourceDeltaInvalidatedByReliable(delta, message) {
			s.datagrams.DeletePane(delta.WorkspaceID, delta.PaneID)
		}
	}
}

func sourceDeltaInvalidatedByReliable(delta remotegrid.PaneDelta, message remotegrid.WorkspaceMessage) bool {
	if keyframe, ok := message.PaneKeyframe(); ok {
		if delta.WorkspaceID != keyframe.WorkspaceID || delta.PaneID != keyframe.PaneID {
			return false
		}
		if delta.PaneGeneration != keyframe.PaneGeneration {
			return delta.PaneGeneration < keyframe.PaneGeneration
		}
		return delta.BaseKeyframeID < keyframe.KeyframeID
	}
	if state, ok := message.UnsupportedPaneState(); ok {
		return delta.WorkspaceID == state.WorkspaceID &&
			delta.PaneID == state.PaneID &&
			delta.PaneGeneration <= state.PaneGeneration
	}
	return false
}

func (s *engineWorkspaceSource) subscribersLocked() []*engine.StreamPump {
	subscribers := make([]*engine.StreamPump, 0, len(s.subscribers))
	for subscriber := range s.subscribers {
		subscribers = append(subscribers, subscriber)
	}
	return subscribers
}

func publishPayloadToSubscribers(payload remoteWorkspacePayload, subscribers []*engine.StreamPump) {
	if len(payload.Reliable) == 0 && len(payload.Datagrams) == 0 {
		return
	}
	for _, subscriber := range subscribers {
		subscriber.PublishReliable(payload.Reliable)
		subscriber.PublishDatagrams(payload.Datagrams)
	}
}
