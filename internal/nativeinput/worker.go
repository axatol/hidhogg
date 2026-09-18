package nativeinput

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"sync"
	"time"

	"hidhogg/internal/execution"
)

const closeTimeout = 2 * time.Second

type Worker struct {
	mu       sync.Mutex
	nativeMu sync.Mutex

	backend       Backend
	backendState  BackendState
	backendDetail string
	permission    Permission
	closed        bool

	requestInProgress bool
	permissionDone    chan struct{}

	active  *workItem
	waiting []*workItem

	history     []execution.Record
	outstanding map[string]*execution.Record

	closeDone chan struct{}
	closeErr  error
	now       func() time.Time
}

type workItem struct {
	id              string
	request         Request
	ctx             context.Context
	cancel          context.CancelFunc
	done            chan struct{}
	started         bool
	cancelRequested bool
}

type permissionResult struct {
	granted bool
	err     error
}

func New() *Worker {
	backend, state, detail := newPlatformBackend()
	worker := newWorker(backend, state, detail)
	if backend != nil && state == BackendReady {
		worker.refreshPermissionAtConstruction()
	}
	return worker
}

func NewWithBackend(backend Backend) *Worker {
	if backend == nil {
		return newWorker(nil, BackendInitializationFailed, detailInitialization)
	}
	worker := newWorker(backend, BackendReady, "")
	worker.refreshPermissionAtConstruction()
	return worker
}

func newWorker(backend Backend, state BackendState, detail string) *Worker {
	if state == "" {
		state = BackendInitializationFailed
	}
	if detail == "" {
		switch state {
		case BackendUnsupported:
			detail = detailUnsupported
		case BackendInitializationFailed:
			detail = detailInitialization
		}
	}
	return &Worker{
		backend:       backend,
		backendState:  state,
		backendDetail: detail,
		permission:    PermissionNotGranted,
		outstanding:   make(map[string]*execution.Record),
		closeDone:     make(chan struct{}),
		now:           time.Now,
	}
}

func (worker *Worker) refreshPermissionAtConstruction() {
	worker.nativeMu.Lock()
	granted, err := worker.backend.CheckPermission()
	worker.nativeMu.Unlock()
	worker.mu.Lock()
	worker.setPermissionLocked(granted, err)
	worker.mu.Unlock()
}

func (worker *Worker) Submit(request Request) (execution.Record, error) {
	if worker == nil {
		return execution.Record{}, ErrClosed
	}
	_, actionType, err := validateRequest(request)
	if err != nil {
		return execution.Record{}, err
	}
	now := worker.now()
	worker.mu.Lock()
	if worker.closed {
		worker.mu.Unlock()
		return execution.Record{}, ErrClosed
	}
	id, err := worker.nextIDLocked()
	if err != nil {
		worker.mu.Unlock()
		return execution.Record{}, err
	}
	record := execution.Record{
		ActionType:  actionType,
		ID:          id,
		ProfileID:   request.ProfileID,
		PositionID:  request.PositionID,
		State:       execution.StateQueued,
		SubmittedAt: now,
	}
	returnRecord := cloneRecord(record)

	if worker.requestInProgress {
		record.State = execution.StateRejectedBusy
		worker.finishAdmissionLocked(&record, now)
		returnRecord = cloneRecord(record)
		worker.mu.Unlock()
		return returnRecord, nil
	}
	if worker.backendState != BackendReady {
		record.State = execution.StateFailed
		worker.finishAdmissionLocked(&record, now)
		returnRecord = cloneRecord(record)
		worker.mu.Unlock()
		return returnRecord, nil
	}
	if worker.permission == PermissionCheckFailed {
		record.State = execution.StateFailed
		worker.finishAdmissionLocked(&record, now)
		returnRecord = cloneRecord(record)
		worker.mu.Unlock()
		return returnRecord, nil
	}
	if worker.permission != PermissionGranted {
		record.State = execution.StatePermissionDenied
		worker.finishAdmissionLocked(&record, now)
		returnRecord = cloneRecord(record)
		worker.mu.Unlock()
		return returnRecord, nil
	}

	item := &workItem{
		id:      record.ID,
		request: request,
		done:    make(chan struct{}),
	}
	item.ctx, item.cancel = context.WithCancel(context.Background())
	if worker.active != nil && len(worker.waiting) >= QueueCapacity {
		record.State = execution.StateRejectedQueueFull
		worker.finishAdmissionLocked(&record, now)
		returnRecord = cloneRecord(record)
		worker.mu.Unlock()
		return returnRecord, nil
	}
	worker.outstanding[record.ID] = &record
	worker.appendHistoryLocked(record)
	start := false
	if worker.active == nil {
		worker.active = item
		start = true
	} else {
		worker.waiting = append(worker.waiting, item)
	}
	worker.mu.Unlock()
	if start {
		go worker.run(item)
	}
	return returnRecord, nil
}

