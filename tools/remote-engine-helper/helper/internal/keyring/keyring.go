package keyring

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"sync"
	"time"
)

var (
	ErrInvalidKey   = errors.New("invalid one-time key")
	ErrWrongSession = errors.New("one-time key belongs to a different session")
	ErrExpiredKey   = errors.New("one-time key expired")
)

type Entry struct {
	Key       string    `json:"key"`
	Session   string    `json:"session"`
	ExpiresAt time.Time `json:"expires_at"`
}

type IssuedKey struct {
	Key       string
	ExpiresAt time.Time
}

type Keyring struct {
	mu      sync.Mutex
	now     func() time.Time
	entries map[string]Entry
}

func New(now func() time.Time) *Keyring {
	if now == nil {
		now = time.Now
	}
	return &Keyring{
		now:     now,
		entries: make(map[string]Entry),
	}
}

func FromEntries(now func() time.Time, entries []Entry) *Keyring {
	ring := New(now)
	for _, entry := range entries {
		ring.entries[entry.Key] = entry
	}
	return ring
}

func (k *Keyring) Mint(session string, ttl time.Duration) (IssuedKey, error) {
	k.mu.Lock()
	defer k.mu.Unlock()

	key, err := randomHex(32)
	if err != nil {
		return IssuedKey{}, err
	}
	issued := IssuedKey{
		Key:       key,
		ExpiresAt: k.now().Add(ttl).UTC(),
	}
	k.entries[key] = Entry{
		Key:       key,
		Session:   session,
		ExpiresAt: issued.ExpiresAt,
	}
	return issued, nil
}

func (k *Keyring) Consume(session, key string) error {
	return k.ConsumeAnd(session, key, nil)
}

func (k *Keyring) ConsumeAnd(session, key string, afterAuth func() error) error {
	k.mu.Lock()
	entry, ok := k.entries[key]
	if !ok {
		k.mu.Unlock()
		return ErrInvalidKey
	}
	delete(k.entries, key)
	now := k.now()
	k.mu.Unlock()

	if !now.Before(entry.ExpiresAt) {
		return ErrExpiredKey
	}
	if entry.Session != session {
		return ErrWrongSession
	}
	if afterAuth != nil {
		return afterAuth()
	}
	return nil
}

func (k *Keyring) Snapshot() []Entry {
	k.mu.Lock()
	defer k.mu.Unlock()

	entries := make([]Entry, 0, len(k.entries))
	now := k.now()
	for key, entry := range k.entries {
		if !now.Before(entry.ExpiresAt) {
			delete(k.entries, key)
			continue
		}
		entries = append(entries, entry)
	}
	return entries
}

func randomHex(byteCount int) (string, error) {
	buf := make([]byte, byteCount)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf), nil
}
