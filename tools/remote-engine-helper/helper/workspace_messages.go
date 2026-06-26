package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"fantastty/remote-engine-helper/remotegrid"
	"fantastty/remote-engine-helper/tmuxcc"
)

const smokeWorkspaceWindowID = 1
const smokeWorkspacePaneID = 7

func buildSmokeWorkspaceMessages(workspaceID string, marker string) ([]remotegrid.WorkspaceMessage, error) {
	if marker == "" {
		return nil, errors.New("smoke workspace marker is empty")
	}

	size := remotegrid.GridSize{Columns: len(marker) + 1, Rows: 1}
	actions, err := buildSmokeWorkspaceActions(workspaceID, size, marker)
	if err != nil {
		return nil, err
	}
	snapshot, err := smokeWorkspaceSnapshot(actions)
	if err != nil {
		return nil, err
	}
	return buildSmokeWorkspaceMessagesFromSnapshot(workspaceID, marker, snapshot, marker)
}

func buildSmokeWorkspaceActions(workspaceID string, size remotegrid.GridSize, marker string) ([]tmuxcc.Action, error) {
	model := tmuxcc.NewModel(workspaceID)
	lines := []string{
		fmt.Sprintf("%%window-add @%d", smokeWorkspaceWindowID),
		fmt.Sprintf("%%window-renamed @%d main", smokeWorkspaceWindowID),
		fmt.Sprintf(
			"%%layout-change @%d 0000,%dx%d,0,0,%%%d",
			smokeWorkspaceWindowID,
			size.Columns,
			size.Rows,
			smokeWorkspacePaneID,
		),
		fmt.Sprintf("%%window-pane-changed @%d %%%d", smokeWorkspaceWindowID, smokeWorkspacePaneID),
		fmt.Sprintf("%%session-window-changed $1 @%d", smokeWorkspaceWindowID),
		fmt.Sprintf("%%output %%%d %s\\015\\012", smokeWorkspacePaneID, marker),
	}

	var actions []tmuxcc.Action
	for _, line := range lines {
		next, err := model.ApplyLine(line)
		if err != nil {
			return nil, err
		}
		actions = append(actions, next...)
	}
	return actions, nil
}

func buildSmokeWorkspaceMessagesFromSnapshot(workspaceID string, marker string, snapshot remotegrid.WorkspaceSnapshot, capture string) ([]remotegrid.WorkspaceMessage, error) {
	if marker == "" {
		return nil, errors.New("smoke workspace marker is empty")
	}

	pane, err := smokeSnapshotPane(snapshot)
	if err != nil {
		return nil, err
	}
	size := remotegrid.GridSize{Columns: pane.Frame.Columns, Rows: pane.Frame.Rows}
	model, err := remotegrid.NewPaneModel(workspaceID, pane.PaneID, size)
	if err != nil {
		return nil, err
	}

	text, err := smokeCaptureLine(capture, marker)
	if err != nil {
		return nil, err
	}
	if text != marker {
		return nil, fmt.Errorf("smoke workspace capture = %q, want %q", text, marker)
	}
	if len(text) >= size.Columns {
		return nil, fmt.Errorf("smoke workspace marker length %d does not fit %d columns", len(text), size.Columns)
	}
	if size.Rows != 1 {
		return nil, fmt.Errorf("smoke workspace rows = %d, want 1", size.Rows)
	}

	cells := make([]remotegrid.GridCell, 0, size.Columns)
	for column := 0; column < len(text); column++ {
		cells = append(cells, remotegrid.GridCell{
			Text:  string(text[column]),
			Width: 1,
			Style: remotegrid.NormalCellStyle,
		})
	}
	for len(cells) < size.Columns {
		cells = append(cells, remotegrid.GridCell{
			Text:  " ",
			Width: 1,
			Style: remotegrid.NormalCellStyle,
		})
	}

	if err := model.SetRow(0, cells); err != nil {
		return nil, err
	}
	if err := model.SetCursor(remotegrid.CursorState{
		Row:     0,
		Column:  len(text),
		Visible: true,
		Shape:   remotegrid.CursorShapeBlock,
	}); err != nil {
		return nil, err
	}

	return []remotegrid.WorkspaceMessage{
		remotegrid.WorkspaceSnapshotMessage(snapshot),
		remotegrid.PaneKeyframeMessage(model.Keyframe()),
	}, nil
}

func smokeWorkspaceSnapshot(actions []tmuxcc.Action) (remotegrid.WorkspaceSnapshot, error) {
	var snapshot remotegrid.WorkspaceSnapshot
	found := false
	for _, action := range actions {
		if next, ok := action.WorkspaceSnapshot(); ok {
			snapshot = next
			found = true
		}
	}
	if !found {
		return remotegrid.WorkspaceSnapshot{}, errors.New("smoke workspace snapshot was not produced")
	}
	return snapshot, nil
}

func smokeSnapshotPane(snapshot remotegrid.WorkspaceSnapshot) (remotegrid.WorkspacePane, error) {
	if len(snapshot.Panes) != 1 {
		return remotegrid.WorkspacePane{}, fmt.Errorf("smoke workspace pane count = %d, want 1", len(snapshot.Panes))
	}
	return snapshot.Panes[0], nil
}

func smokeCaptureLine(capture string, marker string) (string, error) {
	for _, line := range strings.Split(capture, "\n") {
		line = strings.TrimRight(line, "\r")
		if line == marker {
			return line, nil
		}
	}
	return "", errors.New("smoke workspace marker was not captured")
}

func marshalWorkspaceMessageLines(messages []remotegrid.WorkspaceMessage) ([]byte, error) {
	var output []byte
	for _, message := range messages {
		line, err := json.Marshal(message)
		if err != nil {
			return nil, err
		}
		output = append(output, line...)
		output = append(output, '\n')
	}
	return output, nil
}

func smokeRemoteWorkspacePayloadSource(smoke *tmuxSmoke) remoteWorkspacePayloadSource {
	return func(workspaceID string) (remoteWorkspacePayload, error) {
		if smoke == nil {
			return remoteWorkspacePayload{}, errors.New("remote workspace payload source is disabled")
		}
		if err := smoke.verify(); err != nil {
			return remoteWorkspacePayload{}, err
		}
		messages, err := smoke.workspaceMessages(workspaceID)
		if err != nil {
			return remoteWorkspacePayload{}, err
		}
		return remoteWorkspacePayload{Reliable: messages}, nil
	}
}
