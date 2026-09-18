package nativeinput

import (
	"fmt"
	"runtime"
	"sort"
	"time"
)

const (
	hidEventTap        uint32 = 0
	textVirtualKeyCode uint16 = 0

	keyDownEventType          uint32 = 10
	keyUpEventType            uint32 = 11
	keyboardEventKeycodeField uint32 = 9
)

type EventSource uint8

const (
	EventSourceDefault EventSource = iota
	EventSourcePrivate
	EventSourceCombined
	EventSourceHID
)

func (source EventSource) String() string {
	switch source {
	case EventSourceDefault:
		return "default"
	case EventSourcePrivate:
		return "private"
	case EventSourceCombined:
		return "combined"
	case EventSourceHID:
		return "hid"
	default:
		return "unknown"
	}
}

func ParseEventSource(value string) (EventSource, error) {
	switch value {
	case "default":
		return EventSourceDefault, nil
	case "private":
		return EventSourcePrivate, nil
	case "combined":
		return EventSourceCombined, nil
	case "hid":
		return EventSourceHID, nil
	default:
		return EventSourceDefault, fmt.Errorf("%w: %q", ErrInvalidEventSource, value)
	}
}

func (source EventSource) stateID() (int32, bool) {
	switch source {
	case EventSourceDefault:
		return 0, true
	case EventSourcePrivate:
		return -1, true
	case EventSourceCombined:
		return 0, true
	case EventSourceHID:
		return 1, true
	default:
		return 0, false
	}
}

func (source EventSource) StateID() (int32, bool) {
	if source == EventSourceDefault {
		return 0, true
	}
	return source.stateID()
}

type EventTap uint8

const (
	EventTapHID EventTap = iota
	EventTapSession
	EventTapAnnotated
)

func (tap EventTap) String() string {
	switch tap {
	case EventTapHID:
		return "hid"
	case EventTapSession:
		return "session"
	case EventTapAnnotated:
		return "annotated"
	default:
		return "unknown"
	}
}

func ParseEventTap(value string) (EventTap, error) {
	switch value {
	case "hid":
		return EventTapHID, nil
	case "session":
		return EventTapSession, nil
	case "annotated":
		return EventTapAnnotated, nil
	default:
		return EventTapHID, fmt.Errorf("%w: %q", ErrInvalidEventTap, value)
	}
}

func (tap EventTap) id() (uint32, bool) {
	switch tap {
	case EventTapHID, EventTapSession, EventTapAnnotated:
		return uint32(tap), true
	default:
		return 0, false
	}
}

func (tap EventTap) ID() (uint32, bool) {
	return tap.id()
}

type EventOptions struct {
	Source EventSource
	Tap    EventTap
}

func (options EventOptions) Validate() error {
	if _, valid := options.Source.stateID(); !valid {
		return fmt.Errorf("%w: %d", ErrInvalidEventSource, options.Source)
	}
	if _, valid := options.Tap.id(); !valid {
		return fmt.Errorf("%w: %d", ErrInvalidEventTap, options.Tap)
	}
	return nil
}

type EventInspection struct {
	EventType         uint32
	KeyCode           int64
	Flags             uint64
	Unicode           []uint16
	UnicodeMatches    bool
	UnicodeComparable bool
}

type InspectResult struct {
	Source EventSource
	Tap    EventTap
	Events []EventInspection
}

type eventAPI interface {
	preflightPostEventAccess() bool
	createEventSource(stateID int32) uintptr
	createKeyboardEvent(source uintptr, virtualKey uint16, keyDown bool) uintptr
	keyboardSetUnicodeString(event uintptr, stringLength uint64, unicodeString *uint16)
	keyboardGetUnicodeString(event uintptr, maximumLength uint64, actualLength *uint64, unicodeString *uint16)
	eventType(event uintptr) uint32
	eventFlags(event uintptr) uint64
	eventIntegerValueField(event uintptr, field uint32) int64
	postEvent(tap uint32, event uintptr)
	release(event uintptr)
}

type Backend struct {
	api eventAPI
}

