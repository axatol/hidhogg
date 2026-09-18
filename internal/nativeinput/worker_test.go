package nativeinput

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"hidhogg/internal/execution"
)

type testBackend struct {
	mu sync.Mutex

	permission bool
	checkErr   error
	postErr    error

	posted []Request

	postStarted         chan struct{}
	postRelease         chan struct{}
	requestStarted      chan struct{}
	requestRelease      chan struct{}
	closeCalled         chan struct{}
	requestResult       bool
	ignoreCancel        bool
	requestIgnoreCancel bool
	blockCheck          bool
	checkStarted        chan struct{}
	checkRelease        chan struct{}
}

func newTestBackend(permission bool) *testBackend {
	return &testBackend{
		permission:     permission,
		postStarted:    make(chan struct{}),
		postRelease:    make(chan struct{}),
		requestStarted: make(chan struct{}),
		requestRelease: make(chan struct{}),
		closeCalled:    make(chan struct{}),
		requestResult:  true,
		checkStarted:   make(chan struct{}),
		checkRelease:   make(chan struct{}),
	}
}

func (backend *testBackend) CheckPermission() (bool, error) {
	backend.mu.Lock()
	permission, checkErr, block := backend.permission, backend.checkErr, backend.blockCheck
	backend.mu.Unlock()
	if block {
		select {
		case <-backend.checkStarted:
		default:
			close(backend.checkStarted)
		}
		<-backend.checkRelease
	}
	return permission, checkErr
}

func (backend *testBackend) RequestPermission(ctx context.Context) (bool, error) {
	select {
	case <-backend.requestStarted:
	default:
		close(backend.requestStarted)
	}
	backend.mu.Lock()
	ignoreCancel := backend.requestIgnoreCancel
	backend.mu.Unlock()
	if ignoreCancel {
		<-backend.requestRelease
	} else {
		select {
		case <-backend.requestRelease:
		case <-ctx.Done():
			return false, ctx.Err()
		}
	}
	backend.mu.Lock()
	granted := backend.requestResult
	backend.permission = granted
	backend.mu.Unlock()
	return granted, nil
}

