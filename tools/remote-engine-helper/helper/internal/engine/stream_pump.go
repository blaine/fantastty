package engine

import (
	"encoding/json"
	"errors"
	"io"
	"sync"
	"sync/atomic"
	"time"

	"fantastty/remote-engine-helper/remotegrid"
)

var ErrStreamPumpCloseTimeout = errors.New("stream pump close timed out")

const MaxDatagramPayloadBytes = 1200

type DatagramWriter interface {
	WriteDatagram([]byte) error
}

type LatestDatagramWriter interface {
	WriteLatestDatagram(remotegrid.PaneDelta, []byte) error
}

type DatagramTooLargeError struct {
	Err error
}

func (e DatagramTooLargeError) Error() string {
	if e.Err == nil {
		return "datagram too large"
	}
	return e.Err.Error()
}

func (e DatagramTooLargeError) Unwrap() error {
	return e.Err
}

func (DatagramTooLargeError) DatagramTooLarge() bool {
	return true
}

type StreamPump struct {
	reliableWriter io.Writer
	datagramWriter DatagramWriter

	reliable       *remotegrid.LatestReliableOutbox
	datagrams      *remotegrid.LatestDeltaOutbox
	reliableDeltas *remotegrid.LatestDeltaOutbox
	inFlightDeltas *remotegrid.LatestDeltaOutbox

	reliableReady   chan struct{}
	datagramReady   chan struct{}
	done            chan struct{}
	closed          chan struct{}
	closeOnce       sync.Once
	wg              sync.WaitGroup
	reliableMu      sync.Mutex
	datagramMu      sync.Mutex
	reliableWriteMu sync.Mutex
	datagramPaused  atomic.Bool

	errMu sync.Mutex
	err   error

	barrierMu      sync.Mutex
	barriers       map[streamPumpPaneKey]streamPumpPaneBarrier
	panes          map[string]map[int]struct{}
	queuedBarriers map[streamPumpPaneKey]streamPumpPaneBarrier
	queuedPanes    map[string]map[int]struct{}

	closeCallbackMu     sync.Mutex
	closeCallbacks      map[int]func()
	nextCloseCallbackID int
	closing             bool
}

type streamPumpPaneKey struct {
	workspaceID string
	paneID      int
}

type streamPumpPaneBarrier struct {
	paneGeneration uint64
	keyframeID     uint64
	unsupported    bool
}

func NewStreamPump(reliableWriter io.Writer, datagramWriter DatagramWriter) *StreamPump {
	return newStreamPump(reliableWriter, datagramWriter, false)
}

func NewStreamPumpWithPausedDatagrams(reliableWriter io.Writer, datagramWriter DatagramWriter) *StreamPump {
	return newStreamPump(reliableWriter, datagramWriter, true)
}

func newStreamPump(reliableWriter io.Writer, datagramWriter DatagramWriter, pauseDatagrams bool) *StreamPump {
	if reliableWriter == nil {
		reliableWriter = io.Discard
	}
	if datagramWriter == nil {
		datagramWriter = discardDatagramWriter{}
	}

	pump := &StreamPump{
		reliableWriter: reliableWriter,
		datagramWriter: datagramWriter,
		reliable:       remotegrid.NewLatestReliableOutbox(),
		datagrams:      remotegrid.NewLatestDeltaOutbox(),
		reliableDeltas: remotegrid.NewLatestDeltaOutbox(),
		inFlightDeltas: remotegrid.NewLatestDeltaOutbox(),
		reliableReady:  make(chan struct{}, 1),
		datagramReady:  make(chan struct{}, 1),
		done:           make(chan struct{}),
		closed:         make(chan struct{}),
		barriers:       make(map[streamPumpPaneKey]streamPumpPaneBarrier),
		panes:          make(map[string]map[int]struct{}),
		queuedBarriers: make(map[streamPumpPaneKey]streamPumpPaneBarrier),
		queuedPanes:    make(map[string]map[int]struct{}),
		closeCallbacks: make(map[int]func()),
	}
	pump.datagramPaused.Store(pauseDatagrams)
	pump.wg.Add(2)
	go pump.runReliable()
	go pump.runDatagrams()
	return pump
}

func (p *StreamPump) PublishWorkspace(workspace *Workspace) {
	if workspace == nil {
		return
	}
	p.PublishReliable(workspace.DrainReliable())
	p.PublishDatagrams(workspace.DrainDatagrams())
}

