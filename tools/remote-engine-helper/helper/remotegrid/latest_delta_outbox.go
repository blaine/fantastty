package remotegrid

import (
	"sort"
	"sync"
)

type LatestDeltaOutbox struct {
	mu      sync.Mutex
	pending map[latestDeltaKey]*latestDeltaEntry
}

type latestDeltaKey struct {
	workspaceID string
	paneID      int
}

type latestDeltaEntry struct {
	delta PaneDelta
	rows  map[int]RowUpdate
}

func NewLatestDeltaOutbox() *LatestDeltaOutbox {
	return &LatestDeltaOutbox{
		pending: make(map[latestDeltaKey]*latestDeltaEntry),
	}
}

func (o *LatestDeltaOutbox) Publish(delta PaneDelta) bool {
	o.mu.Lock()
	defer o.mu.Unlock()

	key := latestDeltaKey{workspaceID: delta.WorkspaceID, paneID: delta.PaneID}
	entry, ok := o.pending[key]
	if !ok {
		o.pending[key] = newLatestDeltaEntry(delta)
		return true
	}
	if identityCompare := compareDeltaIdentity(delta, entry.delta); identityCompare < 0 {
		return false
	} else if identityCompare > 0 {
		o.pending[key] = newLatestDeltaEntry(delta)
		return true
	}

	changed := false
	for _, update := range delta.RowUpdates {
		current, ok := entry.rows[update.RowIndex]
		if !ok {
			entry.rows[update.RowIndex] = cloneRowUpdate(update)
			changed = true
			continue
		}
		merged, ok := coalesceRowUpdate(current, update)
		if ok {
			entry.rows[update.RowIndex] = merged
			changed = true
		}
	}
	if delta.Cursor != nil {
		if entry.delta.Cursor == nil || delta.Cursor.CursorVersion > entry.delta.Cursor.CursorVersion {
			cursor := *delta.Cursor
			entry.delta.Cursor = &cursor
			changed = true
		}
	}
	if changed && delta.DeltaSequence > entry.delta.DeltaSequence {
		entry.delta.DeltaSequence = delta.DeltaSequence
	}
	entry.delta.RowUpdates = sortedRowUpdates(entry.rows)
	return changed
}

func coalesceRowUpdate(current RowUpdate, next RowUpdate) (RowUpdate, bool) {
	if next.RowVersion <= current.RowVersion {
		return RowUpdate{}, false
	}
	if next.Update.IsFullRow() {
		return cloneRowUpdate(next), true
	}
	if current.Update.span != nil || next.Update.span == nil {
		return RowUpdate{}, false
	}
	if next.Update.span.BaseRowVersion != current.RowVersion {
		return RowUpdate{}, false
	}
	cells, ok := applySpanToFullRow(current.Update.fullRow, next.Update.span)
	if !ok {
		return RowUpdate{}, false
	}
	return RowUpdate{
		RowIndex:   current.RowIndex,
		RowVersion: next.RowVersion,
		Update:     FullRow(cells),
	}, true
}

func applySpanToFullRow(base []GridCell, span *rowUpdateSpan) ([]GridCell, bool) {
	if span == nil || span.StartColumn < 0 || span.StartColumn >= len(base) {
		return nil, false
	}
	if len(span.Cells) == 0 || span.StartColumn+len(span.Cells) > len(base) {
		return nil, false
	}
	if span.ClearToColumn != nil && (*span.ClearToColumn < 0 || *span.ClearToColumn > len(base)) {
		return nil, false
	}
	cells := cloneCells(base)
	for offset, cell := range span.Cells {
		cells[span.StartColumn+offset] = cell
	}
	if span.ClearToColumn != nil {
		clearStart := span.StartColumn + len(span.Cells)
		for column := clearStart; column < *span.ClearToColumn; column++ {
			cells[column] = blankCell()
		}
	}
	return cells, true
}

func (o *LatestDeltaOutbox) DeletePane(workspaceID string, paneID int) {
	o.mu.Lock()
	defer o.mu.Unlock()
	delete(o.pending, latestDeltaKey{workspaceID: workspaceID, paneID: paneID})
}

