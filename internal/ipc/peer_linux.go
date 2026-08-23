//go:build linux

package ipc

import "syscall"

const darwinSocketPathBytes = 104

func getPeerUID(fd int) (uint32, error) {
	credentials, err := syscall.GetsockoptUcred(fd, syscall.SOL_SOCKET, syscall.SO_PEERCRED)
	if err != nil {
		return 0, err
	}
	return credentials.Uid, nil
}