func (backend *testBackend) Post(ctx context.Context, request Request) error {
	backend.mu.Lock()
	backend.posted = append(backend.posted, request)
	backend.mu.Unlock()
	select {
	case <-backend.postStarted:
	default:
		close(backend.postStarted)
	}
	backend.mu.Lock()
	ignoreCancel := backend.ignoreCancel
	backend.mu.Unlock()
	if ignoreCancel {
		<-backend.postRelease
	} else {
		select {
		case <-backend.postRelease:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	backend.mu.Lock()
	err := backend.postErr
	backend.mu.Unlock()
	return err
}

func (backend *testBackend) Close() error {
	select {
	case <-backend.closeCalled:
	default:
		close(backend.closeCalled)
	}
	return nil
}

func (backend *testBackend) setPermission(granted bool) {
	backend.mu.Lock()
	backend.permission = granted
	backend.mu.Unlock()
}

func (backend *testBackend) requests() []Request {
	backend.mu.Lock()
	defer backend.mu.Unlock()
	return append([]Request(nil), backend.posted...)
}

func testRequest(index int) Request {
	return Request{ProfileID: "profile", PositionID: "position", Text: string(rune('a' + index%26))}
}

func TestNewNeverReturnsAnInitializationError(t *testing.T) {
	worker := New()
	status := worker.Status()
	if status.QueueCapacity != QueueCapacity {
		t.Fatalf("startup status = %+v", status)
	}
	if status.BackendState != BackendReady {
		record, err := worker.Submit(testRequest(0))
		if err != nil || record.State != execution.StateFailed {
			t.Fatalf("unsupported submit = %+v, error %v", record, err)
		}
	}
	if err := worker.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestInitializationFailureIsRepresentedWithoutReturningAnError(t *testing.T) {
	worker := newWorker(nil, BackendInitializationFailed, "")
	status := worker.Status()
	if status.BackendState != BackendInitializationFailed || status.Ready || status.Detail == "" {
		t.Fatalf("initialization status = %+v", status)
	}
	record, err := worker.Submit(testRequest(0))
	if err != nil || record.State != execution.StateFailed {
		t.Fatalf("initialization submit = %+v, error %v", record, err)
	}
	if err := worker.Close(); err != nil {
		t.Fatal(err)
	}
}

func waitFor(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("condition was not reached")
}

func TestWorkerFIFOAndSaturation(t *testing.T) {
	backend := newTestBackend(true)
	worker := NewWithBackend(backend)
	first, err := worker.Submit(testRequest(0))
	if err != nil {
		t.Fatal(err)
	}
	<-backend.postStarted
	for index := 1; index <= QueueCapacity; index++ {
		record, err := worker.Submit(testRequest(index))
		if err != nil || record.State != execution.StateQueued {
			t.Fatalf("submit %d = state %s, error %v", index, record.State, err)
		}
	}
	rejected, err := worker.Submit(testRequest(QueueCapacity + 1))
	if err != nil || rejected.State != execution.StateRejectedQueueFull {
		t.Fatalf("saturated submit = state %s, error %v", rejected.State, err)
	}
	if status := worker.Status(); status.QueueDepth != QueueCapacity || status.QueueCapacity != QueueCapacity {
		t.Fatalf("status = %+v", status)
	}
	close(backend.postRelease)
	waitFor(t, func() bool {
		return worker.Status().QueueDepth == 0 && !worker.Status().RequestInProgress && len(backend.requests()) == QueueCapacity+1
	})
	posted := backend.requests()
	if posted[0] != (testRequest(0)) {
		t.Fatalf("first post = %+v", posted[0])
	}
	for index := 1; index < len(posted); index++ {
		if posted[index] != testRequest(index) {
			t.Fatalf("post %d = %+v, want %+v", index, posted[index], testRequest(index))
		}
	}
	if _, ok := worker.Get(first.ID); !ok {
		t.Fatal("posted record was not retained")
	}
	if err := worker.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestWorkerPermissionCacheAndRefresh(t *testing.T) {
	backend := newTestBackend(false)
	worker := NewWithBackend(backend)
	record, err := worker.Submit(testRequest(0))
	if err != nil || record.State != execution.StatePermissionDenied {
		t.Fatalf("denied submit = %+v, error %v", record, err)
	}
	backend.setPermission(true)
	status := worker.Status()
	if !status.Ready || status.Permission != PermissionGranted {
		t.Fatalf("refreshed status = %+v", status)
	}
	record, err = worker.Submit(Request{ProfileID: "profile", PositionID: "position", Key: KeyEnter})
	if err != nil || record.ActionType != ActionTypeKeyPress || record.State != execution.StateQueued {
		t.Fatalf("enter submit = %+v, error %v", record, err)
	}
	waitFor(t, func() bool { return worker.Status().QueueDepth == 0 && len(backend.requests()) == 1 })
	if backend.requests()[0].Key != KeyEnter {
		t.Fatalf("posted request = %+v", backend.requests()[0])
	}
	close(backend.postRelease)
	if err := worker.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestPermissionRequestCancelsWaitingAndRejectsAdmission(t *testing.T) {
	backend := newTestBackend(true)
	worker := NewWithBackend(backend)
	active, err := worker.Submit(testRequest(0))
	if err != nil {
		t.Fatal(err)
	}
	<-backend.postStarted
	waiting, err := worker.Submit(testRequest(1))
	if err != nil {
		t.Fatal(err)
	}
	permissionDone := make(chan error, 1)
	var permissionStatus Status
	go func() {
		permissionStatus, err = worker.RequestPermission(context.Background())
		permissionDone <- err
	}()
	waitFor(t, func() bool { return worker.Status().RequestInProgress })
	rejected, err := worker.Submit(testRequest(2))
	if err != nil || rejected.State != execution.StateRejectedBusy {
		t.Fatalf("busy submit = %+v, error %v", rejected, err)
	}
	if status := worker.Status(); status.Ready {
		t.Fatalf("permission-request status unexpectedly ready: %+v", status)
	}
	close(backend.postRelease)
	close(backend.requestRelease)
	if err := <-permissionDone; err != nil {
		t.Fatal(err)
	}
	if !permissionStatus.Ready {
		t.Fatalf("permission result = %+v", permissionStatus)
	}
	waitFor(t, func() bool {
		record, ok := worker.Get(waiting.ID)
		return ok && record.State == execution.StateCanceled
	})
	if posted := backend.requests(); len(posted) != 1 || posted[0] != testRequest(0) {
		t.Fatalf("posts after permission request = %+v", posted)
	}
	if _, ok := worker.Get(active.ID); !ok {
		t.Fatal("active record was lost")
	}
	if err := worker.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestPermissionRequestCancelsAdmittedItemBeforeNativePreparation(t *testing.T) {
	backend := newTestBackend(true)
	worker := NewWithBackend(backend)
	backend.mu.Lock()
	backend.blockCheck = true
	backend.mu.Unlock()
	queued, err := worker.Submit(testRequest(0))
	if err != nil {
		t.Fatal(err)
	}
	<-backend.checkStarted
	permissionDone := make(chan error, 1)
	go func() {
		_, requestErr := worker.RequestPermission(context.Background())
		permissionDone <- requestErr
	}()
	waitFor(t, func() bool { return worker.Status().RequestInProgress })
	close(backend.checkRelease)
	close(backend.requestRelease)
	if err := <-permissionDone; err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool {
		record, ok := worker.Get(queued.ID)
		return ok && record.State == execution.StateCanceled
	})
	if len(backend.requests()) != 0 {
		t.Fatalf("canceled admitted item posted: %#v", backend.requests())
	}
	if err := worker.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestPermissionRequestContextCancellationKeepsAdmissionClosedUntilNativeFinish(t *testing.T) {
	backend := newTestBackend(true)
	backend.requestIgnoreCancel = true
	worker := NewWithBackend(backend)
	ctx, cancel := context.WithCancel(context.Background())
	resultCh := make(chan struct {
		status Status
		err    error
	}, 1)
	go func() {
		status, requestErr := worker.RequestPermission(ctx)
		resultCh <- struct {
			status Status
			err    error
		}{status: status, err: requestErr}
	}()
	<-backend.requestStarted
	cancel()
	result := <-resultCh
	status, err := result.status, result.err
	if !errors.Is(err, context.Canceled) || !status.RequestInProgress {
		t.Fatalf("canceled permission request status=%+v error=%v", status, err)
	}
	rejected, err := worker.Submit(testRequest(0))
	if err != nil || rejected.State != execution.StateRejectedBusy {
		t.Fatalf("admission during canceled request = %+v, error=%v", rejected, err)
	}
	close(backend.requestRelease)
	waitFor(t, func() bool { return !worker.Status().RequestInProgress })
	record, err := worker.Submit(testRequest(1))
	if err != nil || record.State != execution.StateQueued {
		t.Fatalf("post-cancellation admission = %+v, error=%v", record, err)
	}
	close(backend.postRelease)
	waitFor(t, func() bool { return len(backend.requests()) == 1 && worker.Status().QueueDepth == 0 })
	if err := worker.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestPermissionRequestCancelsActivePostAsCanceled(t *testing.T) {
	backend := newTestBackend(true)
	worker := NewWithBackend(backend)
	active, err := worker.Submit(testRequest(0))
	if err != nil {
		t.Fatal(err)
	}
	<-backend.postStarted
	permissionDone := make(chan error, 1)
	go func() {
		_, requestErr := worker.RequestPermission(context.Background())
		permissionDone <- requestErr
	}()
	waitFor(t, func() bool { return worker.Status().RequestInProgress })
	waitFor(t, func() bool {
		record, ok := worker.Get(active.ID)
		return ok && record.State == execution.StateCanceled
	})
	if posted := backend.requests(); len(posted) != 1 {
		t.Fatalf("posts after cancellation = %d, want one backend call", len(posted))
	}
	close(backend.requestRelease)
	if err := <-permissionDone; err != nil {
		t.Fatal(err)
	}
	if err := worker.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestCloseDefersBackendReleaseUntilPermissionRequestReturns(t *testing.T) {
	backend := newTestBackend(true)
	worker := NewWithBackend(backend)
	permissionDone := make(chan error, 1)
	go func() {
		_, requestErr := worker.RequestPermission(context.Background())
		permissionDone <- requestErr
	}()
	select {
	case <-backend.requestStarted:
	case <-time.After(time.Second):
		t.Fatal("permission request did not reach backend")
	}
	closeDone := make(chan error, 1)
	go func() { closeDone <- worker.Close() }()
	waitFor(t, func() bool { return worker.Status().BackendState == BackendClosed })
	select {
	case <-backend.closeCalled:
		t.Fatal("backend closed while permission request was blocked")
	default:
	}
	close(backend.requestRelease)
	if err := <-permissionDone; err != nil {
		t.Fatal(err)
	}
	if err := <-closeDone; err != nil {
		t.Fatal(err)
	}
	select {
	case <-backend.closeCalled:
	default:
		t.Fatal("backend was not closed after permission completion")
	}
}

func TestCloseWaitsForNativeCallBeforeBackendRelease(t *testing.T) {
	backend := newTestBackend(true)
	backend.ignoreCancel = true
	worker := NewWithBackend(backend)
	if _, err := worker.Submit(testRequest(0)); err != nil {
		t.Fatal(err)
	}
	<-backend.postStarted
	closed := make(chan error, 1)
	go func() { closed <- worker.Close() }()
	select {
	case <-backend.closeCalled:
		t.Fatal("backend closed while post was still blocked")
	case <-time.After(20 * time.Millisecond):
	}
	close(backend.postRelease)
	if err := <-closed; err != nil {
		t.Fatal(err)
	}
	select {
	case <-backend.closeCalled:
	default:
		t.Fatal("backend was not closed after native completion")
	}
	if _, err := worker.Submit(testRequest(1)); !errors.Is(err, ErrClosed) {
		t.Fatalf("submit after close error = %v", err)
	}
}

func TestCloseReportsPendingWhenNativeCallIgnoresCancellation(t *testing.T) {
	backend := newTestBackend(true)
	backend.ignoreCancel = true
	worker := NewWithBackend(backend)
	if _, err := worker.Submit(testRequest(0)); err != nil {
		t.Fatal(err)
	}
	<-backend.postStarted
	if err := worker.Close(); !errors.Is(err, ErrClosePending) {
		t.Fatalf("blocked close error = %v, want %v", err, ErrClosePending)
	}
	select {
	case <-backend.closeCalled:
		t.Fatal("backend was released while native call remained blocked")
	default:
	}
	close(backend.postRelease)
	if err := worker.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-backend.closeCalled:
	default:
		t.Fatal("backend was not released after blocked call completed")
	}
}

func TestRequestValidationUTF16AndNUL(t *testing.T) {
	backend := newTestBackend(true)
	worker := NewWithBackend(backend)
	valid := "😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀"
	if _, err := worker.Submit(Request{ProfileID: "profile", PositionID: "position", Text: valid}); err != nil {
		t.Fatalf("64-unit text rejected: %v", err)
	}
	for name, request := range map[string]Request{
		"too long": {ProfileID: "profile", PositionID: "position", Text: valid + "😀"},
		"NUL":      {ProfileID: "profile", PositionID: "position", Text: "a\x00b"},
		"empty":    {ProfileID: "profile", PositionID: "position"},
		"both":     {ProfileID: "profile", PositionID: "position", Text: "a", Key: KeyEnter},
		"key":      {ProfileID: "profile", PositionID: "position", Key: "return"},
	} {
		if _, err := worker.Submit(request); !errors.Is(err, ErrInvalidRequest) {
			t.Errorf("%s error = %v", name, err)
		}
	}
	close(backend.postRelease)
	waitFor(t, func() bool { return worker.Status().QueueDepth == 0 })
	if err := worker.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestWorkerHistoryIsBoundedAndEvictsOldestCompletedRecords(t *testing.T) {
	backend := newTestBackend(true)
	close(backend.postRelease)
	worker := NewWithBackend(backend)
	ids := make([]string, execution.HistoryLimit+1)
	for index := range ids {
		record, err := worker.Submit(testRequest(index))
		if err != nil {
			t.Fatal(err)
		}
		ids[index] = record.ID
		waitFor(t, func() bool {
			completed, ok := worker.Get(record.ID)
			return ok && completed.State == execution.StatePosted
		})
	}
	summaries, err := worker.ListSummaries(execution.HistoryLimit)
	if err != nil {
		t.Fatal(err)
	}
	if len(summaries) != execution.HistoryLimit || summaries[0].ID != ids[len(ids)-1] {
		t.Fatalf("history length/order = %d/%q", len(summaries), summaries[0].ID)
	}
	if _, ok := worker.Get(ids[0]); ok {
		t.Fatal("oldest completed native record was not evicted")
	}
	if _, ok := worker.Get(ids[len(ids)-1]); !ok {
		t.Fatal("newest native record was evicted")
	}
	if err := worker.Close(); err != nil {
		t.Fatal(err)
	}
}