func (o *LatestDeltaOutbox) DeleteIfCurrent(delta PaneDelta) bool {
	o.mu.Lock()
	defer o.mu.Unlock()

	key := latestDeltaKey{workspaceID: delta.WorkspaceID, paneID: delta.PaneID}
	entry, ok := o.pending[key]
	if !ok {
		return false
	}
	if compareDeltaIdentity(entry.delta, delta) != 0 || entry.delta.DeltaSequence != delta.DeltaSequence {
		return false
	}
	delete(o.pending, key)
	return true
}

func (o *LatestDeltaOutbox) Drain() []PaneDelta {
	o.mu.Lock()
	defer o.mu.Unlock()

	deltas := o.snapshotLocked()
	o.pending = make(map[latestDeltaKey]*latestDeltaEntry)
	return deltas
}

func (o *LatestDeltaOutbox) Snapshot() []PaneDelta {
	o.mu.Lock()
	defer o.mu.Unlock()

	return o.snapshotLocked()
}

func (o *LatestDeltaOutbox) Len() int {
	o.mu.Lock()
	defer o.mu.Unlock()
	return len(o.pending)
}

func (o *LatestDeltaOutbox) snapshotLocked() []PaneDelta {
	keys := make([]latestDeltaKey, 0, len(o.pending))
	for key := range o.pending {
		keys = append(keys, key)
	}
	sort.Slice(keys, func(i, j int) bool {
		if keys[i].workspaceID != keys[j].workspaceID {
			return keys[i].workspaceID < keys[j].workspaceID
		}
		return keys[i].paneID < keys[j].paneID
	})

	deltas := make([]PaneDelta, 0, len(keys))
	for _, key := range keys {
		deltas = append(deltas, clonePaneDelta(o.pending[key].delta))
	}
	return deltas
}

func compareDeltaIdentity(left PaneDelta, right PaneDelta) int {
	if left.PaneGeneration < right.PaneGeneration {
		return -1
	}
	if left.PaneGeneration > right.PaneGeneration {
		return 1
	}
	if left.BaseKeyframeID < right.BaseKeyframeID {
		return -1
	}
	if left.BaseKeyframeID > right.BaseKeyframeID {
		return 1
	}
	return 0
}

func newLatestDeltaEntry(delta PaneDelta) *latestDeltaEntry {
	rows := make(map[int]RowUpdate, len(delta.RowUpdates))
	for _, update := range delta.RowUpdates {
		current, ok := rows[update.RowIndex]
		if !ok || update.RowVersion > current.RowVersion {
			rows[update.RowIndex] = cloneRowUpdate(update)
		}
	}
	next := clonePaneDelta(delta)
	next.RowUpdates = sortedRowUpdates(rows)
	return &latestDeltaEntry{delta: next, rows: rows}
}

func sortedRowUpdates(rows map[int]RowUpdate) []RowUpdate {
	rowIndexes := make([]int, 0, len(rows))
	for rowIndex := range rows {
		rowIndexes = append(rowIndexes, rowIndex)
	}
	sort.Ints(rowIndexes)

	updates := make([]RowUpdate, 0, len(rowIndexes))
	for _, rowIndex := range rowIndexes {
		updates = append(updates, cloneRowUpdate(rows[rowIndex]))
	}
	return updates
}

func clonePaneDelta(delta PaneDelta) PaneDelta {
	next := delta
	next.RowUpdates = make([]RowUpdate, len(delta.RowUpdates))
	for i, update := range delta.RowUpdates {
		next.RowUpdates[i] = cloneRowUpdate(update)
	}
	if delta.Cursor != nil {
		cursor := *delta.Cursor
		next.Cursor = &cursor
	}
	return next
}

func cloneRowUpdate(update RowUpdate) RowUpdate {
	return RowUpdate{
		RowIndex:   update.RowIndex,
		RowVersion: update.RowVersion,
		Update:     cloneRowUpdateBody(update.Update),
	}
}

func cloneRowUpdateBody(body RowUpdateBody) RowUpdateBody {
	if body.span != nil {
		span := *body.span
		span.Cells = cloneCells(span.Cells)
		if body.span.ClearToColumn != nil {
			clearToColumn := *body.span.ClearToColumn
			span.ClearToColumn = &clearToColumn
		}
		return RowUpdateBody{span: &span}
	}
	return RowUpdateBody{fullRow: cloneCells(body.fullRow)}
}
