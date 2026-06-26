package tmuxcc

const defaultPaneOutputBufferLimit = 1024

type PaneOutputBuffer struct {
	knownPanes map[int]struct{}
	pending    []Action
	limit      int
}

func NewPaneOutputBuffer() *PaneOutputBuffer {
	return NewPaneOutputBufferWithLimit(defaultPaneOutputBufferLimit)
}

func NewPaneOutputBufferWithLimit(limit int) *PaneOutputBuffer {
	if limit <= 0 {
		limit = defaultPaneOutputBufferLimit
	}
	return &PaneOutputBuffer{
		knownPanes: make(map[int]struct{}),
		limit:      limit,
	}
}

func (b *PaneOutputBuffer) Filter(actions []Action) []Action {
	var emitted []Action
	for _, action := range actions {
		if snapshot, ok := action.WorkspaceSnapshot(); ok {
			for _, pane := range snapshot.Panes {
				b.knownPanes[pane.PaneID] = struct{}{}
			}
			emitted = append(emitted, action)
			emitted = append(emitted, b.flushKnownPending()...)
			continue
		}

		if output, ok := action.PaneOutput(); ok {
			if b.isKnown(output.PaneID) {
				emitted = append(emitted, action)
			} else {
				b.appendPending(action)
			}
			continue
		}

		emitted = append(emitted, action)
	}
	return emitted
}

func (b *PaneOutputBuffer) appendPending(action Action) {
	if len(b.pending) >= b.limit {
		copy(b.pending, b.pending[1:])
		b.pending[len(b.pending)-1] = action
		return
	}
	b.pending = append(b.pending, action)
}

func (b *PaneOutputBuffer) PendingCount() int {
	return len(b.pending)
}

func (b *PaneOutputBuffer) isKnown(paneID int) bool {
	_, ok := b.knownPanes[paneID]
	return ok
}

func (b *PaneOutputBuffer) flushKnownPending() []Action {
	var emitted []Action
	remaining := b.pending[:0]
	for _, action := range b.pending {
		output, ok := action.PaneOutput()
		if ok && b.isKnown(output.PaneID) {
			emitted = append(emitted, action)
			continue
		}
		remaining = append(remaining, action)
	}
	b.pending = remaining
	return emitted
}
