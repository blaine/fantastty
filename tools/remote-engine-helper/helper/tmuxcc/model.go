package tmuxcc

import (
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"fantastty/remote-engine-helper/remotegrid"
)

type Model struct {
	workspaceID string

	layoutGeneration uint64
	activeWindowID   int
	windows          map[int]*windowState
}

type windowState struct {
	id           int
	title        string
	index        *int
	isActive     bool
	activePaneID int
	panes        map[int]remotegrid.PaneFrame
	layout       string
	hasLayout    bool
}

type Action struct {
	workspaceSnapshot *remotegrid.WorkspaceSnapshot
	paneOutput        *OutputEvent
	paneFlow          *PaneFlowEvent
}

type PaneFlowEvent struct {
	PaneID int
	Paused bool
}

func NewModel(workspaceID string) *Model {
	return &Model{
		workspaceID: workspaceID,
		windows:     make(map[int]*windowState),
	}
}

func (a Action) WorkspaceSnapshot() (remotegrid.WorkspaceSnapshot, bool) {
	if a.workspaceSnapshot == nil {
		return remotegrid.WorkspaceSnapshot{}, false
	}
	return *a.workspaceSnapshot, true
}

func (a Action) PaneOutput() (OutputEvent, bool) {
	if a.paneOutput == nil {
		return OutputEvent{}, false
	}
	return *a.paneOutput, true
}

func (a Action) PaneFlow() (PaneFlowEvent, bool) {
	if a.paneFlow == nil {
		return PaneFlowEvent{}, false
	}
	return *a.paneFlow, true
}

func WorkspaceSnapshotAction(snapshot remotegrid.WorkspaceSnapshot) Action {
	return Action{workspaceSnapshot: &snapshot}
}

