package d200x

import (
	"context"
	"errors"
	"reflect"
	"sync"
	"testing"
	"time"
)

type fakeTransport struct {
	mu       sync.Mutex
	writes   [][]byte
	reads    [][]byte
	writeN   int
	writeErr error
	readErr  error
	closed   bool
	closeErr error
	onClose  func()
}

type blockingReadTransport struct {
	started   chan struct{}
	closedCh  chan struct{}
	startOnce sync.Once
	closeOnce sync.Once
	mu        sync.Mutex
	closed    bool
}

func newBlockingReadTransport() *blockingReadTransport {
	return &blockingReadTransport{
		started:  make(chan struct{}),
		closedCh: make(chan struct{}),
	}
}

func (t *blockingReadTransport) Read(ctx context.Context, _ []byte) (int, error) {
	t.startOnce.Do(func() { close(t.started) })
	select {
	case <-ctx.Done():
		return 0, ctx.Err()
	case <-t.closedCh:
		return 0, context.Canceled
	}
}

func (t *blockingReadTransport) Write(_ context.Context, report []byte) (int, error) {
	return len(report), nil
}

func (t *blockingReadTransport) Close() error {
	t.closeOnce.Do(func() { close(t.closedCh) })
	t.mu.Lock()
	t.closed = true
	t.mu.Unlock()
	return nil
}

func (t *blockingReadTransport) isClosed() bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.closed
}

func (t *fakeTransport) Read(_ context.Context, report []byte) (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.readErr != nil {
		return 0, t.readErr
	}
	if len(t.reads) == 0 {
		return 0, context.DeadlineExceeded
	}
	data := t.reads[0]
	t.reads = t.reads[1:]
	return copy(report, data), nil
}

func (t *fakeTransport) Write(_ context.Context, report []byte) (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.writes = append(t.writes, append([]byte(nil), report...))
	if t.writeErr != nil {
		return 0, t.writeErr
	}
	if t.writeN > 0 {
		return t.writeN, nil
	}
	return len(report), nil
}

func (t *fakeTransport) Close() error {
	t.mu.Lock()
	t.closed = true
	onClose := t.onClose
	err := t.closeErr
	t.mu.Unlock()
	if onClose != nil {
		onClose()
	}
	return err
}

type fakeFactory struct {
	mu          sync.Mutex
	transports  map[string]Transport
	openCalls   []Candidate
	openFailure error
	onOpen      func(Candidate)
}

func (f *fakeFactory) Enumerate(_ context.Context) ([]Candidate, error) {
	return nil, nil
}

func (f *fakeFactory) Open(_ context.Context, candidate Candidate) (Transport, error) {
	f.mu.Lock()
	f.openCalls = append(f.openCalls, candidate)
	onOpen := f.onOpen
	openFailure := f.openFailure
	transport := f.transports[candidate.path]
	f.mu.Unlock()
	if onOpen != nil {
		onOpen(candidate)
	}
	if openFailure != nil {
		return nil, openFailure
	}
	if transport == nil {
		return nil, errors.New("unknown fake candidate")
	}
	return transport, nil
}

func TestSessionReplacementClosesPreviousAndSerializesFrameWrites(t *testing.T) {
	first := NewCandidate("first", VendorID, ProductID, InterfaceNumber)
	second := NewCandidate("second", VendorID, ProductID, InterfaceNumber)
	firstTransport := &fakeTransport{}
	secondTransport := &fakeTransport{}
	var order []string
	firstTransport.onClose = func() { order = append(order, "close-first") }
	factory := &fakeFactory{transports: map[string]Transport{
		first.path:  firstTransport,
		second.path: secondTransport,
	}}
	factory.onOpen = func(candidate Candidate) { order = append(order, "open-"+candidate.path) }
	session := NewSession(factory)

	if err := session.Replace(context.Background(), first); err != nil {
		t.Fatal(err)
	}
	if err := session.SendFrame(context.Background(), NewFrame(CommandCompleteDisplayUpload, syntheticPayload(2_041))); err != nil {
		t.Fatal(err)
	}
	if len(firstTransport.writes) != 3 {
		t.Fatalf("writes = %d, want 3", len(firstTransport.writes))
	}
	for index, report := range firstTransport.writes {
		if len(report) != TransportReportSize || report[0] != ReportIdentifier {
			t.Fatalf("write %d = length %d, ID %d", index, len(report), report[0])
		}
	}

	if err := session.Replace(context.Background(), second); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(order, []string{"open-first", "close-first", "open-second"}) {
		t.Fatalf("replacement order = %v", order)
	}
	if !firstTransport.closed {
		t.Fatal("previous transport was not closed during replacement")
	}
	if current, ok := session.Current(); !ok || current != second {
		t.Fatalf("current candidate = %#v, active=%v", current, ok)
	}
	if err := session.Close(); err != nil {
		t.Fatal(err)
	}
	if !secondTransport.closed {
		t.Fatal("active transport was not closed")
	}
	if _, ok := session.Current(); ok {
		t.Fatal("closed session still has an active transport")
	}
}

