package nativeinput

import (
	"errors"
	"reflect"
	"testing"
	"time"
	"unsafe"
)

type fakeCreateCall struct {
	source  uintptr
	keyCode uint16
	down    bool
}

type fakeSourceCall struct {
	stateID int32
}

type fakeUnicodeCall struct {
	event  uintptr
	length uint64
	units  []uint16
}

type fakeUnicodeGetCall struct {
	event         uintptr
	maximumLength uint64
}

type fakePostCall struct {
	tap   uint32
	event uintptr
}

type fakeAPI struct {
	permission  []bool
	sources     []fakeSourceCall
	creates     []fakeCreateCall
	unicodes    []fakeUnicodeCall
	unicodeGets []fakeUnicodeGetCall
	posts       []fakePostCall
	releases    []uintptr
	events      map[uintptr]fakeEvent
	readback    map[uintptr][]uint16
	failSource  bool
	failCreate  int
	nextEvent   uintptr
	nextSource  uintptr
}

type fakeEvent struct {
	eventType uint32
	keyCode   int64
	flags     uint64
	unicode   []uint16
}

func (f *fakeAPI) preflightPostEventAccess() bool {
	if len(f.permission) == 0 {
		return false
	}
	allowed := f.permission[0]
	f.permission = f.permission[1:]
	return allowed
}

func (f *fakeAPI) createEventSource(stateID int32) uintptr {
	f.sources = append(f.sources, fakeSourceCall{stateID: stateID})
	if f.failSource {
		return 0
	}
	if f.nextSource == 0 {
		f.nextSource = 100
	}
	f.nextSource++
	return f.nextSource
}

func (f *fakeAPI) createKeyboardEvent(source uintptr, keyCode uint16, down bool) uintptr {
	f.creates = append(f.creates, fakeCreateCall{source: source, keyCode: keyCode, down: down})
	if f.failCreate > 0 && len(f.creates) == f.failCreate {
		return 0
	}
	f.nextEvent++
	if f.events == nil {
		f.events = make(map[uintptr]fakeEvent)
	}
	eventType := keyUpEventType
	if down {
		eventType = keyDownEventType
	}
	f.events[f.nextEvent] = fakeEvent{eventType: eventType, keyCode: int64(keyCode)}
	return f.nextEvent
}

func (f *fakeAPI) keyboardSetUnicodeString(event uintptr, length uint64, pointer *uint16) {
	units := make([]uint16, length)
	copy(units, unsafeSlice(pointer, int(length)))
	f.unicodes = append(f.unicodes, fakeUnicodeCall{event: event, length: length, units: units})
	if f.events == nil {
		f.events = make(map[uintptr]fakeEvent)
	}
	state := f.events[event]
	state.unicode = append([]uint16(nil), units...)
	f.events[event] = state
}

func (f *fakeAPI) keyboardGetUnicodeString(event uintptr, maximumLength uint64, actualLength *uint64, pointer *uint16) {
	f.unicodeGets = append(f.unicodeGets, fakeUnicodeGetCall{event: event, maximumLength: maximumLength})
	units := f.events[event].unicode
	if override, ok := f.readback[event]; ok {
		units = override
	}
	if actualLength != nil {
		*actualLength = uint64(len(units))
	}
	if maximumLength == 0 || pointer == nil {
		return
	}
	count := len(units)
	if uint64(count) > maximumLength {
		count = int(maximumLength)
	}
	copy(unsafeSlice(pointer, count), units[:count])
}

func (f *fakeAPI) eventType(event uintptr) uint32 {
	return f.events[event].eventType
}

func (f *fakeAPI) eventFlags(event uintptr) uint64 {
	return f.events[event].flags
}

func (f *fakeAPI) eventIntegerValueField(event uintptr, field uint32) int64 {
	if field != keyboardEventKeycodeField {
		return 0
	}
	return f.events[event].keyCode
}

func (f *fakeAPI) postEvent(tap uint32, event uintptr) {
	f.posts = append(f.posts, fakePostCall{tap: tap, event: event})
}

func (f *fakeAPI) release(event uintptr) {
	f.releases = append(f.releases, event)
}

func unsafeSlice(pointer *uint16, length int) []uint16 {
	if pointer == nil || length == 0 {
		return nil
	}
	return unsafe.Slice(pointer, length)
}