func (m *Model) ApplyLine(line string) ([]Action, error) {
	if event, ok, err := ParseOutputLine(line); ok || err != nil {
		if err != nil {
			return nil, err
		}
		return []Action{{paneOutput: &event}}, nil
	}

	fields := strings.Fields(line)
	if len(fields) == 0 {
		return nil, nil
	}

	switch fields[0] {
	case "%pause", "%continue":
		if len(fields) < 2 {
			return nil, fmt.Errorf("tmuxcc: %s missing pane id", fields[0])
		}
		paneID, err := parseTmuxID(fields[1], '%')
		if err != nil {
			return nil, err
		}
		return []Action{{paneFlow: &PaneFlowEvent{
			PaneID: paneID,
			Paused: fields[0] == "%pause",
		}}}, nil
	case "%window-add":
		if len(fields) < 2 {
			return nil, fmt.Errorf("tmuxcc: %%window-add missing window id")
		}
		windowID, err := parseTmuxID(fields[1], '@')
		if err != nil {
			return nil, err
		}
		window := m.ensureWindow(windowID)
		if len(m.windows) == 1 {
			m.setActiveWindow(windowID)
			window.isActive = true
		}
		return nil, nil
	case "%window-renamed":
		if len(fields) < 3 {
			return nil, fmt.Errorf("tmuxcc: %%window-renamed missing fields")
		}
		windowID, err := parseTmuxID(fields[1], '@')
		if err != nil {
			return nil, err
		}
		window := m.ensureWindow(windowID)
		title := strings.TrimSpace(strings.TrimPrefix(line, fields[0]+" "+fields[1]+" "))
		if window.title == title {
			return nil, nil
		}
		window.title = title
		return m.snapshotIfReady()
	case "%window-close":
		if len(fields) < 2 {
			return nil, fmt.Errorf("tmuxcc: %%window-close missing window id")
		}
		windowID, err := parseTmuxID(fields[1], '@')
		if err != nil {
			return nil, err
		}
		if _, ok := m.windows[windowID]; !ok {
			return nil, nil
		}
		delete(m.windows, windowID)
		if m.activeWindowID == windowID {
			m.activeWindowID = firstWindowID(m.windows)
			m.markActiveWindow()
		}
		return m.snapshotIfReady()
	case "%layout-change":
		if len(fields) < 3 {
			return nil, fmt.Errorf("tmuxcc: %%layout-change missing fields")
		}
		windowID, err := parseTmuxID(fields[1], '@')
		if err != nil {
			return nil, err
		}
		layoutTail := strings.TrimSpace(strings.TrimPrefix(line, fields[0]+" "+fields[1]+" "))
		layout, _, _ := strings.Cut(layoutTail, " ")
		activeMarker := layoutActiveMarker(fields)
		panes, err := parseLayoutPanes(layout)
		if err != nil {
			return nil, err
		}
		window := m.ensureWindow(windowID)
		layoutChanged := !window.hasLayout || window.layout != layout
		activeChanged := false
		if activeMarker == "*" && m.activeWindowID != windowID {
			m.setActiveWindow(windowID)
			activeChanged = true
		}
		if !layoutChanged && !activeChanged {
			return nil, nil
		}
		if layoutChanged {
			window.panes = panes
			window.layout = layout
			window.hasLayout = true
			if _, ok := panes[window.activePaneID]; !ok {
				window.activePaneID = firstPaneID(panes)
			}
		}
		return m.snapshotIfReady()
	case "%window-pane-changed":
		if len(fields) < 3 {
			return nil, fmt.Errorf("tmuxcc: %%window-pane-changed missing fields")
		}
		windowID, err := parseTmuxID(fields[1], '@')
		if err != nil {
			return nil, err
		}
		paneID, err := parseTmuxID(fields[2], '%')
		if err != nil {
			return nil, err
		}
		window := m.ensureWindow(windowID)
		if window.activePaneID == paneID {
			return nil, nil
		}
		window.activePaneID = paneID
		return m.snapshotIfReady()
	case "%session-window-changed":
		if len(fields) < 3 {
			return nil, fmt.Errorf("tmuxcc: %%session-window-changed missing fields")
		}
		windowID, err := parseTmuxID(fields[2], '@')
		if err != nil {
			return nil, err
		}
		if m.activeWindowID == windowID {
			return nil, nil
		}
		m.setActiveWindow(windowID)
		return m.snapshotIfReady()
	default:
		return nil, nil
	}
}

func (m *Model) ApplyListSnapshot(windowLines []string, paneLines []string) ([]Action, error) {
	seed := NewModel(m.workspaceID)
	seed.layoutGeneration = m.layoutGeneration

	activeWindowID := 0
	activeWindowCount := 0
	for _, line := range windowLines {
		fields := strings.Split(line, "\t")
		if len(fields) != 5 {
			return nil, fmt.Errorf("tmuxcc: list-windows line has %d fields, want 5", len(fields))
		}
		windowID, err := parseTmuxID(fields[0], '@')
		if err != nil {
			return nil, err
		}
		panes, err := parseLayoutPanes(fields[2])
		if err != nil {
			return nil, err
		}
		windowIndex, err := strconv.Atoi(fields[3])
		if err != nil {
			return nil, fmt.Errorf("tmuxcc: invalid window index %q: %w", fields[3], err)
		}
		active, err := parseTmuxBool(fields[4], "window_active")
		if err != nil {
			return nil, err
		}
		if active {
			activeWindowID = windowID
			activeWindowCount++
		}

		window := seed.ensureWindow(windowID)
		window.title = fields[1]
		window.index = &windowIndex
		window.panes = panes
		window.layout = fields[2]
		window.hasLayout = true
		if _, ok := panes[window.activePaneID]; !ok {
			window.activePaneID = firstPaneID(panes)
		}
	}
	if len(windowLines) > 0 && activeWindowCount != 1 {
		return nil, fmt.Errorf("tmuxcc: list-windows active window count = %d, want 1", activeWindowCount)
	}

	activePanesByWindow := make(map[int]int)
	for _, line := range paneLines {
		fields := strings.Split(line, "\t")
		if len(fields) < 3 {
			return nil, fmt.Errorf("tmuxcc: list-panes line has %d fields, want at least 3", len(fields))
		}
		windowID, err := parseTmuxID(fields[0], '@')
		if err != nil {
			return nil, err
		}
		paneID, err := parseTmuxID(fields[1], '%')
		if err != nil {
			return nil, err
		}
		active, err := parseTmuxBool(fields[2], "pane_active")
		if err != nil {
			return nil, err
		}
		window, ok := seed.windows[windowID]
		if !ok {
			return nil, fmt.Errorf("tmuxcc: list-panes referenced unknown window @%d", windowID)
		}
		if _, ok := window.panes[paneID]; !ok {
			return nil, fmt.Errorf("tmuxcc: list-panes referenced pane %%%d outside window @%d layout", paneID, windowID)
		}
		if active {
			activePanesByWindow[windowID]++
			if activePanesByWindow[windowID] > 1 {
				return nil, fmt.Errorf("tmuxcc: list-panes window @%d has multiple active panes", windowID)
			}
			window.activePaneID = paneID
		}
	}

	if activeWindowCount == 1 {
		seed.setActiveWindow(activeWindowID)
	}
	*m = *seed
	return m.snapshotIfReady()
}

