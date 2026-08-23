package ipc

import (
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
)

type endpoint struct {
	path        string
	directory   string
	directoryID fileIdentity
	listener    *net.UnixListener
	identity    fileIdentity
	mu          sync.Mutex
	closed      bool
}

func newEndpoint(path string) (*endpoint, error) {
	if err := validateSocketPath(path); err != nil {
		return nil, err
	}
	parent := filepath.Dir(path)
	directoryID, err := validateGenerationDirectory(parent)
	if err != nil {
		return nil, err
	}
	if _, err := os.Lstat(path); err == nil {
		return nil, errors.New("socket endpoint already exists")
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("check socket endpoint: %w", err)
	}
	return &endpoint{path: path, directory: parent, directoryID: directoryID}, nil
}

func (e *endpoint) listen() error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.listener != nil {
		return errors.New("socket endpoint is already listening")
	}
	if e.closed {
		return errors.New("socket endpoint is closed")
	}
	currentDirectoryID, err := validateGenerationDirectory(e.directory)
	if err != nil || !sameFileIdentity(currentDirectoryID, e.directoryID) {
		return errors.New("generation directory changed before bind")
	}
	if _, err := os.Lstat(e.path); err == nil {
		return errors.New("socket endpoint already exists")
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("check socket endpoint before bind: %w", err)
	}
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: e.path, Net: "unix"})
	if err != nil {
		return fmt.Errorf("listen on Unix socket: %w", err)
	}
	listener.SetUnlinkOnClose(false)
	boundIdentity, err := validateSocketEntry(e.path, false)
	if err != nil {
		_ = listener.Close()
		return err
	}
	cleanup := func(cleanupErr error) error {
		_ = listener.Close()
		if current, currentErr := validateSocketEntry(e.path, true); currentErr == nil && sameFileIdentity(current, boundIdentity) {
			_ = os.Remove(e.path)
		}
		return cleanupErr
	}
	if err := os.Chmod(e.path, 0o600); err != nil {
		return cleanup(fmt.Errorf("set socket mode: %w", err))
	}
	identity, err := validateSocketEntry(e.path, true)
	if err != nil {
		return cleanup(err)
	}
	e.listener = listener
	e.identity = identity
	return nil
}

func (e *endpoint) close() error {
	e.mu.Lock()
	if e.closed {
		e.mu.Unlock()
		return nil
	}
	e.closed = true
	listener := e.listener
	identity := e.identity
	e.listener = nil
	e.mu.Unlock()

	var closeErr error
	if listener != nil {
		closeErr = listener.Close()
	}
	if listener != nil && identity.inode != 0 {
		currentDirectoryID, directoryErr := validateGenerationDirectory(e.directory)
		if directoryErr != nil || !sameFileIdentity(currentDirectoryID, e.directoryID) {
			return closeErr
		}
		if current, err := validateSocketEntry(e.path, true); err == nil && sameFileIdentity(current, identity) {
			if err := os.Remove(e.path); err != nil && !errors.Is(err, os.ErrNotExist) {
				closeErr = errors.Join(closeErr, fmt.Errorf("remove owned socket: %w", err))
			}
		}
	}
	return closeErr
}

func (e *endpoint) getListener() *net.UnixListener {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.listener
}
