// Package execution supervises one bounded child process at a time and keeps
// generation-local, command-free execution history.
package execution

import (
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"
)

const (
	HistoryLimit             = 32
	OutputTailLimit          = 4096
	MinimumTimeout           = time.Second
	MaximumTimeout           = 60 * time.Second
	MaximumArgumentCount     = 32
	MaximumArgumentBytes     = 1024
	MaximumArgumentsBytes    = 8192
	TerminationGracePeriod   = 2 * time.Second
	PostKillReapPeriod       = 500 * time.Millisecond
	MinimalPath              = "/usr/bin:/bin:/usr/sbin:/sbin"
	childWorkingDirectory    = "/"
	closeCompletionAllowance = 100 * time.Millisecond
)

var (
	ErrClosed          = errors.New("execution worker is closed")
	ErrInvalidRequest  = errors.New("invalid execution request")
	ErrTermination     = errors.New("execution process-group termination failed")
	ErrReapUnconfirmed = errors.New("execution child reap was not confirmed")
	stableIDPattern    = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)
)

type State string

const (
	StateRunning      State = "running"
	StateExited       State = "exited"
	StateSignaled     State = "signaled"
	StateTimedOut     State = "timed_out"
	StateCanceled     State = "canceled"
	StateStartFailed  State = "start_failed"
	StateRejectedBusy State = "rejected_busy"
)

type Request struct {
	ProfileID  string
	PositionID string
	Executable string
	Arguments  []string
	Timeout    time.Duration
}

type Output struct {
	Tail       []byte
	TotalBytes uint64
	Truncated  bool
}

type Record struct {
	ID               string
	ProfileID        string
	PositionID       string
	State            State
	SubmittedAt      time.Time
	StartedAt        time.Time
	FinishedAt       time.Time
	Duration         time.Duration
	ExitCode         *int
	Signal           *int
	Stdout           Output
	Stderr           Output
	SupervisionError bool
}

type Summary struct {
	ID               string
	ProfileID        string
	PositionID       string
	State            State
	SubmittedAt      time.Time
	StartedAt        time.Time
	FinishedAt       time.Time
	Duration         time.Duration
	ExitCode         *int
	Signal           *int
	SupervisionError bool
}

type Worker struct {
	mu      sync.Mutex
	closed  bool
	active  *activeExecution
	history []Record
	ids     monotonicUUIDs
	now     func() time.Time
	grace   time.Duration
	signal  func(int, syscall.Signal) error
	faults  chan error
}

type activeExecution struct {
	recordID      string
	request       Request
	cancel        chan struct{}
	done          chan struct{}
	cancelAt      time.Time
	completionErr error
}

func New() (*Worker, error) {
	return newWorker(time.Now, rand.Reader, TerminationGracePeriod)
}

func newWorker(now func() time.Time, random io.Reader, grace time.Duration) (*Worker, error) {
	if now == nil || random == nil || grace < 0 {
		return nil, errors.New("invalid execution worker dependency")
	}
	ids, err := newMonotonicUUIDs(random)
	if err != nil {
		return nil, err
	}
	return &Worker{
		ids: ids, now: now, grace: grace, signal: signalProcessGroup,
		faults: make(chan error, 1),
	}, nil
}

// Submit admits a request without waiting for child execution. A busy request
// is a successful admission attempt represented by a rejected_busy record.
func (worker *Worker) Submit(request Request) (Record, error) {
	if worker == nil {
		return Record{}, ErrClosed
	}
	owned, err := validateAndCloneRequest(request)
	if err != nil {
		return Record{}, err
	}

	worker.mu.Lock()
	defer worker.mu.Unlock()
	if worker.closed {
		return Record{}, ErrClosed
	}
	now := worker.now()
	record := Record{
		ID:          worker.ids.next(now),
		ProfileID:   owned.ProfileID,
		PositionID:  owned.PositionID,
		State:       StateRunning,
		SubmittedAt: now,
	}
	if worker.active != nil {
		record.State = StateRejectedBusy
		record.FinishedAt = now
		worker.appendRecordLocked(record)
		return cloneRecord(record), nil
	}

	active := &activeExecution{
		recordID: record.ID,
		request:  owned,
		cancel:   make(chan struct{}),
		done:     make(chan struct{}),
	}
	worker.active = active
	worker.appendRecordLocked(record)
	go worker.execute(active)
	return cloneRecord(record), nil
}

func (worker *Worker) List() []Record {
	if worker == nil {
		return nil
	}
	worker.mu.Lock()
	defer worker.mu.Unlock()
	records := make([]Record, len(worker.history))
	for index := range worker.history {
		records[index] = cloneRecord(worker.history[len(worker.history)-1-index])
	}
	return records
}

