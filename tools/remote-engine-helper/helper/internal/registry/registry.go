package registry

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"fantastty/remote-engine-helper/internal/keyring"
	"golang.org/x/sys/unix"
)

var (
	ErrUnsafePath                = errors.New("unsafe registry path")
	ErrLivePID                   = errors.New("recorded helper pid is still live")
	ErrPeerUIDMismatch           = errors.New("peer uid mismatch")
	ErrPeerCredentialUnavailable = errors.New("peer credentials unavailable")
	ErrSessionNotFound           = errors.New("session not found")
)

type Options struct {
	UID          int
	Now          func() time.Time
	ProcessAlive func(pid int) bool
	Terminate    func(pid int) error
}

type Store struct {
	root         string
	uid          int
	now          func() time.Time
	processAlive func(pid int) bool
	terminate    func(pid int) error
	mu           sync.Mutex
}

type Lock struct {
	store *Store
	file  *os.File
}

type State struct {
	Sessions map[string]SessionRecord `json:"sessions"`
}

type SessionRecord struct {
	Workspace      string          `json:"workspace"`
	TmuxSession    string          `json:"tmux_session,omitempty"`
	Session        string          `json:"session"`
	PID            int             `json:"pid"`
	Port           int             `json:"port"`
	SocketPath     string          `json:"socket_path"`
	HelperVersion  string          `json:"helper_version,omitempty"`
	HelperArch     string          `json:"helper_arch,omitempty"`
	TmuxSmoke      bool            `json:"tmux_smoke"`
	QUICAddr       string          `json:"quic_addr"`
	QUICCertSHA256 string          `json:"quic_cert_sha256"`
	Expires        time.Time       `json:"expires"`
	ActiveClients  int             `json:"active_clients,omitempty"`
	Keys           []keyring.Entry `json:"keys,omitempty"`
}

type Manager struct {
	store         *Store
	helperVersion string
	helperArch    string
}

type StartRequest struct {
	Workspace   string
	TmuxSession string
	Session     string
	Expires     time.Time
}

type StartResult struct {
	PID            int
	Port           int
	SocketPath     string
	HelperVersion  string
	HelperArch     string
	TmuxSmoke      bool
	QUICAddr       string
	QUICCertSHA256 string
}

type LaunchResult struct {
	Workspace      string
	TmuxSession    string
	Session        string
	Key            string
	KeyExpires     time.Time
	Expires        time.Time
	PID            int
	Port           int
	SocketPath     string
	HelperVersion  string
	HelperArch     string
	TmuxSmoke      bool
	QUICAddr       string
	QUICCertSHA256 string
}

type PeerCredential struct {
	UID       uint32
	Available bool
}

func RuntimeDir(env map[string]string, uid int) string {
	if override := env["FANTASTTY_REMOTE_RUNTIME_DIR"]; override != "" {
		return override
	}
	if xdg := env["XDG_RUNTIME_DIR"]; xdg != "" {
		return filepath.Join(xdg, "fantastty-remote-engine")
	}
	return fmt.Sprintf("/tmp/fantastty-remote-engine-%d", uid)
}

func DefaultRuntimeDir() string {
	env := map[string]string{
		"FANTASTTY_REMOTE_RUNTIME_DIR": os.Getenv("FANTASTTY_REMOTE_RUNTIME_DIR"),
		"XDG_RUNTIME_DIR":              os.Getenv("XDG_RUNTIME_DIR"),
	}
	return RuntimeDir(env, os.Geteuid())
}

func EnsureRuntimeDir(root string, uid int) error {
	info, err := os.Lstat(root)
	if errors.Is(err, os.ErrNotExist) {
		if err := os.MkdirAll(root, 0o700); err != nil {
			return err
		}
		if err := os.Chmod(root, 0o700); err != nil {
			return err
		}
		info, err = os.Lstat(root)
	}
	if err != nil {
		return err
	}
	return validateDirectoryInfo(info, uid)
}

