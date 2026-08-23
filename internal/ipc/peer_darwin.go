//go:build darwin

package ipc

import (
	"syscall"
	"unsafe"
)

const (
	darwinSocketPathBytes = 104
	darwinSOLLocal        = 0
	darwinLocalPeercred   = 1
)

type darwinXucred struct {
	Version uint32
	UID     uint32
	Ngroups int16
	Padding int16
	Groups  [16]uint32
}

func getPeerUID(fd int) (uint32, error) {
	var credentials darwinXucred
	length := uint32(unsafe.Sizeof(credentials))
	_, _, errno := syscall.Syscall6(
		syscall.SYS_GETSOCKOPT,
		uintptr(fd),
		uintptr(darwinSOLLocal),
		uintptr(darwinLocalPeercred),
		uintptr(unsafe.Pointer(&credentials)),
		uintptr(unsafe.Pointer(&length)),
		0,
	)
	if errno != 0 {
		return 0, errno
	}
	return credentials.UID, nil
}
