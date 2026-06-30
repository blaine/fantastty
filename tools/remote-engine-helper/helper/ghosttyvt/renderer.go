//go:build linux && cgo && ghostty_vt

package ghosttyvt

/*
#cgo pkg-config: libghostty-vt
#include <ghostty/vt.h>

static inline GhosttyColorPaletteIndex fantastty_style_color_palette(GhosttyStyleColor color) {
	return color.value.palette;
}

static inline GhosttyColorRgb fantastty_style_color_rgb(GhosttyStyleColor color) {
	return color.value.rgb;
}
*/
import "C"

import (
	"fmt"
	"unsafe"

	"fantastty/remote-engine-helper/internal/engine"
	"fantastty/remote-engine-helper/remotegrid"
)

var _ engine.PaneRenderer = (*Renderer)(nil)

type Renderer struct {
	workspaceID string
	panes       map[int]*paneState
}

type paneState struct {
	terminal    C.GhosttyTerminal
	renderState C.GhosttyRenderState
	model       *remotegrid.PaneModel
}

type snapshotResult struct {
	generationChanged bool
}

func NewRenderer(workspaceID string) (*Renderer, error) {
	return &Renderer{
		workspaceID: workspaceID,
		panes:       make(map[int]*paneState),
	}, nil
}

func (r *Renderer) SeedPane(pane remotegrid.WorkspacePane) (remotegrid.PaneKeyframe, bool, error) {
	r.RemovePane(pane.PaneID)

	size := remotegrid.GridSize{Columns: pane.Frame.Columns, Rows: pane.Frame.Rows}
	model, err := remotegrid.NewPaneModel(r.workspaceID, pane.PaneID, size)
	if err != nil {
		return remotegrid.PaneKeyframe{}, false, err
	}

	state, err := newPaneState(model, size)
	if err != nil {
		return remotegrid.PaneKeyframe{}, false, err
	}
	state.write(seedPaneTerminalInput(pane, size))
	if pane.InitialCapture.ScrollRegion != nil {
		upper := pane.InitialCapture.ScrollRegion.Upper + 1
		lower := pane.InitialCapture.ScrollRegion.Lower + 1
		state.write([]byte(fmt.Sprintf("\x1b[%d;%dr", upper, lower)))
	}
	if pane.InitialCapture.Cursor != nil {
		state.seedCapturedCursor(*pane.InitialCapture.Cursor)
	}
	if _, err := state.snapshot(); err != nil {
		state.close()
		return remotegrid.PaneKeyframe{}, false, err
	}

	r.panes[pane.PaneID] = state
	return model.Keyframe(), true, nil
}

func (r *Renderer) ApplyOutput(paneID int, data []byte) (engine.RenderUpdate, error) {
	if len(data) == 0 {
		return engine.RenderUpdate{}, nil
	}

	state, ok := r.panes[paneID]
	if !ok {
		return engine.RenderUpdate{}, fmt.Errorf("ghosttyvt: pane %d has not been seeded", paneID)
	}

	state.write(data)

	result, err := state.snapshot()
	if err != nil {
		unsupported := remotegrid.UnsupportedPaneState{
			WorkspaceID:    r.workspaceID,
			PaneID:         paneID,
			PaneGeneration: state.model.PaneGeneration(),
			Reason:         remotegrid.UnsupportedPaneReasonSnapshotExtractionFailure,
			Fallback:       remotegrid.UnsupportedPaneFallbackBlankWithDiagnostic,
		}
		return engine.RenderUpdate{Unsupported: &unsupported}, nil
	}
	if result.generationChanged || !state.model.HasKeyframe() {
		keyframe := state.model.Keyframe()
		return engine.RenderUpdate{Keyframe: &keyframe}, nil
	}
	delta, ok := state.model.Delta()
	if !ok {
		return engine.RenderUpdate{}, nil
	}
	return engine.RenderUpdate{Delta: &delta}, nil
}