func NewStore(root string, opts Options) (*Store, error) {
	uid := opts.UID
	if uid == 0 {
		uid = os.Geteuid()
	}
	if err := EnsureRuntimeDir(root, uid); err != nil {
		return nil, err
	}
	now := opts.Now
	if now == nil {
		now = time.Now
	}
	processAlive := opts.ProcessAlive
	if processAlive == nil {
		processAlive = defaultProcessAlive
	}
	terminate := opts.Terminate
	if terminate == nil {
		terminate = defaultTerminate
	}
	return &Store{
		root:         root,
		uid:          uid,
		now:          now,
		processAlive: processAlive,
		terminate:    terminate,
	}, nil
}

func (s *Store) Root() string {
	return s.root
}

func (s *Store) RegistryPath() string {
	return filepath.Join(s.root, "registry.json")
}

func (s *Store) LockPath() string {
	return filepath.Join(s.root, "registry.lock")
}

func (s *Store) Lock() (*Lock, error) {
	s.mu.Lock()
	if err := validateFilePath(s.LockPath(), s.uid); err != nil {
		s.mu.Unlock()
		return nil, err
	}
	file, err := os.OpenFile(s.LockPath(), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		s.mu.Unlock()
		return nil, err
	}
	if err := os.Chmod(s.LockPath(), 0o600); err != nil {
		file.Close()
		s.mu.Unlock()
		return nil, err
	}
	if err := unix.Flock(int(file.Fd()), unix.LOCK_EX); err != nil {
		file.Close()
		s.mu.Unlock()
		return nil, err
	}
	return &Lock{store: s, file: file}, nil
}

func (l *Lock) Unlock() error {
	err := unix.Flock(int(l.file.Fd()), unix.LOCK_UN)
	closeErr := l.file.Close()
	l.store.mu.Unlock()
	if err != nil {
		return err
	}
	return closeErr
}

func (s *Store) ValidateSocketPath(path string) error {
	if filepath.Dir(path) != s.root {
		return ErrUnsafePath
	}
	return validateFilePath(path, s.uid)
}

func (s *Store) Load() (State, error) {
	state := State{Sessions: map[string]SessionRecord{}}
	if err := validateFilePath(s.RegistryPath(), s.uid); err != nil {
		return state, err
	}
	data, err := os.ReadFile(s.RegistryPath())
	if errors.Is(err, os.ErrNotExist) {
		return state, nil
	}
	if err != nil {
		return state, err
	}
	if len(data) == 0 {
		return state, nil
	}
	if err := json.Unmarshal(data, &state); err != nil {
		return state, err
	}
	if state.Sessions == nil {
		state.Sessions = map[string]SessionRecord{}
	}
	return state, nil
}

func (s *Store) Save(state State) error {
	if state.Sessions == nil {
		state.Sessions = map[string]SessionRecord{}
	}
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	return atomicWriteFile(s.RegistryPath(), data, 0o600)
}

func NewManager(store *Store) *Manager {
	return &Manager{store: store}
}

func NewManagerWithHelperIdentity(store *Store, helperVersion, helperArch string) *Manager {
	return &Manager{store: store, helperVersion: helperVersion, helperArch: helperArch}
}

func (m *Manager) LaunchOrResume(workspace string, ttl, keyTTL time.Duration, starter func(StartRequest) (StartResult, error)) (LaunchResult, error) {
	return m.LaunchOrResumeTmuxSession(workspace, "", ttl, keyTTL, starter)
}

