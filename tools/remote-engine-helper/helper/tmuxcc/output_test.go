package tmuxcc

import (
	"bytes"
	"testing"
)

func TestParseOutputLineDecodesTmuxControlOctalEscapes(t *testing.T) {
	event, ok, err := ParseOutputLine(`%output %7 hello\012tab\011slash\134done`)
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("ParseOutputLine ok = false, want true")
	}
	if event.PaneID != 7 {
		t.Fatalf("pane id = %d, want 7", event.PaneID)
	}
	want := []byte("hello\ntab\tslash\\done")
	if !bytes.Equal(event.Data, want) {
		t.Fatalf("data = %q, want %q", event.Data, want)
	}
}

func TestParseOutputLineDecodesExtendedOutput(t *testing.T) {
	event, ok, err := ParseOutputLine(`%extended-output %7 125 future ignored : hello\012`)
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("ParseOutputLine ok = false, want true")
	}
	if event.PaneID != 7 {
		t.Fatalf("pane id = %d, want 7", event.PaneID)
	}
	if event.BufferedAgeMillis != 125 {
		t.Fatalf("buffered age = %d, want 125", event.BufferedAgeMillis)
	}
	if want := []byte("hello\n"); !bytes.Equal(event.Data, want) {
		t.Fatalf("data = %q, want %q", event.Data, want)
	}
}

func TestParseOutputLinePreservesInvalidUTF8Bytes(t *testing.T) {
	event, ok, err := ParseOutputLine(`%output %7 \303\050`)
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("ParseOutputLine ok = false, want true")
	}
	want := []byte{0xC3, 0x28}
	if !bytes.Equal(event.Data, want) {
		t.Fatalf("data = %#v, want %#v", event.Data, want)
	}
}

func TestParseOutputLineRejectsMalformedEscapes(t *testing.T) {
	tests := []string{
		`%output %7 bad\12`,
		`%output %7 bad\999`,
		`%output %7 bad\12x`,
	}

	for _, line := range tests {
		t.Run(line, func(t *testing.T) {
			if _, _, err := ParseOutputLine(line); err == nil {
				t.Fatal("ParseOutputLine error = nil, want error")
			}
		})
	}
}

func TestParseOutputLineIgnoresOtherNotifications(t *testing.T) {
	event, ok, err := ParseOutputLine("%window-add @1")
	if err != nil {
		t.Fatal(err)
	}
	if ok {
		t.Fatalf("ParseOutputLine = (%+v, true), want ok false", event)
	}
}
