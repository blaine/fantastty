package main

import (
	"bytes"
	"encoding/json"
	"testing"

	"fantastty/remote-engine-helper/remotegrid"
)

func TestBuildSmokeWorkspaceMessagesBuildsSnapshotAndKeyframe(t *testing.T) {
	messages, err := buildSmokeWorkspaceMessages("workspace-1", "smoke-marker")
	if err != nil {
		t.Fatal(err)
	}
	if len(messages) != 2 {
		t.Fatalf("message count = %d, want 2", len(messages))
	}

	lines := marshalSmokeMessagesForTest(t, messages)
	if len(lines) != 2 {
		t.Fatalf("line count = %d, want 2", len(lines))
	}

	snapshot := decodeWorkspaceMessagePayload(t, lines[0], "workspaceSnapshot")
	if got := stringField(t, snapshot, "workspaceID"); got != "workspace-1" {
		t.Fatalf("snapshot workspaceID = %q, want workspace-1", got)
	}
	if got := intField(t, snapshot, "layoutGeneration"); got != 1 {
		t.Fatalf("snapshot layoutGeneration = %d, want 1", got)
	}

	windows := objectSliceField(t, snapshot, "windows")
	if len(windows) != 1 {
		t.Fatalf("snapshot window count = %d, want 1", len(windows))
	}
	if got := intField(t, windows[0], "windowID"); got != smokeWorkspaceWindowID {
		t.Fatalf("windowID = %d, want %d", got, smokeWorkspaceWindowID)
	}
	if got := stringField(t, windows[0], "title"); got != "main" {
		t.Fatalf("window title = %q, want main", got)
	}
	if got := windows[0]["index"]; got != nil {
		t.Fatalf("window index = %#v, want null until tmux index is seeded", got)
	}
	if got := boolField(t, windows[0], "isActive"); !got {
		t.Fatal("window isActive = false, want true")
	}

	panes := objectSliceField(t, snapshot, "panes")
	if len(panes) != 1 {
		t.Fatalf("snapshot pane count = %d, want 1", len(panes))
	}
	if got := intField(t, panes[0], "paneID"); got != smokeWorkspacePaneID {
		t.Fatalf("paneID = %d, want %d", got, smokeWorkspacePaneID)
	}
	if got := intField(t, panes[0], "windowID"); got != smokeWorkspaceWindowID {
		t.Fatalf("pane windowID = %d, want %d", got, smokeWorkspaceWindowID)
	}
	if got := boolField(t, panes[0], "isActive"); !got {
		t.Fatal("pane isActive = false, want true")
	}
	frame := objectField(t, panes[0], "frame")
	if got := intField(t, frame, "x"); got != 0 {
		t.Fatalf("frame x = %d, want 0", got)
	}
	if got := intField(t, frame, "y"); got != 0 {
		t.Fatalf("frame y = %d, want 0", got)
	}
	if got := intField(t, frame, "columns"); got != len("smoke-marker")+1 {
		t.Fatalf("frame columns = %d, want %d", got, len("smoke-marker")+1)
	}
	if got := intField(t, frame, "rows"); got != 1 {
		t.Fatalf("frame rows = %d, want 1", got)
	}

	keyframe := decodeWorkspaceMessagePayload(t, lines[1], "paneKeyframe")
	if got := stringField(t, keyframe, "workspaceID"); got != "workspace-1" {
		t.Fatalf("keyframe workspaceID = %q, want workspace-1", got)
	}
	if got := intField(t, keyframe, "paneID"); got != smokeWorkspacePaneID {
		t.Fatalf("keyframe paneID = %d, want %d", got, smokeWorkspacePaneID)
	}
	if got := intField(t, keyframe, "paneGeneration"); got != 1 {
		t.Fatalf("paneGeneration = %d, want 1", got)
	}
	if got := intField(t, keyframe, "keyframeID"); got != 1 {
		t.Fatalf("keyframeID = %d, want 1", got)
	}
	gridSize := objectField(t, keyframe, "gridSize")
	if got := intField(t, gridSize, "columns"); got != len("smoke-marker")+1 {
		t.Fatalf("keyframe grid columns = %d, want %d", got, len("smoke-marker")+1)
	}
	if got := intField(t, gridSize, "rows"); got != 1 {
		t.Fatalf("keyframe grid rows = %d, want 1", got)
	}

	rows := objectSliceField(t, keyframe, "rows")
	if len(rows) != 1 {
		t.Fatalf("keyframe row count = %d, want 1", len(rows))
	}
	if got := intField(t, rows[0], "index"); got != 0 {
		t.Fatalf("row index = %d, want 0", got)
	}
	if got := stringField(t, rows[0], "text"); got != "smoke-marker " {
		t.Fatalf("row text = %q, want smoke marker plus trailing blank", got)
	}

	cursor := objectField(t, keyframe, "cursor")
	if got := intField(t, cursor, "row"); got != 0 {
		t.Fatalf("cursor row = %d, want 0", got)
	}
	if got := intField(t, cursor, "column"); got != len("smoke-marker") {
		t.Fatalf("cursor column = %d, want %d", got, len("smoke-marker"))
	}
	if got := boolField(t, cursor, "visible"); !got {
		t.Fatal("cursor visible = false, want true")
	}
	if got := stringField(t, cursor, "shape"); got != "block" {
		t.Fatalf("cursor shape = %q, want block", got)
	}
	if got := stringField(t, keyframe, "activeScreen"); got != "primary" {
		t.Fatalf("activeScreen = %q, want primary", got)
	}
	if got := boolField(t, keyframe, "datagramsEnabledAfterKeyframe"); !got {
		t.Fatal("datagramsEnabledAfterKeyframe = false, want true")
	}
}

