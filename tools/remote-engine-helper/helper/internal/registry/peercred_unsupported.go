//go:build !linux

package registry

import "net"

func PeerCredentialFromUnixConn(conn *net.UnixConn) (PeerCredential, error) {
	return PeerCredential{Available: false}, ErrPeerCredentialUnavailable
}
