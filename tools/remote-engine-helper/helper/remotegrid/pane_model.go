package remotegrid

import (
	"fmt"
	"sort"
)

type PaneModel struct {
	workspaceID string
	paneID      int

	paneGeneration uint64
	keyframeID     uint64
	deltaSequence  uint64
	hasKeyframe    bool

	size        GridSize
	rows        [][]GridCell
	rowVersions []uint64
	dirtyRows   map[int]struct{}

	cursor      CursorState
	cursorDirty bool

	activeScreen ActiveScreen
}

type PaneKeyframeDraft struct {
	workspaceID    string
	paneID         int
	paneGeneration uint64
	keyframeID     uint64
	size           GridSize
	rows           [][]GridCell
	rowVersions    []uint64
	cursor         CursorState
	activeScreen   ActiveScreen
}

func (d PaneKeyframeDraft) WorkspaceID() string {
	return d.workspaceID
}

func (d PaneKeyframeDraft) PaneID() int {
	return d.paneID
}

func (d PaneKeyframeDraft) PaneGeneration() uint64 {
	return d.paneGeneration
}

func (d PaneKeyframeDraft) KeyframeID() uint64 {
	return d.keyframeID
}

func (d PaneKeyframeDraft) Materialize() PaneKeyframe {
	rows := make([]GridRow, len(d.rows))
	for rowIndex, cells := range d.rows {
		rowVersion := uint64(0)
		if rowIndex < len(d.rowVersions) {
			rowVersion = d.rowVersions[rowIndex]
		}
		rows[rowIndex] = GridRow{
			Index:      rowIndex,
			RowVersion: rowVersion,
			Cells:      cloneCells(cells),
		}
	}
	return PaneKeyframe{
		WorkspaceID:                   d.workspaceID,
		PaneID:                        d.paneID,
		PaneGeneration:                d.paneGeneration,
		KeyframeID:                    d.keyframeID,
		GridSize:                      d.size,
		Rows:                          rows,
		Cursor:                        d.cursor,
		ActiveScreen:                  d.activeScreen,
		DatagramsEnabledAfterKeyframe: true,
	}
}

func NewPaneModel(workspaceID string, paneID int, size GridSize) (*PaneModel, error) {
	if err := validateGridSize(size); err != nil {
		return nil, err
	}

	return &PaneModel{
		workspaceID:    workspaceID,
		paneID:         paneID,
		paneGeneration: 1,
		size:           size,
		rows:           newPaneRows(size),
		rowVersions:    make([]uint64, size.Rows),
		dirtyRows:      make(map[int]struct{}),
		cursor:         CursorState{Row: 0, Column: 0, Visible: true, Shape: CursorShapeBlock, CursorVersion: 1},
		activeScreen:   ActiveScreenPrimary,
	}, nil
}

func NewPaneModelFromKeyframe(keyframe PaneKeyframe) (*PaneModel, error) {
	model := &PaneModel{}
	if err := model.ApplyKeyframe(keyframe); err != nil {
		return nil, err
	}
	return model, nil
}

func (p *PaneModel) ApplyKeyframe(keyframe PaneKeyframe) error {
	if err := validateGridSize(keyframe.GridSize); err != nil {
		return err
	}
	if err := validateCursor(keyframe.Cursor, keyframe.GridSize); err != nil {
		return err
	}
	if err := validateActiveScreen(keyframe.ActiveScreen); err != nil {
		return err
	}
	if len(keyframe.Rows) != keyframe.GridSize.Rows {
		return fmt.Errorf("remotegrid: keyframe has %d rows, want %d", len(keyframe.Rows), keyframe.GridSize.Rows)
	}

	rows := newPaneRows(keyframe.GridSize)
	rowVersions := make([]uint64, keyframe.GridSize.Rows)
	seenRows := make([]bool, keyframe.GridSize.Rows)
	for _, row := range keyframe.Rows {
		if row.Index < 0 || row.Index >= keyframe.GridSize.Rows {
			return fmt.Errorf("remotegrid: keyframe row index %d outside grid rows 0..%d", row.Index, keyframe.GridSize.Rows-1)
		}
		if seenRows[row.Index] {
			return fmt.Errorf("remotegrid: duplicate keyframe row %d", row.Index)
		}
		if len(row.Cells) != keyframe.GridSize.Columns {
			return fmt.Errorf("remotegrid: keyframe row %d has %d cells, want %d", row.Index, len(row.Cells), keyframe.GridSize.Columns)
		}
		if err := validateCells(row.Cells); err != nil {
			return fmt.Errorf("remotegrid: keyframe row %d: %w", row.Index, err)
		}
		seenRows[row.Index] = true
		rows[row.Index] = cloneCells(row.Cells)
		rowVersions[row.Index] = row.RowVersion
	}

	p.workspaceID = keyframe.WorkspaceID
	p.paneID = keyframe.PaneID
	p.paneGeneration = keyframe.PaneGeneration
	p.keyframeID = keyframe.KeyframeID
	p.deltaSequence = 0
	p.hasKeyframe = true
	p.size = keyframe.GridSize
	p.rows = rows
	p.rowVersions = rowVersions
	p.dirtyRows = make(map[int]struct{})
	p.cursor = keyframe.Cursor
	p.cursorDirty = false
	p.activeScreen = keyframe.ActiveScreen
	return nil
}

