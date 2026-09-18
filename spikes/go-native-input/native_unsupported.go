//go:build !darwin || (!arm64 && !amd64)

package nativeinput

import (
	"fmt"
	"runtime"
)

func newNativeBackend() (*Backend, error) {
	return nil, fmt.Errorf("%w: %s/%s; build on darwin/arm64 or darwin/amd64", ErrUnsupportedPlatform, runtime.GOOS, runtime.GOARCH)
}