func (worker *Worker) Status() Status {
	if worker == nil {
		return Status{BackendState: BackendClosed, Permission: PermissionNotGranted, QueueCapacity: QueueCapacity, Detail: detailClosed}
	}
	worker.refreshPermission()
	worker.mu.Lock()
	defer worker.mu.Unlock()
	return worker.statusLocked()
}

func (worker *Worker) refreshPermission() {
	worker.mu.Lock()
	if worker.closed || worker.requestInProgress || worker.backendState != BackendReady || worker.backend == nil {
		worker.mu.Unlock()
		return
	}
	backend := worker.backend
	worker.mu.Unlock()
	if !worker.nativeMu.TryLock() {
		return
	}
	granted, err := backend.CheckPermission()
	worker.nativeMu.Unlock()
	worker.mu.Lock()
	if !worker.closed && !worker.requestInProgress && worker.backend == backend {
		worker.setPermissionLocked(granted, err)
	}
	worker.mu.Unlock()
}

func (worker *Worker) statusLocked() Status {
	state := worker.backendState
	permission := worker.permission
	detail := worker.backendDetail
	if worker.closed {
		state = BackendClosed
		detail = detailClosed
	}
	if detail == "" {
		switch {
		case state == BackendUnsupported:
			detail = detailUnsupported
		case state == BackendInitializationFailed:
			detail = detailInitialization
		case worker.requestInProgress:
			detail = detailPermissionRequest
		case permission == PermissionCheckFailed:
			detail = detailPermissionCheck
		case permission != PermissionGranted:
			detail = detailPermission
		}
	}
	ready := state == BackendReady && permission == PermissionGranted && !worker.closed && !worker.requestInProgress
	return Status{
		BackendState:      state,
		Permission:        permission,
		Ready:             ready,
		QueueDepth:        len(worker.waiting),
		QueueCapacity:     QueueCapacity,
		RequestInProgress: worker.requestInProgress,
		Detail:            detail,
	}
}

func (worker *Worker) RequestPermission(ctx context.Context) (Status, error) {
	if worker == nil {
		return Status{BackendState: BackendClosed, Permission: PermissionNotGranted, QueueCapacity: QueueCapacity, Detail: detailClosed}, ErrClosed
	}
	if ctx == nil {
		ctx = context.Background()
	}
	worker.mu.Lock()
	if worker.closed {
		status := worker.statusLocked()
		worker.mu.Unlock()
		return status, ErrClosed
	}
	if worker.backendState == BackendUnsupported {
		status := worker.statusLocked()
		worker.mu.Unlock()
		return status, ErrUnsupportedPlatform
	}
	if worker.backendState != BackendReady || worker.backend == nil {
		status := worker.statusLocked()
		worker.mu.Unlock()
		return status, ErrInitializationFailed
	}
	if worker.requestInProgress {
		status := worker.statusLocked()
		worker.mu.Unlock()
		return status, ErrBusy
	}
	worker.requestInProgress = true
	worker.cancelWaitingLocked(worker.now())
	if worker.active != nil {
		worker.requestCancelLocked(worker.active)
	}
	backend := worker.backend
	done := make(chan struct{})
	worker.permissionDone = done
	worker.mu.Unlock()

	resultCh := make(chan permissionResult, 1)
	go func() {
		worker.nativeMu.Lock()
		if err := ctx.Err(); err != nil {
			worker.nativeMu.Unlock()
			resultCh <- permissionResult{err: err}
			return
		}
		granted, err := backend.RequestPermission(ctx)
		if err == nil && granted {
			checked, checkErr := backend.CheckPermission()
			granted, err = checked, checkErr
		}
		worker.nativeMu.Unlock()
		resultCh <- permissionResult{granted: granted, err: err}
	}()

	select {
	case result := <-resultCh:
		return worker.finishPermission(done, result)
	case <-ctx.Done():
		go func() {
			result := <-resultCh
			worker.finishPermission(done, result)
		}()
		worker.mu.Lock()
		status := worker.statusLocked()
		worker.mu.Unlock()
		return status, ctx.Err()
	}
}