func (p *PaneModel) SetRow(rowIndex int, cells []GridCell) error {
	if rowIndex < 0 || rowIndex >= p.size.Rows {
		return fmt.Errorf("remotegrid: row index %d outside grid rows 0..%d", rowIndex, p.size.Rows-1)
	}
	if len(cells) != p.size.Columns {
		return fmt.Errorf("remotegrid: row %d has %d cells, want %d", rowIndex, len(cells), p.size.Columns)
	}
	if err := validateCells(cells); err != nil {
		return fmt.Errorf("remotegrid: row %d: %w", rowIndex, err)
	}
	if cellsEqual(p.rows[rowIndex], cells) {
		return nil
	}

	p.rows[rowIndex] = cloneCells(cells)
	p.rowVersions[rowIndex]++
	p.dirtyRows[rowIndex] = struct{}{}
	return nil
}

func (p *PaneModel) Keyframe() PaneKeyframe {
	return ClonePaneKeyframe(p.KeyframeDraft())
}

func (p *PaneModel) KeyframeDraft() PaneKeyframe {
	return p.BeginKeyframeDraft().Materialize()
}

func (p *PaneModel) BeginKeyframeDraft() PaneKeyframeDraft {
	p.keyframeID++
	p.deltaSequence = 0
	p.hasKeyframe = true
	p.dirtyRows = make(map[int]struct{})
	p.cursorDirty = false

	return PaneKeyframeDraft{
		workspaceID:    p.workspaceID,
		paneID:         p.paneID,
		paneGeneration: p.paneGeneration,
		keyframeID:     p.keyframeID,
		size:           p.size,
		rows:           append([][]GridCell(nil), p.rows...),
		rowVersions:    append([]uint64(nil), p.rowVersions...),
		cursor:         p.cursor,
		activeScreen:   p.activeScreen,
	}
}

func (p *PaneModel) Delta() (PaneDelta, bool) {
	if !p.hasKeyframe {
		return PaneDelta{}, false
	}
	if len(p.dirtyRows) == 0 && !p.cursorDirty {
		return PaneDelta{}, false
	}

	p.deltaSequence++
	delta := PaneDelta{
		WorkspaceID:    p.workspaceID,
		PaneID:         p.paneID,
		PaneGeneration: p.paneGeneration,
		BaseKeyframeID: p.keyframeID,
		DeltaSequence:  p.deltaSequence,
		RowUpdates:     p.dirtyRowUpdates(),
	}
	if p.cursorDirty {
		cursor := p.cursor
		delta.Cursor = &cursor
	}

	p.dirtyRows = make(map[int]struct{})
	p.cursorDirty = false
	return delta, true
}

