//go:build darwin && (arm64 || amd64)

package nativeinput

import (
	"fmt"

	"github.com/ebitengine/purego"
)

const (
	coreGraphicsPath   = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
	coreFoundationPath = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
)

type darwinAPI struct {
	preflightPostEventAccessFn func() bool
	createEventSourceFn        func(stateID int32) uintptr
	createKeyboardEventFn      func(source uintptr, virtualKey uint16, keyDown bool) uintptr
	keyboardSetUnicodeStringFn func(event uintptr, stringLength uint64, unicodeString *uint16)
	keyboardGetUnicodeStringFn func(event uintptr, maximumLength uint64, actualLength *uint64, unicodeString *uint16)
	eventTypeFn                func(event uintptr) uint32
	eventFlagsFn               func(event uintptr) uint64
	eventIntegerValueFieldFn   func(event uintptr, field uint32) int64
	postEventFn                func(tap uint32, event uintptr)
	releaseFn                  func(event uintptr)
}

func newNativeBackend() (*Backend, error) {
	api, err := loadDarwinAPI()
	if err != nil {
		return nil, err
	}
	return newBackend(api)
}

func loadDarwinAPI() (_ *darwinAPI, err error) {
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

	api := &darwinAPI{}
	if err := registerSymbol(coreGraphics, "CGPreflightPostEventAccess", &api.preflightPostEventAccessFn); err != nil {
		return nil, err
	}
	if err := registerSymbol(coreGraphics, "CGEventSourceCreate", &api.createEventSourceFn); err != nil {
		return nil, err
	}
	if err := registerSymbol(coreGraphics, "CGEventCreateKeyboardEvent", &api.createKeyboardEventFn); err != nil {
		return nil, err
	}
	if err := registerSymbol(coreGraphics, "CGEventKeyboardSetUnicodeString", &api.keyboardSetUnicodeStringFn); err != nil {
		return nil, err
	}
	if err := registerSymbol(coreGraphics, "CGEventKeyboardGetUnicodeString", &api.keyboardGetUnicodeStringFn); err != nil {
		return nil, err
	}
	if err := registerSymbol(coreGraphics, "CGEventGetType", &api.eventTypeFn); err != nil {
		return nil, err
	}
	if err := registerSymbol(coreGraphics, "CGEventGetFlags", &api.eventFlagsFn); err != nil {
		return nil, err
	}
	if err := registerSymbol(coreGraphics, "CGEventGetIntegerValueField", &api.eventIntegerValueFieldFn); err != nil {
		return nil, err
	}
	if err := registerSymbol(coreGraphics, "CGEventPost", &api.postEventFn); err != nil {
		return nil, err
	}
	if err := registerSymbol(coreFoundation, "CFRelease", &api.releaseFn); err != nil {
		return nil, err
	}
	loaded = true
	return api, nil
}

func registerSymbol(handle uintptr, name string, target any) (err error) {
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

func (a *darwinAPI) preflightPostEventAccess() bool {
	return a.preflightPostEventAccessFn()
}

func (a *darwinAPI) createEventSource(stateID int32) uintptr {
	return a.createEventSourceFn(stateID)
}

func (a *darwinAPI) createKeyboardEvent(source uintptr, virtualKey uint16, keyDown bool) uintptr {
	return a.createKeyboardEventFn(source, virtualKey, keyDown)
}

func (a *darwinAPI) keyboardSetUnicodeString(event uintptr, stringLength uint64, unicodeString *uint16) {
	a.keyboardSetUnicodeStringFn(event, stringLength, unicodeString)
}

func (a *darwinAPI) keyboardGetUnicodeString(event uintptr, maximumLength uint64, actualLength *uint64, unicodeString *uint16) {
	a.keyboardGetUnicodeStringFn(event, maximumLength, actualLength, unicodeString)
}

func (a *darwinAPI) eventType(event uintptr) uint32 {
	return a.eventTypeFn(event)
}

func (a *darwinAPI) eventFlags(event uintptr) uint64 {
	return a.eventFlagsFn(event)
}

func (a *darwinAPI) eventIntegerValueField(event uintptr, field uint32) int64 {
	return a.eventIntegerValueFieldFn(event, field)
}

func (a *darwinAPI) postEvent(tap uint32, event uintptr) {
	a.postEventFn(tap, event)
}

func (a *darwinAPI) release(event uintptr) {
	a.releaseFn(event)
}