func (worker *Worker) finishPermission(done chan struct{}, result permissionResult) (Status, error) {
	worker.mu.Lock()
	if worker.permissionDone == done {
		worker.permissionDone = nil
		worker.requestInProgress = false
		if result.err == nil || errors.Is(result.err, ErrPermissionDenied) {
			worker.setPermissionLocked(result.granted, nil)
		} else if !errors.Is(result.err, context.Canceled) && !errors.Is(result.err, context.DeadlineExceeded) {
			worker.permission = PermissionCheckFailed
		}
		close(done)
	}
	status := worker.statusLocked()
	worker.mu.Unlock()
	if result.err != nil && !errors.Is(result.err, ErrPermissionDenied) {
		return status, result.err
	}
	return status, nil
}

func (worker *Worker) ListSummaries(limit int) ([]execution.Summary, error) {
	if limit < 1 || limit > execution.HistoryLimit {
		return nil, fmt.Errorf("%w: summary limit must be between 1 and %d", ErrInvalidRequest, execution.HistoryLimit)
	}
	if worker == nil {
		return nil, nil
	}
	worker.mu.Lock()
	defer worker.mu.Unlock()
	count := limit
	if count > len(worker.history) {
		count = len(worker.history)
	}
	summaries := make([]execution.Summary, count)
	for index := 0; index < count; index++ {
		summaries[index] = summaryOf(worker.history[len(worker.history)-1-index])
	}
	return summaries, nil
}

func (worker *Worker) Get(id string) (execution.Record, bool) {
	if worker == nil {
		return execution.Record{}, false
	}
	worker.mu.Lock()
	defer worker.mu.Unlock()
	if record, ok := worker.outstanding[id]; ok {
		return cloneRecord(*record), true
	}
	for index := len(worker.history) - 1; index >= 0; index-- {
		if worker.history[index].ID == id {
			return cloneRecord(worker.history[index]), true
		}
	}
	return execution.Record{}, false
}

func (worker *Worker) Close() error {
	if worker == nil {
		return nil
	}
	worker.mu.Lock()
	if !worker.closed {
		worker.closed = true
		worker.cancelWaitingLocked(worker.now())
		if worker.active != nil {
			worker.requestCancelLocked(worker.active)
		}
		activeDone := (<-chan struct{})(nil)
		if worker.active != nil {
			activeDone = worker.active.done
		}
		permissionDone := worker.permissionDone
		backend := worker.backend
		go worker.finalizeClose(activeDone, permissionDone, backend)
	}
	closeDone := worker.closeDone
	worker.mu.Unlock()

	timer := time.NewTimer(closeTimeout)
	defer timer.Stop()
	select {
	case <-closeDone:
		worker.mu.Lock()
		err := worker.closeErr
		worker.mu.Unlock()
		return err
	case <-timer.C:
		return ErrClosePending
	}
}