func (m *Manager) LaunchOrResumeTmuxSession(workspace, tmuxSession string, ttl, keyTTL time.Duration, starter func(StartRequest) (StartResult, error)) (LaunchResult, error) {
	lock, err := m.store.Lock()
	if err != nil {
		return LaunchResult{}, err
	}
	defer lock.Unlock()

	state, err := m.store.Load()
	if err != nil {
		return LaunchResult{}, err
	}
	now := m.store.now().UTC()
	for session, record := range state.Sessions {
		if record.Workspace != workspace {
			continue
		}
		if record.TmuxSession != tmuxSession {
			if record.PID > 0 && m.store.processAlive(record.PID) {
				_ = m.store.terminate(record.PID)
			}
			_ = removeSocketPlaceholder(record.SocketPath)
			delete(state.Sessions, session)
			continue
		}
		if (record.ActiveClients > 0 || now.Before(record.Expires)) && m.store.processAlive(record.PID) {
			if m.helperIdentityMatches(record) {
				return m.mintForRecord(state, record, keyTTL)
			}
			_ = m.store.terminate(record.PID)
			_ = removeSocketPlaceholder(record.SocketPath)
			delete(state.Sessions, session)
			continue
		}
		if record.PID > 0 && m.store.processAlive(record.PID) {
			_ = m.store.terminate(record.PID)
		}
		_ = removeSocketPlaceholder(record.SocketPath)
		delete(state.Sessions, session)
	}

	session, err := randomHex(32)
	if err != nil {
		return LaunchResult{}, err
	}
	expires := now.Add(ttl).UTC()
	start, err := starter(StartRequest{Workspace: workspace, TmuxSession: tmuxSession, Session: session, Expires: expires})
	if err != nil {
		return LaunchResult{}, err
	}
	record := SessionRecord{
		Workspace:      workspace,
		TmuxSession:    tmuxSession,
		Session:        session,
		PID:            start.PID,
		Port:           start.Port,
		SocketPath:     start.SocketPath,
		HelperVersion:  firstNonEmpty(start.HelperVersion, m.helperVersion),
		HelperArch:     firstNonEmpty(start.HelperArch, m.helperArch),
		TmuxSmoke:      start.TmuxSmoke,
		QUICAddr:       start.QUICAddr,
		QUICCertSHA256: start.QUICCertSHA256,
		Expires:        expires,
	}
	state.Sessions[session] = record
	return m.mintForRecord(state, record, keyTTL)
}

func (m *Manager) RecordSession(record SessionRecord) error {
	lock, err := m.store.Lock()
	if err != nil {
		return err
	}
	defer lock.Unlock()

	state, err := m.store.Load()
	if err != nil {
		return err
	}
	state.Sessions[record.Session] = record
	return m.store.Save(state)
}

func (m *Manager) ClientAttached(session string) error {
	lock, err := m.store.Lock()
	if err != nil {
		return err
	}
	defer lock.Unlock()

	state, err := m.store.Load()
	if err != nil {
		return err
	}
	record, ok := state.Sessions[session]
	if !ok {
		return ErrSessionNotFound
	}
	record.ActiveClients++
	state.Sessions[session] = record
	return m.store.Save(state)
}

func (m *Manager) ClientDetached(session string, idleTTL time.Duration) error {
	if idleTTL <= 0 {
		return errors.New("idle ttl must be positive")
	}

	lock, err := m.store.Lock()
	if err != nil {
		return err
	}
	defer lock.Unlock()

	state, err := m.store.Load()
	if err != nil {
		return err
	}
	record, ok := state.Sessions[session]
	if !ok {
		return nil
	}
	if record.ActiveClients == 0 {
		return nil
	}
	record.ActiveClients--
	if record.ActiveClients == 0 {
		record.Expires = m.store.now().Add(idleTTL).UTC()
	}
	state.Sessions[session] = record
	return m.store.Save(state)
}

func (m *Manager) RemoveSession(session string, pid int) error {
	lock, err := m.store.Lock()
	if err != nil {
		return err
	}
	defer lock.Unlock()

	state, err := m.store.Load()
	if err != nil {
		return err
	}
	record, ok := state.Sessions[session]
	if !ok {
		return nil
	}
	if pid != 0 && record.PID != pid {
		return nil
	}
	_ = removeSocketPlaceholder(record.SocketPath)
	delete(state.Sessions, session)
	return m.store.Save(state)
}

