package tmuxcc

import (
	"bufio"
	"fmt"
	"io"
	"strings"
)

func ReadActions(reader io.Reader, model *Model) ([]Action, error) {
	var actions []Action
	err := ScanActions(reader, model, func(action Action) error {
		actions = append(actions, action)
		return nil
	})
	return actions, err
}

func ReadBufferedActions(reader io.Reader, model *Model, buffer *PaneOutputBuffer) ([]Action, error) {
	var actions []Action
	err := ScanBufferedActions(reader, model, buffer, func(action Action) error {
		actions = append(actions, action)
		return nil
	})
	return actions, err
}

func ScanActions(reader io.Reader, model *Model, handle func(Action) error) error {
	return scanActions(reader, model, nil, handle)
}

func ScanBufferedActions(reader io.Reader, model *Model, buffer *PaneOutputBuffer, handle func(Action) error) error {
	if buffer == nil {
		buffer = NewPaneOutputBuffer()
	}
	return scanActions(reader, model, buffer, handle)
}

func scanActions(reader io.Reader, model *Model, buffer *PaneOutputBuffer, handle func(Action) error) error {
	buffered := bufio.NewReader(reader)
	lineNumber := 0

	for {
		line, err := buffered.ReadString('\n')
		if err != nil {
			if err == io.EOF {
				if line == "" {
					return nil
				}
			} else {
				return fmt.Errorf("tmuxcc: read line %d: %w", lineNumber+1, err)
			}
		}

		lineNumber++
		line = strings.TrimSuffix(line, "\n")

		next, applyErr := model.ApplyLine(line)
		if applyErr != nil {
			return fmt.Errorf("tmuxcc: line %d: %w", lineNumber, applyErr)
		}
		if buffer != nil {
			next = buffer.Filter(next)
		}
		for _, action := range next {
			if handleErr := handle(action); handleErr != nil {
				return fmt.Errorf("tmuxcc: line %d: %w", lineNumber, handleErr)
			}
		}

		if err == io.EOF {
			return nil
		}
	}
}
