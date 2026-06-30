package ghosttyvt

import (
	"bytes"
	"testing"

	"fantastty/remote-engine-helper/remotegrid"
)

func TestSeedPaneTerminalInputPreservesPrimaryRowsBeforeAlternateRows(t *testing.T) {
	pane := remotegrid.WorkspacePane{
		InitialRows: []string{"visible-tui"},
		InitialCapture: remotegrid.PaneInitialCapture{
			PrimaryRows:   []string{"shell-prompt"},
			AlternateRows: []string{"visible-tui"},
			ActiveScreen:  remotegrid.ActiveScreenAlternate,
		},
	}
	size := remotegrid.GridSize{Columns: 16, Rows: 2}

	input := seedPaneTerminalInput(pane, size)

	primary := initialRowsTerminalInput([]string{"shell-prompt"}, size)
	alternate := initialRowsTerminalInput([]string{"visible-tui"}, size)
	switchToAlternate := []byte("\x1b[?1049h")
	if !bytes.Contains(input, primary) {
		t.Fatalf("seed input %q does not contain primary rows %q", input, primary)
	}
	if !bytes.Contains(input, alternate) {
		t.Fatalf("seed input %q does not contain alternate rows %q", input, alternate)
	}
	if bytes.Index(input, primary) > bytes.Index(input, switchToAlternate) {
		t.Fatalf("primary rows are seeded after alternate-screen switch in %q", input)
	}
	if bytes.Index(input, switchToAlternate) > bytes.Index(input, alternate) {
		t.Fatalf("alternate rows are seeded before alternate-screen switch in %q", input)
	}
}
