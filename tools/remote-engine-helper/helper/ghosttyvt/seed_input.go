package ghosttyvt

import (
	"fmt"
	"strings"

	"fantastty/remote-engine-helper/remotegrid"
)

func seedPaneTerminalInput(pane remotegrid.WorkspacePane, size remotegrid.GridSize) []byte {
	if pane.InitialCapture.ActiveScreen != remotegrid.ActiveScreenAlternate {
		return initialRowsTerminalInput(pane.InitialRows, size)
	}

	var builder strings.Builder
	builder.Write(initialRowsTerminalInput(pane.InitialCapture.PrimaryRows, size))
	builder.WriteString("\x1b[?1049h")
	alternateRows := pane.InitialCapture.AlternateRows
	if alternateRows == nil {
		alternateRows = pane.InitialRows
	}
	builder.Write(initialRowsTerminalInput(alternateRows, size))
	return []byte(builder.String())
}

func initialRowsTerminalInput(rows []string, size remotegrid.GridSize) []byte {
	var builder strings.Builder
	limit := len(rows)
	if limit > size.Rows {
		limit = size.Rows
	}
	for rowIndex := 0; rowIndex < limit; rowIndex++ {
		fmt.Fprintf(&builder, "\x1b[%d;1H%s", rowIndex+1, rows[rowIndex])
	}
	if builder.Len() == 0 {
		return nil
	}
	builder.WriteString("\x1b[H")
	return []byte(builder.String())
}