func (p *PaneModel) ApplyDelta(delta PaneDelta) (PaneDelta, bool, error) {
	if !p.hasKeyframe {
		return PaneDelta{}, false, nil
	}
	if delta.WorkspaceID != p.workspaceID || delta.PaneID != p.paneID {
		return PaneDelta{}, false, fmt.Errorf("remotegrid: delta for workspace %q pane %d cannot apply to workspace %q pane %d", delta.WorkspaceID, delta.PaneID, p.workspaceID, p.paneID)
	}
	if delta.PaneGeneration != p.paneGeneration {
		return PaneDelta{}, false, nil
	}
	if delta.BaseKeyframeID > p.keyframeID {
		return PaneDelta{}, false, nil
	}

	rows := clonePaneRows(p.rows)
	rowVersions := append([]uint64(nil), p.rowVersions...)
	for _, update := range delta.RowUpdates {
		if err := applyRowUpdate(rows, rowVersions, p.size, update); err != nil {
			return PaneDelta{}, false, err
		}
	}

	cursor := p.cursor
	if delta.Cursor != nil {
		if err := validateCursor(*delta.Cursor, p.size); err != nil {
			return PaneDelta{}, false, err
		}
		if delta.Cursor.CursorVersion > cursor.CursorVersion {
			cursor = *delta.Cursor
		}
	}

	normalized := clonePaneDelta(delta)
	if delta.BaseKeyframeID < p.keyframeID {
		p.deltaSequence++
		normalized.BaseKeyframeID = p.keyframeID
		normalized.DeltaSequence = p.deltaSequence
	} else if delta.DeltaSequence > p.deltaSequence {
		p.deltaSequence = delta.DeltaSequence
	}

	p.rows = rows
	p.rowVersions = rowVersions
	p.cursor = cursor
	p.dirtyRows = make(map[int]struct{})
	p.cursorDirty = false
	return normalized, true, nil
}

func (p *PaneModel) Resize(size GridSize) error {
	if err := validateGridSize(size); err != nil {
		return err
	}
	if p.size == size {
		return nil
	}

	oldRows := p.rows
	p.size = size
	p.rows = newPaneRows(size)
	for rowIndex := range p.rows {
		if rowIndex >= len(oldRows) {
			continue
		}
		columns := len(p.rows[rowIndex])
		if len(oldRows[rowIndex]) < columns {
			columns = len(oldRows[rowIndex])
		}
		copy(p.rows[rowIndex][:columns], oldRows[rowIndex][:columns])
		normalizeCells(p.rows[rowIndex])
	}

	p.rowVersions = make([]uint64, size.Rows)
	p.dirtyRows = make(map[int]struct{})
	p.paneGeneration++
	p.keyframeID = 0
	p.deltaSequence = 0
	p.hasKeyframe = false
	clampedCursor := clampCursor(p.cursor, size)
	if cursorPositionChanged(p.cursor, clampedCursor) {
		clampedCursor.CursorVersion = p.cursor.CursorVersion + 1
	}
	p.cursor = clampedCursor
	p.cursorDirty = false
	return nil
}

func (p *PaneModel) GridSize() GridSize {
	return p.size
}

func (p *PaneModel) PaneGeneration() uint64 {
	return p.paneGeneration
}

func (p *PaneModel) HasKeyframe() bool {
	return p.hasKeyframe
}

func (p *PaneModel) SetActiveScreen(screen ActiveScreen) bool {
	if p.activeScreen == screen {
		return false
	}
	p.activeScreen = screen
	p.rows = newPaneRows(p.size)
	p.rowVersions = make([]uint64, p.size.Rows)
	p.dirtyRows = make(map[int]struct{})
	p.paneGeneration++
	p.keyframeID = 0
	p.deltaSequence = 0
	p.hasKeyframe = false
	p.cursor = CursorState{Row: 0, Column: 0, Visible: true, Shape: CursorShapeBlock, CursorVersion: p.cursor.CursorVersion + 1}
	p.cursorDirty = false
	return true
}

func (p *PaneModel) SetCursor(cursor CursorState) error {
	if err := validateCursor(cursor, p.size); err != nil {
		return err
	}
	cursor.CursorVersion = p.cursor.CursorVersion
	if p.cursor == cursor {
		return nil
	}
	cursor.CursorVersion++
	p.cursor = cursor
	if p.hasKeyframe {
		p.cursorDirty = true
	}
	return nil
}

func (p *PaneModel) snapshotRows() []GridRow {
	return CloneGridRows(p.keyframeRows())
}