func (p *StreamPump) PublishReliable(messages []remotegrid.WorkspaceMessage) {
	if len(messages) == 0 {
		return
	}
	for _, message := range messages {
		if !p.reliable.Publish(message) {
			continue
		}
		p.rememberQueuedReliableBarrier(message)
		p.dropDatagramsInvalidatedBy(message)
		p.dropReliableDeltasInvalidatedBy(message)
	}
	p.signal(p.reliableReady)
}

func (p *StreamPump) rememberQueuedReliableBarrier(message remotegrid.WorkspaceMessage) {
	p.barrierMu.Lock()
	streamPumpRememberReliableBarrierLocked(message, p.queuedPanes, p.queuedBarriers)
	p.barrierMu.Unlock()
}

func (p *StreamPump) rememberReliableBarrier(message remotegrid.WorkspaceMessage) {
	p.barrierMu.Lock()
	streamPumpRememberReliableBarrierLocked(message, p.panes, p.barriers)
	p.barrierMu.Unlock()
}

func streamPumpRememberReliableBarrierLocked(message remotegrid.WorkspaceMessage, panesByWorkspace map[string]map[int]struct{}, barriers map[streamPumpPaneKey]streamPumpPaneBarrier) {
	if snapshot, ok := message.WorkspaceSnapshot(); ok {
		panes := streamPumpPaneSet(snapshot.Panes)
		panesByWorkspace[snapshot.WorkspaceID] = panes
		for key := range barriers {
			if key.workspaceID != snapshot.WorkspaceID {
				continue
			}
			if _, ok := panes[key.paneID]; !ok {
				delete(barriers, key)
			}
		}
		return
	}
	if keyframe, ok := message.PaneKeyframe(); ok {
		key := streamPumpPaneKey{workspaceID: keyframe.WorkspaceID, paneID: keyframe.PaneID}
		next := streamPumpPaneBarrier{
			paneGeneration: keyframe.PaneGeneration,
			keyframeID:     keyframe.KeyframeID,
		}
		if current, ok := barriers[key]; !ok || streamPumpBarrierAccepts(current, next) {
			barriers[key] = next
		}
	}
	if state, ok := message.UnsupportedPaneState(); ok {
		key := streamPumpPaneKey{workspaceID: state.WorkspaceID, paneID: state.PaneID}
		next := streamPumpPaneBarrier{
			paneGeneration: state.PaneGeneration,
			unsupported:    true,
		}
		if current, ok := barriers[key]; !ok || streamPumpBarrierAccepts(current, next) {
			barriers[key] = next
		}
	}
}

func streamPumpBarrierAccepts(current streamPumpPaneBarrier, next streamPumpPaneBarrier) bool {
	if current.paneGeneration != next.paneGeneration {
		return next.paneGeneration > current.paneGeneration
	}
	if current.unsupported {
		return true
	}
	if next.unsupported {
		return false
	}
	return next.keyframeID >= current.keyframeID
}

func (p *StreamPump) dropDatagramsInvalidatedBy(message remotegrid.WorkspaceMessage) {
	for _, delta := range p.datagrams.Snapshot() {
		if deltaInvalidatedByReliableMessage(delta, message) {
			p.datagrams.DeletePane(delta.WorkspaceID, delta.PaneID)
		}
	}
}

func (p *StreamPump) dropReliableDeltasInvalidatedBy(message remotegrid.WorkspaceMessage) {
	p.reliableMu.Lock()
	defer p.reliableMu.Unlock()
	for _, delta := range p.reliableDeltas.Snapshot() {
		if deltaInvalidatedByReliableMessage(delta, message) {
			p.reliableDeltas.DeletePane(delta.WorkspaceID, delta.PaneID)
		}
	}
}