func (r *Renderer) CurrentKeyframe(paneID int) (remotegrid.PaneKeyframe, bool, error) {
	state, ok := r.panes[paneID]
	if !ok {
		return remotegrid.PaneKeyframe{}, false, nil
	}
	return state.model.Keyframe(), true, nil
}

func (r *Renderer) RemovePane(paneID int) {
	state, ok := r.panes[paneID]
	if !ok {
		return
	}
	state.close()
	delete(r.panes, paneID)
}

func (r *Renderer) Close() {
	for paneID := range r.panes {
		r.RemovePane(paneID)
	}
}

func newPaneState(model *remotegrid.PaneModel, size remotegrid.GridSize) (*paneState, error) {
	var terminal C.GhosttyTerminal
	var terminalOptions C.GhosttyTerminalOptions
	terminalOptions.cols = C.uint16_t(size.Columns)
	terminalOptions.rows = C.uint16_t(size.Rows)
	terminalOptions.max_scrollback = 0

	if err := check(C.ghostty_terminal_new(nil, &terminal, terminalOptions), "ghostty_terminal_new"); err != nil {
		return nil, err
	}
	if terminal == nil {
		return nil, fmt.Errorf("ghosttyvt: ghostty_terminal_new returned nil terminal")
	}

	var renderState C.GhosttyRenderState
	if err := check(C.ghostty_render_state_new(nil, &renderState), "ghostty_render_state_new"); err != nil {
		C.ghostty_terminal_free(terminal)
		return nil, err
	}
	if renderState == nil {
		C.ghostty_terminal_free(terminal)
		return nil, fmt.Errorf("ghosttyvt: ghostty_render_state_new returned nil render state")
	}

	return &paneState{
		terminal:    terminal,
		renderState: renderState,
		model:       model,
	}, nil
}

func (s *paneState) close() {
	if s.renderState != nil {
		C.ghostty_render_state_free(s.renderState)
		s.renderState = nil
	}
	if s.terminal != nil {
		C.ghostty_terminal_free(s.terminal)
		s.terminal = nil
	}
}

func (s *paneState) seedCapturedCursor(cursor remotegrid.CursorState) {
	row := cursor.Row + 1
	column := cursor.Column + 1
	visibility := "h"
	if !cursor.Visible {
		visibility = "l"
	}
	s.write([]byte(fmt.Sprintf("\x1b[%d;%dH\x1b[?25%s", row, column, visibility)))
}

func (s *paneState) write(data []byte) {
	if len(data) == 0 {
		return
	}
	C.ghostty_terminal_vt_write(
		s.terminal,
		(*C.uint8_t)(unsafe.Pointer(&data[0])),
		C.size_t(len(data)),
	)
}

func (s *paneState) snapshot() (snapshotResult, error) {
	if err := check(C.ghostty_render_state_update(s.renderState, s.terminal), "ghostty_render_state_update"); err != nil {
		return snapshotResult{}, err
	}

	columns, err := renderStateUint16(s.renderState, C.GHOSTTY_RENDER_STATE_DATA_COLS, "cols")
	if err != nil {
		return snapshotResult{}, err
	}
	rows, err := renderStateUint16(s.renderState, C.GHOSTTY_RENDER_STATE_DATA_ROWS, "rows")
	if err != nil {
		return snapshotResult{}, err
	}

	result := snapshotResult{}
	size := remotegrid.GridSize{Columns: int(columns), Rows: int(rows)}
	if s.model.GridSize() != size {
		if err := s.model.Resize(size); err != nil {
			return snapshotResult{}, fmt.Errorf("ghosttyvt: remotegrid.Resize failed: %w", err)
		}
		result.generationChanged = true
	}

	activeScreen, err := terminalActiveScreen(s.terminal)
	if err != nil {
		return snapshotResult{}, err
	}
	if s.model.SetActiveScreen(activeScreen) {
		result.generationChanged = true
	}

	if err := snapshotRows(s.renderState, s.model, int(columns), int(rows)); err != nil {
		return snapshotResult{}, err
	}
	if err := setSnapshotCursor(s.renderState, s.model, int(columns), int(rows)); err != nil {
		return snapshotResult{}, err
	}
	return result, nil
}

