//go:build darwin && (arm64 || amd64)

package nativeinput

import (
	"context"
	"fmt"
	"runtime"
	"sync"

	"github.com/ebitengine/purego"
)

const (
	coreGraphicsPath   = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
	coreFoundationPath = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"

	combinedSessionState int32  = 0
	sessionEventTap      uint32 = 1
	textVirtualKeyCode   uint16 = 0
)

type coreGraphicsAPI struct {
	preflightPostEventAccessFn func() bool
	requestPostEventAccessFn   func() bool
	createEventSourceFn        func(stateID int32) uintptr
	createKeyboardEventFn      func(source uintptr, virtualKey uint16, keyDown bool) uintptr
	setEventFlagsFn            func(event uintptr, flags uint64)
	keyboardSetUnicodeStringFn func(event uintptr, stringLength uint64, unicodeString *uint16)
	postEventFn                func(tap uint32, event uintptr)
	releaseFn                  func(event uintptr)
	// Framework handles stay open while registered function pointers are in use.
	coreGraphicsHandle   uintptr
	coreFoundationHandle uintptr
}

type coreGraphicsBackend struct {
	mu     sync.Mutex
	api    *coreGraphicsAPI
	source uintptr
	closed bool
}

func newPlatformBackend() (Backend, BackendState, string) {
	api, err := loadCoreGraphicsAPI()
	if err != nil {
		return nil, BackendInitializationFailed, detailInitialization
	}
	source := api.createEventSourceFn(combinedSessionState)
	if source == 0 {
		api.closeHandles()
		return nil, BackendInitializationFailed, detailInitialization
	}
	return &coreGraphicsBackend{api: api, source: source}, BackendReady, ""
}

func loadCoreGraphicsAPI() (_ *coreGraphicsAPI, err error) {
	coreGraphics, err := purego.Dlopen(coreGraphicsPath, purego.RTLD_NOW|purego.RTLD_LOCAL)
	if err != nil {
		return nil, fmt.Errorf("load CoreGraphics: %w", err)
	}
	coreFoundation, err := purego.Dlopen(coreFoundationPath, purego.RTLD_NOW|purego.RTLD_LOCAL)
	if err != nil {
		_ = purego.Dlclose(coreGraphics)
		return nil, fmt.Errorf("load CoreFoundation: %w", err)
	}
	loaded := false
	defer func() {
		if loaded {
			return
		}
		_ = purego.Dlclose(coreFoundation)
		_ = purego.Dlclose(coreGraphics)
	}()

	api := &coreGraphicsAPI{}
	if err := registerCoreGraphicsSymbol(coreGraphics, "CGPreflightPostEventAccess", &api.preflightPostEventAccessFn); err != nil {
		return nil, err
	}
	if err := registerCoreGraphicsSymbol(coreGraphics, "CGRequestPostEventAccess", &api.requestPostEventAccessFn); err != nil {
		return nil, err
	}
	if err := registerCoreGraphicsSymbol(coreGraphics, "CGEventSourceCreate", &api.createEventSourceFn); err != nil {
		return nil, err
	}
	if err := registerCoreGraphicsSymbol(coreGraphics, "CGEventCreateKeyboardEvent", &api.createKeyboardEventFn); err != nil {
		return nil, err
	}
	if err := registerCoreGraphicsSymbol(coreGraphics, "CGEventSetFlags", &api.setEventFlagsFn); err != nil {
		return nil, err
	}
	if err := registerCoreGraphicsSymbol(coreGraphics, "CGEventKeyboardSetUnicodeString", &api.keyboardSetUnicodeStringFn); err != nil {
		return nil, err
	}
	if err := registerCoreGraphicsSymbol(coreGraphics, "CGEventPost", &api.postEventFn); err != nil {
		return nil, err
	}
	if err := registerCoreGraphicsSymbol(coreFoundation, "CFRelease", &api.releaseFn); err != nil {
		return nil, err
	}
	loaded = true
	api.coreGraphicsHandle = coreGraphics
	api.coreFoundationHandle = coreFoundation
	return api, nil
}

func registerCoreGraphicsSymbol(handle uintptr, name string, target any) (err error) {
	pointer, err := purego.Dlsym(handle, name)
	if err != nil {
		return fmt.Errorf("resolve %s: %w", name, err)
	}
	defer func() {
		if recovered := recover(); recovered != nil {
			err = fmt.Errorf("bind %s: %v", name, recovered)
		}
	}()
	purego.RegisterFunc(target, pointer)
	return nil
}

func (backend *coreGraphicsBackend) CheckPermission() (bool, error) {
	backend.mu.Lock()
	defer backend.mu.Unlock()
	if backend.closed || backend.api == nil {
		return false, ErrClosed
	}
	return backend.api.preflightPostEventAccessFn(), nil
}

func (backend *coreGraphicsBackend) RequestPermission(ctx context.Context) (bool, error) {
	select {
	case <-ctx.Done():
		return false, ctx.Err()
	default:
	}
	backend.mu.Lock()
	defer backend.mu.Unlock()
	if backend.closed || backend.api == nil {
		return false, ErrClosed
	}
	return backend.api.requestPostEventAccessFn(), nil
}

func (backend *coreGraphicsBackend) Post(ctx context.Context, request Request) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	action, _, err := validateRequest(request)
	if err != nil {
		return err
	}
	units := actionUnits(action.text)
	backend.mu.Lock()
	defer backend.mu.Unlock()
	if backend.closed || backend.api == nil {
		return ErrClosed
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	down := backend.api.createKeyboardEventFn(backend.source, action.keyCodeOrText(), true)
	if down == 0 {
		return ErrEventAllocation
	}
	up := backend.api.createKeyboardEventFn(backend.source, action.keyCodeOrText(), false)
	if up == 0 {
		backend.api.releaseFn(down)
		return ErrEventAllocation
	}
	defer func() {
		backend.api.releaseFn(up)
		backend.api.releaseFn(down)
	}()
	if len(units) != 0 {
		backend.api.keyboardSetUnicodeStringFn(down, uint64(len(units)), &units[0])
		runtime.KeepAlive(units)
		backend.api.keyboardSetUnicodeStringFn(up, uint64(len(units)), &units[0])
		runtime.KeepAlive(units)
	}
	backend.api.setEventFlagsFn(down, 0)
	backend.api.setEventFlagsFn(up, 0)
	if !backend.api.preflightPostEventAccessFn() {
		return ErrPermissionDenied
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	backend.api.postEventFn(sessionEventTap, down)
	backend.api.postEventFn(sessionEventTap, up)
	return nil
}

func (action action) keyCodeOrText() uint16 {
	if action.keyCode != 0 {
		return action.keyCode
	}
	return textVirtualKeyCode
}

func (backend *coreGraphicsBackend) Close() error {
	backend.mu.Lock()
	defer backend.mu.Unlock()
	if backend.closed {
		return nil
	}
	backend.closed = true
	if backend.source != 0 {
		backend.api.releaseFn(backend.source)
		backend.source = 0
	}
	backend.api.closeHandles()
	return nil
}

func (api *coreGraphicsAPI) closeHandles() {
	if api == nil {
		return
	}
	if api.coreFoundationHandle != 0 {
		_ = purego.Dlclose(api.coreFoundationHandle)
		api.coreFoundationHandle = 0
	}
	if api.coreGraphicsHandle != 0 {
		_ = purego.Dlclose(api.coreGraphicsHandle)
		api.coreGraphicsHandle = 0
	}
}
