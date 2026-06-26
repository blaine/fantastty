//go:build linux && cgo && ghostty_vt

package ghosttyvt

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	"fantastty/remote-engine-helper/remotegrid"
)

func TestRendererSeedsPaneAndAppliesOutput(t *testing.T) {
	renderer, err := NewRenderer("workspace-1")
	if err != nil {
		t.Fatal(err)
	}
	defer renderer.Close()

	keyframe, ok, err := renderer.SeedPane(remotegrid.WorkspacePane{
		PaneID: 7,
		Frame:  remotegrid.PaneFrame{Columns: 8, Rows: 3},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("SeedPane returned ok=false")
	}
	if keyframe.GridSize != (remotegrid.GridSize{Columns: 8, Rows: 3}) {
		t.Fatalf("keyframe grid size = %+v, want 8x3", keyframe.GridSize)
	}
	if got := keyframeText(keyframe); strings.Contains(got, "fish") {
		t.Fatalf("blank keyframe unexpectedly contains output text: %q", got)
	}

	update, err := renderer.ApplyOutput(7, []byte("fish\r\n"))
	if err != nil {
		t.Fatal(err)
	}
	if update.Delta == nil {
		t.Fatal("ApplyOutput delta = nil")
	}
	if got := deltaText(*update.Delta); !strings.Contains(got, "fish") {
		t.Fatalf("delta text = %q, want fish", got)
	}
}

func TestRendererSeedsPaneWithCapturedCursor(t *testing.T) {
	renderer, err := NewRenderer("workspace-1")
	if err != nil {
		t.Fatal(err)
	}
	defer renderer.Close()

	cursor := remotegrid.CursorState{Row: 1, Column: 5, Visible: true, Shape: remotegrid.CursorShapeBlock}
	keyframe, ok, err := renderer.SeedPane(remotegrid.WorkspacePane{
		PaneID:      7,
		Frame:       remotegrid.PaneFrame{Columns: 8, Rows: 2},
		InitialRows: []string{"prompt"},
		InitialCapture: remotegrid.PaneInitialCapture{
			Cursor: &cursor,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("SeedPane returned ok=false")
	}
	if keyframe.Cursor.Row != 1 || keyframe.Cursor.Column != 5 {
		t.Fatalf("seeded keyframe cursor = %+v, want row 1 column 5", keyframe.Cursor)
	}
}

func TestRendererPreservesCapturedHiddenCursorAfterOutput(t *testing.T) {
	renderer, err := NewRenderer("workspace-1")
	if err != nil {
		t.Fatal(err)
	}
	defer renderer.Close()

	cursor := remotegrid.CursorState{Row: 0, Column: 1, Visible: false, Shape: remotegrid.CursorShapeBlock}
	keyframe, ok, err := renderer.SeedPane(remotegrid.WorkspacePane{
		PaneID:      7,
		Frame:       remotegrid.PaneFrame{Columns: 8, Rows: 2},
		InitialRows: []string{"prompt"},
		InitialCapture: remotegrid.PaneInitialCapture{
			Cursor: &cursor,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("SeedPane returned ok=false")
	}
	if keyframe.Cursor.Visible {
		t.Fatalf("seeded keyframe cursor visible = true, want false")
	}

	if _, err := renderer.ApplyOutput(7, []byte("x")); err != nil {
		t.Fatal(err)
	}
	current, ok, err := renderer.CurrentKeyframe(7)
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("CurrentKeyframe returned ok=false")
	}
	if current.Cursor.Visible {
		t.Fatalf("current cursor visible = true, want false")
	}
	if current.Cursor.Row != 0 || current.Cursor.Column != 2 {
		t.Fatalf("current cursor = %+v, want row 0 column 2 after output", current.Cursor)
	}
}

func TestRendererSeedsPaneAsAlternateScreenFromInitialCapture(t *testing.T) {
	renderer, err := NewRenderer("workspace-1")
	if err != nil {
		t.Fatal(err)
	}
	defer renderer.Close()

	keyframe, ok, err := renderer.SeedPane(remotegrid.WorkspacePane{
		PaneID:      7,
		Frame:       remotegrid.PaneFrame{Columns: 12, Rows: 2},
		InitialRows: []string{"visible-tui"},
		InitialCapture: remotegrid.PaneInitialCapture{
			ActiveScreen:  remotegrid.ActiveScreenAlternate,
			PrimaryRows:   []string{"stale-shell"},
			AlternateRows: []string{"visible-tui"},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("SeedPane returned ok=false")
	}
	if keyframe.ActiveScreen != remotegrid.ActiveScreenAlternate {
		t.Fatalf("seeded active screen = %q, want alternate", keyframe.ActiveScreen)
	}
	if got := keyframeText(keyframe); !strings.Contains(got, "visible-tui") || strings.Contains(got, "stale-shell") {
		t.Fatalf("keyframe text = %q, want alternate screen content", got)
	}
}

func TestRendererSeedsCapturedScrollRegionBeforeOutput(t *testing.T) {
	renderer, err := NewRenderer("workspace-1")
	if err != nil {
		t.Fatal(err)
	}
	defer renderer.Close()

	scrollRegion := remotegrid.ScrollRegion{Upper: 1, Lower: 2}
	cursor := remotegrid.CursorState{Row: 2, Column: 0, Visible: true, Shape: remotegrid.CursorShapeBlock}
	_, ok, err := renderer.SeedPane(remotegrid.WorkspacePane{
		PaneID:      7,
		Frame:       remotegrid.PaneFrame{Columns: 10, Rows: 4},
		InitialRows: []string{"top", "middle-a", "middle-b", "bottom"},
		InitialCapture: remotegrid.PaneInitialCapture{
			ScrollRegion: &scrollRegion,
			Cursor:       &cursor,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("SeedPane returned ok=false")
	}

	if _, err := renderer.ApplyOutput(7, []byte("\n")); err != nil {
		t.Fatal(err)
	}
	current, ok, err := renderer.CurrentKeyframe(7)
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("CurrentKeyframe returned ok=false")
	}
	wantRows := []string{"top", "middle-b", "", "bottom"}
	for index, want := range wantRows {
		if got := trimmedKeyframeRowText(current, index); got != want {
			t.Fatalf("row %d text = %q, want %q", index, got, want)
		}
	}
}

func TestRendererSeedsRowsBeforeCapturedScrollRegion(t *testing.T) {
	renderer, err := NewRenderer("workspace-1")
	if err != nil {
		t.Fatal(err)
	}
	defer renderer.Close()

	scrollRegion := remotegrid.ScrollRegion{Upper: 1, Lower: 2}
	keyframe, ok, err := renderer.SeedPane(remotegrid.WorkspacePane{
		PaneID:      7,
		Frame:       remotegrid.PaneFrame{Columns: 8, Rows: 4},
		InitialRows: []string{"top", "region-a", "wrapwrapwrap", "bottom"},
		InitialCapture: remotegrid.PaneInitialCapture{
			ScrollRegion: &scrollRegion,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("SeedPane returned ok=false")
	}
	if got := trimmedKeyframeRowText(keyframe, 0); got != "top" {
		t.Fatalf("top row = %q, want top", got)
	}
	if got := trimmedKeyframeRowText(keyframe, 3); got != "bottom" {
		t.Fatalf("bottom row = %q, want bottom", got)
	}
}

func TestRendererPublishesKeyframeForAlternateScreenSwitch(t *testing.T) {
	renderer, err := NewRenderer("workspace-1")
	if err != nil {
		t.Fatal(err)
	}
	defer renderer.Close()

	keyframe, ok, err := renderer.SeedPane(remotegrid.WorkspacePane{
		PaneID: 7,
		Frame:  remotegrid.PaneFrame{Columns: 8, Rows: 3},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("SeedPane returned ok=false")
	}
	if keyframe.ActiveScreen != remotegrid.ActiveScreenPrimary {
		t.Fatalf("seed active screen = %q, want primary", keyframe.ActiveScreen)
	}

	update, err := renderer.ApplyOutput(7, []byte("\x1b[?1049hfish\r\n"))
	if err != nil {
		t.Fatal(err)
	}
	if update.Keyframe == nil {
		t.Fatal("ApplyOutput keyframe = nil, want fresh keyframe after active screen switch")
	}
	if update.Keyframe.ActiveScreen != remotegrid.ActiveScreenAlternate {
		t.Fatalf("active screen = %q, want alternate", update.Keyframe.ActiveScreen)
	}
	if update.Keyframe.PaneGeneration <= keyframe.PaneGeneration {
		t.Fatalf("pane generation = %d, want greater than seed generation %d", update.Keyframe.PaneGeneration, keyframe.PaneGeneration)
	}
	if got := keyframeText(*update.Keyframe); !strings.Contains(got, "fish") {
		t.Fatalf("keyframe text = %q, want fish", got)
	}
}

func TestRendererPreservesUnderlineColor(t *testing.T) {
	renderer, err := NewRenderer("workspace-1")
	if err != nil {
		t.Fatal(err)
	}
	defer renderer.Close()

	_, ok, err := renderer.SeedPane(remotegrid.WorkspacePane{
		PaneID: 7,
		Frame:  remotegrid.PaneFrame{Columns: 8, Rows: 3},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("SeedPane returned ok=false")
	}

	update, err := renderer.ApplyOutput(7, []byte("\x1b[4m\x1b[58:2::12:34:56mu\x1b[0m"))
	if err != nil {
		t.Fatal(err)
	}
	if update.Delta == nil {
		t.Fatal("ApplyOutput delta = nil")
	}

	cell, ok := deltaCell(*update.Delta, "u")
	if !ok {
		t.Fatalf("delta does not contain styled cell: %q", deltaText(*update.Delta))
	}
	if cell.Style.Underline != remotegrid.UnderlineStyleSingle {
		t.Fatalf("underline style = %q, want single", cell.Style.Underline)
	}
	assertJSONValueEqual(t, cell.Style.UnderlineColor, `{"rgb":{"red":12,"green":34,"blue":56}}`)
}

func TestRendererPreservesIndexedForegroundAndBackground(t *testing.T) {
	renderer, err := NewRenderer("workspace-1")
	if err != nil {
		t.Fatal(err)
	}
	defer renderer.Close()

	_, ok, err := renderer.SeedPane(remotegrid.WorkspacePane{
		PaneID: 7,
		Frame:  remotegrid.PaneFrame{Columns: 8, Rows: 3},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("SeedPane returned ok=false")
	}

	update, err := renderer.ApplyOutput(7, []byte("\x1b[31;44mc\x1b[0m"))
	if err != nil {
		t.Fatal(err)
	}
	if update.Delta == nil {
		t.Fatal("ApplyOutput delta = nil")
	}

	cell, ok := deltaCell(*update.Delta, "c")
	if !ok {
		t.Fatalf("delta does not contain styled cell: %q", deltaText(*update.Delta))
	}
	assertJSONValueEqual(t, cell.Style.Foreground, `{"indexed":{"_0":1}}`)
	assertJSONValueEqual(t, cell.Style.Background, `{"indexed":{"_0":4}}`)
}

func keyframeText(keyframe remotegrid.PaneKeyframe) string {
	var builder strings.Builder
	for _, row := range keyframe.Rows {
		for _, cell := range row.Cells {
			builder.WriteString(cell.Text)
		}
	}
	return builder.String()
}

func trimmedKeyframeRowText(keyframe remotegrid.PaneKeyframe, index int) string {
	for _, row := range keyframe.Rows {
		if row.Index != index {
			continue
		}
		var builder strings.Builder
		for _, cell := range row.Cells {
			builder.WriteString(cell.Text)
		}
		return strings.TrimRight(builder.String(), " ")
	}
	return ""
}

type decodedDeltaCell struct {
	Text  string `json:"text"`
	Style struct {
		Foreground     json.RawMessage           `json:"foreground"`
		Background     json.RawMessage           `json:"background"`
		Underline      remotegrid.UnderlineStyle `json:"underline"`
		UnderlineColor json.RawMessage           `json:"underlineColor"`
	} `json:"style"`
}

func deltaCell(delta remotegrid.PaneDelta, text string) (decodedDeltaCell, bool) {
	data, err := json.Marshal(delta)
	if err != nil {
		return decodedDeltaCell{}, false
	}

	var payload struct {
		RowUpdates []struct {
			Update struct {
				FullRow struct {
					Cells []decodedDeltaCell `json:"_0"`
				} `json:"fullRow"`
			} `json:"update"`
		} `json:"rowUpdates"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return decodedDeltaCell{}, false
	}

	for _, update := range payload.RowUpdates {
		for _, cell := range update.Update.FullRow.Cells {
			if cell.Text == text {
				return cell, true
			}
		}
	}
	return decodedDeltaCell{}, false
}

func assertJSONValueEqual(t *testing.T, got json.RawMessage, want string) {
	t.Helper()

	var gotValue any
	if err := json.Unmarshal(got, &gotValue); err != nil {
		t.Fatalf("got JSON %s: %v", string(got), err)
	}
	var wantValue any
	if err := json.Unmarshal([]byte(want), &wantValue); err != nil {
		t.Fatalf("want JSON %s: %v", want, err)
	}
	if !reflect.DeepEqual(gotValue, wantValue) {
		t.Fatalf("JSON value = %s, want %s", string(got), want)
	}
}

func deltaText(delta remotegrid.PaneDelta) string {
	data, err := json.Marshal(delta)
	if err != nil {
		return ""
	}

	var payload struct {
		RowUpdates []struct {
			Update struct {
				FullRow struct {
					Cells []struct {
						Text string `json:"text"`
					} `json:"_0"`
				} `json:"fullRow"`
			} `json:"update"`
		} `json:"rowUpdates"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return ""
	}

	var builder strings.Builder
	for _, update := range payload.RowUpdates {
		for _, cell := range update.Update.FullRow.Cells {
			builder.WriteString(cell.Text)
		}
	}
	return builder.String()
}