// Faults reports worker supervision failures that leave child reap
// unconfirmed. Ordinary child outcomes are represented only in history.
func (worker *Worker) Faults() <-chan error {
	if worker == nil {
		return nil
	}
	return worker.faults
}

func (worker *Worker) ListSummaries(limit int) ([]Summary, error) {
	if limit < 1 || limit > HistoryLimit {
		return nil, fmt.Errorf("%w: summary limit must be between 1 and %d", ErrInvalidRequest, HistoryLimit)
	}
	if worker == nil {
		return nil, nil
	}
	worker.mu.Lock()
	defer worker.mu.Unlock()
	count := min(limit, len(worker.history))
	summaries := make([]Summary, count)
	for index := range count {
		summaries[index] = summaryOf(worker.history[len(worker.history)-1-index])
	}
	return summaries, nil
}

func (worker *Worker) Get(id string) (Record, bool) {
	if worker == nil {
		return Record{}, false
	}
	worker.mu.Lock()
	defer worker.mu.Unlock()
	for index := len(worker.history) - 1; index >= 0; index-- {
		if worker.history[index].ID == id {
			return cloneRecord(worker.history[index]), true
		}
	}
	return Record{}, false
}

// Close rejects new admission, cancels the active process group, and waits
// only for the fixed termination policy rather than the action timeout.
func (worker *Worker) Close() error {
	if worker == nil {
		return nil
	}
	worker.mu.Lock()
	if !worker.closed {
		worker.closed = true
		if worker.active != nil {
			worker.active.cancelAt = worker.now()
			close(worker.active.cancel)
		}
	}
	active := worker.active
	worker.mu.Unlock()
	if active == nil {
		return nil
	}

	timer := time.NewTimer(worker.grace + PostKillReapPeriod + closeCompletionAllowance)
	defer timer.Stop()
	select {
	case <-active.done:
		worker.mu.Lock()
		err := active.completionErr
		worker.mu.Unlock()
		return err
	case <-timer.C:
		return ErrReapUnconfirmed
	}
}

func (worker *Worker) execute(active *activeExecution) {
	stdout := newTailWriter(OutputTailLimit)
	stderr := newTailWriter(OutputTailLimit)
	command := newCommand(active.request)
	command.WaitDelay = PostKillReapPeriod
	command.Stdout = stdout
	command.Stderr = stderr

	select {
	case <-active.cancel:
		worker.finish(active, StateCanceled, time.Time{}, nil, stdout.snapshot(), stderr.snapshot())
		return
	default:
	}

	if err := command.Start(); err != nil {
		worker.finish(active, StateStartFailed, time.Time{}, nil, stdout.snapshot(), stderr.snapshot())
		return
	}
	startedAt := worker.now()
	worker.markStarted(active.recordID, startedAt)
	deadline := startedAt.Add(active.request.Timeout)

	wait := make(chan error, 1)
	go func() { wait <- command.Wait() }()
	timer := time.NewTimer(active.request.Timeout)
	defer timer.Stop()

	select {
	case err := <-wait:
		worker.finish(active, naturalState(command, err), startedAt, command.ProcessState, stdout.snapshot(), stderr.snapshot())
		return
	case <-timer.C:
		if processState, err, completed := completedProcess(wait, command); completed {
			worker.finish(active, naturalState(command, err), startedAt, processState, stdout.snapshot(), stderr.snapshot())
			return
		}
		state := worker.terminationState(active, deadline)
		processState, terminationErr := terminateProcessGroup(command, wait, worker.grace, worker.signal)
		worker.finishTermination(active, state, startedAt, processState, stdout.snapshot(), stderr.snapshot(), terminationErr)
	case <-active.cancel:
		if processState, err, completed := completedProcess(wait, command); completed {
			worker.finish(active, naturalState(command, err), startedAt, processState, stdout.snapshot(), stderr.snapshot())
			return
		}
		state := worker.terminationState(active, deadline)
		processState, terminationErr := terminateProcessGroup(command, wait, worker.grace, worker.signal)
		worker.finishTermination(active, state, startedAt, processState, stdout.snapshot(), stderr.snapshot(), terminationErr)
	}
}

func newCommand(request Request) *exec.Cmd {
	command := exec.Command(request.Executable, request.Arguments...)
	command.Dir = childWorkingDirectory
	command.Env = []string{"PATH=" + MinimalPath}
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	return command
}