func TestReplacementOpenFailureLeavesSessionUnavailableWithCause(t *testing.T) {
	first := NewCandidate("first", VendorID, ProductID, InterfaceNumber)
	second := NewCandidate("second", VendorID, ProductID, InterfaceNumber)
	openFailure := errors.New("replacement unavailable")
	firstTransport := &fakeTransport{}
	secondTransport := &fakeTransport{}
	factory := &fakeFactory{transports: map[string]Transport{
		first.path:  firstTransport,
		second.path: secondTransport,
	}}
	session := NewSession(factory)
	if err := session.Replace(context.Background(), first); err != nil {
		t.Fatal(err)
	}
	factory.openFailure = openFailure
	if err := session.Replace(context.Background(), second); !errors.Is(err, openFailure) {
		t.Fatalf("replacement error = %v", err)
	}
	if !firstTransport.closed {
		t.Fatal("old transport was not closed before failed replacement")
	}
	if _, ok := session.Current(); ok {
		t.Fatal("failed replacement still reports an active transport")
	}
	if !errors.Is(session.LastError(), openFailure) {
		t.Fatalf("last replacement error = %v", session.LastError())
	}
	if _, err := session.Read(context.Background(), make([]byte, TransportReportSize)); !errors.Is(err, openFailure) {
		t.Fatalf("read after failed replacement = %v", err)
	}

	factory.openFailure = nil
	if err := session.Replace(context.Background(), second); err != nil {
		t.Fatal(err)
	}
	if current, ok := session.Current(); !ok || current != second {
		t.Fatalf("recovered replacement = %#v, active=%v", current, ok)
	}
}

func TestReplacementDoesNotOpenWhenPreviousCloseFails(t *testing.T) {
	first := NewCandidate("first", VendorID, ProductID, InterfaceNumber)
	second := NewCandidate("second", VendorID, ProductID, InterfaceNumber)
	closeFailure := errors.New("close failed")
	firstTransport := &fakeTransport{closeErr: closeFailure}
	secondTransport := &fakeTransport{}
	factory := &fakeFactory{transports: map[string]Transport{
		first.path:  firstTransport,
		second.path: secondTransport,
	}}
	session := NewSession(factory)
	if err := session.Replace(context.Background(), first); err != nil {
		t.Fatal(err)
	}
	if err := session.Replace(context.Background(), second); !errors.Is(err, closeFailure) {
		t.Fatalf("close failure = %v", err)
	}
	if len(factory.openCalls) != 1 {
		t.Fatalf("open calls after close failure = %d, want 1", len(factory.openCalls))
	}
	if _, ok := session.Current(); ok {
		t.Fatal("close-failed replacement still reports an active transport")
	}
}

func TestSessionRejectsNonmatchingCandidateBeforeOpening(t *testing.T) {
	factory := &fakeFactory{transports: map[string]Transport{}}
	session := NewSession(factory)
	nonmatching := NewCandidate("keyboard", VendorID, ProductID, 1)
	if err := session.Replace(context.Background(), nonmatching); !hasProtocolKind(err, ErrorIneligibleDevice) {
		t.Fatalf("replacement error = %v", err)
	}
	if len(factory.openCalls) != 0 {
		t.Fatalf("factory opened %d ineligible candidates", len(factory.openCalls))
	}
}

func TestSessionRejectsUnsafeOutboundCommandsWithoutWriting(t *testing.T) {
	candidate := NewCandidate("first", VendorID, ProductID, InterfaceNumber)
	transport := &fakeTransport{}
	factory := &fakeFactory{transports: map[string]Transport{candidate.path: transport}}
	session := NewSession(factory)
	if err := session.Replace(context.Background(), candidate); err != nil {
		t.Fatal(err)
	}
	for _, command := range []Command{Command(0xBEEF), CommandLockScreen, CommandInputEvent} {
		err := session.SendFrame(context.Background(), NewFrame(command, nil))
		var protocolErr *ProtocolError
		if !errors.As(err, &protocolErr) || protocolErr.Kind != ErrorUnsafeOutboundCommand || protocolErr.Command != command {
			t.Fatalf("command %s error = %#v", command, err)
		}
	}
	if len(transport.writes) != 0 {
		t.Fatalf("unsafe commands produced %d writes", len(transport.writes))
	}
}