func newBackend(api eventAPI) (*Backend, error) {
	if api == nil {
		return nil, fmt.Errorf("%w: nil native API", ErrUnsupportedPlatform)
	}
	return &Backend{api: api}, nil
}

func New() (*Backend, error) {
	return newNativeBackend()
}

func (b *Backend) Check() (bool, error) {
	if b == nil || b.api == nil {
		return false, ErrUnsupportedPlatform
	}
	return b.api.preflightPostEventAccess(), nil
}

func (b *Backend) Post(action Action, delay time.Duration) error {
	return b.PostWithOptions(action, delay, EventOptions{})
}

func (b *Backend) PostWithOptions(action Action, delay time.Duration, options EventOptions) error {
	if b == nil || b.api == nil {
		return ErrUnsupportedPlatform
	}
	if err := action.Validate(); err != nil {
		return err
	}
	if err := options.Validate(); err != nil {
		return err
	}
	if err := validateDelay(delay); err != nil {
		return err
	}
	if !b.api.preflightPostEventAccess() {
		return ErrPermissionDenied
	}
	if delay > 0 {
		time.Sleep(delay)
		if !b.api.preflightPostEventAccess() {
			return ErrPermissionDenied
		}
	}

	pair, source, err := b.allocateWithOptions(action, options)
	if err != nil {
		return err
	}
	defer b.releaseAllocated(pair, source)
	tap, _ := options.Tap.id()
	b.api.postEvent(tap, pair.down)
	b.api.postEvent(tap, pair.up)
	return nil
}

type eventPair struct {
	down uintptr
	up   uintptr
}

func (b *Backend) allocate(action Action) (eventPair, error) {
	pair, _, err := b.allocateWithOptions(action, EventOptions{})
	return pair, err
}

func (b *Backend) allocateWithOptions(action Action, options EventOptions) (eventPair, uintptr, error) {
	if err := options.Validate(); err != nil {
		return eventPair{}, 0, err
	}
	units, err := action.utf16Units()
	if err != nil {
		return eventPair{}, 0, err
	}

	var source uintptr
	if options.Source != EventSourceDefault {
		stateID, _ := options.Source.stateID()
		source = b.api.createEventSource(stateID)
		if source == 0 {
			return eventPair{}, 0, ErrSourceAllocation
		}
	}

	pair, err := b.allocateFromSource(action, units, source)
	if err != nil {
		if source != 0 {
			b.api.release(source)
		}
		return eventPair{}, 0, err
	}
	return pair, source, nil
}

func (b *Backend) allocateFromSource(action Action, units []uint16, source uintptr) (eventPair, error) {

	virtualKey := action.KeyCode
	if action.Kind == ActionText {
		virtualKey = textVirtualKeyCode
	}
	down := b.api.createKeyboardEvent(source, virtualKey, true)
	if down == 0 {
		return eventPair{}, ErrEventAllocation
	}
	up := b.api.createKeyboardEvent(source, virtualKey, false)
	if up == 0 {
		b.api.release(down)
		return eventPair{}, ErrEventAllocation
	}

	if len(units) != 0 {
		unicodeString := &units[0]
		b.api.keyboardSetUnicodeString(down, uint64(len(units)), unicodeString)
		runtime.KeepAlive(units)
		b.api.keyboardSetUnicodeString(up, uint64(len(units)), unicodeString)
		runtime.KeepAlive(units)
	}
	return eventPair{down: down, up: up}, nil
}

func (b *Backend) Inspect(action Action, options EventOptions) (InspectResult, error) {
	if b == nil || b.api == nil {
		return InspectResult{}, ErrUnsupportedPlatform
	}
	if err := action.Validate(); err != nil {
		return InspectResult{}, err
	}
	if err := options.Validate(); err != nil {
		return InspectResult{}, err
	}
	units, err := action.utf16Units()
	if err != nil {
		return InspectResult{}, err
	}
	pair, source, err := b.allocateWithOptions(action, options)
	if err != nil {
		return InspectResult{}, err
	}
	defer b.releaseAllocated(pair, source)

	inspected := make([]EventInspection, 0, 2)
	for _, event := range []uintptr{pair.down, pair.up} {
		readback, err := b.inspectEvent(event, units, action.Kind == ActionText)
		if err != nil {
			return InspectResult{}, err
		}
		inspected = append(inspected, readback)
	}
	return InspectResult{Source: options.Source, Tap: options.Tap, Events: inspected}, nil
}