func (worker *Worker) terminationState(active *activeExecution, deadline time.Time) State {
	worker.mu.Lock()
	cancelAt := active.cancelAt
	worker.mu.Unlock()
	if !cancelAt.IsZero() && cancelAt.Before(deadline) {
		return StateCanceled
	}
	return StateTimedOut
}

func completedProcess(wait <-chan error, command *exec.Cmd) (*os.ProcessState, error, bool) {
	select {
	case err := <-wait:
		return command.ProcessState, err, true
	default:
		return nil, nil, false
	}
}

func terminateProcessGroup(command *exec.Cmd, wait <-chan error, grace time.Duration, signal func(int, syscall.Signal) error) (*os.ProcessState, error) {
	pid := command.Process.Pid
	var failures []error
	if err := signal(pid, syscall.SIGTERM); err != nil {
		failures = append(failures, fmt.Errorf("%w: SIGTERM: %v", ErrTermination, err))
	}
	timer := time.NewTimer(grace)
	defer timer.Stop()
	select {
	case <-wait:
		if err := signal(pid, syscall.SIGKILL); err != nil {
			failures = append(failures, fmt.Errorf("%w: final process-group cleanup: %v", ErrTermination, err))
		}
		return command.ProcessState, errors.Join(failures...)
	case <-timer.C:
		if err := signal(pid, syscall.SIGKILL); err != nil {
			failures = append(failures, fmt.Errorf("%w: SIGKILL: %v", ErrTermination, err))
		}
	}
	reapTimer := time.NewTimer(PostKillReapPeriod)
	defer reapTimer.Stop()
	select {
	case <-wait:
		return command.ProcessState, errors.Join(failures...)
	case <-reapTimer.C:
		failures = append(failures, ErrReapUnconfirmed)
		return nil, errors.Join(failures...)
	}
}

func signalProcessGroup(pid int, signal syscall.Signal) error {
	err := syscall.Kill(-pid, signal)
	if errors.Is(err, syscall.ESRCH) {
		return nil
	}
	return err
}

func naturalState(command *exec.Cmd, waitError error) State {
	if command.ProcessState != nil {
		if status, ok := command.ProcessState.Sys().(syscall.WaitStatus); ok && status.Signaled() {
			return StateSignaled
		}
	}
	_ = waitError
	return StateExited
}

func (worker *Worker) markStarted(id string, startedAt time.Time) {
	worker.mu.Lock()
	defer worker.mu.Unlock()
	for index := range worker.history {
		if worker.history[index].ID == id {
			worker.history[index].StartedAt = startedAt
			return
		}
	}
}

func (worker *Worker) finish(active *activeExecution, state State, startedAt time.Time, processState *os.ProcessState, stdout, stderr Output) {
	worker.finishWithError(active, state, startedAt, processState, stdout, stderr, nil)
}

func (worker *Worker) finishTermination(active *activeExecution, state State, startedAt time.Time, processState *os.ProcessState, stdout, stderr Output, terminationErr error) {
	if errors.Is(terminationErr, ErrReapUnconfirmed) {
		worker.failSupervision(active, terminationErr)
		return
	}
	worker.finishWithError(active, state, startedAt, processState, stdout, stderr, terminationErr)
}

func (worker *Worker) finishWithError(active *activeExecution, state State, startedAt time.Time, processState *os.ProcessState, stdout, stderr Output, terminationErr error) {
	finishedAt := worker.now()
	worker.mu.Lock()
	defer worker.mu.Unlock()
	for index := range worker.history {
		if worker.history[index].ID != active.recordID {
			continue
		}
		record := &worker.history[index]
		record.State = state
		record.FinishedAt = finishedAt
		if startedAt.IsZero() {
			record.Duration = nonnegativeDuration(record.SubmittedAt, finishedAt)
		} else {
			record.StartedAt = startedAt
			record.Duration = nonnegativeDuration(startedAt, finishedAt)
		}
		record.Stdout = stdout
		record.Stderr = stderr
		record.SupervisionError = terminationErr != nil
		setProcessResult(record, processState)
		break
	}
	if worker.active == active {
		worker.active = nil
	}
	active.completionErr = terminationErr
	close(active.done)
}

func (worker *Worker) failSupervision(active *activeExecution, terminationErr error) {
	worker.mu.Lock()
	for index := range worker.history {
		if worker.history[index].ID == active.recordID {
			worker.history[index].SupervisionError = true
			break
		}
	}
	active.completionErr = terminationErr
	worker.mu.Unlock()
	select {
	case worker.faults <- terminationErr:
	default:
	}
	close(active.done)
}

