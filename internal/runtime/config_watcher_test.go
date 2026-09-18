package runtime

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/fsnotify/fsnotify"

	"hidhogg/internal/discovery"
)

func TestRelevantConfigEventFiltersBasenameAndOperations(t *testing.T) {
	tests := []struct {
		name  string
		event fsnotify.Event
		want  bool
	}{
		{name: "create", event: fsnotify.Event{Name: "/config/runtime.toml", Op: fsnotify.Create}, want: true},
		{name: "write", event: fsnotify.Event{Name: "/config/runtime.toml", Op: fsnotify.Write}, want: true},
		{name: "rename", event: fsnotify.Event{Name: "/config/runtime.toml", Op: fsnotify.Rename}, want: true},
		{name: "remove", event: fsnotify.Event{Name: "/config/runtime.toml", Op: fsnotify.Remove}, want: true},
		{name: "combined", event: fsnotify.Event{Name: "/config/runtime.toml", Op: fsnotify.Chmod | fsnotify.Write}, want: true},
		{name: "chmod", event: fsnotify.Event{Name: "/config/runtime.toml", Op: fsnotify.Chmod}},
		{name: "unrelated", event: fsnotify.Event{Name: "/config/other.toml", Op: fsnotify.Write}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := relevantConfigEvent(test.event, "runtime.toml"); got != test.want {
				t.Fatalf("relevant event = %t, want %t", got, test.want)
			}
		})
	}
}

func TestConfigWatcherUsesTrailingDebounceAndCoalescesBurst(t *testing.T) {
	clock := newPolicyFakeClock(time.Unix(1500, 0))
	source := newFakeConfigWatchSource()
	dirty := make(chan struct{}, 4)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan bool, 1)
	go func() {
		done <- runConfigWatcher(ctx, clock, source, "runtime.toml", func() { dirty <- struct{}{} })
	}()

	source.events <- fsnotify.Event{Name: "/config/runtime.toml", Op: fsnotify.Write}
	waitForPolicyTimers(t, clock, 1)
	source.events <- fsnotify.Event{Name: "/config/other.toml", Op: fsnotify.Write}
	source.events <- fsnotify.Event{Name: "/config/runtime.toml", Op: fsnotify.Chmod}
	source.events <- fsnotify.Event{Name: "/config/runtime.toml", Op: fsnotify.Create}
	waitForPolicyTimers(t, clock, 2)
	source.events <- fsnotify.Event{Name: "/config/runtime.toml", Op: fsnotify.Rename}
	waitForPolicyTimers(t, clock, 3)
	clock.advance(configReloadDebounce - time.Millisecond)
	select {
	case <-dirty:
		t.Fatal("debounce fired before the trailing deadline")
	default:
	}
	clock.advance(time.Millisecond)
	select {
	case <-dirty:
	case <-time.After(time.Second):
		t.Fatal("debounce did not emit a dirty hint")
	}
	select {
	case <-dirty:
		t.Fatal("burst emitted more than one dirty hint")
	default:
	}
	cancel()
	if failed := <-done; failed {
		t.Fatal("context cancellation reported watcher failure")
	}
}

func TestConfigWatcherErrorDisablesWithoutDirtyHint(t *testing.T) {
	source := newFakeConfigWatchSource()
	dirty := make(chan struct{}, 1)
	done := make(chan bool, 1)
	go func() {
		done <- runConfigWatcher(context.Background(), realClock{}, source, "runtime.toml", func() { dirty <- struct{}{} })
	}()
	source.errors <- errors.New("injected watcher failure")
	if failed := <-done; !failed {
		t.Fatal("watcher error was not classified as a runtime failure")
	}
	select {
	case <-dirty:
		t.Fatal("watcher error emitted a dirty hint")
	default:
	}
}