func snapshotRows(renderState C.GhosttyRenderState, model *remotegrid.PaneModel, columns int, rows int) error {
	var iterator C.GhosttyRenderStateRowIterator
	if err := check(C.ghostty_render_state_row_iterator_new(nil, &iterator), "ghostty_render_state_row_iterator_new"); err != nil {
		return err
	}
	if iterator == nil {
		return fmt.Errorf("ghosttyvt: ghostty_render_state_row_iterator_new returned nil iterator")
	}
	defer C.ghostty_render_state_row_iterator_free(iterator)

	if err := check(
		C.ghostty_render_state_get(
			renderState,
			C.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
			unsafe.Pointer(&iterator),
		),
		"ghostty_render_state_get row iterator",
	); err != nil {
		return err
	}

	var cells C.GhosttyRenderStateRowCells
	if err := check(C.ghostty_render_state_row_cells_new(nil, &cells), "ghostty_render_state_row_cells_new"); err != nil {
		return err
	}
	if cells == nil {
		return fmt.Errorf("ghosttyvt: ghostty_render_state_row_cells_new returned nil cells")
	}
	defer C.ghostty_render_state_row_cells_free(cells)

	rowIndex := 0
	for C.ghostty_render_state_row_iterator_next(iterator) {
		if rowIndex >= rows {
			return fmt.Errorf("ghosttyvt: render state returned more than %d rows", rows)
		}
		if err := check(
			C.ghostty_render_state_row_get(
				iterator,
				C.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
				unsafe.Pointer(&cells),
			),
			"ghostty_render_state_row_get cells",
		); err != nil {
			return err
		}

		rowCells := make([]remotegrid.GridCell, 0, columns)
		for C.ghostty_render_state_row_cells_next(cells) {
			if len(rowCells) >= columns {
				return fmt.Errorf("ghosttyvt: render state row %d returned more than %d cells", rowIndex, columns)
			}
			cell, err := snapshotCell(cells)
			if err != nil {
				return err
			}
			rowCells = append(rowCells, cell)
		}
		if len(rowCells) != columns {
			return fmt.Errorf("ghosttyvt: render state row %d returned %d cells, want %d", rowIndex, len(rowCells), columns)
		}
		if err := model.SetRow(rowIndex, rowCells); err != nil {
			return fmt.Errorf("ghosttyvt: remotegrid.SetRow(%d) failed: %w", rowIndex, err)
		}
		rowIndex++
	}
	if rowIndex != rows {
		return fmt.Errorf("ghosttyvt: render state returned %d rows, want %d", rowIndex, rows)
	}
	return nil
}

func snapshotCell(cells C.GhosttyRenderStateRowCells) (remotegrid.GridCell, error) {
	var raw C.GhosttyCell
	if err := check(
		C.ghostty_render_state_row_cells_get(
			cells,
			C.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW,
			unsafe.Pointer(&raw),
		),
		"ghostty_render_state_row_cells_get raw",
	); err != nil {
		return remotegrid.GridCell{}, err
	}

	var wide C.GhosttyCellWide
	if err := check(C.ghostty_cell_get(raw, C.GHOSTTY_CELL_DATA_WIDE, unsafe.Pointer(&wide)), "ghostty_cell_get wide"); err != nil {
		return remotegrid.GridCell{}, err
	}

	text, err := cellGraphemeUTF8(cells)
	if err != nil {
		return remotegrid.GridCell{}, err
	}
	style, err := snapshotCellStyle(cells)
	if err != nil {
		return remotegrid.GridCell{}, err
	}

	switch wide {
	case C.GHOSTTY_CELL_WIDE_NARROW:
		if text == "" {
			text = " "
		}
		return remotegrid.GridCell{Text: text, Width: 1, Style: style}, nil
	case C.GHOSTTY_CELL_WIDE_WIDE:
		if text == "" {
			return remotegrid.GridCell{}, fmt.Errorf("ghosttyvt: wide cell has no text")
		}
		return remotegrid.GridCell{Text: text, Width: 2, Style: style}, nil
	case C.GHOSTTY_CELL_WIDE_SPACER_TAIL:
		return remotegrid.GridCell{Text: "", Width: 0, Style: remotegrid.NormalCellStyle}, nil
	case C.GHOSTTY_CELL_WIDE_SPACER_HEAD:
		return remotegrid.GridCell{}, fmt.Errorf("ghosttyvt: unsupported Ghostty cell width state: spacer head")
	default:
		return remotegrid.GridCell{}, fmt.Errorf("ghosttyvt: unsupported Ghostty cell width state: %d", int(wide))
	}
}

