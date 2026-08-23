//go:build !darwin && !linux

package ipc

import "errors"

const darwinSocketPathBytes = 104

func getPeerUID(int) (uint32, error) {
	return 0, errors.New("Unix peer credentials are unsupported on this platform")
}