func TestPostPermissionDeniedDoesNotAllocateOrPost(t *testing.T) {
	fake := &fakeAPI{permission: []bool{false}}
	backend, err := newBackend(fake)
	if err != nil {
		t.Fatal(err)
	}
	if err := backend.Post(Enter(), 0); !errors.Is(err, ErrPermissionDenied) {
		t.Fatalf("Post error = %v, want permission denied", err)
	}
	if len(fake.creates) != 0 || len(fake.posts) != 0 || len(fake.releases) != 0 {
		t.Fatalf("permission-denied path touched events: creates=%d posts=%d releases=%d", len(fake.creates), len(fake.posts), len(fake.releases))
	}
}

func TestTextUsesSurrogatePairsForBothEvents(t *testing.T) {
	fake := &fakeAPI{permission: []bool{true, true}}
	backend, err := newBackend(fake)
	if err != nil {
		t.Fatal(err)
	}
	if err := backend.Post(Text("A😀é"), 0); err != nil {
		t.Fatal(err)
	}
	wantUnits := []uint16{0x0041, 0xd83d, 0xde00, 0x0065, 0x0301}
	if len(fake.unicodes) != 2 {
		t.Fatalf("Unicode setter calls = %d, want 2", len(fake.unicodes))
	}
	for _, call := range fake.unicodes {
		if call.length != uint64(len(wantUnits)) || !reflect.DeepEqual(call.units, wantUnits) {
			t.Fatalf("Unicode call = %+v, want units %#v", call, wantUnits)
		}
	}
	if len(fake.posts) != 2 || len(fake.releases) != 2 {
		t.Fatalf("text event counts: posts=%d releases=%d", len(fake.posts), len(fake.releases))
	}
}

func TestSecondAllocationFailureReleasesFirstEventAndDoesNotPost(t *testing.T) {
	fake := &fakeAPI{permission: []bool{true, true}, failCreate: 2}
	backend, err := newBackend(fake)
	if err != nil {
		t.Fatal(err)
	}
	if err := backend.Post(Enter(), 0); !errors.Is(err, ErrEventAllocation) {
		t.Fatalf("Post error = %v, want allocation failure", err)
	}
	if !reflect.DeepEqual(fake.releases, []uintptr{1}) {
		t.Fatalf("releases = %#v, want [1]", fake.releases)
	}
	if len(fake.posts) != 0 {
		t.Fatalf("posts = %d, want zero", len(fake.posts))
	}
}

func TestPostAllocatesBothBeforeBalancedDownUpPostingAndRelease(t *testing.T) {
	fake := &fakeAPI{permission: []bool{true, true}}
	backend, err := newBackend(fake)
	if err != nil {
		t.Fatal(err)
	}
	if err := backend.Post(Enter(), 0); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(fake.creates, []fakeCreateCall{{keyCode: KeyCodeEnter, down: true}, {keyCode: KeyCodeEnter, down: false}}) {
		t.Fatalf("creates = %#v", fake.creates)
	}
	if !reflect.DeepEqual(fake.posts, []fakePostCall{{tap: hidEventTap, event: 1}, {tap: hidEventTap, event: 2}}) {
		t.Fatalf("posts = %#v", fake.posts)
	}
	if !reflect.DeepEqual(fake.releases, []uintptr{2, 1}) {
		t.Fatalf("releases = %#v, want [2 1]", fake.releases)
	}
}

func TestInspectReadsBackFieldsWithoutPermissionOrPosting(t *testing.T) {
	fake := &fakeAPI{}
	backend, err := newBackend(fake)
	if err != nil {
		t.Fatal(err)
	}
	result, err := backend.Inspect(Text("A😀"), EventOptions{})
	if err != nil {
		t.Fatal(err)
	}
	wantUnits := []uint16{0x0041, 0xd83d, 0xde00}
	if result.Source != EventSourceDefault || result.Tap != EventTapHID || len(result.Events) != 2 {
		t.Fatalf("result = %+v", result)
	}
	for _, event := range result.Events {
		if event.KeyCode != 0 || event.Flags != 0 || !event.UnicodeComparable || !event.UnicodeMatches || !reflect.DeepEqual(event.Unicode, wantUnits) {
			t.Fatalf("event = %+v, want keycode 0 and units %#v", event, wantUnits)
		}
	}
	if len(fake.posts) != 0 || !reflect.DeepEqual(fake.releases, []uintptr{2, 1}) {
		t.Fatalf("posts=%d releases=%#v", len(fake.posts), fake.releases)
	}
	if !reflect.DeepEqual(fake.unicodeGets, []fakeUnicodeGetCall{{event: 1, maximumLength: 0}, {event: 1, maximumLength: 3}, {event: 2, maximumLength: 0}, {event: 2, maximumLength: 3}}) {
		t.Fatalf("Unicode getter calls = %#v", fake.unicodeGets)
	}
}