func (b *Backend) inspectEvent(event uintptr, expected []uint16, compareUnicode bool) (EventInspection, error) {
	unicode, err := b.readUnicode(event)
	if err != nil {
		return EventInspection{}, err
	}
	return EventInspection{
		EventType:         b.api.eventType(event),
		KeyCode:           b.api.eventIntegerValueField(event, keyboardEventKeycodeField),
		Flags:             b.api.eventFlags(event),
		Unicode:           unicode,
		UnicodeMatches:    compareUnicode && equalUTF16(expected, unicode),
		UnicodeComparable: compareUnicode,
	}, nil
}

func (b *Backend) readUnicode(event uintptr) ([]uint16, error) {
	var length uint64
	b.api.keyboardGetUnicodeString(event, 0, &length, nil)
	if length == 0 {
		return nil, nil
	}
	if length > MaximumTextUTF16Units {
		return nil, ErrUnicodeReadback
	}
	units := make([]uint16, length)
	var actualLength uint64
	b.api.keyboardGetUnicodeString(event, length, &actualLength, &units[0])
	if actualLength > length {
		return nil, ErrUnicodeReadback
	}
	return units[:actualLength], nil
}

func equalUTF16(left, right []uint16) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}

func (b *Backend) releaseAllocated(pair eventPair, source uintptr) {
	if pair.up != 0 {
		b.api.release(pair.up)
	}
	if pair.down != 0 {
		b.api.release(pair.down)
	}
	if source != 0 {
		b.api.release(source)
	}
}

type BenchmarkResult struct {
	Iterations int
	Samples    []time.Duration
	Minimum    time.Duration
	Median     time.Duration
	P95        time.Duration
	Maximum    time.Duration
}

func (b *Backend) Benchmark(action Action, iterations int) (BenchmarkResult, error) {
	return b.BenchmarkWithOptions(action, iterations, EventOptions{})
}

func (b *Backend) BenchmarkWithOptions(action Action, iterations int, options EventOptions) (BenchmarkResult, error) {
	if b == nil || b.api == nil {
		return BenchmarkResult{}, ErrUnsupportedPlatform
	}
	if err := action.Validate(); err != nil {
		return BenchmarkResult{}, err
	}
	if err := options.Validate(); err != nil {
		return BenchmarkResult{}, err
	}
	if err := validateBenchmarkIterations(iterations); err != nil {
		return BenchmarkResult{}, err
	}
	if err := b.constructAndReleaseWithOptions(action, options); err != nil {
		return BenchmarkResult{}, err
	}

	samples := make([]time.Duration, iterations)
	for index := range samples {
		started := time.Now()
		if err := b.constructAndReleaseWithOptions(action, options); err != nil {
			return BenchmarkResult{}, fmt.Errorf("benchmark iteration %d: %w", index+1, err)
		}
		samples[index] = time.Since(started)
	}
	distribution := append([]time.Duration(nil), samples...)
	sort.Slice(distribution, func(left, right int) bool { return distribution[left] < distribution[right] })
	p95Index := (len(distribution)*95+99)/100 - 1
	return BenchmarkResult{
		Iterations: iterations,
		Samples:    samples,
		Minimum:    distribution[0],
		Median:     distribution[len(distribution)/2],
		P95:        distribution[p95Index],
		Maximum:    distribution[len(distribution)-1],
	}, nil
}

func (b *Backend) constructAndRelease(action Action) error {
	return b.constructAndReleaseWithOptions(action, EventOptions{})
}

func (b *Backend) constructAndReleaseWithOptions(action Action, options EventOptions) error {
	pair, source, err := b.allocateWithOptions(action, options)
	if err != nil {
		return err
	}
	b.releaseAllocated(pair, source)
	return nil
}