func TestFSNotifyConfigWatcherObservesDirectWriteAndAtomicReplacement(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "runtime.toml")
	if err := os.WriteFile(path, []byte("initial"), 0o600); err != nil {
		t.Fatal(err)
	}
	source, err := newFSNotifyConfigWatchSource()
	if err != nil {
		t.Fatal(err)
	}
	if err := source.Add(directory); err != nil {
		_ = source.Close()
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	dirty := make(chan struct{}, 4)
	done := make(chan bool, 1)
	go func() {
		defer source.Close()
		done <- runConfigWatcher(ctx, realClock{}, source, filepath.Base(path), func() { dirty <- struct{}{} })
	}()

	if err := os.WriteFile(path, []byte("direct"), 0o600); err != nil {
		t.Fatal(err)
	}
	waitForWatcherDirty(t, dirty)
	assertNoWatcherDirty(t, dirty)
	replacement := filepath.Join(directory, "replacement.tmp")
	if err := os.WriteFile(replacement, []byte("atomic"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(replacement, path); err != nil {
		t.Fatal(err)
	}
	waitForWatcherDirty(t, dirty)
	assertNoWatcherDirty(t, dirty)
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("recreated"), 0o600); err != nil {
		t.Fatal(err)
	}
	waitForWatcherDirty(t, dirty)
	assertNoWatcherDirty(t, dirty)
	cancel()
	if failed := <-done; failed {
		t.Fatal("watcher shutdown reported failure")
	}
}

func TestWatcherSetupFailureLeavesManualReloadAvailable(t *testing.T) {
	runtimeProcess, path := newReloadTestRuntime(t, reloadTestConfiguration(), &profilePageSender{}, nil)
	runtimeProcess.config.Verbose = true
	runtimeProcess.stderr = &synchronizedWriter{}
	runtimeProcess.clock = realClock{}
	runtimeProcess.automaticReload = make(chan struct{}, 1)
	runtimeProcess.configWatchFactory = func() (configWatchSource, error) {
		return nil, errors.New("injected setup failure")
	}
	done := runtimeProcess.startConfigWatcher(context.Background())
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("setup failure did not disable watcher promptly")
	}
	changed := bytes.Replace(reloadTestConfiguration(), []byte("label = \"default 0\""), []byte("label = \"changed 0\""), 1)
	writeReloadTestFile(t, path, changed)
	result, err := runtimeProcess.Reload(context.Background())
	if err != nil || !result.Changed || result.Revision != 2 {
		t.Fatalf("manual reload after watcher setup failure = %+v, %v", result, err)
	}
}

func TestWatcherRuntimeFailureLeavesManualReloadAvailable(t *testing.T) {
	runtimeProcess, path := newReloadTestRuntime(t, reloadTestConfiguration(), &profilePageSender{}, nil)
	logOutput := &synchronizedWriter{}
	runtimeProcess.config.Verbose = true
	runtimeProcess.stderr = logOutput
	runtimeProcess.clock = realClock{}
	runtimeProcess.automaticReload = make(chan struct{}, 1)
	source := newFakeConfigWatchSource()
	runtimeProcess.configWatchFactory = func() (configWatchSource, error) { return source, nil }
	done := runtimeProcess.startConfigWatcher(context.Background())
	source.errors <- errors.New("/private/config.toml: injected raw watcher failure")
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("runtime failure did not disable watcher promptly")
	}
	if output := logOutput.String(); output != "runtime config watcher disabled: runtime failure\n" {
		t.Fatalf("watcher diagnostic = %q", output)
	}
	changed := bytes.Replace(reloadTestConfiguration(), []byte("label = \"default 0\""), []byte("label = \"changed 0\""), 1)
	writeReloadTestFile(t, path, changed)
	result, err := runtimeProcess.Reload(context.Background())
	if err != nil || !result.Changed || result.Revision != 2 {
		t.Fatalf("manual reload after watcher runtime failure = %+v, %v", result, err)
	}
}