func (m *Model) ensureWindow(windowID int) *windowState {
	if window, ok := m.windows[windowID]; ok {
		return window
	}
	window := &windowState{
		id:    windowID,
		title: fmt.Sprintf("@%d", windowID),
		panes: make(map[int]remotegrid.PaneFrame),
	}
	m.windows[windowID] = window
	if len(m.windows) == 1 {
		m.activeWindowID = windowID
		window.isActive = true
	}
	return window
}

func (m *Model) setActiveWindow(windowID int) {
	m.activeWindowID = windowID
	m.ensureWindow(windowID)
	m.markActiveWindow()
}

func (m *Model) markActiveWindow() {
	for id, window := range m.windows {
		window.isActive = id == m.activeWindowID
	}
}

func (m *Model) snapshotIfReady() ([]Action, error) {
	if !m.hasAnyLayout() {
		return nil, nil
	}
	m.layoutGeneration++
	snapshot := m.snapshot()
	return []Action{{workspaceSnapshot: &snapshot}}, nil
}

func (m *Model) hasAnyLayout() bool {
	for _, window := range m.windows {
		if window.hasLayout {
			return true
		}
	}
	return false
}

func (m *Model) snapshot() remotegrid.WorkspaceSnapshot {
	windowIDs := make([]int, 0, len(m.windows))
	for windowID := range m.windows {
		windowIDs = append(windowIDs, windowID)
	}
	sort.Ints(windowIDs)

	windows := make([]remotegrid.WorkspaceWindow, 0, len(windowIDs))
	var panes []remotegrid.WorkspacePane
	for _, windowID := range windowIDs {
		window := m.windows[windowID]
		windows = append(windows, remotegrid.WorkspaceWindow{
			WindowID: window.id,
			Title:    window.title,
			Index:    window.index,
			IsActive: window.isActive,
			Layout:   window.layout,
		})
		paneIDs := make([]int, 0, len(window.panes))
		for paneID := range window.panes {
			paneIDs = append(paneIDs, paneID)
		}
		sort.Ints(paneIDs)
		for _, paneID := range paneIDs {
			panes = append(panes, remotegrid.WorkspacePane{
				PaneID:   paneID,
				WindowID: window.id,
				IsActive: window.isActive && paneID == window.activePaneID,
				Frame:    window.panes[paneID],
			})
		}
	}

	return remotegrid.WorkspaceSnapshot{
		WorkspaceID:      m.workspaceID,
		LayoutGeneration: m.layoutGeneration,
		Windows:          windows,
		Panes:            panes,
	}
}