func TestBuildSmokeWorkspaceMessagesUsesTmuxControlSnapshotModel(t *testing.T) {
	messages, err := buildSmokeWorkspaceMessages("workspace-1", "smoke-marker")
	if err != nil {
		t.Fatal(err)
	}

	lines := marshalSmokeMessagesForTest(t, messages)
	snapshot := decodeWorkspaceMessagePayload(t, lines[0], "workspaceSnapshot")
	if got := intField(t, snapshot, "layoutGeneration"); got != 1 {
		t.Fatalf("snapshot layoutGeneration = %d, want tmuxcc-generated generation 1", got)
	}
	panes := objectSliceField(t, snapshot, "panes")
	if got := intField(t, panes[0], "paneID"); got != smokeWorkspacePaneID {
		t.Fatalf("snapshot paneID = %d, want %d", got, smokeWorkspacePaneID)
	}
	if got := boolField(t, panes[0], "isActive"); !got {
		t.Fatal("snapshot pane isActive = false, want true")
	}
}

func TestBuildSmokeWorkspaceMessagesRejectsEmptyMarker(t *testing.T) {
	if _, err := buildSmokeWorkspaceMessages("workspace-1", ""); err == nil {
		t.Fatal("buildSmokeWorkspaceMessages error = nil, want error")
	}
}

func TestSmokeCaptureLineRejectsDecoratedMarker(t *testing.T) {
	if got, err := smokeCaptureLine("prefix smoke-marker suffix\n", "smoke-marker"); err == nil {
		t.Fatalf("smokeCaptureLine = (%q, nil), want decorated capture rejected", got)
	}
}

func TestMarshalWorkspaceMessageLinesWritesNewlineDelimitedJSON(t *testing.T) {
	messages := []remotegrid.WorkspaceMessage{
		remotegrid.WorkspaceSnapshotMessage(remotegrid.WorkspaceSnapshot{WorkspaceID: "workspace-1"}),
		remotegrid.PaneKeyframeMessage(remotegrid.PaneKeyframe{WorkspaceID: "workspace-1", PaneID: smokeWorkspacePaneID}),
	}

	got, err := marshalWorkspaceMessageLines(messages)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.HasSuffix(got, []byte("\n")) {
		t.Fatalf("marshaled messages = %q, want trailing newline", string(got))
	}

	lines := bytes.Split(bytes.TrimSuffix(got, []byte("\n")), []byte("\n"))
	if len(lines) != 2 {
		t.Fatalf("line count = %d, want 2", len(lines))
	}
	decodeWorkspaceMessagePayload(t, lines[0], "workspaceSnapshot")
	decodeWorkspaceMessagePayload(t, lines[1], "paneKeyframe")
}

