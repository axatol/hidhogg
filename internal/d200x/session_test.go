package d200x

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"strings"
	"sync"
	"testing"
	"time"
)

type fakeTransport struct {
	mu           sync.Mutex
	writes       [][]byte
	writeCalls   int
	activeWrites int
	maxActive    int
	writeDelay   time.Duration
	failAt       int
	failErr      error
	shortAt      int

	readReports   [][]byte
	blockRead     bool
	readStarted   chan struct{}
	readStartOnce sync.Once
	closed        chan struct{}
	closeOnce     sync.Once
	closeCount    int
}

func newFakeTransport() *fakeTransport {
	return &fakeTransport{
		readStarted: make(chan struct{}),
		closed:      make(chan struct{}),
	}
}

func (transport *fakeTransport) Read(ctx context.Context, report []byte) (int, error) {
	transport.readStartOnce.Do(func() { close(transport.readStarted) })
	transport.mu.Lock()
	if len(transport.readReports) > 0 {
		queued := transport.readReports[0]
		transport.readReports = transport.readReports[1:]
		transport.mu.Unlock()
		if len(queued) > len(report) {
			return 0, fmt.Errorf("fake report exceeds destination")
		}
		copy(report, queued)
		return len(queued), nil
	}
	block := transport.blockRead
	transport.mu.Unlock()
	if !block {
		return 0, io.EOF
	}
	select {
	case <-ctx.Done():
		return 0, ctx.Err()
	case <-transport.closed:
		if err := ctx.Err(); err != nil {
			return 0, err
		}
		return 0, errors.New("fake transport closed")
	}
}

func (transport *fakeTransport) Write(_ context.Context, report []byte) (int, error) {
	transport.mu.Lock()
	transport.writeCalls++
	call := transport.writeCalls
	transport.writes = append(transport.writes, append([]byte(nil), report...))
	transport.activeWrites++
	if transport.activeWrites > transport.maxActive {
		transport.maxActive = transport.activeWrites
	}
	delay := transport.writeDelay
	var writeErr error
	if call == transport.failAt {
		writeErr = transport.failErr
	}
	short := call == transport.shortAt
	transport.mu.Unlock()

	if delay > 0 {
		time.Sleep(delay)
	}
	transport.mu.Lock()
	transport.activeWrites--
	transport.mu.Unlock()
	if writeErr != nil {
		return 0, writeErr
	}
	if short {
		return len(report) - 1, nil
	}
	return len(report), nil
}

func (transport *fakeTransport) Close() error {
	transport.mu.Lock()
	transport.closeCount++
	transport.mu.Unlock()
	transport.closeOnce.Do(func() { close(transport.closed) })
	return nil
}

func (transport *fakeTransport) snapshotWrites() [][]byte {
	transport.mu.Lock()
	defer transport.mu.Unlock()
	result := make([][]byte, len(transport.writes))
	for index := range transport.writes {
		result[index] = append([]byte(nil), transport.writes[index]...)
	}
	return result
}

func (transport *fakeTransport) stats() (writeCalls, maxActive, closeCount int) {
	transport.mu.Lock()
	defer transport.mu.Unlock()
	return transport.writeCalls, transport.maxActive, transport.closeCount
}

type fakeFactory struct {
	transport Transport
	openErr   error
	mu        sync.Mutex
	openCount int
	selected  Candidate
}

func (factory *fakeFactory) Enumerate(context.Context) ([]Candidate, error) {
	return nil, nil
}

func (factory *fakeFactory) Open(_ context.Context, candidate Candidate) (Transport, error) {
	factory.mu.Lock()
	factory.openCount++
	factory.selected = candidate
	factory.mu.Unlock()
	if factory.openErr != nil {
		return nil, factory.openErr
	}
	return factory.transport, nil
}

type recordingInputSink struct {
	mu     sync.Mutex
	events []InputDiagnostic
}

func (sink *recordingInputSink) InputEvent(event InputDiagnostic) {
	sink.mu.Lock()
	sink.events = append(sink.events, event)
	sink.mu.Unlock()
}

func (sink *recordingInputSink) snapshot() []InputDiagnostic {
	sink.mu.Lock()
	defer sink.mu.Unlock()
	return append([]InputDiagnostic(nil), sink.events...)
}

func openTestSession(t *testing.T, transport Transport, options ...SessionOptions) (*Session, Candidate) {
	t.Helper()
	candidate := NewCandidate("/private/hid/path/serial=do-not-log", VendorID, ProductID, InterfaceNumber)
	session := NewSession(&fakeFactory{transport: transport}, options...)
	if err := session.Open(context.Background(), candidate); err != nil {
		t.Fatalf("Session.Open: %v", err)
	}
	return session, candidate
}