func (worker *Worker) finalizeClose(activeDone, permissionDone <-chan struct{}, backend Backend) {
	if activeDone != nil {
		<-activeDone
	}
	if permissionDone != nil {
		<-permissionDone
	}
	var err error
	if closable, ok := backend.(closableBackend); ok {
		worker.nativeMu.Lock()
		err = closable.Close()
		worker.nativeMu.Unlock()
	}
	worker.mu.Lock()
	worker.closeErr = err
	worker.mu.Unlock()
	close(worker.closeDone)
}

func (worker *Worker) run(item *workItem) {
	if worker.isCanceled(item) {
		worker.finishActive(item, execution.StateCanceled, time.Time{})
		return
	}
	worker.nativeMu.Lock()
	granted, checkErr := worker.backend.CheckPermission()
	if checkErr != nil {
		worker.nativeMu.Unlock()
		if item.ctx.Err() != nil {
			worker.finishActive(item, execution.StateCanceled, time.Time{})
			return
		}
		worker.setPermission(PermissionCheckFailed)
		worker.finishActive(item, execution.StateFailed, time.Time{})
		return
	}
	if !granted {
		worker.nativeMu.Unlock()
		if item.ctx.Err() != nil {
			worker.finishActive(item, execution.StateCanceled, time.Time{})
			return
		}
		worker.setPermission(PermissionNotGranted)
		worker.finishActive(item, execution.StatePermissionDenied, time.Time{})
		return
	}
	worker.mu.Lock()
	if worker.isCanceledLocked(item) {
		worker.mu.Unlock()
		worker.nativeMu.Unlock()
		worker.finishActive(item, execution.StateCanceled, time.Time{})
		return
	}
	item.started = true
	worker.updateRecordStateLocked(item.id, execution.StateRunning)
	startedAt := worker.now()
	worker.markStartedLocked(item.id, startedAt)
	worker.mu.Unlock()
	err := worker.backend.Post(item.ctx, item.request)
	worker.nativeMu.Unlock()

	state := execution.StatePosted
	if err != nil {
		switch {
		case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
			state = execution.StateCanceled
		case errors.Is(err, ErrPermissionDenied):
			state = execution.StatePermissionDenied
			worker.setPermission(PermissionNotGranted)
		default:
			state = execution.StateFailed
		}
	}
	worker.finishActive(item, state, startedAt)
}

func (worker *Worker) isCanceled(item *workItem) bool {
	worker.mu.Lock()
	defer worker.mu.Unlock()
	return worker.isCanceledLocked(item)
}

func (worker *Worker) isCanceledLocked(item *workItem) bool {
	select {
	case <-item.ctx.Done():
		return true
	default:
		return worker.closed
	}
}

func (worker *Worker) requestCancelLocked(item *workItem) {
	if item.cancelRequested {
		return
	}
	item.cancelRequested = true
	item.cancel()
}

func (worker *Worker) finishActive(item *workItem, state execution.State, startedAt time.Time) {
	worker.mu.Lock()
	finishedAt := worker.now()
	if record, ok := worker.outstanding[item.id]; ok {
		record.State = state
		record.FinishedAt = finishedAt
		if !startedAt.IsZero() {
			record.StartedAt = startedAt
			record.Duration = nonnegativeDuration(startedAt, finishedAt)
		}
		worker.updateHistoryLocked(*record)
		delete(worker.outstanding, item.id)
	}
	if worker.active == item {
		worker.active = nil
	}
	close(item.done)
	var next *workItem
	if !worker.closed && !worker.requestInProgress && len(worker.waiting) > 0 {
		next = worker.waiting[0]
		copy(worker.waiting, worker.waiting[1:])
		worker.waiting[len(worker.waiting)-1] = nil
		worker.waiting = worker.waiting[:len(worker.waiting)-1]
		worker.active = next
	}
	worker.mu.Unlock()
	if next != nil {
		go worker.run(next)
	}
}

