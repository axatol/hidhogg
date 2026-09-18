//go:build darwin && (arm64 || amd64)

package nativeinput

import (
	"context"
	"reflect"
	"testing"
	"unsafe"
)

type nativeFakeEvent struct {
	keyCode uint16
	down    bool
	flags   uint64
	unicode []uint16
}

type nativeFakeAPI struct {
	permission bool
	createFail int
	nextEvent  uintptr
	events     map[uintptr]*nativeFakeEvent
	creates    []uintptr
	posts      []struct {
		tap   uint32
		event uintptr
	}
	releases []uintptr
	flags    []struct {
		event uintptr
		value uint64
	}
	unicode       [][]uint16
	cancel        context.CancelFunc
	cancelOnFlags bool
}

func newNativeFakeAPI(permission bool) (*nativeFakeAPI, *coreGraphicsBackend) {
	fake := &nativeFakeAPI{permission: permission, events: make(map[uintptr]*nativeFakeEvent)}
	api := &coreGraphicsAPI{
		preflightPostEventAccessFn: func() bool { return fake.permission },
		requestPostEventAccessFn:   func() bool { fake.permission = true; return true },
		createEventSourceFn:        func(int32) uintptr { return 99 },
		createKeyboardEventFn: func(_ uintptr, keyCode uint16, down bool) uintptr {
			fake.creates = append(fake.creates, uintptr(len(fake.creates)+1))
			if fake.createFail != 0 && len(fake.creates) == fake.createFail {
				return 0
			}
			fake.nextEvent++
			fake.events[fake.nextEvent] = &nativeFakeEvent{keyCode: keyCode, down: down}
			return fake.nextEvent
		},
		setEventFlagsFn: func(event uintptr, flags uint64) {
			fake.flags = append(fake.flags, struct {
				event uintptr
				value uint64
			}{event: event, value: flags})
			fake.events[event].flags = flags
			if fake.cancelOnFlags && fake.cancel != nil {
				fake.cancel()
				fake.cancel = nil
			}
		},
		keyboardSetUnicodeStringFn: func(event uintptr, length uint64, value *uint16) {
			units := make([]uint16, length)
			copy(units, unsafe.Slice(value, int(length)))
			fake.unicode = append(fake.unicode, units)
			fake.events[event].unicode = units
		},
		postEventFn: func(tap uint32, event uintptr) {
			fake.posts = append(fake.posts, struct {
				tap   uint32
				event uintptr
			}{tap: tap, event: event})
			if fake.cancel != nil {
				fake.cancel()
				fake.cancel = nil
			}
		},
		releaseFn: func(event uintptr) { fake.releases = append(fake.releases, event) },
	}
	return fake, &coreGraphicsBackend{api: api, source: 99}
}

func TestCoreGraphicsTextPairUsesPlainSessionEventsAndBalancedCleanup(t *testing.T) {
	fake, backend := newNativeFakeAPI(true)
	request := Request{ProfileID: "profile", PositionID: "position", Text: "A😀é"}
	if err := backend.Post(context.Background(), request); err != nil {
		t.Fatal(err)
	}
	wantUnits := [][]uint16{{0x0041, 0xd83d, 0xde00, 0x0065, 0x0301}, {0x0041, 0xd83d, 0xde00, 0x0065, 0x0301}}
	if !reflect.DeepEqual(fake.unicode, wantUnits) {
		t.Fatalf("unicode = %#v, want %#v", fake.unicode, wantUnits)
	}
	if len(fake.posts) != 2 || fake.posts[0].tap != sessionEventTap || fake.posts[1].tap != sessionEventTap {
		t.Fatalf("posts = %#v", fake.posts)
	}
	if len(fake.flags) != 2 || fake.flags[0].value != 0 || fake.flags[1].value != 0 {
		t.Fatalf("flags = %#v", fake.flags)
	}
	if !reflect.DeepEqual(fake.releases, []uintptr{2, 1}) {
		t.Fatalf("releases = %#v", fake.releases)
	}
}

func TestCoreGraphicsAllocationAndPermissionFailuresDoNotPost(t *testing.T) {
	fake, backend := newNativeFakeAPI(true)
	fake.createFail = 2
	if err := backend.Post(context.Background(), Request{ProfileID: "profile", PositionID: "position", Key: KeyEnter}); err == nil {
		t.Fatal("second allocation unexpectedly succeeded")
	}
	if len(fake.posts) != 0 || !reflect.DeepEqual(fake.releases, []uintptr{1}) {
		t.Fatalf("allocation failure posts=%#v releases=%#v", fake.posts, fake.releases)
	}

	fake, backend = newNativeFakeAPI(false)
	if err := backend.Post(context.Background(), Request{ProfileID: "profile", PositionID: "position", Key: KeyEnter}); err != ErrPermissionDenied {
		t.Fatalf("permission error = %v", err)
	}
	if len(fake.posts) != 0 || !reflect.DeepEqual(fake.releases, []uintptr{2, 1}) {
		t.Fatalf("permission failure posts=%#v releases=%#v", fake.posts, fake.releases)
	}
}

func TestCoreGraphicsCancellationBeforeAndAfterDown(t *testing.T) {
	fake, backend := newNativeFakeAPI(true)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := backend.Post(ctx, Request{ProfileID: "profile", PositionID: "position", Text: "x"}); err != context.Canceled {
		t.Fatalf("preallocation cancellation = %v", err)
	}
	if len(fake.creates) != 0 || len(fake.posts) != 0 {
		t.Fatalf("preallocation cancellation touched native events: creates=%#v posts=%#v", fake.creates, fake.posts)
	}

	fake, backend = newNativeFakeAPI(true)
	ctx, cancel = context.WithCancel(context.Background())
	fake.cancel = cancel
	if err := backend.Post(ctx, Request{ProfileID: "profile", PositionID: "position", Text: "x"}); err != nil {
		t.Fatalf("cancellation during construction = %v", err)
	}
	if len(fake.posts) != 2 {
		t.Fatalf("down/up posts after cancellation = %#v", fake.posts)
	}
}

func TestCoreGraphicsCancellationDuringPreparationReleasesWithoutPosting(t *testing.T) {
	fake, backend := newNativeFakeAPI(true)
	ctx, cancel := context.WithCancel(context.Background())
	fake.cancel = cancel
	fake.cancelOnFlags = true
	if err := backend.Post(ctx, Request{ProfileID: "profile", PositionID: "position", Text: "x"}); err != context.Canceled {
		t.Fatalf("pre-post cancellation = %v", err)
	}
	if len(fake.posts) != 0 || !reflect.DeepEqual(fake.releases, []uintptr{2, 1}) {
		t.Fatalf("pre-post cancellation posts=%#v releases=%#v", fake.posts, fake.releases)
	}
}