func TestSessionSendPageWritesUploadThenBrightnessUnlockAndInputEnable(t *testing.T) {
	transport := newFakeTransport()
	session, _ := openTestSession(t, transport)
	if err := session.SendPage(context.Background(), configuredTestPage(), 73); err != nil {
		t.Fatalf("SendPage: %v", err)
	}
	commands, err := commandsFromReports(transport.snapshotWrites())
	if err != nil {
		t.Fatal(err)
	}
	want := []Command{
		CommandCompleteDisplayUpload,
		CommandBrightness,
		CommandUnlockScreen,
		CommandEnableInputStream,
	}
	if len(commands) != len(want) {
		t.Fatalf("commands = %v, want %v", commands, want)
	}
	for index := range want {
		if commands[index] != want[index] {
			t.Fatalf("command %d = %s, want %s", index, commands[index], want[index])
		}
	}
	if err := session.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestSessionSerializesConcurrentWrites(t *testing.T) {
	transport := newFakeTransport()
	transport.writeDelay = time.Millisecond
	session, _ := openTestSession(t, transport)
	var wait sync.WaitGroup
	for _, frame := range []Frame{BrightnessFrame(10), UnlockScreenFrame(), EnableInputStreamFrame()} {
		frame := frame
		wait.Add(1)
		go func() {
			defer wait.Done()
			if err := session.SendFrame(context.Background(), frame); err != nil {
				t.Errorf("SendFrame(%s): %v", frame.Command, err)
			}
		}()
	}
	wait.Wait()
	_, maxActive, _ := transport.stats()
	if maxActive != 1 {
		t.Fatalf("concurrent transport writes = %d, want 1", maxActive)
	}
	_ = session.Close()
}

func TestSessionShortOrFailedWriteInvalidatesWithoutRetry(t *testing.T) {
	tests := []struct {
		name       string
		short      bool
		failure    error
		wantKind   ProtocolErrorKind
		wantRedact string
	}{
		{name: "short", short: true, wantKind: ErrorTransportShortWrite},
		{name: "failed", failure: errors.New("hidraw=/private/secret serial=private-token"), wantRedact: "private-token"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			transport := newFakeTransport()
			transport.shortAt = 1
			if test.failure != nil {
				transport.shortAt = 0
				transport.failAt = 1
				transport.failErr = test.failure
			}
			session, _ := openTestSession(t, transport)
			err := session.SendFrame(context.Background(), BrightnessFrame(20))
			if test.short {
				if !hasProtocolKind(err, test.wantKind) {
					t.Fatalf("error = %v, want %s", err, test.wantKind)
				}
			} else {
				if err == nil || strings.Contains(err.Error(), test.wantRedact) || errors.Is(err, test.failure) {
					t.Fatalf("failed write was not redacted: %v", err)
				}
				if errors.Unwrap(err) != nil {
					t.Fatalf("sanitized write error unwrap = %v, want nil", errors.Unwrap(err))
				}
			}
			calls, _, closes := transport.stats()
			if calls != 1 || closes != 1 {
				t.Fatalf("write calls=%d close calls=%d, want one each", calls, closes)
			}
			if _, active := session.Current(); active {
				t.Fatal("session remained active after failed write")
			}
			last := session.LastError()
			if last == nil || (test.wantRedact != "" && strings.Contains(last.Error(), test.wantRedact)) || (test.failure != nil && errors.Is(last, test.failure)) {
				t.Fatalf("last error leaked failed write: %v", last)
			}
			if retryErr := session.SendFrame(context.Background(), BrightnessFrame(20)); retryErr == nil {
				t.Fatal("session retried write after uncertain failure")
			}
			calls, _, _ = transport.stats()
			if calls != 1 {
				t.Fatalf("write calls after retry attempt = %d, want 1", calls)
			}
		})
	}
}