func TestInspectUsesSourceAndTapAndReleasesSource(t *testing.T) {
	fake := &fakeAPI{}
	backend, err := newBackend(fake)
	if err != nil {
		t.Fatal(err)
	}
	options := EventOptions{Source: EventSourcePrivate, Tap: EventTapAnnotated}
	result, err := backend.Inspect(Text("A"), options)
	if err != nil {
		t.Fatal(err)
	}
	if result.Source != options.Source || result.Tap != options.Tap {
		t.Fatalf("result options = %+v, want %+v", result, options)
	}
	if !reflect.DeepEqual(fake.sources, []fakeSourceCall{{stateID: -1}}) {
		t.Fatalf("sources = %#v", fake.sources)
	}
	if !reflect.DeepEqual(fake.creates, []fakeCreateCall{{source: 101, keyCode: 0, down: true}, {source: 101, keyCode: 0, down: false}}) {
		t.Fatalf("creates = %#v", fake.creates)
	}
	if len(fake.posts) != 0 || !reflect.DeepEqual(fake.releases, []uintptr{2, 1, 101}) {
		t.Fatalf("posts=%d releases=%#v", len(fake.posts), fake.releases)
	}
}

func TestInspectReadbackMismatchIsReportedAndStillReleases(t *testing.T) {
	fake := &fakeAPI{readback: map[uintptr][]uint16{1: {0x0042}, 2: {0x0042}}}
	backend, err := newBackend(fake)
	if err != nil {
		t.Fatal(err)
	}
	result, err := backend.Inspect(Text("A"), EventOptions{})
	if err != nil {
		t.Fatal(err)
	}
	for _, event := range result.Events {
		if event.UnicodeMatches {
			t.Fatalf("event unexpectedly matched: %+v", event)
		}
	}
	if len(fake.posts) != 0 || !reflect.DeepEqual(fake.releases, []uintptr{2, 1}) {
		t.Fatalf("posts=%d releases=%#v", len(fake.posts), fake.releases)
	}
}

func TestInspectOversizedReadbackReleasesEventsAndSource(t *testing.T) {
	oversized := make([]uint16, MaximumTextUTF16Units+1)
	fake := &fakeAPI{readback: map[uintptr][]uint16{1: oversized, 2: oversized}}
	backend, err := newBackend(fake)
	if err != nil {
		t.Fatal(err)
	}
	_, err = backend.Inspect(Text("A"), EventOptions{Source: EventSourceCombined})
	if !errors.Is(err, ErrUnicodeReadback) {
		t.Fatalf("Inspect error = %v, want Unicode readback failure", err)
	}
	if len(fake.posts) != 0 {
		t.Fatalf("posts = %d, want zero", len(fake.posts))
	}
	if !reflect.DeepEqual(fake.releases, []uintptr{2, 1, 101}) {
		t.Fatalf("releases = %#v, want [2 1 101]", fake.releases)
	}
}

func TestInspectAllocationFailuresReleaseAllOwnedResources(t *testing.T) {
	t.Run("source allocation", func(t *testing.T) {
		fake := &fakeAPI{failSource: true}
		backend, err := newBackend(fake)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := backend.Inspect(Text("A"), EventOptions{Source: EventSourceCombined}); !errors.Is(err, ErrSourceAllocation) {
			t.Fatalf("Inspect error = %v, want source allocation", err)
		}
		if len(fake.creates) != 0 || len(fake.posts) != 0 || len(fake.releases) != 0 {
			t.Fatalf("source allocation path touched resources: creates=%d posts=%d releases=%d", len(fake.creates), len(fake.posts), len(fake.releases))
		}
	})

	t.Run("second event allocation", func(t *testing.T) {
		fake := &fakeAPI{failCreate: 2}
		backend, err := newBackend(fake)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := backend.Inspect(Enter(), EventOptions{Source: EventSourceHID}); !errors.Is(err, ErrEventAllocation) {
			t.Fatalf("Inspect error = %v, want event allocation", err)
		}
		if len(fake.posts) != 0 || !reflect.DeepEqual(fake.releases, []uintptr{1, 101}) {
			t.Fatalf("posts=%d releases=%#v, want [1 101]", len(fake.posts), fake.releases)
		}
	})
}