func (m *Manager) FindSession(session string) (SessionRecord, error) {
	lock, err := m.store.Lock()
	if err != nil {
		return SessionRecord{}, err
	}
	defer lock.Unlock()

	state, err := m.store.Load()
	if err != nil {
		return SessionRecord{}, err
	}
	record, ok := state.Sessions[session]
	if !ok {
		return SessionRecord{}, ErrSessionNotFound
	}
	return record, nil
}

func (m *Manager) ListSessions() ([]SessionRecord, error) {
	lock, err := m.store.Lock()
	if err != nil {
		return nil, err
	}
	defer lock.Unlock()

	state, err := m.store.Load()
	if err != nil {
		return nil, err
	}
	records := make([]SessionRecord, 0, len(state.Sessions))
	for _, record := range state.Sessions {
		records = append(records, record)
	}
	return records, nil
}

func (m *Manager) FindKeyOwner(oneTimeKey string) (SessionRecord, error) {
	lock, err := m.store.Lock()
	if err != nil {
		return SessionRecord{}, err
	}
	defer lock.Unlock()

	state, err := m.store.Load()
	if err != nil {
		return SessionRecord{}, err
	}
	now := m.store.now()
	for candidateSession, candidate := range state.Sessions {
		for _, entry := range candidate.Keys {
			if entry.Key == oneTimeKey {
				if !now.Before(entry.ExpiresAt) {
					ring := keyring.FromEntries(m.store.now, candidate.Keys)
					err := ring.Consume(candidate.Session, oneTimeKey)
					candidate.Keys = ring.Snapshot()
					state.Sessions[candidateSession] = candidate
					if saveErr := m.store.Save(state); saveErr != nil {
						return SessionRecord{}, saveErr
					}
					return SessionRecord{}, err
				}
				return candidate, nil
			}
		}
	}
	return SessionRecord{}, keyring.ErrInvalidKey
}

func (m *Manager) ConsumeKey(session, oneTimeKey string) (SessionRecord, error) {
	lock, err := m.store.Lock()
	if err != nil {
		return SessionRecord{}, err
	}
	defer lock.Unlock()

	state, err := m.store.Load()
	if err != nil {
		return SessionRecord{}, err
	}

	var record SessionRecord
	var ownerSession string
	for candidateSession, candidate := range state.Sessions {
		for _, entry := range candidate.Keys {
			if entry.Key == oneTimeKey {
				record = candidate
				ownerSession = candidateSession
				break
			}
		}
		if ownerSession != "" {
			break
		}
	}
	if ownerSession == "" {
		if _, ok := state.Sessions[session]; !ok {
			return SessionRecord{}, ErrSessionNotFound
		}
		return SessionRecord{}, keyring.ErrInvalidKey
	}

	ring := keyring.FromEntries(m.store.now, record.Keys)
	err = ring.Consume(session, oneTimeKey)
	record.Keys = ring.Snapshot()
	state.Sessions[ownerSession] = record
	if saveErr := m.store.Save(state); saveErr != nil {
		return SessionRecord{}, saveErr
	}
	if err != nil {
		return SessionRecord{}, err
	}
	return record, nil
}

func (m *Manager) RecoverStale(session string) error {
	lock, err := m.store.Lock()
	if err != nil {
		return err
	}
	defer lock.Unlock()

	state, err := m.store.Load()
	if err != nil {
		return err
	}
	record, ok := state.Sessions[session]
	if !ok {
		return nil
	}
	if m.store.processAlive(record.PID) {
		return ErrLivePID
	}
	_ = removeSocketPlaceholder(record.SocketPath)
	delete(state.Sessions, session)
	return m.store.Save(state)
}

func (m *Manager) PruneExpired() error {
	lock, err := m.store.Lock()
	if err != nil {
		return err
	}
	defer lock.Unlock()

	state, err := m.store.Load()
	if err != nil {
		return err
	}
	now := m.store.now().UTC()
	changed := false
	for session, record := range state.Sessions {
		processAlive := record.PID > 0 && m.store.processAlive(record.PID)
		if record.ActiveClients > 0 && processAlive {
			continue
		}
		if now.Before(record.Expires) {
			continue
		}
		if record.PID > 0 {
			_ = m.store.terminate(record.PID)
		}
		_ = removeSocketPlaceholder(record.SocketPath)
		delete(state.Sessions, session)
		changed = true
	}
	if !changed {
		return nil
	}
	return m.store.Save(state)
}