func TestFailedWriteInvalidatesSessionAndDoesNotRetry(t *testing.T) {
	candidate := NewCandidate("first", VendorID, ProductID, InterfaceNumber)
	transport := &fakeTransport{writeN: TransportReportSize - 1}
	factory := &fakeFactory{transports: map[string]Transport{candidate.path: transport}}
	session := NewSession(factory)
	if err := session.Replace(context.Background(), candidate); err != nil {
		t.Fatal(err)
	}
	err := session.SendFrame(context.Background(), EnableInputStreamFrame())
	if !hasProtocolKind(err, ErrorTransportShortWrite) {
		t.Fatalf("short write error = %v", err)
	}
	if len(transport.writes) != 1 {
		t.Fatalf("short write was retried %d times", len(transport.writes))
	}
	if !transport.closed {
		t.Fatal("failed transport was not closed")
	}
	if _, ok := session.Current(); ok {
		t.Fatal("failed session remains active")
	}
}

func TestSessionReadUsesCurrentReplacement(t *testing.T) {
	first := NewCandidate("first", VendorID, ProductID, InterfaceNumber)
	second := NewCandidate("second", VendorID, ProductID, InterfaceNumber)
	firstTransport := &fakeTransport{reads: [][]byte{{1, 2, 3}}}
	secondTransport := &fakeTransport{reads: [][]byte{{4, 5, 6}}}
	factory := &fakeFactory{transports: map[string]Transport{
		first.path:  firstTransport,
		second.path: secondTransport,
	}}
	session := NewSession(factory)
	if err := session.Replace(context.Background(), first); err != nil {
		t.Fatal(err)
	}
	buffer := make([]byte, 3)
	if n, err := session.Read(context.Background(), buffer); err != nil || n != 3 || !reflect.DeepEqual(buffer, []byte{1, 2, 3}) {
		t.Fatalf("first read = %d, %v, %v", n, err, buffer)
	}
	if err := session.Replace(context.Background(), second); err != nil {
		t.Fatal(err)
	}
	if n, err := session.Read(context.Background(), buffer); err != nil || n != 3 || !reflect.DeepEqual(buffer, []byte{4, 5, 6}) {
		t.Fatalf("replacement read = %d, %v, %v", n, err, buffer)
	}
}

func TestSessionReplacementCancelsInFlightReadBeforeOpening(t *testing.T) {
	first := NewCandidate("first", VendorID, ProductID, InterfaceNumber)
	second := NewCandidate("second", VendorID, ProductID, InterfaceNumber)
	firstTransport := newBlockingReadTransport()
	secondTransport := &fakeTransport{}
	var openedAfterClose bool
	factory := &fakeFactory{transports: map[string]Transport{
		first.path:  firstTransport,
		second.path: secondTransport,
	}}
	factory.onOpen = func(candidate Candidate) {
		if candidate.path == second.path {
			openedAfterClose = firstTransport.isClosed()
		}
	}
	session := NewSession(factory)
	if err := session.Replace(context.Background(), first); err != nil {
		t.Fatal(err)
	}
	readResult := make(chan error, 1)
	go func() {
		_, err := session.Read(context.Background(), make([]byte, TransportReportSize))
		readResult <- err
	}()
	select {
	case <-firstTransport.started:
	case <-time.After(time.Second):
		t.Fatal("read did not start")
	}
	if err := session.Replace(context.Background(), second); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-readResult:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("replacement read error = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("replacement did not cancel in-flight read")
	}
	if !openedAfterClose {
		t.Fatal("replacement opened before closing the old transport")
	}
}

func TestSessionCloseCancelsInFlightReadWithoutDeadlock(t *testing.T) {
	candidate := NewCandidate("first", VendorID, ProductID, InterfaceNumber)
	transport := newBlockingReadTransport()
	factory := &fakeFactory{transports: map[string]Transport{candidate.path: transport}}
	session := NewSession(factory)
	if err := session.Replace(context.Background(), candidate); err != nil {
		t.Fatal(err)
	}
	readResult := make(chan error, 1)
	go func() {
		_, err := session.Read(context.Background(), make([]byte, TransportReportSize))
		readResult <- err
	}()
	select {
	case <-transport.started:
	case <-time.After(time.Second):
		t.Fatal("read did not start")
	}
	closeResult := make(chan error, 1)
	go func() { closeResult <- session.Close() }()
	select {
	case err := <-closeResult:
		if err != nil {
			t.Fatalf("session close error = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("session close deadlocked on in-flight read")
	}
	select {
	case err := <-readResult:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("close read error = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("close did not drain in-flight read")
	}
	if !transport.isClosed() {
		t.Fatal("close did not close the active transport")
	}
}