func TestRuntimeRunOwnsWatcherAndAutomaticallyReloads(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "runtime.toml")
	base := reloadTestConfiguration()
	if err := os.WriteFile(path, base, 0o600); err != nil {
		t.Fatal(err)
	}
	runtimeDir := m03RuntimeSecureDirectory(t)
	transport := newRuntimeFakeTransport()
	runtimeProcess, err := New(Config{
		RuntimeDir:       runtimeDir,
		InstanceID:       runtimeTestInstanceID,
		ConfigPath:       path,
		TransportFactory: &recordingFactory{transport: transport},
	})
	if err != nil {
		t.Fatal(err)
	}
	source := newFakeConfigWatchSource()
	var factoryCalls int
	runtimeProcess.configWatchFactory = func() (configWatchSource, error) {
		factoryCalls++
		return source, nil
	}
	if err := runtimeProcess.Start(); err != nil {
		t.Fatal(err)
	}
	if factoryCalls != 0 {
		t.Fatalf("watcher factory calls during Start = %d, want 0", factoryCalls)
	}
	ctx, cancel := context.WithCancel(context.Background())
	runDone := make(chan error, 1)
	go func() { runDone <- runtimeProcess.Run(ctx) }()
	paths, err := discovery.NewPaths(runtimeDir)
	if err != nil {
		t.Fatal(err)
	}
	waitForRuntimeMetadata(t, paths.MetadataPath, runDone)
	waitForRuntime(t, func() bool { return source.addedPath() == directory })
	changed := bytes.Replace(base, []byte("label = \"default 0\""), []byte("label = \"automatic 0\""), 1)
	writeReloadTestFile(t, path, changed)
	source.events <- fsnotify.Event{Name: path, Op: fsnotify.Write}
	waitForRuntime(t, func() bool { return runtimeProcess.ReloadStatus().Revision == 2 })
	cancel()
	select {
	case err := <-runDone:
		if err != nil {
			t.Fatalf("runtime shutdown: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("runtime did not join watcher during shutdown")
	}
	if source.closeCallCount() != 1 {
		t.Fatalf("watcher close calls = %d, want 1", source.closeCallCount())
	}
}

func TestAutomaticReloadDirtyBitRunsOnceAfterManualReload(t *testing.T) {
	runtimeProcess, _ := newReloadTestRuntime(t, reloadTestConfiguration(), &profilePageSender{}, nil)
	runtimeProcess.automaticReload = make(chan struct{}, 1)
	started := make(chan struct{})
	release := make(chan struct{})
	var calls int
	var callsMu sync.Mutex
	runtimeProcess.reloadBuilder = func(path, currentID string) (reloadCandidate, error) {
		callsMu.Lock()
		calls++
		currentCall := calls
		callsMu.Unlock()
		if currentCall == 1 {
			close(started)
			<-release
		}
		return buildReloadCandidate(path, currentID)
	}
	ctx, cancel := context.WithCancel(context.Background())
	automaticDone := make(chan struct{})
	go func() {
		defer close(automaticDone)
		runtimeProcess.runAutomaticReloads(ctx)
	}()
	manualDone := make(chan error, 1)
	go func() {
		_, err := runtimeProcess.Reload(context.Background())
		manualDone <- err
	}()
	<-started
	runtimeProcess.signalAutomaticReload()
	waitForRuntime(t, func() bool {
		runtimeProcess.reload.mu.Lock()
		defer runtimeProcess.reload.mu.Unlock()
		return runtimeProcess.reload.dirty
	})
	if _, err := runtimeProcess.Reload(context.Background()); !errors.Is(err, ErrReloadBusy) {
		t.Fatalf("manual concurrent reload error = %v", err)
	}
	close(release)
	if err := <-manualDone; err != nil {
		t.Fatal(err)
	}
	waitForRuntime(t, func() bool {
		callsMu.Lock()
		defer callsMu.Unlock()
		return calls == 2
	})
	assertNoAutomaticSignal(t, runtimeProcess.automaticReload)
	cancel()
	<-automaticDone
}

func TestAutomaticReloadRejectsInvalidStableContentOnceAndRecoversOnDirty(t *testing.T) {
	runtimeProcess, path := newReloadTestRuntime(t, reloadTestConfiguration(), &profilePageSender{}, nil)
	runtimeProcess.automaticReload = make(chan struct{}, 1)
	var calls int
	var callsMu sync.Mutex
	runtimeProcess.reloadBuilder = func(path, currentID string) (reloadCandidate, error) {
		callsMu.Lock()
		calls++
		callsMu.Unlock()
		return buildReloadCandidate(path, currentID)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		runtimeProcess.runAutomaticReloads(ctx)
	}()
	writeReloadTestFile(t, path, []byte("schema_version = 3\n"))
	runtimeProcess.signalAutomaticReload()
	waitForRuntime(t, func() bool {
		callsMu.Lock()
		defer callsMu.Unlock()
		return calls == 1 && runtimeProcess.ReloadStatus().Outcome == ReloadOutcomeRejected
	})
	time.Sleep(2 * configReloadDebounce)
	callsMu.Lock()
	stableCalls := calls
	callsMu.Unlock()
	if stableCalls != 1 {
		t.Fatalf("invalid stable content attempts = %d, want 1", stableCalls)
	}
	changed := bytes.Replace(reloadTestConfiguration(), []byte("label = \"default 0\""), []byte("label = \"recovered 0\""), 1)
	writeReloadTestFile(t, path, changed)
	runtimeProcess.signalAutomaticReload()
	waitForRuntime(t, func() bool {
		callsMu.Lock()
		defer callsMu.Unlock()
		return calls == 2 && runtimeProcess.ReloadStatus().Revision == 2
	})
	cancel()
	<-done
}

func TestAutomaticReloadCoalescesSignalsDuringActiveAttempt(t *testing.T) {
	runtimeProcess, _ := newReloadTestRuntime(t, reloadTestConfiguration(), &profilePageSender{}, nil)
	runtimeProcess.automaticReload = make(chan struct{}, 1)
	started := make(chan struct{})
	release := make(chan struct{})
	var calls int
	var callsMu sync.Mutex
	runtimeProcess.reloadBuilder = func(path, currentID string) (reloadCandidate, error) {
		callsMu.Lock()
		calls++
		currentCall := calls
		callsMu.Unlock()
		if currentCall == 1 {
			close(started)
			<-release
		}
		return buildReloadCandidate(path, currentID)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		runtimeProcess.runAutomaticReloads(ctx)
	}()
	runtimeProcess.signalAutomaticReload()
	<-started
	for range 8 {
		runtimeProcess.signalAutomaticReload()
	}
	close(release)
	waitForRuntime(t, func() bool {
		callsMu.Lock()
		defer callsMu.Unlock()
		return calls == 2
	})
	time.Sleep(2 * configReloadDebounce)
	callsMu.Lock()
	finalCalls := calls
	callsMu.Unlock()
	if finalCalls != 2 {
		t.Fatalf("automatic attempts = %d, want 2", finalCalls)
	}
	cancel()
	<-done
}

type fakeConfigWatchSource struct {
	events chan fsnotify.Event
	errors chan error
	mu     sync.Mutex
	added  string
	closed int
}

func newFakeConfigWatchSource() *fakeConfigWatchSource {
	return &fakeConfigWatchSource{events: make(chan fsnotify.Event, 16), errors: make(chan error, 1)}
}

func (source *fakeConfigWatchSource) Add(path string) error {
	source.mu.Lock()
	source.added = path
	source.mu.Unlock()
	return nil
}

func (source *fakeConfigWatchSource) Close() error {
	source.mu.Lock()
	source.closed++
	source.mu.Unlock()
	return nil
}

func (source *fakeConfigWatchSource) Events() <-chan fsnotify.Event { return source.events }
func (source *fakeConfigWatchSource) Errors() <-chan error          { return source.errors }

func (source *fakeConfigWatchSource) addedPath() string {
	source.mu.Lock()
	defer source.mu.Unlock()
	return source.added
}

func (source *fakeConfigWatchSource) closeCallCount() int {
	source.mu.Lock()
	defer source.mu.Unlock()
	return source.closed
}

func waitForWatcherDirty(t *testing.T, dirty <-chan struct{}) {
	t.Helper()
	select {
	case <-dirty:
	case <-time.After(2 * time.Second):
		t.Fatal("watcher did not emit a dirty hint")
	}
}

func assertNoWatcherDirty(t *testing.T, dirty <-chan struct{}) {
	t.Helper()
	select {
	case <-dirty:
		t.Fatal("watcher emitted an extra dirty hint")
	case <-time.After(2 * configReloadDebounce):
	}
}

func assertNoAutomaticSignal(t *testing.T, signal <-chan struct{}) {
	t.Helper()
	select {
	case <-signal:
		t.Fatal("automatic reload retained more than one signal")
	default:
	}
}