func deltaInvalidatedByReliableMessage(delta remotegrid.PaneDelta, message remotegrid.WorkspaceMessage) bool {
	if snapshot, ok := message.WorkspaceSnapshot(); ok {
		if delta.WorkspaceID != snapshot.WorkspaceID {
			return false
		}
		return !streamPumpSnapshotContainsPane(snapshot, delta.PaneID)
	}
	if keyframe, ok := message.PaneKeyframe(); ok {
		if delta.WorkspaceID != keyframe.WorkspaceID || delta.PaneID != keyframe.PaneID {
			return false
		}
		if delta.PaneGeneration < keyframe.PaneGeneration {
			return true
		}
		if delta.PaneGeneration > keyframe.PaneGeneration {
			return false
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

func (p *StreamPump) PublishDatagrams(deltas []remotegrid.PaneDelta) {
	if len(deltas) == 0 {
		return
	}
	datagramQueued := false
	for _, delta := range deltas {
		if p.datagramInvalidatedByQueuedReliable(delta) {
			continue
		}
		if p.datagramInvalidatedByReliableBarrier(delta) && !p.datagramMatchesQueuedReliableBarrier(delta) {
			continue
		}
		if p.datagramDependsOnReliableFallback(delta) {
			p.queueReliableDelta(delta)
			p.signal(p.reliableReady)
			continue
		}
		if p.datagrams.Publish(delta) {
			p.dropReliableDeltasSupersededByDatagram(delta)
			datagramQueued = true
		}
	}
	if datagramQueued {
		if p.datagramPaused.Load() {
			p.signal(p.reliableReady)
		} else {
			p.signal(p.datagramReady)
		}
	}
}

func (p *StreamPump) datagramInvalidatedByReliableBarrier(delta remotegrid.PaneDelta) bool {
	p.barrierMu.Lock()
	defer p.barrierMu.Unlock()
	return streamPumpDeltaInvalidatedByReliableState(delta, p.panes, p.barriers)
}

func (p *StreamPump) datagramInvalidatedByQueuedReliable(delta remotegrid.PaneDelta) bool {
	p.barrierMu.Lock()
	defer p.barrierMu.Unlock()
	return streamPumpDeltaInvalidatedByReliableState(delta, p.queuedPanes, p.queuedBarriers)
}

func (p *StreamPump) datagramMatchesQueuedReliableBarrier(delta remotegrid.PaneDelta) bool {
	p.barrierMu.Lock()
	defer p.barrierMu.Unlock()
	return streamPumpDeltaMatchesReliableBarrier(delta, p.queuedBarriers)
}

func streamPumpDeltaInvalidatedByReliableState(delta remotegrid.PaneDelta, panesByWorkspace map[string]map[int]struct{}, barriers map[streamPumpPaneKey]streamPumpPaneBarrier) bool {
	if panes, ok := panesByWorkspace[delta.WorkspaceID]; ok {
		if _, ok := panes[delta.PaneID]; !ok {
			return true
		}
	}
	barrier, ok := barriers[streamPumpPaneKey{workspaceID: delta.WorkspaceID, paneID: delta.PaneID}]
	if !ok {
		return false
	}
	if barrier.unsupported {
		return delta.PaneGeneration <= barrier.paneGeneration
	}
	if delta.PaneGeneration < barrier.paneGeneration {
		return true
	}
	if delta.PaneGeneration > barrier.paneGeneration {
		return false
	}
	return delta.BaseKeyframeID < barrier.keyframeID
}

func streamPumpDeltaMatchesReliableBarrier(delta remotegrid.PaneDelta, barriers map[streamPumpPaneKey]streamPumpPaneBarrier) bool {
	barrier, ok := barriers[streamPumpPaneKey{workspaceID: delta.WorkspaceID, paneID: delta.PaneID}]
	return ok &&
		!barrier.unsupported &&
		delta.PaneGeneration == barrier.paneGeneration &&
		delta.BaseKeyframeID == barrier.keyframeID
}

func streamPumpPaneSet(panes []remotegrid.WorkspacePane) map[int]struct{} {
	set := make(map[int]struct{}, len(panes))
	for _, pane := range panes {
		set[pane.PaneID] = struct{}{}
	}
	return set
}

func streamPumpSnapshotContainsPane(snapshot remotegrid.WorkspaceSnapshot, paneID int) bool {
	for _, pane := range snapshot.Panes {
		if pane.PaneID == paneID {
			return true
		}
	}
	return false
}

func (p *StreamPump) hasMatchingReliableBarrier(delta remotegrid.PaneDelta) bool {
	p.barrierMu.Lock()
	defer p.barrierMu.Unlock()
	barrier, ok := p.barriers[streamPumpPaneKey{workspaceID: delta.WorkspaceID, paneID: delta.PaneID}]
	return ok &&
		!barrier.unsupported &&
		delta.PaneGeneration == barrier.paneGeneration &&
		delta.BaseKeyframeID == barrier.keyframeID
}

func (p *StreamPump) ResumeDatagrams() {
	p.datagramPaused.Store(false)
	p.signal(p.datagramReady)
}

func (p *StreamPump) DropQueuedPaneDeltas(workspaceID string, paneID int) {
	p.datagrams.DeletePane(workspaceID, paneID)

	p.reliableMu.Lock()
	defer p.reliableMu.Unlock()
	p.reliableDeltas.DeletePane(workspaceID, paneID)
}

func (p *StreamPump) PublishReliableDeltaFallback(delta remotegrid.PaneDelta) {
	if p.datagramInvalidatedByQueuedReliable(delta) || p.datagramInvalidatedByReliableBarrier(delta) {
		return
	}
	p.queueReliableDelta(delta)
	p.signal(p.reliableReady)
}

func (p *StreamPump) dropReliableDeltasSupersededByDatagram(delta remotegrid.PaneDelta) {
	p.reliableMu.Lock()
	defer p.reliableMu.Unlock()
	for _, current := range p.reliableDeltas.Snapshot() {
		if current.WorkspaceID != delta.WorkspaceID || current.PaneID != delta.PaneID {
			continue
		}
		if streamPumpDeltaCoversQueuedReliableFallback(delta, current) {
			p.reliableDeltas.DeletePane(current.WorkspaceID, current.PaneID)
		}
	}
}

func (p *StreamPump) datagramDependsOnReliableFallback(delta remotegrid.PaneDelta) bool {
	p.reliableMu.Lock()
	defer p.reliableMu.Unlock()
	for _, fallback := range p.reliableDeltas.Snapshot() {
		if !streamPumpDeltaDependsOnReliableFallback(delta, fallback) {
			continue
		}
		return true
	}
	for _, fallback := range p.inFlightDeltas.Snapshot() {
		if !streamPumpDeltaDependsOnReliableFallback(delta, fallback) {
			continue
		}
		return true
	}
	return false
}

func streamPumpDeltaDependsOnReliableFallback(delta remotegrid.PaneDelta, fallback remotegrid.PaneDelta) bool {
	if delta.WorkspaceID != fallback.WorkspaceID ||
		delta.PaneID != fallback.PaneID ||
		delta.PaneGeneration != fallback.PaneGeneration ||
		delta.BaseKeyframeID != fallback.BaseKeyframeID {
		return false
	}
	fallbackRows := make(map[int]uint64, len(fallback.RowUpdates))
	for _, update := range fallback.RowUpdates {
		fallbackRows[update.RowIndex] = update.RowVersion
	}
	for _, update := range delta.RowUpdates {
		baseRowVersion, ok := update.Update.SpanBaseRowVersion()
		if !ok {
			continue
		}
		if fallbackRows[update.RowIndex] >= baseRowVersion {
			return true
		}
	}
	return false
}

func (p *StreamPump) Flush() error {
	if !p.flushReliable() {
		return p.Err()
	}
	if !p.flushDatagrams() {
		return p.Err()
	}
	if !p.flushReliable() {
		return p.Err()
	}
	return p.Err()
}

func (p *StreamPump) Close() error {
	p.closeOnce.Do(func() {
		callbacks := p.closeCallbacksSnapshot()
		close(p.done)
		unblockWriter(p.reliableWriter)
		unblockWriter(p.datagramWriter)
		for _, callback := range callbacks {
			callback()
		}
		go func() {
			p.wg.Wait()
			close(p.closed)
		}()
	})
	select {
	case <-p.closed:
	case <-time.After(2 * time.Second):
		p.recordError(ErrStreamPumpCloseTimeout)
	}
	return p.Err()
}

func (p *StreamPump) OnClose(callback func()) func() {
	if callback == nil {
		return func() {}
	}

	p.closeCallbackMu.Lock()
	if p.closing {
		p.closeCallbackMu.Unlock()
		callback()
		return func() {}
	}
	id := p.nextCloseCallbackID
	p.nextCloseCallbackID++
	p.closeCallbacks[id] = callback
	p.closeCallbackMu.Unlock()

	var unregisterOnce sync.Once
	return func() {
		unregisterOnce.Do(func() {
			p.closeCallbackMu.Lock()
			delete(p.closeCallbacks, id)
			p.closeCallbackMu.Unlock()
		})
	}
}

func (p *StreamPump) closeCallbacksSnapshot() []func() {
	p.closeCallbackMu.Lock()
	defer p.closeCallbackMu.Unlock()

	p.closing = true
	callbacks := make([]func(), 0, len(p.closeCallbacks))
	for _, callback := range p.closeCallbacks {
		callbacks = append(callbacks, callback)
	}
	p.closeCallbacks = nil
	return callbacks
}

func (p *StreamPump) Err() error {
	p.errMu.Lock()
	defer p.errMu.Unlock()
	return p.err
}

func (p *StreamPump) signal(ch chan struct{}) {
	select {
	case ch <- struct{}{}:
	case <-p.done:
	default:
	}
}

func (p *StreamPump) runReliable() {
	defer p.wg.Done()
	for {
		select {
		case <-p.done:
			return
		case <-p.reliableReady:
			if !p.flushReliable() {
				return
			}
		}
	}
}

func (p *StreamPump) flushReliable() bool {
	p.reliableWriteMu.Lock()
	defer p.reliableWriteMu.Unlock()

	for {
		if p.datagramPaused.Load() && !p.promotePausedOversizedDatagramsToReliable() {
			return false
		}
		p.reliableMu.Lock()
		messages := p.drainReliableMessages()
		p.reliableMu.Unlock()
		if len(messages) == 0 {
			return true
		}
		for _, message := range messages {
			inFlightDelta, hasInFlightDelta := message.PaneDelta()
			if p.reliableMessageInvalidatedByQueuedReliable(message) {
				if hasInFlightDelta {
					p.clearReliableDeltaInFlight(inFlightDelta)
				}
				continue
			}
			if hasInFlightDelta {
				p.markReliableDeltaInFlight(inFlightDelta)
			}
			err := writeReliableMessage(p.reliableWriter, message)
			if hasInFlightDelta {
				p.clearReliableDeltaInFlight(inFlightDelta)
			}
			if err != nil {
				p.clearReliableMessagesInFlight(messages)
				p.recordError(err)
				return false
			}
			p.rememberReliableBarrier(message)
			if !p.datagramPaused.Load() {
				p.signal(p.datagramReady)
			}
		}
		select {
		case <-p.done:
			return false
		default:
		}
	}
}

func (p *StreamPump) promotePausedOversizedDatagramsToReliable() bool {
	for _, delta := range p.datagrams.Snapshot() {
		if p.datagramInvalidatedByQueuedReliable(delta) ||
			(p.datagramInvalidatedByReliableBarrier(delta) && !p.datagramMatchesQueuedReliableBarrier(delta)) {
			p.datagrams.DeleteIfCurrent(delta)
			continue
		}
		if !p.hasMatchingReliableBarrier(delta) {
			continue
		}
		payload, err := encodeDatagram(delta)
		if err != nil {
			p.recordError(err)
			return false
		}
		if len(payload) <= MaxDatagramPayloadBytes {
			continue
		}
		if p.datagrams.DeleteIfCurrent(delta) {
			p.queueReliableDelta(delta)
		}
	}
	return true
}

func (p *StreamPump) drainReliableMessages() []remotegrid.WorkspaceMessage {
	messages := p.reliable.Drain()

	held := make([]remotegrid.PaneDelta, 0)
	for _, delta := range p.reliableDeltas.Drain() {
		if p.datagramInvalidatedByQueuedReliable(delta) || !p.hasMatchingReliableBarrier(delta) {
			held = append(held, delta)
			continue
		}
		p.inFlightDeltas.Publish(delta)
		messages = append(messages, remotegrid.PaneDeltaMessage(delta))
	}
	for _, delta := range held {
		p.reliableDeltas.Publish(delta)
	}
	return messages
}

func (p *StreamPump) runDatagrams() {
	defer p.wg.Done()
	for {
		select {
		case <-p.done:
			return
		case <-p.datagramReady:
			if !p.flushDatagrams() {
				return
			}
		}
	}
}

func (p *StreamPump) flushDatagrams() bool {
	if p.datagramPaused.Load() {
		return true
	}

	p.datagramMu.Lock()
	defer p.datagramMu.Unlock()

	for {
		deltas := p.datagrams.Drain()
		if len(deltas) == 0 {
			return true
		}
		held := make([]remotegrid.PaneDelta, 0)
		reliableQueued := false
		for _, delta := range deltas {
			if p.datagramInvalidatedByQueuedReliable(delta) || !p.hasMatchingReliableBarrier(delta) {
				held = append(held, delta)
				continue
			}
			payload, err := encodeDatagram(delta)
			if err != nil {
				p.recordError(err)
				return false
			}
			if len(payload) > MaxDatagramPayloadBytes {
				if p.datagramInvalidatedByQueuedReliable(delta) {
					continue
				}
				p.queueReliableDelta(delta)
				reliableQueued = true
				continue
			}
			if p.datagramInvalidatedByQueuedReliable(delta) {
				continue
			}
			if err := p.writeDatagram(delta, payload); err != nil {
				if isDatagramTooLarge(err) {
					if p.datagramInvalidatedByQueuedReliable(delta) {
						continue
					}
					p.queueReliableDelta(delta)
					reliableQueued = true
					continue
				}
				p.recordError(err)
				return false
			}
		}
		if reliableQueued {
			p.signal(p.reliableReady)
		}
		for _, delta := range held {
			p.datagrams.Publish(delta)
		}
		if len(held) > 0 {
			return true
		}
		select {
		case <-p.done:
			return false
		default:
		}
	}
}

type datagramTooLarge interface {
	DatagramTooLarge() bool
}

func isDatagramTooLarge(err error) bool {
	var tooLarge datagramTooLarge
	return errors.As(err, &tooLarge) && tooLarge.DatagramTooLarge()
}

func (p *StreamPump) writeDatagram(delta remotegrid.PaneDelta, payload []byte) error {
	if writer, ok := p.datagramWriter.(LatestDatagramWriter); ok {
		return writer.WriteLatestDatagram(delta, payload)
	}
	return p.datagramWriter.WriteDatagram(payload)
}

func (p *StreamPump) queueReliableDelta(delta remotegrid.PaneDelta) {
	p.reliableMu.Lock()
	p.reliableDeltas.Publish(delta)
	p.reliableMu.Unlock()
}

func (p *StreamPump) markReliableDeltaInFlight(delta remotegrid.PaneDelta) {
	p.reliableMu.Lock()
	p.inFlightDeltas.Publish(delta)
	p.reliableMu.Unlock()
}

func (p *StreamPump) clearReliableDeltaInFlight(delta remotegrid.PaneDelta) {
	p.reliableMu.Lock()
	p.inFlightDeltas.DeleteIfCurrent(delta)
	p.reliableMu.Unlock()
}

func (p *StreamPump) clearReliableMessagesInFlight(messages []remotegrid.WorkspaceMessage) {
	for _, message := range messages {
		if delta, ok := message.PaneDelta(); ok {
			p.clearReliableDeltaInFlight(delta)
		}
	}
}

func (p *StreamPump) reliableMessageInvalidatedByQueuedReliable(message remotegrid.WorkspaceMessage) bool {
	if delta, ok := message.PaneDelta(); ok {
		return p.datagramInvalidatedByQueuedReliable(delta) || p.reliableDeltaInvalidatedByQueuedDatagram(delta)
	}
	if snapshot, ok := message.WorkspaceSnapshot(); ok {
		return p.snapshotInvalidatedByQueuedReliable(snapshot)
	}
	if keyframe, ok := message.PaneKeyframe(); ok {
		key := streamPumpPaneKey{workspaceID: keyframe.WorkspaceID, paneID: keyframe.PaneID}
		barrier := streamPumpPaneBarrier{
			paneGeneration: keyframe.PaneGeneration,
			keyframeID:     keyframe.KeyframeID,
		}
		return p.reliableBarrierInvalidatedByQueuedReliable(key, barrier)
	}
	if state, ok := message.UnsupportedPaneState(); ok {
		key := streamPumpPaneKey{workspaceID: state.WorkspaceID, paneID: state.PaneID}
		barrier := streamPumpPaneBarrier{
			paneGeneration: state.PaneGeneration,
			unsupported:    true,
		}
		return p.reliableBarrierInvalidatedByQueuedReliable(key, barrier)
	}
	return false
}

func (p *StreamPump) reliableDeltaInvalidatedByQueuedDatagram(delta remotegrid.PaneDelta) bool {
	for _, queued := range p.datagrams.Snapshot() {
		if queued.WorkspaceID != delta.WorkspaceID || queued.PaneID != delta.PaneID {
			continue
		}
		if streamPumpDeltaCoversQueuedReliableFallback(queued, delta) {
			return true
		}
	}
	return false
}

func streamPumpDeltaSupersedes(next remotegrid.PaneDelta, current remotegrid.PaneDelta) bool {
	if next.PaneGeneration != current.PaneGeneration {
		return next.PaneGeneration > current.PaneGeneration
	}
	if next.BaseKeyframeID != current.BaseKeyframeID {
		return next.BaseKeyframeID > current.BaseKeyframeID
	}
	return next.DeltaSequence > current.DeltaSequence
}

func streamPumpDeltaCoversQueuedReliableFallback(next remotegrid.PaneDelta, current remotegrid.PaneDelta) bool {
	if next.PaneGeneration != current.PaneGeneration {
		return next.PaneGeneration > current.PaneGeneration
	}
	if next.BaseKeyframeID != current.BaseKeyframeID {
		return next.BaseKeyframeID > current.BaseKeyframeID
	}
	if next.DeltaSequence <= current.DeltaSequence {
		return false
	}
	if current.Cursor != nil && (next.Cursor == nil || next.Cursor.CursorVersion < current.Cursor.CursorVersion) {
		return false
	}
	nextRows := make(map[int]remotegrid.RowUpdate, len(next.RowUpdates))
	for _, update := range next.RowUpdates {
		nextRows[update.RowIndex] = update
	}
	for _, update := range current.RowUpdates {
		nextUpdate, ok := nextRows[update.RowIndex]
		if !ok || nextUpdate.RowVersion < update.RowVersion || !nextUpdate.Update.IsFullRow() {
			return false
		}
	}
	return true
}

func (p *StreamPump) snapshotInvalidatedByQueuedReliable(snapshot remotegrid.WorkspaceSnapshot) bool {
	for _, message := range p.reliable.Snapshot() {
		queued, ok := message.WorkspaceSnapshot()
		if !ok || queued.WorkspaceID != snapshot.WorkspaceID {
			continue
		}
		if queued.LayoutGeneration > snapshot.LayoutGeneration {
			return true
		}
	}
	return false
}

func (p *StreamPump) reliableBarrierInvalidatedByQueuedReliable(key streamPumpPaneKey, barrier streamPumpPaneBarrier) bool {
	p.barrierMu.Lock()
	if panes, ok := p.queuedPanes[key.workspaceID]; ok {
		if _, ok := panes[key.paneID]; !ok {
			p.barrierMu.Unlock()
			return true
		}
	}
	queued, ok := p.queuedBarriers[key]
	p.barrierMu.Unlock()
	return ok && streamPumpBarrierSupersedes(queued, barrier)
}

func streamPumpBarrierSupersedes(next streamPumpPaneBarrier, current streamPumpPaneBarrier) bool {
	if next.paneGeneration != current.paneGeneration {
		return next.paneGeneration > current.paneGeneration
	}
	if current.unsupported {
		return !next.unsupported
	}
	if next.unsupported {
		return false
	}
	return next.keyframeID > current.keyframeID
}

func (p *StreamPump) recordError(err error) {
	p.errMu.Lock()
	defer p.errMu.Unlock()
	if p.err == nil {
		p.err = err
	}
}

func writeReliableMessage(writer io.Writer, message remotegrid.WorkspaceMessage) error {
	var payload []byte
	var err error
	if delta, ok := message.PaneDelta(); ok {
		payload, err = remotegrid.MarshalCompactPaneDeltaMessage(delta)
	} else {
		payload, err = json.Marshal(message)
	}
	if err != nil {
		return err
	}
	payload = append(payload, '\n')
	n, err := writer.Write(payload)
	if err != nil {
		return err
	}
	if n != len(payload) {
		return io.ErrShortWrite
	}
	return nil
}

func encodeDatagram(delta remotegrid.PaneDelta) ([]byte, error) {
	return remotegrid.MarshalCompactPaneDelta(delta)
}

type discardDatagramWriter struct{}

func (discardDatagramWriter) WriteDatagram([]byte) error {
	return nil
}

type closeWriter interface {
	Close() error
}

type writeDeadlineWriter interface {
	SetWriteDeadline(time.Time) error
}

func unblockWriter(writer any) {
	if writer == nil {
		return
	}
	if deadlineWriter, ok := writer.(writeDeadlineWriter); ok {
		_ = deadlineWriter.SetWriteDeadline(time.Now())
	}
	if closeWriter, ok := writer.(closeWriter); ok {
		_ = closeWriter.Close()
	}
}
