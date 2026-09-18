//go:build !darwin || (!arm64 && !amd64)

package nativeinput

import "runtime"

func newPlatformBackend() (Backend, BackendState, string) {
	return nil, BackendUnsupported, detailUnsupported + ": " + runtime.GOOS + "/" + runtime.GOARCH
}