var layoutPanePattern = regexp.MustCompile(`(\d+)x(\d+),(\d+),(\d+),%?(\d+)`)

func parseLayoutPanes(layout string) (map[int]remotegrid.PaneFrame, error) {
	matches := layoutPanePattern.FindAllStringSubmatch(layout, -1)
	if len(matches) == 0 {
		return nil, fmt.Errorf("tmuxcc: layout contains no panes: %q", layout)
	}

	panes := make(map[int]remotegrid.PaneFrame, len(matches))
	for _, match := range matches {
		columns, err := strconv.Atoi(match[1])
		if err != nil {
			return nil, fmt.Errorf("tmuxcc: invalid pane columns: %w", err)
		}
		rows, err := strconv.Atoi(match[2])
		if err != nil {
			return nil, fmt.Errorf("tmuxcc: invalid pane rows: %w", err)
		}
		x, err := strconv.Atoi(match[3])
		if err != nil {
			return nil, fmt.Errorf("tmuxcc: invalid pane x: %w", err)
		}
		y, err := strconv.Atoi(match[4])
		if err != nil {
			return nil, fmt.Errorf("tmuxcc: invalid pane y: %w", err)
		}
		paneID, err := strconv.Atoi(match[5])
		if err != nil {
			return nil, fmt.Errorf("tmuxcc: invalid pane id: %w", err)
		}
		if columns <= 0 || rows <= 0 {
			return nil, fmt.Errorf("tmuxcc: invalid pane size %dx%d for %%%d", columns, rows, paneID)
		}
		if _, exists := panes[paneID]; exists {
			return nil, fmt.Errorf("tmuxcc: duplicate pane id %%%d", paneID)
		}
		panes[paneID] = remotegrid.PaneFrame{X: x, Y: y, Columns: columns, Rows: rows}
	}
	return panes, nil
}

func parseTmuxID(value string, prefix byte) (int, error) {
	if value == "" || value[0] != prefix {
		return 0, fmt.Errorf("tmuxcc: invalid tmux id %q, want %cN", value, prefix)
	}
	id, err := strconv.Atoi(value[1:])
	if err != nil {
		return 0, fmt.Errorf("tmuxcc: invalid tmux id %q: %w", value, err)
	}
	return id, nil
}

func parseTmuxBool(value string, name string) (bool, error) {
	switch value {
	case "0":
		return false, nil
	case "1":
		return true, nil
	default:
		return false, fmt.Errorf("tmuxcc: invalid %s %q, want 0 or 1", name, value)
	}
}

func layoutActiveMarker(fields []string) string {
	if len(fields) == 0 {
		return ""
	}
	marker := fields[len(fields)-1]
	if marker == "*" || marker == "-" {
		return marker
	}
	return ""
}

func paneLayoutKey(panes map[int]remotegrid.PaneFrame) string {
	ids := make([]int, 0, len(panes))
	for paneID := range panes {
		ids = append(ids, paneID)
	}
	sort.Ints(ids)
	parts := make([]string, len(ids))
	for i, paneID := range ids {
		frame := panes[paneID]
		parts[i] = fmt.Sprintf("%d:%d,%d,%d,%d", paneID, frame.X, frame.Y, frame.Columns, frame.Rows)
	}
	return strings.Join(parts, ",")
}

func firstWindowID(windows map[int]*windowState) int {
	ids := make([]int, 0, len(windows))
	for windowID := range windows {
		ids = append(ids, windowID)
	}
	sort.Ints(ids)
	if len(ids) == 0 {
		return 0
	}
	return ids[0]
}

func firstPaneID(panes map[int]remotegrid.PaneFrame) int {
	ids := make([]int, 0, len(panes))
	for paneID := range panes {
		ids = append(ids, paneID)
	}
	sort.Ints(ids)
	if len(ids) == 0 {
		return 0
	}
	return ids[0]
}
