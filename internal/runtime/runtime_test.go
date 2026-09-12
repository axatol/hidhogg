package runtime

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	goruntime "runtime"
	"strings"
	"sync"
	"testing"
	"time"

	appconfig "hidhogg/internal/config"
	"hidhogg/internal/d200x"
	"hidhogg/internal/discovery"
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

func TestRuntimeBindsBeforeHIDAndPublishesReadinessAfterServing(t *testing.T) {
	configurationPath := filepath.Join(t.TempDir(), "valid.toml")
	if err := os.WriteFile(configurationPath, runtimeTestConfiguration(), 0o600); err != nil {
		t.Fatal(err)
	}
	generation := m03RuntimeSecureDirectory(t)
	socketPath := filepath.Join(generation, "runtime.sock")
	var stdout synchronizedWriter
	var stderr synchronizedWriter
	transport := newRuntimeFakeTransport()
	transport.writeStarted = make(chan struct{})
	transport.writeGate = make(chan struct{})
	factory := &recordingFactory{transport: transport}
	runtimeProcess, err := New(Config{
		RuntimeDir:       generation,
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
	case err := <-runDone:
		if strings.Contains(fmt.Sprint(err), "start IPC server failed") {
			t.Skipf("Unix socket creation unavailable in this environment: %v", err)
		}
		t.Fatalf("runtime exited before the initial HID write: %v", err)
	case <-time.After(2 * time.Second):
		t.Fatal("initial HID write did not start")
	}
	if _, err := os.Lstat(socketPath); err != nil {
		t.Fatalf("IPC endpoint was not bound before the initial HID write: %v", err)
	}
	metadataPath := filepath.Join(generation, discovery.MetadataFileName)
	if _, err := os.Lstat(metadataPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("readiness metadata appeared before initialization: %v", err)
	}
	close(transport.writeGate)
	waitForRuntime(t, func() bool { return transport.writeCount() >= 4 })
	waitForRuntimeMetadata(t, metadataPath, runDone)
	commands, err := commandsFromReports(transport.writesSnapshot())
	if err != nil {
		t.Fatalf("decode startup reports: %v", err)
	}
	wantCommands := []d200x.Command{
		d200x.CommandUnlockScreen,
		d200x.CommandCompleteDisplayUpload,
		d200x.CommandBrightness,
		d200x.CommandEnableInputStream,
	}
	if len(commands) < len(wantCommands) || !reflect.DeepEqual(commands[:len(wantCommands)], wantCommands) {
		t.Fatalf("startup commands = %v, want prefix %v", commands, wantCommands)
	}
	if profileID, ok := runtimeProcess.CurrentProfileID(); !ok || profileID != "default" {
		t.Fatalf("startup current profile = %q/%t, want default", profileID, ok)
	}

	resolved, err := discovery.Resolve(generation)
	if err != nil {
		t.Fatalf("resolve ready runtime: %v", err)
	}
	client, err := ipc.NewClient(ipc.ClientConfig{SocketPath: resolved.Paths.SocketPath})
	if err != nil {
		t.Fatal(err)
	}
	if response, err := client.Call(ctx, ipc.MethodHealth, resolved.Metadata.InstanceID); err != nil || response.Result == nil {
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
	if _, err := os.Lstat(metadataPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("readiness metadata after shutdown: %v", err)
	}
	if _, err := os.Lstat(filepath.Join(generation, discovery.LockFileName)); err != nil {
		t.Fatalf("persistent runtime lock after shutdown: %v", err)
	}
}

func TestRuntimeSerializesAllStderrWriters(t *testing.T) {
	const iterations = 32
	configurationPath := filepath.Join(t.TempDir(), "config.toml")
	configuration := runtimeMultiProfileConfiguration()
	if err := os.WriteFile(configurationPath, configuration, 0o600); err != nil {
		t.Fatal(err)
	}
	stderr := &deliberatelyUnsynchronizedWriter{}
	transport := newRuntimeFakeTransport()
	runtimeProcess, err := New(Config{
		RuntimeDir:       m03RuntimeSecureDirectory(t),
		ConfigPath:       configurationPath,
		Verbose:          true,
		TransportFactory: &recordingFactory{transport: transport},
		Stderr:           stderr,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := runtimeProcess.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = runtimeProcess.Close() })

	invalid := bytes.Replace(configuration, []byte("brightness = 73"), []byte("brightness = \"SERIALIZATION_SECRET\""), 1)
	if bytes.Equal(invalid, configuration) {
		t.Fatal("test configuration did not contain expected brightness")
	}
	if err := os.WriteFile(configurationPath, invalid, 0o600); err != nil {
		t.Fatal(err)
	}

	start := make(chan struct{})
	var wait sync.WaitGroup
	errorsFound := make(chan error, iterations*2)
	wait.Add(3)
	go func() {
		defer wait.Done()
		<-start
		for range iterations {
			if err := runtimeProcess.session.SendFrame(context.Background(), d200x.BrightnessFrame(55)); err != nil {
				errorsFound <- err
			}
		}
	}()
	go func() {
		defer wait.Done()
		<-start
		for range iterations {
			runtimeProcess.profileService.logTransition("concurrent", "default", "alternate", 1)
		}
	}()
	go func() {
		defer wait.Done()
		<-start
		for range iterations {
			if _, err := runtimeProcess.Reload(context.Background()); err == nil {
				errorsFound <- errors.New("invalid reload succeeded")
			}
		}
	}()
	close(start)
	wait.Wait()
	close(errorsFound)
	for err := range errorsFound {
		t.Error(err)
	}

	output := stderr.String()
	if strings.Contains(output, "SERIALIZATION_SECRET") {
		t.Fatalf("stderr exposed configuration value: %q", output)
	}
	if count := strings.Count(output, "runtime config reload rejected:"); count != iterations {
		t.Fatalf("reload diagnostic lines = %d, want %d", count, iterations)
	}
	if count := strings.Count(output, "runtime profile transition phase=concurrent"); count != iterations {
		t.Fatalf("profile diagnostic lines = %d, want %d", count, iterations)
	}
	if count := strings.Count(output, "d200x outbound command=brightness"); count < iterations {
		t.Fatalf("brightness diagnostic lines = %d, want at least %d", count, iterations)
	}
	for _, line := range strings.Split(strings.TrimSuffix(output, "\n"), "\n") {
		if !strings.HasPrefix(line, "d200x ") && !strings.HasPrefix(line, "runtime profile transition ") && !strings.HasPrefix(line, "runtime config reload rejected: ") {
			t.Fatalf("corrupted stderr line: %q", line)
		}
	}
}

func TestRuntimeLegacyModeNormalizesUppercaseInstanceID(t *testing.T) {
	configurationPath := filepath.Join(t.TempDir(), "valid.toml")
	if err := os.WriteFile(configurationPath, runtimeTestConfiguration(), 0o600); err != nil {
		t.Fatal(err)
	}
	generation := m03RuntimeSecureDirectory(t)
	socketPath := filepath.Join(generation, "runtime.sock")
	transport := newRuntimeFakeTransport()
	factory := &recordingFactory{transport: transport}
	runtimeProcess, err := New(Config{
		SocketPath:       socketPath,
		InstanceID:       strings.ToUpper(runtimeTestInstanceID),
		ConfigPath:       configurationPath,
		TransportFactory: factory,
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runDone := make(chan error, 1)
	go func() { runDone <- runtimeProcess.Run(ctx) }()
	waitForRuntimeSocket(t, socketPath, runDone)
	client, err := ipc.NewClient(ipc.ClientConfig{SocketPath: socketPath})
	if err != nil {
		t.Fatal(err)
	}
	if response, err := client.Call(ctx, ipc.MethodHealth, runtimeTestInstanceID); err != nil || response.Result == nil || response.Result.InstanceID != runtimeTestInstanceID {
		t.Fatalf("health response = %#v, error = %v", response, err)
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
}

func TestRuntimeStartsDefaultAndActivatesProfileTransactionally(t *testing.T) {
	configurationPath := filepath.Join(t.TempDir(), "profiles.toml")
	if err := os.WriteFile(configurationPath, runtimeMultiProfileConfiguration(), 0o600); err != nil {
		t.Fatal(err)
	}
	socketDirectory := runtimeSocketTestDirectory(t)
	transport := newRuntimeFakeTransport()
	factory := &recordingFactory{transport: transport}
	runtimeProcess, err := New(Config{
		SocketPath:       filepath.Join(socketDirectory, "runtime.sock"),
		InstanceID:       runtimeTestInstanceID,
		ConfigPath:       configurationPath,
		TransportFactory: factory,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := runtimeProcess.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = runtimeProcess.Close() })
	if profileID, ok := runtimeProcess.CurrentProfileID(); !ok || profileID != "default" {
		t.Fatalf("startup profile = %q/%t, want default", profileID, ok)
	}
	result, err := runtimeProcess.ActivateProfile(context.Background(), "alternate")
	if err != nil {
		t.Fatalf("alternate activation: %v", err)
	}
	if result.ProfileID != "alternate" || !result.Changed {
		t.Fatalf("activation result = %+v", result)
	}
	if profileID, ok := runtimeProcess.CurrentProfileID(); !ok || profileID != "alternate" {
		t.Fatalf("committed profile = %q/%t, want alternate", profileID, ok)
	}
	commands, err := commandsFromReports(transport.writesSnapshot())
	if err != nil {
		t.Fatalf("decode writes: %v", err)
	}
	assertRuntimeCommandSequence(t, commands, runtimeLiveCommandSequence(1))
}

func TestRuntimeActivationWriteFailureWithdrawsReadinessAndStops(t *testing.T) {
	configurationPath := filepath.Join(t.TempDir(), "profiles.toml")
	if err := os.WriteFile(configurationPath, runtimeMultiProfileConfiguration(), 0o600); err != nil {
		t.Fatal(err)
	}
	runtimeDir := m03RuntimeSecureDirectory(t)
	transport := newRuntimeFakeTransport()
	factory := &recordingFactory{transport: transport}
	terminalCalls := make(chan error, 2)
	runtimeProcess, err := New(Config{
		RuntimeDir:       runtimeDir,
		InstanceID:       runtimeTestInstanceID,
		ConfigPath:       configurationPath,
		TransportFactory: factory,
		Terminal: func(err error) {
			terminalCalls <- err
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runDone := make(chan error, 1)
	go func() { runDone <- runtimeProcess.Run(ctx) }()
	paths, err := discovery.NewPaths(runtimeDir)
	if err != nil {
		t.Fatal(err)
	}
	waitForRuntimeMetadata(t, paths.MetadataPath, runDone)
	service := runtimeProcess.ProfileService()
	if service == nil {
		t.Fatal("profile service unavailable after readiness")
	}
	transport.failNextWrite(errors.New("injected activation write failure"))
	activationDone := make(chan error, 1)
	go func() {
		_, err := service.ActivateProfile(context.Background(), "alternate")
		activationDone <- err
	}()
	select {
	case err := <-activationDone:
		if err == nil {
			t.Fatal("failed activation returned nil error")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("failed activation did not return")
	}
	select {
	case err := <-terminalCalls:
		if err == nil {
			t.Fatal("terminal callback received nil error")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("terminal callback was not invoked")
	}
	waitForRuntime(t, func() bool {
		_, err := os.Lstat(paths.MetadataPath)
		return errors.Is(err, os.ErrNotExist)
	})
	select {
	case err := <-runDone:
		if !errors.Is(err, ErrProfileStateUncertain) {
			t.Fatalf("runtime failure = %v, want uncertain state", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("runtime did not stop after activation failure")
	}
	if _, err := service.ActivateProfile(context.Background(), "default"); !errors.Is(err, ErrProfileStateUncertain) {
		t.Fatalf("future activation error = %v, want uncertain state", err)
	}
	select {
	case err := <-terminalCalls:
		t.Fatalf("terminal callback invoked more than once: %v", err)
	default:
	}
	if !transport.wasClosed() {
		t.Fatal("activation failure did not close HID transport")
	}
}

func TestRuntimeStartFailureJoinsDiscoveryCleanupFailure(t *testing.T) {
	configurationPath := filepath.Join(t.TempDir(), "valid.toml")
	if err := os.WriteFile(configurationPath, runtimeTestConfiguration(), 0o600); err != nil {
		t.Fatal(err)
	}
	runtimeDir := m03RuntimeSecureDirectory(t)
	enumerateStarted := make(chan struct{})
	enumerateGate := make(chan struct{})
	factory := &recordingFactory{
		enumerateErr:     errors.New("injected enumeration failure"),
		enumerateStarted: enumerateStarted,
		enumerateGate:    enumerateGate,
	}
	runtimeProcess, err := New(Config{
		RuntimeDir:       runtimeDir,
		InstanceID:       runtimeTestInstanceID,
		ConfigPath:       configurationPath,
		TransportFactory: factory,
	})
	if err != nil {
		t.Fatal(err)
	}
	startDone := make(chan error, 1)
	go func() { startDone <- runtimeProcess.Start() }()
	select {
	case <-enumerateStarted:
	case err := <-startDone:
		if strings.Contains(fmt.Sprint(err), "start IPC server failed") {
			t.Skipf("Unix socket creation unavailable in this environment: %v", err)
		}
		t.Fatalf("runtime exited before gated enumeration: %v", err)
	case <-time.After(2 * time.Second):
		t.Fatal("enumeration did not start")
	}
	paths, err := discovery.NewPaths(runtimeDir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(paths.SocketPath); err != nil {
		t.Fatalf("IPC socket was not bound before enumeration: %v", err)
	}
	if _, err := os.Lstat(paths.MetadataPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("metadata appeared during Start: %v", err)
	}
	if err := os.Remove(paths.SocketPath); err != nil {
		t.Fatalf("remove owned socket for cleanup failure: %v", err)
	}
	if err := os.WriteFile(paths.SocketPath, []byte("foreign"), 0o600); err != nil {
		t.Fatalf("substitute socket path: %v", err)
	}
	close(enumerateGate)
	var startErr error
	select {
	case startErr = <-startDone:
	case <-time.After(2 * time.Second):
		t.Fatal("Start did not return")
	}
	if startErr == nil {
		t.Fatal("Start accepted injected enumeration failure")
	}
	if !strings.Contains(startErr.Error(), "close runtime discovery failed") {
		t.Fatalf("Start omitted joined discovery cleanup failure: %v", startErr)
	}
	if err := os.Remove(paths.SocketPath); err != nil {
		t.Fatalf("remove substituted socket path: %v", err)
	}
	assertM03DiscoveryEntriesUnwound(t, runtimeDir)
	if calls := factory.snapshot(); !reflect.DeepEqual(calls, []string{"enumerate"}) {
		t.Fatalf("HID calls = %v, want gated enumeration only", calls)
	}
}

func TestRuntimeStartThenRunPublishesAndShutsDown(t *testing.T) {
	configurationPath := filepath.Join(t.TempDir(), "valid.toml")
	if err := os.WriteFile(configurationPath, runtimeTestConfiguration(), 0o600); err != nil {
		t.Fatal(err)
	}
	runtimeDir := m03RuntimeSecureDirectory(t)
	transport := newRuntimeFakeTransport()
	factory := &recordingFactory{transport: transport}
	runtimeProcess, err := New(Config{
		RuntimeDir:       runtimeDir,
		InstanceID:       runtimeTestInstanceID,
		ConfigPath:       configurationPath,
		TransportFactory: factory,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := runtimeProcess.Start(); err != nil {
		if strings.Contains(err.Error(), "start IPC server failed") {
			t.Skipf("Unix socket creation unavailable in this environment: %v", err)
		}
		t.Fatalf("runtime Start: %v", err)
	}
	paths, err := discovery.NewPaths(runtimeDir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(paths.SocketPath); err != nil {
		t.Fatalf("IPC socket after Start: %v", err)
	}
	if _, err := os.Lstat(paths.MetadataPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("metadata appeared during Start: %v", err)
	}
	runtimeProcess.mu.Lock()
	server := runtimeProcess.server
	runtimeProcess.mu.Unlock()
	if server == nil {
		t.Fatal("runtime Start did not retain IPC server")
	}
	ctx, cancel := context.WithCancel(context.Background())
	runDone := make(chan error, 1)
	go func() { runDone <- runtimeProcess.Run(ctx) }()
	select {
	case <-server.ServingReady():
	case err := <-runDone:
		t.Fatalf("runtime exited before serving: %v", err)
	case <-time.After(2 * time.Second):
		t.Fatal("IPC server did not become ready")
	}
	waitForRuntimeMetadata(t, paths.MetadataPath, runDone)
	resolved, err := discovery.Resolve(runtimeDir)
	if err != nil {
		t.Fatalf("resolve runtime after Run: %v", err)
	}
	if resolved.Metadata.InstanceID != runtimeTestInstanceID {
		t.Fatalf("published instance ID = %q, want %q", resolved.Metadata.InstanceID, runtimeTestInstanceID)
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
		t.Fatal("Run after Start did not close HID transport")
	}
	assertM03DiscoveryEntriesUnwound(t, runtimeDir)
}

func TestWaitForServingTerminalBranches(t *testing.T) {
	serveErr := errors.New("serve failed")
	tests := []struct {
		name            string
		prepare         func() (context.Context, *runtimeServingStub, chan error)
		wantErr         error
		wantConsumed    bool
		wantDoneRemains bool
	}{
		{
			name: "server returns nil",
			prepare: func() (context.Context, *runtimeServingStub, chan error) {
				done := make(chan error, 1)
				done <- nil
				return context.Background(), &runtimeServingStub{ready: make(chan struct{})}, done
			},
			wantErr:      errors.New("IPC server stopped before serving"),
			wantConsumed: true,
		},
		{
			name: "server returns error",
			prepare: func() (context.Context, *runtimeServingStub, chan error) {
				done := make(chan error, 1)
				done <- serveErr
				return context.Background(), &runtimeServingStub{ready: make(chan struct{})}, done
			},
			wantErr:      serveErr,
			wantConsumed: true,
		},
		{
			name: "context cancellation",
			prepare: func() (context.Context, *runtimeServingStub, chan error) {
				ctx, cancel := context.WithCancel(context.Background())
				cancel()
				done := make(chan error, 1)
				return ctx, &runtimeServingStub{ready: make(chan struct{})}, done
			},
			wantErr: context.Canceled,
		},
		{
			name: "serving readiness wins",
			prepare: func() (context.Context, *runtimeServingStub, chan error) {
				ready := make(chan struct{})
				close(ready)
				done := make(chan error, 1)
				return context.Background(), &runtimeServingStub{ready: ready}, done
			},
			wantDoneRemains: true,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			ctx, server, done := test.prepare()
			gotErr, gotConsumed := waitForServing(ctx, server, done)
			if test.wantErr == nil {
				if gotErr != nil {
					t.Fatalf("waitForServing error = %v, want nil", gotErr)
				}
			} else if test.name == "server returns nil" {
				if gotErr == nil || gotErr.Error() != test.wantErr.Error() {
					t.Fatalf("waitForServing error = %v, want %v", gotErr, test.wantErr)
				}
			} else if !errors.Is(gotErr, test.wantErr) {
				t.Fatalf("waitForServing error = %v, want %v", gotErr, test.wantErr)
			}
			if gotConsumed != test.wantConsumed {
				t.Fatalf("done consumed = %t, want %t", gotConsumed, test.wantConsumed)
			}
			if test.wantDoneRemains {
				done <- serveErr
				select {
				case <-done:
				default:
					t.Fatal("waitForServing consumed a completion result that should remain pending")
				}
			} else {
				select {
				case <-done:
					t.Fatal("waitForServing received the completion result more than once")
				default:
				}
			}
		})
	}
}

type runtimeServingStub struct {
	ready <-chan struct{}
}

func (server *runtimeServingStub) ServingReady() <-chan struct{} {
	return server.ready
}

func TestRuntimePostStartRunServeTerminationWithdrawsMetadata(t *testing.T) {
	transport := newRuntimeFakeTransport()
	runtimeProcess, paths, server := newM03StartedRuntime(t, transport, nil)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runDone := make(chan error, 1)
	go func() { runDone <- runtimeProcess.Run(ctx) }()
	waitForRuntimeServing(t, server, runDone)
	waitForRuntimeMetadata(t, paths.MetadataPath, runDone)
	if err := server.Close(); err != nil {
		t.Fatalf("close IPC server: %v", err)
	}
	select {
	case err := <-runDone:
		if err != nil {
			t.Fatalf("serve-terminal Run error = %v, want nil", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("serve-terminal Run did not return")
	}
	if !transport.wasClosed() {
		t.Fatal("serve-terminal Run did not close HID transport")
	}
	assertM03DiscoveryEntriesUnwound(t, paths.RuntimeDir)
}

func TestRuntimePostStartRunInputTerminationJoinsCleanup(t *testing.T) {
	transport := newRuntimeFakeTransport()
	transport.readErr = errors.New("injected input failure")
	transport.closeErr = errors.New("injected close failure")
	transport.readStarted = make(chan struct{})
	transport.readGate = make(chan struct{})
	defer func() {
		select {
		case <-transport.readGate:
		default:
			close(transport.readGate)
		}
	}()
	runtimeProcess, paths, server := newM03StartedRuntime(t, transport, nil)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runDone := make(chan error, 1)
	go func() { runDone <- runtimeProcess.Run(ctx) }()
	waitForRuntimeServing(t, server, runDone)
	waitForRuntimeMetadata(t, paths.MetadataPath, runDone)
	select {
	case <-transport.readStarted:
	case err := <-runDone:
		t.Fatalf("input-terminal Run exited before gated read: %v", err)
	case <-time.After(2 * time.Second):
		t.Fatal("input read did not start")
	}
	close(transport.readGate)
	select {
	case err := <-runDone:
		if err == nil {
			t.Fatal("input-terminal Run returned nil")
		}
		if strings.Count(err.Error(), "runtime operation failed") < 2 {
			t.Fatalf("input-terminal Run omitted joined cleanup failure: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("input-terminal Run did not return")
	}
	if !transport.wasClosed() {
		t.Fatal("input-terminal Run did not close HID transport")
	}
	assertM03DiscoveryEntriesUnwound(t, paths.RuntimeDir)
}

func TestRuntimePostStartRunPolicyTerminationWithdrawsMetadata(t *testing.T) {
	transport := newRuntimeFakeTransport()
	runtimeProcess, paths, server := newM03StartedRuntime(t, transport, nil)
	runtimeProcess.stdout = failingWriter{err: errors.New("injected policy output failure")}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runDone := make(chan error, 1)
	go func() { runDone <- runtimeProcess.Run(ctx) }()
	waitForRuntimeServing(t, server, runDone)
	waitForRuntimeMetadata(t, paths.MetadataPath, runDone)
	transport.queueFrame(d200x.NewFrame(d200x.CommandInputEvent, []byte{1, 0, byte(d200x.InputMarkerButton), byte(d200x.InputActionPressed)}))
	select {
	case err := <-runDone:
		if err == nil {
			t.Fatal("policy-terminal Run returned nil")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("policy-terminal Run did not return")
	}
	if !transport.wasClosed() {
		t.Fatal("policy-terminal Run did not close HID transport")
	}
	assertM03DiscoveryEntriesUnwound(t, paths.RuntimeDir)
}

func newM03StartedRuntime(t *testing.T, transport *runtimeFakeTransport, clock Clock) (*Runtime, discovery.Paths, *ipc.Server) {
	t.Helper()
	configurationPath := filepath.Join(t.TempDir(), "valid.toml")
	if err := os.WriteFile(configurationPath, runtimeTestConfiguration(), 0o600); err != nil {
		t.Fatal(err)
	}
	runtimeDir := m03RuntimeSecureDirectory(t)
	runtimeProcess, err := New(Config{
		RuntimeDir:       runtimeDir,
		ConfigPath:       configurationPath,
		Clock:            clock,
		TransportFactory: &recordingFactory{transport: transport},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := runtimeProcess.Start(); err != nil {
		if strings.Contains(err.Error(), "start IPC server failed") {
			t.Skipf("Unix socket creation unavailable in this environment: %v", err)
		}
		t.Fatalf("runtime Start: %v", err)
	}
	paths, err := discovery.NewPaths(runtimeDir)
	if err != nil {
		t.Fatal(err)
	}
	runtimeProcess.mu.Lock()
	server := runtimeProcess.server
	runtimeProcess.mu.Unlock()
	if server == nil {
		t.Fatal("runtime Start did not retain IPC server")
	}
	t.Cleanup(func() { _ = runtimeProcess.Close() })
	return runtimeProcess, paths, server
}

func waitForRuntimeServing(t *testing.T, server *ipc.Server, runDone <-chan error) {
	t.Helper()
	select {
	case <-server.ServingReady():
	case err := <-runDone:
		t.Fatalf("runtime exited before serving: %v", err)
	case <-time.After(2 * time.Second):
		t.Fatal("IPC server did not become ready")
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

func TestRuntimeDiscoveryPreflightFailuresDoNotTouchHID(t *testing.T) {
	configurationPath := filepath.Join(t.TempDir(), "valid.toml")
	if err := os.WriteFile(configurationPath, runtimeTestConfiguration(), 0o600); err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name    string
		prepare func(t *testing.T) (string, func())
	}{
		{
			name: "missing directory",
			prepare: func(t *testing.T) (string, func()) {
				return filepath.Join(t.TempDir(), "missing"), func() {}
			},
		},
		{
			name: "wrong directory mode",
			prepare: func(t *testing.T) (string, func()) {
				directory := filepath.Join(t.TempDir(), "runtime")
				if err := os.Mkdir(directory, 0o755); err != nil {
					t.Fatal(err)
				}
				return directory, func() {}
			},
		},
		{
			name: "occupied directory",
			prepare: func(t *testing.T) (string, func()) {
				directory := m03RuntimeSecureDirectory(t)
				generation, err := discovery.Open(discovery.Options{RuntimeDir: directory, InstanceID: runtimeTestInstanceID})
				if err != nil {
					t.Fatal(err)
				}
				return directory, func() { _ = generation.Close() }
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			runtimeDir, release := test.prepare(t)
			defer release()
			factory := &recordingFactory{}
			runtimeProcess, err := New(Config{
				RuntimeDir:       runtimeDir,
				ConfigPath:       configurationPath,
				TransportFactory: factory,
			})
			if err != nil {
				t.Fatal(err)
			}
			err = runtimeProcess.Run(context.Background())
			if err == nil {
				t.Fatal("invalid discovery state was accepted")
			}
			if calls := factory.snapshot(); len(calls) != 0 {
				t.Fatalf("HID calls after discovery preflight failure: %v", calls)
			}
		})
	}
}

func TestRuntimeDiscoveryOverlongSocketFailsBeforeHID(t *testing.T) {
	configurationPath := filepath.Join(t.TempDir(), "valid.toml")
	if err := os.WriteFile(configurationPath, runtimeTestConfiguration(), 0o600); err != nil {
		t.Fatal(err)
	}
	base := m03RuntimeSecureDirectory(t)
	component := strings.Repeat("x", 100)
	runtimeDir := filepath.Join(base, component)
	if err := os.Mkdir(runtimeDir, 0o700); err != nil {
		t.Fatal(err)
	}
	factory := &recordingFactory{}
	runtimeProcess, err := New(Config{
		RuntimeDir:       runtimeDir,
		ConfigPath:       configurationPath,
		TransportFactory: factory,
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	err = runtimeProcess.Run(ctx)
	if len(factory.snapshot()) != 0 {
		t.Skip("platform accepted the test socket path length")
	}
	if err == nil {
		t.Fatal("overlong runtime socket was accepted")
	}
}

func TestRuntimeInitializationFailureUnwindsDiscoveryGeneration(t *testing.T) {
	configurationPath := filepath.Join(t.TempDir(), "valid.toml")
	if err := os.WriteFile(configurationPath, runtimeTestConfiguration(), 0o600); err != nil {
		t.Fatal(err)
	}
	runtimeDir := m03RuntimeSecureDirectory(t)
	transport := newRuntimeFakeTransport()
	transport.writeErr = errors.New("injected initialization failure")
	factory := &recordingFactory{transport: transport}
	runtimeProcess, err := New(Config{
		RuntimeDir:       runtimeDir,
		ConfigPath:       configurationPath,
		TransportFactory: factory,
	})
	if err != nil {
		t.Fatal(err)
	}
	err = runtimeProcess.Run(context.Background())
	if len(factory.snapshot()) == 0 && strings.Contains(fmt.Sprint(err), "start IPC server failed") {
		t.Skipf("Unix socket creation unavailable in this environment: %v", err)
	}
	if err == nil {
		t.Fatal("initialization failure was not reported")
	}
	assertM03DiscoveryEntriesUnwound(t, runtimeDir)
}

func TestRuntimePublicationFailureUnwindsSocketAndPreservesForeignMetadata(t *testing.T) {
	configurationPath := filepath.Join(t.TempDir(), "valid.toml")
	if err := os.WriteFile(configurationPath, runtimeTestConfiguration(), 0o600); err != nil {
		t.Fatal(err)
	}
	runtimeDir := m03RuntimeSecureDirectory(t)
	transport := newRuntimeFakeTransport()
	transport.postInitializationStarted = make(chan struct{})
	transport.postInitializationGate = make(chan struct{})
	factory := &recordingFactory{transport: transport}
	runtimeProcess, err := New(Config{
		RuntimeDir:       runtimeDir,
		ConfigPath:       configurationPath,
		TransportFactory: factory,
	})
	if err != nil {
		t.Fatal(err)
	}
	runDone := make(chan error, 1)
	go func() { runDone <- runtimeProcess.Run(context.Background()) }()
	select {
	case <-transport.postInitializationStarted:
	case err := <-runDone:
		if strings.Contains(fmt.Sprint(err), "start IPC server failed") {
			t.Skipf("Unix socket creation unavailable in this environment: %v", err)
		}
		t.Fatalf("runtime exited before publication gate: %v", err)
	case <-time.After(2 * time.Second):
		t.Fatal("initialization did not reach publication gate")
	}
	foreign, err := discovery.EncodeMetadata(discovery.Metadata{
		SchemaVersion: discovery.MetadataSchemaVersion,
		InstanceID:    "22222222-2222-4222-8222-222222222222",
		SocketName:    discovery.SocketFileName,
	})
	if err != nil {
		t.Fatal(err)
	}
	metadataPath := filepath.Join(runtimeDir, discovery.MetadataFileName)
	if err := os.WriteFile(metadataPath, foreign, 0o600); err != nil {
		t.Fatal(err)
	}
	close(transport.postInitializationGate)
	select {
	case err := <-runDone:
		if err == nil {
			t.Fatal("metadata publication failure was not reported")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("runtime did not unwind publication failure")
	}
	if _, err := os.Lstat(filepath.Join(runtimeDir, discovery.SocketFileName)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("socket after publication failure: %v", err)
	}
	if _, _, err := discovery.ValidateMetadata(metadataPath); err != nil {
		t.Fatalf("foreign metadata was not preserved: %v", err)
	}
	if _, err := os.Lstat(filepath.Join(runtimeDir, discovery.LockFileName)); err != nil {
		t.Fatalf("persistent lock after publication failure: %v", err)
	}
}

func TestRuntimeShutdownWithdrawsMetadataBeforeClosingDevice(t *testing.T) {
	configurationPath := filepath.Join(t.TempDir(), "valid.toml")
	if err := os.WriteFile(configurationPath, runtimeTestConfiguration(), 0o600); err != nil {
		t.Fatal(err)
	}
	runtimeDir := m03RuntimeSecureDirectory(t)
	transport := newRuntimeFakeTransport()
	closeStarted := make(chan struct{})
	closeGate := make(chan struct{})
	defer func() {
		select {
		case <-closeGate:
		default:
			close(closeGate)
		}
	}()
	transport.onClose = func() {
		close(closeStarted)
		<-closeGate
	}
	factory := &recordingFactory{transport: transport}
	runtimeProcess, err := New(Config{
		RuntimeDir:       runtimeDir,
		ConfigPath:       configurationPath,
		TransportFactory: factory,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := runtimeProcess.Start(); err != nil {
		if strings.Contains(err.Error(), "start IPC server failed") {
			t.Skipf("Unix socket creation unavailable in this environment: %v", err)
		}
		t.Fatalf("runtime startup: %v", err)
	}
	runtimeProcess.mu.Lock()
	server := runtimeProcess.server
	generation := runtimeProcess.generation
	runtimeProcess.mu.Unlock()
	if server == nil || generation == nil {
		t.Fatal("runtime did not retain discovery and IPC ownership")
	}
	ctx, cancel := context.WithCancel(context.Background())
	serveDone := make(chan error, 1)
	go func() { serveDone <- server.Serve(ctx) }()
	select {
	case <-server.ServingReady():
	case err := <-serveDone:
		t.Fatalf("IPC server exited before serving: %v", err)
	case <-time.After(2 * time.Second):
		t.Fatal("IPC server did not become ready")
	}
	if err := generation.PublishMetadata(); err != nil {
		t.Fatalf("publish metadata: %v", err)
	}
	metadataPath := filepath.Join(runtimeDir, discovery.MetadataFileName)
	closeDone := make(chan error, 1)
	go func() { closeDone <- runtimeProcess.Close() }()
	select {
	case <-closeStarted:
		if _, err := os.Lstat(metadataPath); !errors.Is(err, os.ErrNotExist) {
			t.Fatal("device closed before readiness metadata was withdrawn")
		}
		if _, err := os.Lstat(filepath.Join(runtimeDir, discovery.SocketFileName)); err != nil {
			t.Fatal("IPC socket closed before device; shutdown order changed")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("device close was not observed")
	}
	close(closeGate)
	select {
	case err := <-closeDone:
		if err != nil {
			t.Fatalf("runtime close: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("runtime close did not finish")
	}
	if _, err := os.Lstat(metadataPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("metadata after shutdown: %v", err)
	}
	if _, err := os.Lstat(filepath.Join(runtimeDir, discovery.SocketFileName)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("socket after shutdown: %v", err)
	}
	if _, err := os.Lstat(filepath.Join(runtimeDir, discovery.LockFileName)); err != nil {
		t.Fatalf("persistent lock after shutdown: %v", err)
	}
	cancel()
	select {
	case err := <-serveDone:
		if err != nil {
			t.Fatalf("IPC server after external close: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("IPC server did not stop after external close")
	}
}

func m03RuntimeSecureDirectory(t *testing.T) string {
	t.Helper()
	directory, err := os.MkdirTemp(".", ".r-")
	if err != nil {
		t.Fatal(err)
	}
	absolute, err := filepath.Abs(directory)
	if err != nil {
		_ = os.RemoveAll(directory)
		t.Fatal(err)
	}
	if err := os.Chmod(absolute, 0o700); err != nil {
		_ = os.RemoveAll(absolute)
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(absolute) })
	return absolute
}

func runtimeSocketTestDirectory(t *testing.T) string {
	t.Helper()
	const prefix = ".hidhogg-socket-test-"
	workspace, err := filepath.Abs(".")
	if err != nil {
		t.Fatal(err)
	}
	workspace, err = filepath.EvalSymlinks(workspace)
	if err != nil {
		t.Fatal(err)
	}
	directory, err := os.MkdirTemp(workspace, prefix)
	if err != nil {
		t.Fatal(err)
	}
	resolved, err := filepath.EvalSymlinks(directory)
	if err != nil {
		_ = os.RemoveAll(directory)
		t.Fatal(err)
	}
	if filepath.Dir(resolved) != workspace || !strings.HasPrefix(filepath.Base(resolved), prefix) {
		_ = os.RemoveAll(resolved)
		t.Fatalf("unsafe socket test directory: %q", resolved)
	}
	if err := os.Chmod(resolved, 0o700); err != nil {
		_ = os.RemoveAll(resolved)
		t.Fatal(err)
	}
	info, err := os.Stat(resolved)
	if err != nil {
		_ = os.RemoveAll(resolved)
		t.Fatal(err)
	}
	if !info.IsDir() || info.Mode().Perm() != 0o700 {
		_ = os.RemoveAll(resolved)
		t.Fatalf("socket test directory mode = %v, want directory 0700", info.Mode())
	}
	t.Cleanup(func() {
		if filepath.Dir(resolved) != workspace || !strings.HasPrefix(filepath.Base(resolved), prefix) {
			t.Errorf("refusing unsafe socket test cleanup target: %q", resolved)
			return
		}
		if err := os.RemoveAll(resolved); err != nil {
			t.Errorf("remove socket test directory: %v", err)
		}
	})
	return resolved
}

func assertM03DiscoveryEntriesUnwound(t *testing.T, runtimeDir string) {
	t.Helper()
	for _, name := range []string{discovery.SocketFileName, discovery.MetadataFileName} {
		if _, err := os.Lstat(filepath.Join(runtimeDir, name)); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("discovery entry %s after startup failure: %v", name, err)
		}
	}
	if _, err := os.Lstat(filepath.Join(runtimeDir, discovery.LockFileName)); err != nil {
		t.Fatalf("persistent lock after startup failure: %v", err)
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
		d200x.CommandUnlockScreen,
		d200x.CommandCompleteDisplayUpload,
		d200x.CommandBrightness,
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
	builder.WriteString("schema_version = 2\nadapter = \"ulanzi.d200x\"\nbrightness = 73\ndefault_profile_id = \"default\"\n\n[[profiles]]\nid = \"default\"\nlabel = \"Default\"\n\n")
	for index, spec := range d200x.SupportedPositions() {
		fmt.Fprintf(&builder, "[[profiles.positions]]\nid = \"tile-%s\"\nposition = \"%s\"\nlabel = \"Tile %d\"\nbackground = \"#102030\"\n\n", spec.Name, spec.Name, index)
	}
	return []byte(builder.String())
}

func runtimeMultiProfileConfiguration() []byte {
	var builder strings.Builder
	builder.WriteString("schema_version = 2\nadapter = \"ulanzi.d200x\"\nbrightness = 73\ndefault_profile_id = \"default\"\n\n")
	for _, profileID := range []string{"default", "alternate"} {
		fmt.Fprintf(&builder, "[[profiles]]\nid = \"%s\"\nlabel = \"%s\"\n\n", profileID, profileID)
		for index, spec := range d200x.SupportedPositions() {
			fmt.Fprintf(&builder, "[[profiles.positions]]\nid = \"%s-%s\"\nposition = \"%s\"\nlabel = \"%s %d\"\nbackground = \"#102030\"\n\n", profileID, spec.Name, spec.Name, profileID, index)
		}
	}
	return []byte(builder.String())
}

func countRuntimeCommand(commands []d200x.Command, want d200x.Command) int {
	count := 0
	for _, command := range commands {
		if command == want {
			count++
		}
	}
	return count
}

func runtimeStartupCommandSequence() []d200x.Command {
	return []d200x.Command{
		d200x.CommandUnlockScreen,
		d200x.CommandCompleteDisplayUpload,
		d200x.CommandBrightness,
		d200x.CommandEnableInputStream,
	}
}

func runtimeLiveCommandSequence(transitions int) []d200x.Command {
	commands := runtimeStartupCommandSequence()
	for index := 0; index < transitions; index++ {
		commands = append(commands, d200x.CommandCompleteDisplayUpload)
	}
	return commands
}

func runtimeCommandsEqual(got, want []d200x.Command) bool {
	return reflect.DeepEqual(got, want)
}

func assertRuntimeCommandSequence(t *testing.T, got, want []d200x.Command) {
	t.Helper()
	if !runtimeCommandsEqual(got, want) {
		t.Fatalf("commands = %v, want %v", got, want)
	}
}

type recordingFactory struct {
	mu               sync.Mutex
	transport        *runtimeFakeTransport
	enumerateErr     error
	openErr          error
	enumerateStarted chan struct{}
	enumerateGate    chan struct{}
	enumerateOnce    sync.Once
	called           []string
}

func (factory *recordingFactory) Enumerate(context.Context) ([]d200x.Candidate, error) {
	factory.mu.Lock()
	factory.called = append(factory.called, "enumerate")
	enumerateStarted := factory.enumerateStarted
	enumerateGate := factory.enumerateGate
	enumerateErr := factory.enumerateErr
	factory.mu.Unlock()
	if enumerateStarted != nil {
		factory.enumerateOnce.Do(func() { close(enumerateStarted) })
		<-enumerateGate
	}
	if enumerateErr != nil {
		return nil, enumerateErr
	}
	return []d200x.Candidate{d200x.NewCandidate("opaque-device-path", d200x.VendorID, d200x.ProductID, d200x.InterfaceNumber)}, nil
}

func (factory *recordingFactory) Open(context.Context, d200x.Candidate) (d200x.Transport, error) {
	factory.mu.Lock()
	factory.called = append(factory.called, "open")
	transport := factory.transport
	openErr := factory.openErr
	factory.mu.Unlock()
	if openErr != nil {
		return nil, openErr
	}
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
	mu                        sync.Mutex
	writes                    [][]byte
	readData                  chan []byte
	closed                    chan struct{}
	once                      sync.Once
	readErr                   error
	closeErr                  error
	readStarted               chan struct{}
	readGate                  chan struct{}
	readOnce                  sync.Once
	writeStarted              chan struct{}
	writeGate                 chan struct{}
	writeOnce                 sync.Once
	writeErr                  error
	nextWriteErr              error
	failAt                    int
	failErr                   error
	postInitializationStarted chan struct{}
	postInitializationGate    chan struct{}
	postInitializationOnce    sync.Once
	onClose                   func()
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

type deliberatelyUnsynchronizedWriter struct {
	data []byte
}

func (writer *deliberatelyUnsynchronizedWriter) Write(data []byte) (int, error) {
	for _, value := range data {
		writer.data = append(writer.data, value)
		goruntime.Gosched()
	}
	return len(data), nil
}

func (writer *deliberatelyUnsynchronizedWriter) String() string {
	return string(writer.data)
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
	if transport.readStarted != nil {
		transport.readOnce.Do(func() { close(transport.readStarted) })
		<-transport.readGate
	}
	if transport.readErr != nil {
		return 0, transport.readErr
	}
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
	writeIndex := len(transport.writes)
	nextWriteErr := transport.nextWriteErr
	transport.nextWriteErr = nil
	writeErr := transport.writeErr
	failAt := transport.failAt
	failErr := transport.failErr
	transport.mu.Unlock()
	if nextWriteErr != nil {
		return 0, nextWriteErr
	}
	if writeErr != nil {
		return 0, writeErr
	}
	if failAt > 0 && writeIndex == failAt {
		if failErr == nil {
			failErr = errors.New("injected write failure")
		}
		return 0, failErr
	}
	if transport.postInitializationStarted != nil {
		packet, err := d200x.NormalizeReport(report)
		if err == nil && d200x.Command(binary.BigEndian.Uint16(packet[2:4])) == d200x.CommandEnableInputStream {
			transport.postInitializationOnce.Do(func() {
				close(transport.postInitializationStarted)
				<-transport.postInitializationGate
			})
		}
	}
	return len(report), nil
}

func (transport *runtimeFakeTransport) failNextWrite(err error) {
	transport.mu.Lock()
	transport.nextWriteErr = err
	transport.mu.Unlock()
}

func (transport *runtimeFakeTransport) Close() error {
	closeErr := transport.closeErr
	transport.once.Do(func() {
		if transport.onClose != nil {
			transport.onClose()
		}
		close(transport.closed)
	})
	return closeErr
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

func waitForRuntimeMetadata(t *testing.T, path string, runDone <-chan error) {
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
			t.Fatalf("runtime exited before readiness metadata: %v", err)
		default:
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("readiness metadata did not become available")
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