func TestSessionReadCancellationClosesAndDrainsTransport(t *testing.T) {
	transport := newFakeTransport()
	transport.blockRead = true
	session, _ := openTestSession(t, transport)
	readDone := make(chan error, 1)
	go func() {
		_, err := session.Read(context.Background(), make([]byte, TransportReportSize))
		readDone <- err
	}()
	select {
	case <-transport.readStarted:
	case <-time.After(time.Second):
		t.Fatal("read did not start")
	}
	if err := session.Close(); err != nil {
		t.Fatalf("Session.Close: %v", err)
	}
	select {
	case err := <-readDone:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("read cancellation error = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("Session.Close did not drain read")
	}
	if _, active := session.Current(); active {
		t.Fatal("closed session remained active")
	}
	_, _, closes := transport.stats()
	if closes != 1 {
		t.Fatalf("transport close calls = %d, want 1", closes)
	}
}

func TestSessionReadInputPreservesUnknownValuesAndEmitsBoundedEvent(t *testing.T) {
	inputPayload := []byte{0xa5, 13, 0xf4, 0xf5, 0x41}
	reports, err := EncodeFrame(NewFrame(CommandInputEvent, inputPayload))
	if err != nil {
		t.Fatal(err)
	}
	transport := newFakeTransport()
	transport.readReports = reports
	sink := &recordingInputSink{}
	session, _ := openTestSession(t, transport, SessionOptions{Sink: sink})
	event, ok, err := session.ReadInput(context.Background())
	if err != nil || !ok {
		t.Fatalf("ReadInput: event=%+v ok=%t err=%v", event, ok, err)
	}
	if event.DeviceState != inputPayload[0] || event.WireIndex != inputPayload[1] || byte(event.Marker) != inputPayload[2] || byte(event.Action) != inputPayload[3] || !bytes.Equal(event.RawPayload, inputPayload) {
		t.Fatalf("ReadInput lost unknown values: %+v", event)
	}
	if event.Marker.IsKnown() || event.Action.IsKnown() {
		t.Fatal("unknown input value was classified as known")
	}
	events := sink.snapshot()
	if len(events) != 1 || events[0].WireIndex != inputPayload[1] || byte(events[0].Marker) != inputPayload[2] || byte(events[0].Action) != inputPayload[3] || events[0].PayloadBytes != len(inputPayload) {
		t.Fatalf("input diagnostics = %+v", events)
	}
	_ = session.Close()
}

func TestVerboseDiagnosticsAreBoundedAndOptIn(t *testing.T) {
	if got := (SessionOptions{MaxDiagnosticLineBytes: 1 << 20}).lineLimit(); got != maximumDiagnosticLineBytes {
		t.Fatalf("diagnostic line limit = %d, want hard cap %d", got, maximumDiagnosticLineBytes)
	}
	if got := (SessionOptions{MaxPacketPreviewBytes: 1 << 20}).previewLimit(); got != maximumPacketPreviewBytes {
		t.Fatalf("packet preview limit = %d, want hard cap %d", got, maximumPacketPreviewBytes)
	}
	const rawPayloadToken = "RAW-PAYLOAD-IDENTITY-DO-NOT-EMIT-0123456789"
	transport := newFakeTransport()
	var diagnostics bytes.Buffer
	session, _ := openTestSession(t, transport, SessionOptions{
		Verbose:                true,
		Writer:                 &diagnostics,
		MaxDiagnosticLineBytes: 80,
		MaxPacketPreviewBytes:  4096,
	})
	if err := session.SendFrame(context.Background(), NewFrame(CommandBrightness, []byte(rawPayloadToken))); err != nil {
		t.Fatal(err)
	}
	for _, line := range strings.Split(diagnostics.String(), "\n") {
		if len(line) > 80 {
			t.Fatalf("diagnostic line length = %d, want <= 80", len(line))
		}
	}
	if strings.Contains(diagnostics.String(), rawPayloadToken) {
		t.Fatal("verbose packet diagnostics emitted the complete payload")
	}

	quietTransport := newFakeTransport()
	var quiet bytes.Buffer
	quietSession, _ := openTestSession(t, quietTransport, SessionOptions{Writer: &quiet})
	if err := quietSession.SendFrame(context.Background(), BrightnessFrame(1)); err != nil {
		t.Fatal(err)
	}
	if quiet.Len() != 0 {
		t.Fatal("packet diagnostics emitted without Verbose")
	}
	_ = session.Close()
	_ = quietSession.Close()
}

func commandsFromReports(reports [][]byte) ([]Command, error) {
	commands := make([]Command, 0)
	for offset := 0; offset < len(reports); {
		packet, err := NormalizeReport(reports[offset])
		if err != nil {
			return nil, err
		}
		if packet[0] != 0x7c || packet[1] != 0x7c {
			return nil, fmt.Errorf("report %d is not a frame start", offset)
		}
		declared := int(binary.LittleEndian.Uint32(packet[4:8]))
		count := 1
		if declared > FirstPayloadCapacity {
			count += (declared - FirstPayloadCapacity + ProtocolPacketSize - 1) / ProtocolPacketSize
		}
		if offset+count > len(reports) {
			return nil, fmt.Errorf("frame at report %d extends beyond writes", offset)
		}
		commands = append(commands, Command(binary.BigEndian.Uint16(packet[2:4])))
		offset += count
	}
	return commands, nil
}
