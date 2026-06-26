package artifact

import (
	"errors"
	"testing"
)

func TestSelectRemoteArchitecture(t *testing.T) {
	tests := map[string]string{
		"x86_64":  "linux-amd64",
		"amd64":   "linux-amd64",
		"aarch64": "linux-arm64",
		"arm64":   "linux-arm64",
	}

	for uname, want := range tests {
		t.Run(uname, func(t *testing.T) {
			got, err := Select(uname)
			if err != nil {
				t.Fatalf("Select returned error: %v", err)
			}
			if got.Label != want {
				t.Fatalf("label = %q, want %q", got.Label, want)
			}
		})
	}
}

func TestSelectRejectsUnknownArchitecture(t *testing.T) {
	if _, err := Select("riscv64"); !errors.Is(err, ErrUnsupportedArch) {
		t.Fatalf("Select error = %v, want ErrUnsupportedArch", err)
	}
}

func TestManifestVerifyRejectsMismatch(t *testing.T) {
	manifest := Manifest{
		Version: "abc123",
		Arch:    "amd64",
		SHA256:  "0123456789abcdef",
	}

	if err := manifest.Verify("abc123", "amd64", "0123456789abcdef"); err != nil {
		t.Fatalf("Verify returned error for matching manifest: %v", err)
	}
	if err := manifest.Verify("def456", "amd64", "0123456789abcdef"); !errors.Is(err, ErrVersionMismatch) {
		t.Fatalf("version mismatch error = %v, want ErrVersionMismatch", err)
	}
	if err := manifest.Verify("abc123", "arm64", "0123456789abcdef"); !errors.Is(err, ErrArchMismatch) {
		t.Fatalf("arch mismatch error = %v, want ErrArchMismatch", err)
	}
	if err := manifest.Verify("abc123", "amd64", "bad"); !errors.Is(err, ErrChecksumMismatch) {
		t.Fatalf("checksum mismatch error = %v, want ErrChecksumMismatch", err)
	}
}