func cellGraphemeUTF8(cells C.GhosttyRenderStateRowCells) (string, error) {
	var query C.GhosttyBuffer
	result := C.ghostty_render_state_row_cells_get(
		cells,
		C.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8,
		unsafe.Pointer(&query),
	)
	switch result {
	case C.GHOSTTY_SUCCESS:
		if query.len != 0 {
			return "", fmt.Errorf("ghosttyvt: grapheme UTF-8 query unexpectedly succeeded with required length %d", int(query.len))
		}
		return "", nil
	case C.GHOSTTY_OUT_OF_SPACE:
	default:
		return "", fmt.Errorf("ghosttyvt: ghostty_render_state_row_cells_get graphemes UTF-8 failed: %d", int(result))
	}

	if query.len == 0 {
		return "", nil
	}

	data := C.ghostty_alloc(nil, query.len)
	if data == nil {
		return "", fmt.Errorf("ghosttyvt: ghostty_alloc grapheme buffer failed for %d bytes", int(query.len))
	}
	defer C.ghostty_free(nil, data, query.len)

	buffer := C.GhosttyBuffer{
		ptr: data,
		cap: query.len,
	}
	if err := check(
		C.ghostty_render_state_row_cells_get(
			cells,
			C.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8,
			unsafe.Pointer(&buffer),
		),
		"ghostty_render_state_row_cells_get graphemes UTF-8",
	); err != nil {
		return "", err
	}
	return string(C.GoBytes(unsafe.Pointer(data), C.int(buffer.len))), nil
}

func snapshotCellStyle(cells C.GhosttyRenderStateRowCells) (remotegrid.CellStyle, error) {
	style := remotegrid.NormalCellStyle

	var ghosttyStyle C.GhosttyStyle
	ghosttyStyle.size = C.size_t(unsafe.Sizeof(ghosttyStyle))
	if err := check(
		C.ghostty_render_state_row_cells_get(
			cells,
			C.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE,
			unsafe.Pointer(&ghosttyStyle),
		),
		"ghostty_render_state_row_cells_get style",
	); err != nil {
		return remotegrid.CellStyle{}, err
	}

	style.Bold = bool(ghosttyStyle.bold)
	style.Faint = bool(ghosttyStyle.faint)
	style.Italic = bool(ghosttyStyle.italic)
	style.Blink = bool(ghosttyStyle.blink)
	style.Inverse = bool(ghosttyStyle.inverse)
	style.Invisible = bool(ghosttyStyle.invisible)
	style.Strikethrough = bool(ghosttyStyle.strikethrough)

	underline, err := underlineStyle(ghosttyStyle.underline)
	if err != nil {
		return remotegrid.CellStyle{}, err
	}
	style.Underline = underline
	style.UnderlineColor, err = styleColor(ghosttyStyle.underline_color)
	if err != nil {
		return remotegrid.CellStyle{}, fmt.Errorf("ghosttyvt: unsupported Ghostty underline color: %w", err)
	}

	foreground, err := styleColor(ghosttyStyle.fg_color)
	if err != nil {
		return remotegrid.CellStyle{}, fmt.Errorf("ghosttyvt: unsupported Ghostty foreground color: %w", err)
	}
	style.Foreground = foreground

	background, err := styleColor(ghosttyStyle.bg_color)
	if err != nil {
		return remotegrid.CellStyle{}, fmt.Errorf("ghosttyvt: unsupported Ghostty background color: %w", err)
	}
	if background == remotegrid.DefaultColor {
		contentBackground, ok, err := cellBackgroundContentColor(cells)
		if err != nil {
			return remotegrid.CellStyle{}, err
		}
		if ok {
			background = contentBackground
		}
	}
	style.Background = background

	return style, nil
}