func (worker *Worker) cancelWaitingLocked(finishedAt time.Time) {
	for index, item := range worker.waiting {
		if record, ok := worker.outstanding[item.id]; ok {
			record.State = execution.StateCanceled
			record.FinishedAt = finishedAt
			worker.updateHistoryLocked(*record)
			delete(worker.outstanding, item.id)
		}
		worker.waiting[index] = nil
	}
	worker.waiting = nil
}

func (worker *Worker) finishAdmissionLocked(record *execution.Record, finishedAt time.Time) {
	record.FinishedAt = finishedAt
	worker.appendHistoryLocked(*record)
}

func (worker *Worker) markStartedLocked(id string, startedAt time.Time) {
	if record, ok := worker.outstanding[id]; ok {
		record.StartedAt = startedAt
		worker.updateHistoryLocked(*record)
	}
}

func (worker *Worker) setPermission(permission Permission) {
	worker.mu.Lock()
	worker.permission = permission
	worker.mu.Unlock()
}

func (worker *Worker) setPermissionLocked(granted bool, err error) {
	if err != nil {
		worker.permission = PermissionCheckFailed
		return
	}
	if granted {
		worker.permission = PermissionGranted
		return
	}
	worker.permission = PermissionNotGranted
}

func (worker *Worker) updateRecordStateLocked(id string, state execution.State) {
	if record, ok := worker.outstanding[id]; ok {
		record.State = state
		worker.updateHistoryLocked(*record)
	}
}

func (worker *Worker) nextIDLocked() (string, error) {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "", fmt.Errorf("generate native input ID: %w", err)
	}
	value[6] = value[6]&0x0f | 0x40
	value[8] = value[8]&0x3f | 0x80
	var encoded [36]byte
	hex.Encode(encoded[0:8], value[0:4])
	encoded[8] = '-'
	hex.Encode(encoded[9:13], value[4:6])
	encoded[13] = '-'
	hex.Encode(encoded[14:18], value[6:8])
	encoded[18] = '-'
	hex.Encode(encoded[19:23], value[8:10])
	encoded[23] = '-'
	hex.Encode(encoded[24:], value[10:])
	return string(encoded[:]), nil
}

func (worker *Worker) appendHistoryLocked(record execution.Record) {
	if len(worker.history) >= execution.HistoryLimit {
		evict := -1
		for index := range worker.history {
			if _, outstanding := worker.outstanding[worker.history[index].ID]; !outstanding {
				evict = index
				break
			}
		}
		if evict >= 0 {
			copy(worker.history[evict:], worker.history[evict+1:])
			worker.history = worker.history[:len(worker.history)-1]
		}
	}
	worker.history = append(worker.history, cloneRecord(record))
}

func (worker *Worker) updateHistoryLocked(record execution.Record) {
	for index := range worker.history {
		if worker.history[index].ID == record.ID {
			worker.history[index] = cloneRecord(record)
			return
		}
	}
}

func summaryOf(record execution.Record) execution.Summary {
	return execution.Summary{
		ActionType:       record.ActionType,
		ID:               record.ID,
		ProfileID:        record.ProfileID,
		PositionID:       record.PositionID,
		State:            record.State,
		SubmittedAt:      record.SubmittedAt,
		StartedAt:        record.StartedAt,
		FinishedAt:       record.FinishedAt,
		Duration:         record.Duration,
		ExitCode:         cloneInt(record.ExitCode),
		Signal:           cloneInt(record.Signal),
		SupervisionError: record.SupervisionError,
	}
}

func cloneRecord(record execution.Record) execution.Record {
	record.Stdout.Tail = append([]byte(nil), record.Stdout.Tail...)
	record.Stderr.Tail = append([]byte(nil), record.Stderr.Tail...)
	record.ExitCode = cloneInt(record.ExitCode)
	record.Signal = cloneInt(record.Signal)
	return record
}

func cloneInt(value *int) *int {
	if value == nil {
		return nil
	}
	copy := *value
	return &copy
}

func nonnegativeDuration(start, finish time.Time) time.Duration {
	duration := finish.Sub(start)
	if duration < 0 {
		return 0
	}
	return duration
}
