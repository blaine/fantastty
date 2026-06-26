package tmuxcc

import (
	"fmt"
	"strconv"
	"strings"
)

type OutputEvent struct {
	PaneID            int
	Data              []byte
	BufferedAgeMillis int
}

func ParseOutputLine(line string) (OutputEvent, bool, error) {
	const prefix = "%output "
	if strings.HasPrefix(line, prefix) {
		return parseOutputPayload(strings.TrimPrefix(line, prefix), " ")
	}

	const extendedPrefix = "%extended-output "
	if strings.HasPrefix(line, extendedPrefix) {
		return parseOutputPayload(strings.TrimPrefix(line, extendedPrefix), " : ")
	}
	return OutputEvent{}, false, nil
}

func parseOutputPayload(remainder string, payloadSeparator string) (OutputEvent, bool, error) {
	paneText, payload, ok := strings.Cut(remainder, payloadSeparator)
	if !ok {
		return OutputEvent{}, true, fmt.Errorf("tmuxcc: %%output missing payload")
	}
	bufferedAgeMillis := 0
	if payloadSeparator != " " {
		fields := strings.Fields(paneText)
		if len(fields) < 2 {
			return OutputEvent{}, true, fmt.Errorf("tmuxcc: %%extended-output missing fields")
		}
		paneText = fields[0]
		age, err := strconv.Atoi(fields[1])
		if err != nil {
			return OutputEvent{}, true, fmt.Errorf("tmuxcc: invalid %%extended-output buffered age %q: %w", fields[1], err)
		}
		bufferedAgeMillis = age
	}
	paneID, err := parseTmuxID(paneText, '%')
	if err != nil {
		return OutputEvent{}, true, err
	}
	data, err := decodeControlOutput(payload)
	if err != nil {
		return OutputEvent{}, true, err
	}
	return OutputEvent{PaneID: paneID, Data: data, BufferedAgeMillis: bufferedAgeMillis}, true, nil
}

func decodeControlOutput(payload string) ([]byte, error) {
	output := make([]byte, 0, len(payload))
	for index := 0; index < len(payload); index++ {
		if payload[index] != '\\' {
			output = append(output, payload[index])
			continue
		}
		if index+3 >= len(payload) {
			return nil, fmt.Errorf("tmuxcc: truncated octal escape in %%output")
		}
		escape := payload[index+1 : index+4]
		value, err := strconv.ParseUint(escape, 8, 8)
		if err != nil {
			return nil, fmt.Errorf("tmuxcc: invalid octal escape \\%s: %w", escape, err)
		}
		output = append(output, byte(value))
		index += 3
	}
	return output, nil
}
