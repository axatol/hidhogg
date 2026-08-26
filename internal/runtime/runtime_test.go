package runtime

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	appconfig "hidhogg/internal/config"
	"hidhogg/internal/d200x"
	"hidhogg/internal/ipc"
)

const runtimeTestInstanceID = "11111111-1111-4111-8111-111111111111"

func TestRuntimeRejectsInvalidConfigurationBeforeHID(t *testing.T) {
	configurationPath := filepath.Join(t.TempDir(), "invalid.toml")
	if err := os.WriteFile(configurationPath, []byte("schema_version = 2\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	factory := &recordingFactory{}
	runtimeProcess, err := New(Config{
		SocketPath:       filepath.Join(t.TempDir(), "runtime.sock"),
		InstanceID:       runtimeTestInstanceID,
		ConfigPath:       configurationPath,
		TransportFactory: factory,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := runtimeProcess.Run(context.Background()); err == nil {
		t.Fatal("invalid configuration was accepted")
	}
	if got := factory.snapshot(); len(got) != 0 {
		t.Fatalf("HID calls after invalid configuration: %v", got)
	}
}

func TestRuntimeInitializesDeviceBeforeIPCAndMapsInput(t *testing.T) {
	configurationPath := filepath.Join(t.TempDir(), "valid.toml")
	if err := os.WriteFile(configurationPath, runtimeTestConfiguration(), 0o600); err != nil {
		t.Fatal(err)
	}
	generation := filepath.Join(t.TempDir(), "generation")
	if err := os.Mkdir(generation, 0o700); err != nil {
		t.Fatal(err)
	}
	socketPath := filepath.Join(generation, "runtime.sock")
	var stdout synchronizedWriter
	var stderr synchronizedWriter
	transport := newRuntimeFakeTransport()
	transport.writeStarted = make(chan struct{})
	transport.writeGate = make(chan struct{})
	factory := &recordingFactory{transport: transport}
	runtimeProcess, err := New(Config{
		SocketPath:       socketPath,
		InstanceID:       runtimeTestInstanceID,
		ConfigPath:       configurationPath,
		Verbose:          true,
		TransportFactory: factory,
		Stdout:           &stdout,
		Stderr:           &stderr,
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runDone := make(chan error, 1)
	go func() { runDone <- runtimeProcess.Run(ctx) }()

	select {
	case <-transport.writeStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("initial HID write did not start")
	}
	if _, err := os.Lstat(socketPath); err == nil {
		t.Fatal("IPC became ready before the initial HID writes completed")
	} else if !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("inspect IPC endpoint: %v", err)
	}
	close(transport.writeGate)
	waitForRuntime(t, func() bool { return transport.writeCount() >= 4 })
	waitForRuntimeSocket(t, socketPath, runDone)
	commands, err := commandsFromReports(transport.writesSnapshot())
	if err != nil {
		t.Fatalf("decode startup reports: %v", err)
	}
	wantCommands := []d200x.Command{
		d200x.CommandCompleteDisplayUpload,
		d200x.CommandBrightness,
		d200x.CommandUnlockScreen,
		d200x.CommandEnableInputStream,
	}
	if len(commands) < len(wantCommands) || !reflect.DeepEqual(commands[:len(wantCommands)], wantCommands) {
		t.Fatalf("startup commands = %v, want prefix %v", commands, wantCommands)
	}

	client, err := ipc.NewClient(ipc.ClientConfig{SocketPath: socketPath})
	if err != nil {
		t.Fatal(err)
	}
	if response, err := client.Call(ctx, ipc.MethodHealth, runtimeTestInstanceID); err != nil || response.Result == nil {
		t.Fatalf("health response = %#v, error = %v", response, err)
	}
	transport.queueFrame(d200x.NewFrame(d200x.CommandInputEvent, []byte{1, 6, byte(d200x.InputMarkerButton), byte(d200x.InputActionPressed)}))
	waitForRuntime(t, func() bool { return strings.Contains(stdout.String(), "tile-1_1") })
	var event map[string]any
	if err := json.Unmarshal([]byte(strings.TrimSpace(stdout.String())), &event); err != nil {
		t.Fatalf("input event JSON: %v", err)
	}
	if event["event"] != "input" || event["id"] != "tile-1_1" || event["position"] != "1_1" || event["action"] != "pressed" {
		t.Fatalf("input event = %#v", event)
	}
	if !strings.Contains(stderr.String(), "d200x outbound command=complete-display-upload") {
		t.Fatalf("verbose diagnostics omitted upload: %q", stderr.String())
	}

	cancel()
	select {
	case err := <-runDone:
		if err != nil {
			t.Fatalf("runtime shutdown: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("runtime did not shut down")
	}
	if !transport.wasClosed() {
		t.Fatal("runtime did not close HID transport")
	}
	if _, err := os.Lstat(socketPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("IPC endpoint after shutdown: %v", err)
	}
}

func TestRuntimeSanitizesDeviceFailures(t *testing.T) {
	configurationPath := filepath.Join(t.TempDir(), "valid.toml")
	if err := os.WriteFile(configurationPath, runtimeTestConfiguration(), 0o600); err != nil {
		t.Fatal(err)
	}
	factory := &recordingFactory{enumerateErr: errors.New("/secret/serial=abc")}
	runtimeProcess, err := New(Config{
		SocketPath:       filepath.Join(t.TempDir(), "runtime.sock"),
		InstanceID:       runtimeTestInstanceID,
		ConfigPath:       configurationPath,
		TransportFactory: factory,
	})
	if err != nil {
		t.Fatal(err)
	}
	err = runtimeProcess.Run(context.Background())
	if err == nil || strings.Contains(err.Error(), "serial=abc") || strings.Contains(err.Error(), "/secret") {
		t.Fatalf("unsanitized device failure: %v", err)
	}
}

func TestRecoverableInputErrorsExcludeSessionAndTransportFailures(t *testing.T) {
	recoverable := []d200x.ProtocolErrorKind{
		d200x.ErrorInvalidReportLength,
		d200x.ErrorUnsupportedReportID,
		d200x.ErrorInvalidFrameMagic,
		d200x.ErrorPayloadTooLarge,
		d200x.ErrorTruncatedPayload,
		d200x.ErrorUnexpectedContinuation,
		d200x.ErrorMalformedInputPayload,
	}
	for _, kind := range recoverable {
		if !isRecoverableInputError(&d200x.ProtocolError{Kind: kind}) {
			t.Fatalf("input protocol error %q was fatal", kind)
		}
	}

	fatal := []d200x.ProtocolErrorKind{
		d200x.ErrorSessionClosed,
		d200x.ErrorNoActiveTransport,
		d200x.ErrorTransportShortWrite,
	}
	for _, kind := range fatal {
		if isRecoverableInputError(&d200x.ProtocolError{Kind: kind}) {
			t.Fatalf("session or transport error %q was recoverable", kind)
		}
	}
	if isRecoverableInputError(errors.New("transport failed")) {
		t.Fatal("non-protocol transport error was recoverable")
	}
}

func TestRuntimeAndD200XPositionMappingsStayInParity(t *testing.T) {
	configurationPositions := appconfig.SupportedPositions()
	devicePositions := d200x.SupportedPositions()
	if len(configurationPositions) != len(devicePositions) {
		t.Fatalf("position counts differ: config=%d d200x=%d", len(configurationPositions), len(devicePositions))
	}
	for index, configurationPosition := range configurationPositions {
		devicePosition := devicePositions[index]
		if configurationPosition.Name != devicePosition.Name || configurationPosition.WireIndex != devicePosition.WireIndex || configurationPosition.Wide != devicePosition.Wide {
			t.Fatalf("position %d differs: config=%+v d200x=%+v", index, configurationPosition, devicePosition)
		}
		lookup, ok := d200x.LookupPosition(configurationPosition.Name)
		if !ok || lookup != devicePosition {
			t.Fatalf("D200X lookup for %q = %+v, %t; want %+v", configurationPosition.Name, lookup, ok, devicePosition)
		}
	}
}

func TestRuntimeStdoutFailureClosesSession(t *testing.T) {
	configurationPath := filepath.Join(t.TempDir(), "valid.toml")
	if err := os.WriteFile(configurationPath, runtimeTestConfiguration(), 0o600); err != nil {
		t.Fatal(err)
	}
	transport := newRuntimeFakeTransport()
	factory := &recordingFactory{transport: transport}
	failingOutput := failingWriter{err: errors.New("stdout unavailable")}
	runtimeProcess, err := New(Config{
		SocketPath:       filepath.Join(t.TempDir(), "runtime.sock"),
		InstanceID:       runtimeTestInstanceID,
		ConfigPath:       configurationPath,
		TransportFactory: factory,
		Stdout:           failingOutput,
	})
	if err != nil {
		t.Fatal(err)
	}
	plan, err := buildDevicePlan(configurationPath)
	if err != nil {
		t.Fatal(err)
	}
	candidate := d200x.NewCandidate("opaque-device-path", d200x.VendorID, d200x.ProductID, d200x.InterfaceNumber)
	session := d200x.NewSession(factory)
	if err := session.Open(context.Background(), candidate); err != nil {
		t.Fatal(err)
	}
	if err := session.SendPage(context.Background(), plan.page, plan.brightness); err != nil {
		t.Fatal(err)
	}
	commands, err := commandsFromReports(transport.writesSnapshot())
	if err != nil {
		t.Fatalf("decode startup reports: %v", err)
	}
	wantCommands := []d200x.Command{
		d200x.CommandCompleteDisplayUpload,
		d200x.CommandBrightness,
		d200x.CommandUnlockScreen,
		d200x.CommandEnableInputStream,
	}
	if len(commands) < len(wantCommands) || !reflect.DeepEqual(commands[:len(wantCommands)], wantCommands) {
		t.Fatalf("startup commands = %v, want prefix %v", commands, wantCommands)
	}
	runtimeProcess.mu.Lock()
	runtimeProcess.plan = plan
	runtimeProcess.session = session
	runtimeProcess.started = true
	runtimeProcess.mu.Unlock()
	transport.queueFrame(d200x.NewFrame(d200x.CommandInputEvent, []byte{1, 0, byte(d200x.InputMarkerButton), byte(d200x.InputActionPressed)}))
	if err := runtimeProcess.readInputs(context.Background()); err == nil {
		t.Fatal("stdout failure did not terminate input session")
	}
	if !transport.wasClosed() {
		t.Fatal("stdout failure did not close HID transport")
	}
	if err := runtimeProcess.Close(); err != nil {
		t.Fatalf("runtime close after stdout failure: %v", err)
	}
}

func runtimeTestConfiguration() []byte {
	var builder strings.Builder
	builder.WriteString("schema_version = 1\nadapter = \"ulanzi.d200x\"\nbrightness = 73\n\n[[pages]]\n")
	for index, spec := range d200x.SupportedPositions() {
		fmt.Fprintf(&builder, "[[pages.positions]]\nid = \"tile-%s\"\nposition = \"%s\"\nlabel = \"Tile %d\"\nbackground = \"#102030\"\n\n", spec.Name, spec.Name, index)
	}
	return []byte(builder.String())
}

type recordingFactory struct {
	mu           sync.Mutex
	transport    *runtimeFakeTransport
	enumerateErr error
	called       []string
}

func (factory *recordingFactory) Enumerate(context.Context) ([]d200x.Candidate, error) {
	factory.mu.Lock()
	factory.called = append(factory.called, "enumerate")
	factory.mu.Unlock()
	if factory.enumerateErr != nil {
		return nil, factory.enumerateErr
	}
	return []d200x.Candidate{d200x.NewCandidate("opaque-device-path", d200x.VendorID, d200x.ProductID, d200x.InterfaceNumber)}, nil
}

func (factory *recordingFactory) Open(context.Context, d200x.Candidate) (d200x.Transport, error) {
	factory.mu.Lock()
	factory.called = append(factory.called, "open")
	transport := factory.transport
	factory.mu.Unlock()
	if transport == nil {
		return nil, errors.New("test transport is unavailable")
	}
	return transport, nil
}

func (factory *recordingFactory) snapshot() []string {
	factory.mu.Lock()
	defer factory.mu.Unlock()
	return append([]string(nil), factory.called...)
}

type runtimeFakeTransport struct {
	mu           sync.Mutex
	writes       [][]byte
	readData     chan []byte
	closed       chan struct{}
	once         sync.Once
	writeStarted chan struct{}
	writeGate    chan struct{}
	writeOnce    sync.Once
}

type failingWriter struct {
	err error
}

func (writer failingWriter) Write([]byte) (int, error) {
	return 0, writer.err
}

type synchronizedWriter struct {
	mu   sync.Mutex
	data strings.Builder
}

func (writer *synchronizedWriter) Write(data []byte) (int, error) {
	writer.mu.Lock()
	defer writer.mu.Unlock()
	return writer.data.Write(data)
}

func (writer *synchronizedWriter) String() string {
	writer.mu.Lock()
	defer writer.mu.Unlock()
	return writer.data.String()
}

func newRuntimeFakeTransport() *runtimeFakeTransport {
	return &runtimeFakeTransport{
		readData: make(chan []byte, 16),
		closed:   make(chan struct{}),
	}
}

func (transport *runtimeFakeTransport) Read(ctx context.Context, report []byte) (int, error) {
	select {
	case <-ctx.Done():
		return 0, ctx.Err()
	case <-transport.closed:
		return 0, errors.New("transport closed")
	case data := <-transport.readData:
		if len(data) > len(report) {
			return 0, io.ErrShortBuffer
		}
		return copy(report, data), nil
	}
}

func (transport *runtimeFakeTransport) Write(_ context.Context, report []byte) (int, error) {
	if transport.writeStarted != nil {
		transport.writeOnce.Do(func() { close(transport.writeStarted) })
		<-transport.writeGate
	}
	transport.mu.Lock()
	transport.writes = append(transport.writes, append([]byte(nil), report...))
	transport.mu.Unlock()
	return len(report), nil
}

func (transport *runtimeFakeTransport) Close() error {
	transport.once.Do(func() { close(transport.closed) })
	return nil
}

func (transport *runtimeFakeTransport) queueFrame(frame d200x.Frame) {
	reports, err := d200x.EncodeFrame(frame)
	if err != nil {
		panic(err)
	}
	for _, report := range reports {
		transport.readData <- report
	}
}

func (transport *runtimeFakeTransport) writeCount() int {
	transport.mu.Lock()
	defer transport.mu.Unlock()
	return len(transport.writes)
}

func (transport *runtimeFakeTransport) writesSnapshot() [][]byte {
	transport.mu.Lock()
	defer transport.mu.Unlock()
	reports := make([][]byte, len(transport.writes))
	for index, report := range transport.writes {
		reports[index] = append([]byte(nil), report...)
	}
	return reports
}

func (transport *runtimeFakeTransport) wasClosed() bool {
	select {
	case <-transport.closed:
		return true
	default:
		return false
	}
}

func waitForRuntime(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("condition did not become true")
}

func waitForRuntimeSocket(t *testing.T, path string, runDone <-chan error) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Lstat(path); err == nil {
			return
		}
		select {
		case err := <-runDone:
			if err != nil && strings.Contains(err.Error(), "start IPC server failed") {
				t.Skipf("Unix socket creation unavailable in this environment: %v", err)
			}
			t.Fatalf("runtime exited before IPC readiness: %v", err)
		default:
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("IPC endpoint did not become ready")
}

func commandsFromReports(reports [][]byte) ([]d200x.Command, error) {
	commands := make([]d200x.Command, 0)
	for offset := 0; offset < len(reports); {
		packet, err := d200x.NormalizeReport(reports[offset])
		if err != nil {
			return nil, err
		}
		declared := int(binary.LittleEndian.Uint32(packet[4:8]))
		packetCount := 1
		if declared > d200x.FirstPayloadCapacity {
			packetCount += (declared - d200x.FirstPayloadCapacity + d200x.ProtocolPacketSize - 1) / d200x.ProtocolPacketSize
		}
		if offset+packetCount > len(reports) {
			return nil, fmt.Errorf("frame at report %d extends beyond writes", offset)
		}
		commands = append(commands, d200x.Command(binary.BigEndian.Uint16(packet[2:4])))
		offset += packetCount
	}
	return commands, nil
}

var _ d200x.TransportFactory = (*recordingFactory)(nil)
var _ d200x.Transport = (*runtimeFakeTransport)(nil)
var _ io.Writer = (*synchronizedWriter)(nil)