func TestInvalidEventOptionsDoNotAllocateOrPost(t *testing.T) {
	fake := &fakeAPI{}
	backend, err := newBackend(fake)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := backend.Inspect(Text("A"), EventOptions{Source: EventSource(99)}); !errors.Is(err, ErrInvalidEventSource) {
		t.Fatalf("Inspect error = %v, want invalid source", err)
	}
	if _, err := backend.Inspect(Text("A"), EventOptions{Tap: EventTap(99)}); !errors.Is(err, ErrInvalidEventTap) {
		t.Fatalf("Inspect error = %v, want invalid tap", err)
	}
	if len(fake.sources) != 0 || len(fake.creates) != 0 || len(fake.posts) != 0 || len(fake.releases) != 0 {
		t.Fatalf("invalid options touched resources: sources=%d creates=%d posts=%d releases=%d", len(fake.sources), len(fake.creates), len(fake.posts), len(fake.releases))
	}
}

func TestPostWithOptionsUsesSelectedTapAndSource(t *testing.T) {
	fake := &fakeAPI{permission: []bool{true}}
	backend, err := newBackend(fake)
	if err != nil {
		t.Fatal(err)
	}
	options := EventOptions{Source: EventSourceCombined, Tap: EventTapSession}
	if err := backend.PostWithOptions(Enter(), 0, options); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(fake.sources, []fakeSourceCall{{stateID: 0}}) {
		t.Fatalf("sources = %#v", fake.sources)
	}
	if !reflect.DeepEqual(fake.posts, []fakePostCall{{tap: 1, event: 1}, {tap: 1, event: 2}}) {
		t.Fatalf("posts = %#v", fake.posts)
	}
	if !reflect.DeepEqual(fake.releases, []uintptr{2, 1, 101}) {
		t.Fatalf("releases = %#v", fake.releases)
	}
}

func TestPostRechecksPermissionAfterDelay(t *testing.T) {
	fake := &fakeAPI{permission: []bool{true, false}}
	backend, err := newBackend(fake)
	if err != nil {
		t.Fatal(err)
	}
	if err := backend.Post(Enter(), time.Nanosecond); !errors.Is(err, ErrPermissionDenied) {
		t.Fatalf("Post error = %v, want permission denied", err)
	}
	if len(fake.creates) != 0 || len(fake.posts) != 0 {
		t.Fatalf("post proceeded after permission changed: creates=%d posts=%d", len(fake.creates), len(fake.posts))
	}
}

func TestBenchmarkWarmIterationsNeverPost(t *testing.T) {
	fake := &fakeAPI{permission: []bool{false}}
	backend, err := newBackend(fake)
	if err != nil {
		t.Fatal(err)
	}
	result, err := backend.Benchmark(Text("1"), 3)
	if err != nil {
		t.Fatal(err)
	}
	if result.Iterations != 3 || len(result.Samples) != 3 {
		t.Fatalf("result = %+v", result)
	}
	if len(fake.posts) != 0 || len(fake.creates) != 8 || len(fake.releases) != 8 || len(fake.unicodes) != 8 {
		t.Fatalf("benchmark event counts: creates=%d posts=%d releases=%d", len(fake.creates), len(fake.posts), len(fake.releases))
	}
}

func TestActionLimitsAndInvalidForms(t *testing.T) {
	if err := Text(string(make([]byte, MaximumTextUTF16Units+1))).Validate(); !errors.Is(err, ErrInvalidText) && !errors.Is(err, ErrTextTooLong) {
		t.Fatalf("long invalid-byte text error = %v", err)
	}
	if err := Text(string(make([]rune, MaximumTextUTF16Units+1))).Validate(); !errors.Is(err, ErrTextTooLong) {
		t.Fatalf("long text error = %v, want too long", err)
	}
	if err := (Action{Kind: ActionEnter, KeyCode: 0}).Validate(); !errors.Is(err, ErrInvalidAction) {
		t.Fatalf("invalid enter error = %v", err)
	}
	if err := validateBenchmarkIterations(0); !errors.Is(err, ErrInvalidBenchmarkCount) {
		t.Fatalf("zero benchmark error = %v", err)
	}
	if err := validateBenchmarkIterations(MaximumBenchmarkIterations + 1); !errors.Is(err, ErrInvalidBenchmarkCount) {
		t.Fatalf("large benchmark error = %v", err)
	}
	if err := validateDelay(-1); !errors.Is(err, ErrInvalidDelay) {
		t.Fatalf("negative delay error = %v", err)
	}
}