func (p *PaneModel) keyframeRows() []GridRow {
	rows := make([]GridRow, len(p.rows))
	for rowIndex := range p.rows {
		rows[rowIndex] = GridRow{
			Index:      rowIndex,
			RowVersion: p.rowVersions[rowIndex],
			Cells:      p.rows[rowIndex],
		}
	}
	return rows
}

func (p *PaneModel) dirtyRowUpdates() []RowUpdate {
	rowIndexes := make([]int, 0, len(p.dirtyRows))
	for rowIndex := range p.dirtyRows {
		rowIndexes = append(rowIndexes, rowIndex)
	}
	sort.Ints(rowIndexes)

	updates := make([]RowUpdate, 0, len(rowIndexes))
	for _, rowIndex := range rowIndexes {
		updates = append(updates, RowUpdate{
			RowIndex:   rowIndex,
			RowVersion: p.rowVersions[rowIndex],
			Update:     FullRow(cloneCells(p.rows[rowIndex])),
		})
	}
	return updates
}

func newPaneRows(size GridSize) [][]GridCell {
	rows := make([][]GridCell, size.Rows)
	for rowIndex := range rows {
		rows[rowIndex] = blankCells(size.Columns)
	}
	return rows
}

func blankCells(columns int) []GridCell {
	cells := make([]GridCell, columns)
	for column := range cells {
		cells[column] = blankCell()
	}
	return cells
}

func cloneCells(cells []GridCell) []GridCell {
	clone := make([]GridCell, len(cells))
	copy(clone, cells)
	return clone
}

func cellsEqual(left, right []GridCell) bool {
	if len(left) != len(right) {
		return false
	}
	for i := range left {
		if left[i] != right[i] {
			return false
		}
	}
	return true
}

func clonePaneRows(rows [][]GridCell) [][]GridCell {
	clone := make([][]GridCell, len(rows))
	for rowIndex := range rows {
		clone[rowIndex] = cloneCells(rows[rowIndex])
	}
	return clone
}

func applyRowUpdate(rows [][]GridCell, rowVersions []uint64, size GridSize, update RowUpdate) error {
	if update.RowIndex < 0 || update.RowIndex >= size.Rows {
		return fmt.Errorf("remotegrid: row update index %d outside grid rows 0..%d", update.RowIndex, size.Rows-1)
	}
	if update.Update.span != nil {
		return applySpanUpdate(rows, rowVersions, size, update)
	}
	return applyFullRowUpdate(rows, rowVersions, size, update)
}

func applyFullRowUpdate(rows [][]GridCell, rowVersions []uint64, size GridSize, update RowUpdate) error {
	cells := update.Update.fullRow
	if len(cells) != size.Columns {
		return fmt.Errorf("remotegrid: full row update %d has %d cells, want %d", update.RowIndex, len(cells), size.Columns)
	}
	if err := validateCells(cells); err != nil {
		return fmt.Errorf("remotegrid: full row update %d: %w", update.RowIndex, err)
	}
	if update.RowVersion <= rowVersions[update.RowIndex] {
		return nil
	}
	rows[update.RowIndex] = cloneCells(cells)
	rowVersions[update.RowIndex] = update.RowVersion
	return nil
}

func applySpanUpdate(rows [][]GridCell, rowVersions []uint64, size GridSize, update RowUpdate) error {
	span := update.Update.span
	if span.StartColumn < 0 || span.StartColumn > size.Columns {
		return fmt.Errorf("remotegrid: span update row %d start column %d outside grid columns 0..%d", update.RowIndex, span.StartColumn, size.Columns)
	}
	endColumn := span.StartColumn + len(span.Cells)
	if len(span.Cells) == 0 {
		return fmt.Errorf("remotegrid: span update row %d has no cells", update.RowIndex)
	}
	if endColumn > size.Columns {
		return fmt.Errorf("remotegrid: span update row %d ends at column %d outside grid columns 0..%d", update.RowIndex, endColumn, size.Columns)
	}
	clearToColumn := endColumn
	if span.ClearToColumn != nil {
		clearToColumn = *span.ClearToColumn
		if clearToColumn < endColumn || clearToColumn > size.Columns {
			return fmt.Errorf("remotegrid: span update row %d clear column %d outside grid columns %d..%d", update.RowIndex, clearToColumn, endColumn, size.Columns)
		}
	}
	if err := validateCells(span.Cells); err != nil {
		return fmt.Errorf("remotegrid: span update row %d: %w", update.RowIndex, err)
	}
	if update.RowVersion <= rowVersions[update.RowIndex] {
		return nil
	}
	if span.BaseRowVersion != rowVersions[update.RowIndex] {
		return fmt.Errorf("remotegrid: span update row %d base row version %d does not match current row version %d", update.RowIndex, span.BaseRowVersion, rowVersions[update.RowIndex])
	}

	row := cloneCells(rows[update.RowIndex])
	copy(row[span.StartColumn:endColumn], span.Cells)
	for column := endColumn; column < clearToColumn; column++ {
		row[column] = blankCell()
	}
	if err := validateCells(row); err != nil {
		return fmt.Errorf("remotegrid: span update row %d: %w", update.RowIndex, err)
	}
	rows[update.RowIndex] = row
	rowVersions[update.RowIndex] = update.RowVersion
	return nil
}

