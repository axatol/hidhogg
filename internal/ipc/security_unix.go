//go:build !windows

package ipc

import (
	"errors"
	"fmt"
	"net"
	"os"
	"runtime"
	"syscall"
)

type fileIdentity struct {
	device uint64
	inode  uint64
	uid    uint32
}

func inspectFile(info os.FileInfo) (fileIdentity, error) {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return fileIdentity{}, errors.New("file metadata has an unsupported type")
	}
	return fileIdentity{device: uint64(stat.Dev), inode: stat.Ino, uid: stat.Uid}, nil
}

func currentUID() uint32 {
	return uint32(syscall.Geteuid())
}

func validateGenerationDirectory(path string) (fileIdentity, error) {
	if path == "" {
		return fileIdentity{}, errors.New("socket path has no generation directory")
	}
	info, err := os.Lstat(path)
	if err != nil {
		return fileIdentity{}, fmt.Errorf("lstat generation directory: %w", err)
	}
	identity, err := inspectFile(info)
	if err != nil {
		return fileIdentity{}, fmt.Errorf("inspect generation directory: %w", err)
	}
	if !info.IsDir() || permissionBits(info.Mode()) != 0o700 || identity.uid != currentUID() {
		return fileIdentity{}, errors.New("generation directory must be an owner-only directory")
	}
	return identity, nil
}

func validateSocketPath(path string) error {
	if path == "" {
		return errors.New("socket path is required")
	}
	for index := 0; index < len(path); index++ {
		if path[index] == 0 {
			return errors.New("socket path contains NUL")
		}
	}
	if runtime.GOOS == "darwin" && len([]byte(path))+1 > darwinSocketPathBytes {
		return errors.New("socket path exceeds Darwin sockaddr capacity")
	}
	return nil
}

func validateSocketEntry(path string, requireMode bool) (fileIdentity, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return fileIdentity{}, fmt.Errorf("lstat socket: %w", err)
	}
	identity, err := inspectFile(info)
	if err != nil {
		return fileIdentity{}, fmt.Errorf("inspect socket: %w", err)
	}
	if info.Mode()&os.ModeSocket != os.ModeSocket || identity.uid != currentUID() {
		return fileIdentity{}, errors.New("socket must be an owner-owned Unix socket")
	}
	if requireMode && permissionBits(info.Mode()) != 0o600 {
		return fileIdentity{}, errors.New("socket must have mode 0600")
	}
	return identity, nil
}

func permissionBits(mode os.FileMode) os.FileMode {
	return mode & (os.ModePerm | os.ModeSetuid | os.ModeSetgid | os.ModeSticky)
}

func sameFileIdentity(left, right fileIdentity) bool {
	return left.device == right.device && left.inode == right.inode
}

func verifyPeerUID(connection net.Conn) error {
	unixConnection, ok := connection.(interface {
		SyscallConn() (syscall.RawConn, error)
	})
	if !ok {
		return errors.New("Unix connection does not expose a file descriptor")
	}
	raw, err := unixConnection.SyscallConn()
	if err != nil {
		return fmt.Errorf("obtain Unix connection control: %w", err)
	}
	var peerUID uint32
	var peerErr error
	if err := raw.Control(func(fd uintptr) {
		peerUID, peerErr = getPeerUID(int(fd))
	}); err != nil {
		return fmt.Errorf("control Unix connection: %w", err)
	}
	if peerErr != nil {
		return fmt.Errorf("get Unix peer credentials: %w", peerErr)
	}
	if peerUID != currentUID() {
		return errors.New("Unix peer credentials do not match effective UID")
	}
	return nil
}
