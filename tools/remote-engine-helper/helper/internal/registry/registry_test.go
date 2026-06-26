package registry

import (
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"fantastty/remote-engine-helper/internal/keyring"
)

func TestRuntimeDirFallsBackWhenXDGIsMissing(t *testing.T) {
	got := RuntimeDir(map[string]string{}, 501)
	want := "/tmp/fantastty-remote-engine-501"
	if got != want {
		t.Fatalf("RuntimeDir = %q, want %q", got, want)
	}

	got = RuntimeDir(map[string]string{"XDG_RUNTIME_DIR": "/run/user/501"}, 501)
	want = "/run/user/501/fantastty-remote-engine"
	if got != want {
		t.Fatalf("RuntimeDir with XDG = %q, want %q", got, want)
	}
}

func TestEnsureRuntimeDirRequiresSecureDirectory(t *testing.T) {
	base := t.TempDir()
	root := filepath.Join(base, "runtime")

	if err := EnsureRuntimeDir(root, os.Geteuid()); err != nil {
		t.Fatalf("EnsureRuntimeDir created root: %v", err)
	}
	info, err := os.Stat(root)
	if err != nil {
		t.Fatalf("stat root: %v", err)
	}
	if mode := info.Mode().Perm(); mode != 0o700 {
		t.Fatalf("runtime mode = %o, want 0700", mode)
	}

	if err := os.Chmod(root, 0o755); err != nil {
		t.Fatalf("chmod root: %v", err)
	}
	if err := EnsureRuntimeDir(root, os.Geteuid()); !errors.Is(err, ErrUnsafePath) {
		t.Fatalf("unsafe mode error = %v, want ErrUnsafePath", err)
	}
}

func TestEnsureRuntimeDirRejectsSymlink(t *testing.T) {
	base := t.TempDir()
	target := filepath.Join(base, "target")
	link := filepath.Join(base, "runtime")
	if err := os.Mkdir(target, 0o700); err != nil {
		t.Fatalf("mkdir target: %v", err)
	}
	if err := os.Symlink(target, link); err != nil {
		t.Fatalf("symlink: %v", err)
	}

	if err := EnsureRuntimeDir(link, os.Geteuid()); !errors.Is(err, ErrUnsafePath) {
		t.Fatalf("symlink error = %v, want ErrUnsafePath", err)
	}
}