func setProcessResult(record *Record, processState *os.ProcessState) {
	if processState == nil {
		return
	}
	status, ok := processState.Sys().(syscall.WaitStatus)
	if ok && status.Signaled() {
		signal := int(status.Signal())
		record.Signal = &signal
		return
	}
	exitCode := processState.ExitCode()
	record.ExitCode = &exitCode
}

func nonnegativeDuration(start, finish time.Time) time.Duration {
	duration := finish.Sub(start)
	if duration < 0 {
		return 0
	}
	return duration
}

func (worker *Worker) appendRecordLocked(record Record) {
	if len(worker.history) == HistoryLimit {
		evict := 0
		for worker.history[evict].State == StateRunning {
			evict++
		}
		copy(worker.history[evict:], worker.history[evict+1:])
		worker.history[len(worker.history)-1] = record
		return
	}
	worker.history = append(worker.history, record)
}

func summaryOf(record Record) Summary {
	summary := Summary{
		ID: record.ID, ProfileID: record.ProfileID, PositionID: record.PositionID,
		State: record.State, SubmittedAt: record.SubmittedAt, StartedAt: record.StartedAt,
		FinishedAt: record.FinishedAt, Duration: record.Duration,
		SupervisionError: record.SupervisionError,
	}
	if record.ExitCode != nil {
		value := *record.ExitCode
		summary.ExitCode = &value
	}
	if record.Signal != nil {
		value := *record.Signal
		summary.Signal = &value
	}
	return summary
}

func validateAndCloneRequest(request Request) (Request, error) {
	if !validStableID(request.ProfileID) || !validStableID(request.PositionID) {
		return Request{}, fmt.Errorf("%w: profile and position IDs must be stable IDs", ErrInvalidRequest)
	}
	if request.Executable == "" || !path.IsAbs(request.Executable) || !utf8.ValidString(request.Executable) || strings.ContainsRune(request.Executable, '\x00') {
		return Request{}, fmt.Errorf("%w: executable must be a non-empty absolute UTF-8 path without NUL", ErrInvalidRequest)
	}
	if request.Timeout < MinimumTimeout || request.Timeout > MaximumTimeout || request.Timeout%time.Second != 0 {
		return Request{}, fmt.Errorf("%w: timeout must be a whole number of seconds between 1 and 60", ErrInvalidRequest)
	}
	if len(request.Arguments) > MaximumArgumentCount {
		return Request{}, fmt.Errorf("%w: too many arguments", ErrInvalidRequest)
	}
	total := 0
	for _, argument := range request.Arguments {
		if !utf8.ValidString(argument) || strings.ContainsRune(argument, '\x00') || len(argument) > MaximumArgumentBytes {
			return Request{}, fmt.Errorf("%w: invalid argument", ErrInvalidRequest)
		}
		total += len(argument)
	}
	if total > MaximumArgumentsBytes {
		return Request{}, fmt.Errorf("%w: arguments are too large", ErrInvalidRequest)
	}
	request.Arguments = append([]string(nil), request.Arguments...)
	return request, nil
}

func validStableID(value string) bool {
	return utf8.ValidString(value) && stableIDPattern.MatchString(value)
}

func cloneRecord(record Record) Record {
	record.Stdout.Tail = append([]byte(nil), record.Stdout.Tail...)
	record.Stderr.Tail = append([]byte(nil), record.Stderr.Tail...)
	if record.ExitCode != nil {
		value := *record.ExitCode
		record.ExitCode = &value
	}
	if record.Signal != nil {
		value := *record.Signal
		record.Signal = &value
	}
	return record
}

type tailWriter struct {
	limit int
	total uint64
	tail  []byte
}

func newTailWriter(limit int) *tailWriter {
	return &tailWriter{limit: limit, tail: make([]byte, 0, limit)}
}

func (writer *tailWriter) Write(value []byte) (int, error) {
	written := len(value)
	writer.total += uint64(written)
	if written >= writer.limit {
		writer.tail = append(writer.tail[:0], value[written-writer.limit:]...)
		return written, nil
	}
	overflow := len(writer.tail) + written - writer.limit
	if overflow > 0 {
		copy(writer.tail, writer.tail[overflow:])
		writer.tail = writer.tail[:len(writer.tail)-overflow]
	}
	writer.tail = append(writer.tail, value...)
	return written, nil
}

func (writer *tailWriter) snapshot() Output {
	return Output{
		Tail:       append([]byte(nil), writer.tail...),
		TotalBytes: writer.total,
		Truncated:  writer.total > uint64(len(writer.tail)),
	}
}
