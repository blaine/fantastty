//go:build linux

package registry

import (
	"net"

	"golang.org/x/sys/unix"
)

func PeerCredentialFromUnixConn(conn *net.UnixConn) (PeerCredential, error) {
	raw, err := conn.SyscallConn()
	if err != nil {
		return PeerCredential{}, err
	}
	var cred *unix.Ucred
	var controlErr error
	if err := raw.Control(func(fd uintptr) {
		cred, controlErr = unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
	}); err != nil {
		return PeerCredential{}, err
	}
	if controlErr != nil {
		return PeerCredential{}, controlErr
	}
	return PeerCredential{UID: cred.Uid, Available: true}, nil
}
