//go:build !windows

package discovery

import "path/filepath"

const (
	LockFileName     = "runtime.lock"
	SocketFileName   = "runtime.sock"
	MetadataFileName = "runtime.json"
)

// Paths contains the fixed names used inside one secure runtime directory.
type Paths struct {
	RuntimeDir   string
	LockPath     string
	SocketPath   string
	MetadataPath string
}

// NewPaths validates and canonicalizes a runtime directory path, then derives
// the fixed lock, socket, and metadata paths. It does not require the
// directory to exist; Open and Resolve perform that check.
func NewPaths(runtimeDir string) (Paths, error) {
	runtimeDir, err := validateRuntimePath(runtimeDir)
	if err != nil {
		return Paths{}, err
	}
	return Paths{
		RuntimeDir:   runtimeDir,
		LockPath:     filepath.Join(runtimeDir, LockFileName),
		SocketPath:   filepath.Join(runtimeDir, SocketFileName),
		MetadataPath: filepath.Join(runtimeDir, MetadataFileName),
	}, nil
}