func validateGridSize(size GridSize) error {
	if size.Columns <= 0 || size.Rows <= 0 {
		return fmt.Errorf("remotegrid: invalid grid size %dx%d", size.Columns, size.Rows)
	}
	return nil
}

func validateActiveScreen(screen ActiveScreen) error {
	if screen != ActiveScreenPrimary && screen != ActiveScreenAlternate {
		return fmt.Errorf("remotegrid: unsupported active screen %q", screen)
	}
	return nil
}

func validateCursor(cursor CursorState, size GridSize) error {
	if cursor.Row < 0 || cursor.Row >= size.Rows {
		return fmt.Errorf("remotegrid: cursor row %d outside grid rows 0..%d", cursor.Row, size.Rows-1)
	}
	if cursor.Column < 0 || cursor.Column >= size.Columns {
		return fmt.Errorf("remotegrid: cursor column %d outside grid columns 0..%d", cursor.Column, size.Columns-1)
	}
	if cursor.Shape != CursorShapeBlock && cursor.Shape != CursorShapeBar && cursor.Shape != CursorShapeUnderline {
		return fmt.Errorf("remotegrid: unsupported cursor shape %q", cursor.Shape)
	}
	return nil
}

func clampCursor(cursor CursorState, size GridSize) CursorState {
	if cursor.Row < 0 {
		cursor.Row = 0
	} else if cursor.Row >= size.Rows {
		cursor.Row = size.Rows - 1
	}
	if cursor.Column < 0 {
		cursor.Column = 0
	} else if cursor.Column >= size.Columns {
		cursor.Column = size.Columns - 1
	}
	return cursor
}

func cursorPositionChanged(left CursorState, right CursorState) bool {
	return left.Row != right.Row ||
		left.Column != right.Column ||
		left.Visible != right.Visible ||
		left.Shape != right.Shape
}

func validateCells(cells []GridCell) error {
	for column := 0; column < len(cells); {
		cell := cells[column]
		switch cell.Width {
		case 1:
			column++
		case 2:
			continuationColumn := column + 1
			if continuationColumn >= len(cells) {
				return fmt.Errorf("wide cell at column %d has no continuation cell", column)
			}
			if cells[continuationColumn] != continuationCell() {
				return fmt.Errorf("wide cell at column %d has invalid continuation cell at column %d", column, continuationColumn)
			}
			column += 2
		default:
			return fmt.Errorf("cell at column %d has invalid width %d", column, cell.Width)
		}
	}
	return nil
}

func normalizeCells(cells []GridCell) {
	for column := 0; column < len(cells); {
		cell := cells[column]
		switch cell.Width {
		case 1:
			column++
		case 2:
			continuationColumn := column + 1
			if continuationColumn < len(cells) && cells[continuationColumn] == continuationCell() {
				column += 2
				continue
			}
			cells[column] = blankCell()
			column++
		default:
			cells[column] = blankCell()
			column++
		}
	}
}

func blankCell() GridCell {
	return GridCell{Text: " ", Width: 1, Style: NormalCellStyle}
}

func continuationCell() GridCell {
	return GridCell{Text: "", Width: 0, Style: NormalCellStyle}
}