func marshalSmokeMessagesForTest(t *testing.T, messages []remotegrid.WorkspaceMessage) [][]byte {
	t.Helper()

	encoded, err := marshalWorkspaceMessageLines(messages)
	if err != nil {
		t.Fatal(err)
	}
	return bytes.Split(bytes.TrimSuffix(encoded, []byte("\n")), []byte("\n"))
}

func decodeWorkspaceMessagePayload(t *testing.T, line []byte, wantCase string) map[string]any {
	t.Helper()

	var message map[string]json.RawMessage
	if err := json.Unmarshal(line, &message); err != nil {
		t.Fatal(err)
	}
	if len(message) != 1 {
		t.Fatalf("message case count = %d, want 1 in %s", len(message), string(line))
	}
	rawEnvelope, ok := message[wantCase]
	if !ok {
		t.Fatalf("message case = %v, want %s", keys(message), wantCase)
	}

	var envelope map[string]json.RawMessage
	if err := json.Unmarshal(rawEnvelope, &envelope); err != nil {
		t.Fatal(err)
	}
	rawPayload, ok := envelope["_0"]
	if !ok {
		t.Fatalf("%s payload missing _0", wantCase)
	}

	var payload map[string]any
	if err := json.Unmarshal(rawPayload, &payload); err != nil {
		t.Fatal(err)
	}
	return payload
}

func objectField(t *testing.T, fields map[string]any, name string) map[string]any {
	t.Helper()

	value, ok := fields[name]
	if !ok {
		t.Fatalf("field %s missing", name)
	}
	object, ok := value.(map[string]any)
	if !ok {
		t.Fatalf("field %s has type %T, want object", name, value)
	}
	return object
}

func objectSliceField(t *testing.T, fields map[string]any, name string) []map[string]any {
	t.Helper()

	value, ok := fields[name]
	if !ok {
		t.Fatalf("field %s missing", name)
	}
	values, ok := value.([]any)
	if !ok {
		t.Fatalf("field %s has type %T, want array", name, value)
	}

	objects := make([]map[string]any, len(values))
	for i, value := range values {
		object, ok := value.(map[string]any)
		if !ok {
			t.Fatalf("field %s[%d] has type %T, want object", name, i, value)
		}
		objects[i] = object
	}
	return objects
}

func stringField(t *testing.T, fields map[string]any, name string) string {
	t.Helper()

	value, ok := fields[name]
	if !ok {
		t.Fatalf("field %s missing", name)
	}
	got, ok := value.(string)
	if !ok {
		t.Fatalf("field %s has type %T, want string", name, value)
	}
	return got
}

func intField(t *testing.T, fields map[string]any, name string) int {
	t.Helper()

	value, ok := fields[name]
	if !ok {
		t.Fatalf("field %s missing", name)
	}
	got, ok := value.(float64)
	if !ok {
		t.Fatalf("field %s has type %T, want number", name, value)
	}
	return int(got)
}

func boolField(t *testing.T, fields map[string]any, name string) bool {
	t.Helper()

	value, ok := fields[name]
	if !ok {
		t.Fatalf("field %s missing", name)
	}
	got, ok := value.(bool)
	if !ok {
		t.Fatalf("field %s has type %T, want bool", name, value)
	}
	return got
}

func keys[K comparable, V any](values map[K]V) []K {
	result := make([]K, 0, len(values))
	for key := range values {
		result = append(result, key)
	}
	return result
}