func underlineStyle(underline C.int) (remotegrid.UnderlineStyle, error) {
	switch underline {
	case C.GHOSTTY_SGR_UNDERLINE_NONE:
		return remotegrid.UnderlineStyleNone, nil
	case C.GHOSTTY_SGR_UNDERLINE_SINGLE:
		return remotegrid.UnderlineStyleSingle, nil
	case C.GHOSTTY_SGR_UNDERLINE_DOUBLE:
		return remotegrid.UnderlineStyleDouble, nil
	case C.GHOSTTY_SGR_UNDERLINE_CURLY:
		return remotegrid.UnderlineStyleCurly, nil
	case C.GHOSTTY_SGR_UNDERLINE_DOTTED:
		return remotegrid.UnderlineStyleDotted, nil
	case C.GHOSTTY_SGR_UNDERLINE_DASHED:
		return remotegrid.UnderlineStyleDashed, nil
	default:
		return "", fmt.Errorf("ghosttyvt: unsupported Ghostty underline style: %d", int(underline))
	}
}

func styleColor(color C.GhosttyStyleColor) (remotegrid.Color, error) {
	switch color.tag {
	case C.GHOSTTY_STYLE_COLOR_NONE:
		return remotegrid.DefaultColor, nil
	case C.GHOSTTY_STYLE_COLOR_PALETTE:
		return remotegrid.IndexedColor(uint8(C.fantastty_style_color_palette(color))), nil
	case C.GHOSTTY_STYLE_COLOR_RGB:
		rgb := C.fantastty_style_color_rgb(color)
		return remotegrid.RGBColor(uint8(rgb.r), uint8(rgb.g), uint8(rgb.b)), nil
	default:
		return remotegrid.Color{}, fmt.Errorf("style color tag %d", int(color.tag))
	}
}

func cellBackgroundContentColor(cells C.GhosttyRenderStateRowCells) (remotegrid.Color, bool, error) {
	var raw C.GhosttyCell
	if err := check(
		C.ghostty_render_state_row_cells_get(
			cells,
			C.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW,
			unsafe.Pointer(&raw),
		),
		"ghostty_render_state_row_cells_get raw",
	); err != nil {
		return remotegrid.Color{}, false, err
	}

	var tag C.GhosttyCellContentTag
	if err := check(C.ghostty_cell_get(raw, C.GHOSTTY_CELL_DATA_CONTENT_TAG, unsafe.Pointer(&tag)), "ghostty_cell_get content tag"); err != nil {
		return remotegrid.Color{}, false, err
	}

	switch tag {
	case C.GHOSTTY_CELL_CONTENT_CODEPOINT, C.GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME:
		return remotegrid.DefaultColor, false, nil
	case C.GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE:
		var index C.GhosttyColorPaletteIndex
		if err := check(C.ghostty_cell_get(raw, C.GHOSTTY_CELL_DATA_COLOR_PALETTE, unsafe.Pointer(&index)), "ghostty_cell_get background palette"); err != nil {
			return remotegrid.Color{}, false, err
		}
		return remotegrid.IndexedColor(uint8(index)), true, nil
	case C.GHOSTTY_CELL_CONTENT_BG_COLOR_RGB:
		var rgb C.GhosttyColorRgb
		if err := check(C.ghostty_cell_get(raw, C.GHOSTTY_CELL_DATA_COLOR_RGB, unsafe.Pointer(&rgb)), "ghostty_cell_get background rgb"); err != nil {
			return remotegrid.Color{}, false, err
		}
		return remotegrid.RGBColor(uint8(rgb.r), uint8(rgb.g), uint8(rgb.b)), true, nil
	default:
		return remotegrid.Color{}, false, fmt.Errorf("ghosttyvt: unsupported Ghostty cell content tag: %d", int(tag))
	}
}