func TestLockRejectsUnsafeExistingLockPath(t *testing.T) {
	root := secureRoot(t)
	store, err := NewStore(root, Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	if err := os.WriteFile(store.LockPath(), []byte("x"), 0o644); err != nil {
		t.Fatalf("write unsafe lock: %v", err)
	}

	if _, err := store.Lock(); !errors.Is(err, ErrUnsafePath) {
		t.Fatalf("Lock error = %v, want ErrUnsafePath", err)
	}
}

func TestLoadRejectsUnsafeExistingRegistryPath(t *testing.T) {
	root := secureRoot(t)
	store, err := NewStore(root, Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	if err := os.WriteFile(store.RegistryPath(), []byte(`{"sessions":{}}`), 0o644); err != nil {
		t.Fatalf("write unsafe registry: %v", err)
	}

	if _, err := store.Load(); !errors.Is(err, ErrUnsafePath) {
		t.Fatalf("Load error = %v, want ErrUnsafePath", err)
	}
}

func TestLoadRejectsSymlinkRegistryPath(t *testing.T) {
	root := secureRoot(t)
	store, err := NewStore(root, Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	target := filepath.Join(root, "target-registry.json")
	if err := os.WriteFile(target, []byte(`{"sessions":{}}`), 0o600); err != nil {
		t.Fatalf("write target: %v", err)
	}
	if err := os.Symlink(target, store.RegistryPath()); err != nil {
		t.Fatalf("symlink registry: %v", err)
	}

	if _, err := store.Load(); !errors.Is(err, ErrUnsafePath) {
		t.Fatalf("Load symlink error = %v, want ErrUnsafePath", err)
	}
}

func TestValidateSocketPathRejectsSymlink(t *testing.T) {
	root := secureRoot(t)
	store, err := NewStore(root, Options{UID: os.Geteuid()})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	target := filepath.Join(root, "target.sock")
	if err := os.WriteFile(target, []byte("x"), 0o600); err != nil {
		t.Fatalf("write target: %v", err)
	}
	link := filepath.Join(root, "control.sock")
	if err := os.Symlink(target, link); err != nil {
		t.Fatalf("symlink: %v", err)
	}

	if err := store.ValidateSocketPath(link); !errors.Is(err, ErrUnsafePath) {
		t.Fatalf("ValidateSocketPath error = %v, want ErrUnsafePath", err)
	}
}

func TestLaunchOrResumeConcurrentCallsReuseLiveSessionAndMintFreshKeys(t *testing.T) {
	now := time.Unix(1700000000, 0).UTC()
	store, err := NewStore(secureRoot(t), Options{
		UID: os.Geteuid(),
		Now: func() time.Time { return now },
		ProcessAlive: func(pid int) bool {
			return pid == 4242
		},
	})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := NewManager(store)
	var starts int
	starter := func(StartRequest) (StartResult, error) {
		starts++
		return StartResult{PID: 4242, Port: 34567, SocketPath: filepath.Join(store.Root(), "phase0.sock")}, nil
	}

	const callers = 8
	results := make([]LaunchResult, callers)
	var wg sync.WaitGroup
	for i := 0; i < callers; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			result, err := manager.LaunchOrResume("workspace-a", time.Minute, time.Second, starter)
			if err != nil {
				t.Errorf("LaunchOrResume[%d]: %v", i, err)
				return
			}
			results[i] = result
		}(i)
	}
	wg.Wait()

	if starts != 1 {
		t.Fatalf("starts = %d, want 1", starts)
	}
	seenKeys := map[string]bool{}
	for i, result := range results {
		if result.Session == "" {
			t.Fatalf("result[%d] missing session", i)
		}
		if result.PID != 4242 {
			t.Fatalf("result[%d] pid = %d, want 4242", i, result.PID)
		}
		if i > 0 && result.Session != results[0].Session {
			t.Fatalf("result[%d] session = %s, want %s", i, result.Session, results[0].Session)
		}
		if seenKeys[result.Key] {
			t.Fatalf("duplicate one-time key minted: %s", result.Key)
		}
		seenKeys[result.Key] = true
	}
}

func TestLaunchOrResumeReusesSameWorkspaceAndIsolatesDifferentWorkspaces(t *testing.T) {
	now := time.Unix(1700000000, 0).UTC()
	livePIDs := map[int]bool{}
	store, err := NewStore(secureRoot(t), Options{
		UID: os.Geteuid(),
		Now: func() time.Time { return now },
		ProcessAlive: func(pid int) bool {
			return livePIDs[pid]
		},
	})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := NewManager(store)
	starts := 0
	starter := func(req StartRequest) (StartResult, error) {
		starts++
		pid := 4000 + starts
		livePIDs[pid] = true
		return StartResult{
			PID:            pid,
			Port:           34000 + starts,
			SocketPath:     filepath.Join(store.Root(), req.Workspace+".sock"),
			HelperVersion:  "v1",
			HelperArch:     "amd64",
			QUICAddr:       "127.0.0.1:0",
			QUICCertSHA256: "abc123",
		}, nil
	}

	first, err := manager.LaunchOrResume("workspace-a", time.Minute, time.Second, starter)
	if err != nil {
		t.Fatalf("LaunchOrResume first: %v", err)
	}
	second, err := manager.LaunchOrResume("workspace-a", time.Minute, time.Second, starter)
	if err != nil {
		t.Fatalf("LaunchOrResume second: %v", err)
	}
	other, err := manager.LaunchOrResume("workspace-b", time.Minute, time.Second, starter)
	if err != nil {
		t.Fatalf("LaunchOrResume other: %v", err)
	}

	if starts != 2 {
		t.Fatalf("starts = %d, want 2", starts)
	}
	if second.Session != first.Session || second.PID != first.PID || second.SocketPath != first.SocketPath {
		t.Fatalf("same workspace resumed %+v, want session/pid/socket from %+v", second, first)
	}
	if second.Key == first.Key {
		t.Fatalf("same workspace resume reused one-time key %s", second.Key)
	}
	if second.KeyExpires != now.Add(time.Second).UTC() {
		t.Fatalf("same workspace key expiry = %s, want %s", second.KeyExpires, now.Add(time.Second).UTC())
	}
	if other.Workspace != "workspace-b" || other.Session == first.Session || other.PID == first.PID || other.SocketPath == first.SocketPath {
		t.Fatalf("different workspace result = %+v, want independent session/pid/socket from %+v", other, first)
	}
	if other.KeyExpires != now.Add(time.Second).UTC() {
		t.Fatalf("different workspace key expiry = %s, want %s", other.KeyExpires, now.Add(time.Second).UTC())
	}
}

func TestRecoverStaleArtifactsOnlyWhenRecordedPIDIsDead(t *testing.T) {
	store, err := NewStore(secureRoot(t), Options{
		UID: os.Geteuid(),
		ProcessAlive: func(pid int) bool {
			return pid == 111
		},
	})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := NewManager(store)
	socketPath := filepath.Join(store.Root(), "stale.sock")
	if err := os.WriteFile(socketPath, []byte("stale"), 0o600); err != nil {
		t.Fatalf("write stale socket placeholder: %v", err)
	}

	if err := manager.RecordSession(SessionRecord{
		Workspace:  "workspace-a",
		Session:    "session-a",
		PID:        111,
		Port:       1234,
		SocketPath: socketPath,
		Expires:    time.Now().Add(time.Minute),
	}); err != nil {
		t.Fatalf("RecordSession: %v", err)
	}
	if err := manager.RecoverStale("session-a"); !errors.Is(err, ErrLivePID) {
		t.Fatalf("RecoverStale live error = %v, want ErrLivePID", err)
	}

	store.processAlive = func(pid int) bool { return false }
	if err := manager.RecoverStale("session-a"); err != nil {
		t.Fatalf("RecoverStale dead pid: %v", err)
	}
	if _, err := os.Lstat(socketPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("socket placeholder after recovery err = %v, want not exist", err)
	}
}

func TestConsumeKeyBurnsKeyWhenWrongSessionIsSupplied(t *testing.T) {
	now := time.Unix(1700000000, 0).UTC()
	store, err := NewStore(secureRoot(t), Options{
		UID: os.Geteuid(),
		Now: func() time.Time { return now },
		ProcessAlive: func(pid int) bool {
			return pid == 4242
		},
	})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := NewManager(store)
	result, err := manager.LaunchOrResume("workspace-a", time.Minute, time.Minute, func(StartRequest) (StartResult, error) {
		return StartResult{PID: 4242, Port: 34567, SocketPath: filepath.Join(store.Root(), "phase0.sock")}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume: %v", err)
	}

	if _, err := manager.ConsumeKey("0000000000000000000000000000000000000000000000000000000000000000", result.Key); !errors.Is(err, keyring.ErrWrongSession) {
		t.Fatalf("wrong-session consume error = %v, want ErrWrongSession", err)
	}
	if _, err := manager.ConsumeKey(result.Session, result.Key); !errors.Is(err, keyring.ErrInvalidKey) {
		t.Fatalf("key survived wrong-session registry consume: %v", err)
	}
}

func TestFindKeyOwnerRejectsExpiredKeyAndPrunesIt(t *testing.T) {
	now := time.Unix(1700000000, 0).UTC()
	store, err := NewStore(secureRoot(t), Options{
		UID: os.Geteuid(),
		Now: func() time.Time { return now },
		ProcessAlive: func(pid int) bool {
			return pid == 4242
		},
	})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := NewManager(store)
	result, err := manager.LaunchOrResume("workspace-a", time.Minute, time.Second, func(StartRequest) (StartResult, error) {
		return StartResult{PID: 4242, Port: 34567, SocketPath: filepath.Join(store.Root(), "phase0.sock")}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume: %v", err)
	}

	now = now.Add(2 * time.Second)
	if _, err := manager.FindKeyOwner(result.Key); !errors.Is(err, keyring.ErrExpiredKey) {
		t.Fatalf("FindKeyOwner expired error = %v, want ErrExpiredKey", err)
	}
	if _, err := manager.ConsumeKey(result.Session, result.Key); !errors.Is(err, keyring.ErrInvalidKey) {
		t.Fatalf("expired key survived owner lookup: %v", err)
	}
}

func TestAuthenticatedClientLifecycleExtendsSessionUntilIdleTTL(t *testing.T) {
	now := time.Unix(1700000000, 0).UTC()
	var terminated []int
	store, err := NewStore(secureRoot(t), Options{
		UID: os.Geteuid(),
		Now: func() time.Time { return now },
		ProcessAlive: func(pid int) bool {
			return pid == 4242
		},
		Terminate: func(pid int) error {
			terminated = append(terminated, pid)
			return nil
		},
	})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := NewManager(store)
	result, err := manager.LaunchOrResume("workspace-a", 10*time.Second, time.Second, func(StartRequest) (StartResult, error) {
		return StartResult{PID: 4242, Port: 34567, SocketPath: filepath.Join(store.Root(), "phase0.sock")}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume: %v", err)
	}

	now = now.Add(9 * time.Second)
	if err := manager.ClientAttached(result.Session); err != nil {
		t.Fatalf("ClientAttached: %v", err)
	}
	now = now.Add(2 * time.Second)
	if err := manager.PruneExpired(); err != nil {
		t.Fatalf("PruneExpired with active client: %v", err)
	}
	if len(terminated) != 0 {
		t.Fatalf("terminated active helper = %v, want none", terminated)
	}
	if resumed, err := manager.LaunchOrResume("workspace-a", 10*time.Second, time.Second, func(StartRequest) (StartResult, error) {
		t.Fatal("LaunchOrResume started duplicate helper while authenticated client was active")
		return StartResult{}, nil
	}); err != nil {
		t.Fatalf("LaunchOrResume active session: %v", err)
	} else if resumed.Session != result.Session {
		t.Fatalf("resumed session = %s, want %s", resumed.Session, result.Session)
	}

	if err := manager.ClientDetached(result.Session, 10*time.Second); err != nil {
		t.Fatalf("ClientDetached: %v", err)
	}
	now = now.Add(9 * time.Second)
	if err := manager.PruneExpired(); err != nil {
		t.Fatalf("PruneExpired before idle ttl: %v", err)
	}
	if len(terminated) != 0 {
		t.Fatalf("terminated before idle ttl = %v, want none", terminated)
	}
	now = now.Add(2 * time.Second)
	if err := manager.PruneExpired(); err != nil {
		t.Fatalf("PruneExpired after idle ttl: %v", err)
	}
	if len(terminated) != 1 || terminated[0] != 4242 {
		t.Fatalf("terminated after idle ttl = %v, want [4242]", terminated)
	}
}

func TestPruneExpiredRemovesDeadHelperWithStaleActiveClientCount(t *testing.T) {
	now := time.Unix(1700000000, 0).UTC()
	store, err := NewStore(secureRoot(t), Options{
		UID: os.Geteuid(),
		Now: func() time.Time { return now },
		ProcessAlive: func(pid int) bool {
			return false
		},
	})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := NewManager(store)
	if err := manager.RecordSession(SessionRecord{
		Workspace:     "workspace-a",
		Session:       "session-a",
		PID:           4242,
		Port:          1234,
		Expires:       now.Add(-time.Second),
		ActiveClients: 1,
	}); err != nil {
		t.Fatalf("RecordSession: %v", err)
	}

	if err := manager.PruneExpired(); err != nil {
		t.Fatalf("PruneExpired: %v", err)
	}
	state, err := store.Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(state.Sessions) != 0 {
		t.Fatalf("sessions after prune = %d, want 0", len(state.Sessions))
	}
}

func TestLaunchOrResumeDoesNotExtendIdleExpiryWithoutAuthenticatedClient(t *testing.T) {
	now := time.Unix(1700000000, 0).UTC()
	store, err := NewStore(secureRoot(t), Options{
		UID: os.Geteuid(),
		Now: func() time.Time { return now },
		ProcessAlive: func(pid int) bool {
			return pid == 4242
		},
	})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := NewManager(store)
	var starts int
	starter := func(StartRequest) (StartResult, error) {
		starts++
		return StartResult{PID: 4242, Port: 34567, SocketPath: filepath.Join(store.Root(), "phase0.sock")}, nil
	}
	result, err := manager.LaunchOrResume("workspace-a", 10*time.Second, time.Second, starter)
	if err != nil {
		t.Fatalf("LaunchOrResume: %v", err)
	}

	now = now.Add(9 * time.Second)
	resumed, err := manager.LaunchOrResume("workspace-a", 10*time.Second, time.Second, starter)
	if err != nil {
		t.Fatalf("LaunchOrResume near expiry: %v", err)
	}
	if resumed.Session != result.Session {
		t.Fatalf("resumed session = %s, want %s", resumed.Session, result.Session)
	}
	now = now.Add(2 * time.Second)
	restarted, err := manager.LaunchOrResume("workspace-a", 10*time.Second, time.Second, starter)
	if err != nil {
		t.Fatalf("LaunchOrResume after un-attached expiry: %v", err)
	}
	if restarted.Session == result.Session {
		t.Fatalf("session survived past idle expiry after only minting keys")
	}
	if starts != 2 {
		t.Fatalf("starts = %d, want 2", starts)
	}
}

func TestLaunchOrResumeRestartsLiveSessionWhenHelperVersionChanges(t *testing.T) {
	now := time.Unix(1700000000, 0).UTC()
	var terminated []int
	store, err := NewStore(secureRoot(t), Options{
		UID: os.Geteuid(),
		Now: func() time.Time { return now },
		ProcessAlive: func(pid int) bool {
			return pid == 4242
		},
		Terminate: func(pid int) error {
			terminated = append(terminated, pid)
			return nil
		},
	})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := NewManagerWithHelperIdentity(store, "v2", "amd64")
	if err := manager.RecordSession(SessionRecord{
		Workspace:     "workspace-a",
		Session:       "session-v1",
		PID:           4242,
		Port:          34567,
		SocketPath:    filepath.Join(store.Root(), "phase0.sock"),
		HelperVersion: "v1",
		HelperArch:    "amd64",
		Expires:       now.Add(time.Minute),
	}); err != nil {
		t.Fatalf("RecordSession: %v", err)
	}

	result, err := manager.LaunchOrResume("workspace-a", time.Minute, time.Second, func(StartRequest) (StartResult, error) {
		return StartResult{
			PID:            5252,
			Port:           45678,
			SocketPath:     filepath.Join(store.Root(), "phase0-v2.sock"),
			HelperVersion:  "v2",
			HelperArch:     "amd64",
			QUICAddr:       "127.0.0.1:45678",
			QUICCertSHA256: "abc",
		}, nil
	})
	if err != nil {
		t.Fatalf("LaunchOrResume: %v", err)
	}
	if len(terminated) != 1 || terminated[0] != 4242 {
		t.Fatalf("terminated = %v, want [4242]", terminated)
	}
	if result.Session == "session-v1" {
		t.Fatalf("LaunchOrResume reused stale helper session")
	}
	if result.HelperVersion != "v2" || result.HelperArch != "amd64" {
		t.Fatalf("helper identity = %s/%s, want v2/amd64", result.HelperVersion, result.HelperArch)
	}
}

func TestPeerCredentialValidationFailsClosed(t *testing.T) {
	if err := ValidatePeerCredential(PeerCredential{UID: uint32(os.Geteuid()), Available: true}, os.Geteuid()); err != nil {
		t.Fatalf("same uid credential rejected: %v", err)
	}
	if err := ValidatePeerCredential(PeerCredential{UID: uint32(os.Geteuid() + 1), Available: true}, os.Geteuid()); !errors.Is(err, ErrPeerUIDMismatch) {
		t.Fatalf("wrong uid error = %v, want ErrPeerUIDMismatch", err)
	}
	if err := ValidatePeerCredential(PeerCredential{Available: false}, os.Geteuid()); !errors.Is(err, ErrPeerCredentialUnavailable) {
		t.Fatalf("unavailable credential error = %v, want ErrPeerCredentialUnavailable", err)
	}
}

func TestPruneExpiredTerminatesAndRemovesSession(t *testing.T) {
	now := time.Unix(1700000000, 0).UTC()
	var terminated []int
	store, err := NewStore(secureRoot(t), Options{
		UID: os.Geteuid(),
		Now: func() time.Time { return now },
		Terminate: func(pid int) error {
			terminated = append(terminated, pid)
			return nil
		},
	})
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	manager := NewManager(store)
	if err := manager.RecordSession(SessionRecord{
		Workspace: "workspace-a",
		Session:   "session-a",
		PID:       5150,
		Port:      1234,
		Expires:   now.Add(-time.Second),
	}); err != nil {
		t.Fatalf("RecordSession: %v", err)
	}

	if err := manager.PruneExpired(); err != nil {
		t.Fatalf("PruneExpired: %v", err)
	}
	if len(terminated) != 1 || terminated[0] != 5150 {
		t.Fatalf("terminated = %v, want [5150]", terminated)
	}
	state, err := store.Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(state.Sessions) != 0 {
		t.Fatalf("sessions after prune = %d, want 0", len(state.Sessions))
	}
}

func secureRoot(t *testing.T) string {
	t.Helper()
	root := filepath.Join(t.TempDir(), "runtime")
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatalf("mkdir runtime: %v", err)
	}
	return root
}
