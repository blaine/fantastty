package artifact

import "errors"

var (
	ErrUnsupportedArch  = errors.New("unsupported architecture")
	ErrVersionMismatch  = errors.New("helper version mismatch")
	ErrArchMismatch     = errors.New("helper architecture mismatch")
	ErrChecksumMismatch = errors.New("helper checksum mismatch")
)

type Artifact struct {
	Label  string
	GOOS   string
	GOARCH string
}

type Manifest struct {
	Version string
	Arch    string
	SHA256  string
}

func Select(uname string) (Artifact, error) {
	switch uname {
	case "x86_64", "amd64":
		return Artifact{Label: "linux-amd64", GOOS: "linux", GOARCH: "amd64"}, nil
	case "aarch64", "arm64":
		return Artifact{Label: "linux-arm64", GOOS: "linux", GOARCH: "arm64"}, nil
	default:
		return Artifact{}, ErrUnsupportedArch
	}
}

func (m Manifest) Verify(version, arch, checksum string) error {
	if m.Version != version {
		return ErrVersionMismatch
	}
	if m.Arch != arch {
		return ErrArchMismatch
	}
	if m.SHA256 != checksum {
		return ErrChecksumMismatch
	}
	return nil
}