func setSnapshotCursor(renderState C.GhosttyRenderState, model *remotegrid.PaneModel, columns int, rows int) error {
	var cursorVisible C.bool
	if err := check(
		C.ghostty_render_state_get(
			renderState,
			C.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE,
			unsafe.Pointer(&cursorVisible),
		),
		"ghostty_render_state_get cursor visible",
	); err != nil {
		return err
	}

	var cursorInViewport C.bool
	if err := check(
		C.ghostty_render_state_get(
			renderState,
			C.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE,
			unsafe.Pointer(&cursorInViewport),
		),
		"ghostty_render_state_get cursor viewport",
	); err != nil {
		return err
	}

	row := 0
	column := 0
	if bool(cursorInViewport) {
		x, err := renderStateUint16(renderState, C.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, "cursor viewport x")
		if err != nil {
			return err
		}
		y, err := renderStateUint16(renderState, C.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, "cursor viewport y")
		if err != nil {
			return err
		}
		column = int(x)
		row = int(y)
		if column < 0 || column >= columns || row < 0 || row >= rows {
			return fmt.Errorf("ghosttyvt: cursor viewport position (%d,%d) outside grid %dx%d", column, row, columns, rows)
		}
	}

	shape, err := cursorShape(renderState)
	if err != nil {
		return err
	}
	cursor := remotegrid.CursorState{
		Row:     row,
		Column:  column,
		Visible: bool(cursorVisible) && bool(cursorInViewport),
		Shape:   shape,
	}
	if err := model.SetCursor(cursor); err != nil {
		return fmt.Errorf("ghosttyvt: remotegrid.SetCursor failed: %w", err)
	}
	return nil
}

func cursorShape(renderState C.GhosttyRenderState) (remotegrid.CursorShape, error) {
	var shape C.GhosttyRenderStateCursorVisualStyle
	if err := check(
		C.ghostty_render_state_get(
			renderState,
			C.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE,
			unsafe.Pointer(&shape),
		),
		"ghostty_render_state_get cursor visual style",
	); err != nil {
		return "", err
	}

	switch shape {
	case C.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR:
		return remotegrid.CursorShapeBar, nil
	case C.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK, C.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW:
		return remotegrid.CursorShapeBlock, nil
	case C.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE:
		return remotegrid.CursorShapeUnderline, nil
	default:
		return "", fmt.Errorf("ghosttyvt: unsupported Ghostty cursor visual style: %d", int(shape))
	}
}

func terminalActiveScreen(terminal C.GhosttyTerminal) (remotegrid.ActiveScreen, error) {
	var screen C.GhosttyTerminalScreen
	if err := check(
		C.ghostty_terminal_get(
			terminal,
			C.GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN,
			unsafe.Pointer(&screen),
		),
		"ghostty_terminal_get active screen",
	); err != nil {
		return "", err
	}

	switch screen {
	case C.GHOSTTY_TERMINAL_SCREEN_PRIMARY:
		return remotegrid.ActiveScreenPrimary, nil
	case C.GHOSTTY_TERMINAL_SCREEN_ALTERNATE:
		return remotegrid.ActiveScreenAlternate, nil
	default:
		return "", fmt.Errorf("ghosttyvt: unsupported Ghostty active screen: %d", int(screen))
	}
}

func renderStateUint16(renderState C.GhosttyRenderState, data C.GhosttyRenderStateData, name string) (uint16, error) {
	var value C.uint16_t
	if err := check(C.ghostty_render_state_get(renderState, data, unsafe.Pointer(&value)), "ghostty_render_state_get "+name); err != nil {
		return 0, err
	}
	return uint16(value), nil
}

func check(result C.GhosttyResult, operation string) error {
	if result != C.GHOSTTY_SUCCESS {
		return fmt.Errorf("ghosttyvt: %s failed: %d", operation, int(result))
	}
	return nil
}
