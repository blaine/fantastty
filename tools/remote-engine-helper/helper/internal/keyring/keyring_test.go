package keyring

import (
	"errors"
	"strings"
	"testing"
	"time"
)

func TestMintKeyConsumesOnce(t *testing.T) {
	now := time.Unix(1700000000, 0).UTC()
	ring := New(func() time.Time { return now })

	issued, err := ring.Mint("session-a", time.Minute)
	if err != nil {
		t.Fatalf("Mint returned error: %v", err)
	}
	if len(issued.Key) != 64 {
		t.Fatalf("key length = %d, want 64", len(issued.Key))
	}
	if strings.Trim(issued.Key, "0123456789abcdef") != "" {
		t.Fatalf("key is not lowercase hex: %q", issued.Key)
	}

	if err := ring.Consume("session-a", issued.Key); err != nil {
		t.Fatalf("first consume returned error: %v", err)
	}
	if err := ring.Consume("session-a", issued.Key); !errors.Is(err, ErrInvalidKey) {
		t.Fatalf("replay error = %v, want ErrInvalidKey", err)
	}
}

func TestConsumeRejectsWrongSessionAndBurnsKey(t *testing.T) {
	now := time.Unix(1700000000, 0).UTC()
	ring := New(func() time.Time { return now })

	issued, err := ring.Mint("session-a", time.Minute)
	if err != nil {
		t.Fatalf("Mint returned error: %v", err)
	}

	if err := ring.Consume("session-b", issued.Key); !errors.Is(err, ErrWrongSession) {
		t.Fatalf("wrong-session consume error = %v, want ErrWrongSession", err)
	}
	if err := ring.Consume("session-a", issued.Key); !errors.Is(err, ErrInvalidKey) {
		t.Fatalf("key survived wrong-session attempt: %v", err)
	}
}

func TestConsumeRejectsExpiredKey(t *testing.T) {
	now := time.Unix(1700000000, 0).UTC()
	ring := New(func() time.Time { return now })

	issued, err := ring.Mint("session-a", time.Second)
	if err != nil {
		t.Fatalf("Mint returned error: %v", err)
	}

	now = now.Add(2 * time.Second)
	if err := ring.Consume("session-a", issued.Key); !errors.Is(err, ErrExpiredKey) {
		t.Fatalf("expired consume error = %v, want ErrExpiredKey", err)
	}
	if err := ring.Consume("session-a", issued.Key); !errors.Is(err, ErrInvalidKey) {
		t.Fatalf("expired key survived consume: %v", err)
	}
}

func TestConsumeAndBurnsKeyWhenProbeFails(t *testing.T) {
	now := time.Unix(1700000000, 0).UTC()
	ring := New(func() time.Time { return now })
	probeErr := errors.New("probe failed")

	issued, err := ring.Mint("session-a", time.Minute)
	if err != nil {
		t.Fatalf("Mint returned error: %v", err)
	}

	if err := ring.ConsumeAnd("session-a", issued.Key, func() error { return probeErr }); !errors.Is(err, probeErr) {
		t.Fatalf("ConsumeAnd error = %v, want probe error", err)
	}
	if err := ring.Consume("session-a", issued.Key); !errors.Is(err, ErrInvalidKey) {
		t.Fatalf("key survived failed probe: %v", err)
	}
}