func (m *Manager) mintForRecord(state State, record SessionRecord, keyTTL time.Duration) (LaunchResult, error) {
	ring := keyring.FromEntries(m.store.now, record.Keys)
	issued, err := ring.Mint(record.Session, keyTTL)
	if err != nil {
		return LaunchResult{}, err
	}
	record.Keys = ring.Snapshot()
	state.Sessions[record.Session] = record
	if err := m.store.Save(state); err != nil {
		return LaunchResult{}, err
	}
	return LaunchResult{
		Workspace:      record.Workspace,
		TmuxSession:    record.TmuxSession,
		Session:        record.Session,
		Key:            issued.Key,
		KeyExpires:     issued.ExpiresAt,
		Expires:        record.Expires,
		PID:            record.PID,
		Port:           record.Port,
		SocketPath:     record.SocketPath,
		HelperVersion:  record.HelperVersion,
		HelperArch:     record.HelperArch,
		TmuxSmoke:      record.TmuxSmoke,
		QUICAddr:       record.QUICAddr,
		QUICCertSHA256: record.QUICCertSHA256,
	}, nil
}

func (m *Manager) helperIdentityMatches(record SessionRecord) bool {
	if m.helperVersion != "" && record.HelperVersion != m.helperVersion {
		return false
	}
	if m.helperArch != "" && record.HelperArch != m.helperArch {
		return false
	}
	return true
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

func ValidatePeerCredential(cred PeerCredential, expectedUID int) error {
	if !cred.Available {
		return ErrPeerCredentialUnavailable
	}
	if cred.UID != uint32(expectedUID) {
		return ErrPeerUIDMismatch
	}
	return nil
}

func validateDirectoryInfo(info os.FileInfo, uid int) error {
	if info.Mode()&os.ModeSymlink != 0 {
		return ErrUnsafePath
	}
	if !info.IsDir() {
		return ErrUnsafePath
	}
	if info.Mode().Perm() != 0o700 {
		return ErrUnsafePath
	}
	fileUID, err := ownerUID(info)
	if err != nil {
		return err
	}
	if fileUID != uid {
		return ErrUnsafePath
	}
	return nil
}

func validateFilePath(path string, uid int) error {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return ErrUnsafePath
	}
	if info.Mode().Perm()&0o077 != 0 {
		return ErrUnsafePath
	}
	fileUID, err := ownerUID(info)
	if err != nil {
		return err
	}
	if fileUID != uid {
		return ErrUnsafePath
	}
	return nil
}

func ownerUID(info os.FileInfo) (int, error) {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, ErrUnsafePath
	}
	return int(stat.Uid), nil
}

func atomicWriteFile(path string, data []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".registry-*.tmp")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)

	if err := tmp.Chmod(mode); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmpName, path); err != nil {
		return err
	}
	return fsyncDir(dir)
}

func fsyncDir(dir string) error {
	file, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer file.Close()
	return file.Sync()
}

func removeSocketPlaceholder(path string) error {
	if path == "" {
		return nil
	}
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return ErrUnsafePath
	}
	return os.Remove(path)
}

func defaultProcessAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := unix.Kill(pid, 0)
	return err == nil || errors.Is(err, unix.EPERM)
}

func defaultTerminate(pid int) error {
	if pid <= 0 {
		return nil
	}
	err := unix.Kill(pid, unix.SIGTERM)
	if errors.Is(err, unix.ESRCH) {
		return nil
	}
	return err
}

func randomHex(byteCount int) (string, error) {
	buf := make([]byte, byteCount)
	if _, err := io.ReadFull(rand.Reader, buf); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf), nil
}
