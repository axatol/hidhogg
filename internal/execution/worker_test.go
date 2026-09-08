package execution

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

const helperMarker = "--execution-helper"

func TestExecutionHelperProcess(t *testing.T) {
	arguments := helperArguments(os.Args)
	if arguments == nil {
		return
	}
	switch arguments[0] {
	case "inspect":
		workingDirectory, err := os.Getwd()
		if err != nil {
			os.Exit(91)
		}
		fmt.Printf("cwd=%s\n", workingDirectory)
		for index, argument := range arguments[1:] {
			fmt.Printf("arg%d=%s\n", index, argument)
		}
		fmt.Fprint(os.Stderr, "helper-stderr")
	case "exit":
		code, err := strconv.Atoi(arguments[1])
		if err != nil {
			os.Exit(92)
		}
		fmt.Fprint(os.Stdout, "helper-stdout")
		fmt.Fprint(os.Stderr, "helper-stderr")
		os.Exit(code)
	case "block":
		time.Sleep(time.Hour)
	case "output":
		count, err := strconv.Atoi(arguments[1])
		if err != nil {
			os.Exit(93)
		}
		_, _ = os.Stdout.Write(bytes.Repeat([]byte("o"), count))
		_, _ = os.Stderr.Write(bytes.Repeat([]byte("e"), count+1))
	case "signal":
		_ = syscall.Kill(os.Getpid(), syscall.SIGTERM)
		time.Sleep(time.Second)
	default:
		os.Exit(94)
	}
	os.Exit(0)
}

func TestWorkerUsesIsolatedProcessContractAndLiteralArguments(t *testing.T) {
	worker := newTestWorker(t, 50*time.Millisecond)
	request := helperRequest(t, "inspect", "a;$(not-executed)", "*.txt", "two words")
	record, err := worker.Submit(request)
	if err != nil {
		t.Fatal(err)
	}
	finished := waitForTerminalRecord(t, worker, record.ID)
	if finished.State != StateExited || finished.ExitCode == nil || *finished.ExitCode != 0 {
		t.Fatalf("terminal result = %#v", finished)
	}
	stdout := string(finished.Stdout.Tail)
	for _, expected := range []string{
		"cwd=/\n",
		"arg0=a;$(not-executed)\n",
		"arg1=*.txt\n",
		"arg2=two words\n",
	} {
		if !strings.Contains(stdout, expected) {
			t.Fatalf("stdout %q does not contain %q", stdout, expected)
		}
	}
	command := newCommand(request)
	if command.Dir != "/" || len(command.Env) != 1 || command.Env[0] != "PATH="+MinimalPath {
		t.Fatalf("command isolation = dir %q, env %#v", command.Dir, command.Env)
	}
	if command.SysProcAttr == nil || !command.SysProcAttr.Setpgid {
		t.Fatalf("command process group = %#v", command.SysProcAttr)
	}
	if string(finished.Stderr.Tail) != "helper-stderr" {
		t.Fatalf("stderr = %q", finished.Stderr.Tail)
	}
}

func TestCommandCompletesWithBoundedWriters(t *testing.T) {
	request := helperRequest(t, "exit", "0")
	command := newCommand(request)
	stdout := newTailWriter(OutputTailLimit)
	stderr := newTailWriter(OutputTailLimit)
	command.Stdout = stdout
	command.Stderr = stderr
	if err := command.Run(); err != nil {
		t.Fatal(err)
	}
	if string(stdout.snapshot().Tail) != "helper-stdout" || string(stderr.snapshot().Tail) != "helper-stderr" {
		t.Fatalf("output = %q/%q", stdout.snapshot().Tail, stderr.snapshot().Tail)
	}
}

func TestWorkerRecordsExitCodes(t *testing.T) {
	worker := newTestWorker(t, 50*time.Millisecond)
	for _, code := range []int{0, 17} {
		record, err := worker.Submit(helperRequest(t, "exit", strconv.Itoa(code)))
		if err != nil {
			t.Fatal(err)
		}
		finished := waitForTerminalRecord(t, worker, record.ID)
		if finished.State != StateExited || finished.ExitCode == nil || *finished.ExitCode != code {
			t.Fatalf("code %d result = %#v", code, finished)
		}
	}
}

func TestWorkerRecordsSignalAndStartFailure(t *testing.T) {
	worker := newTestWorker(t, 50*time.Millisecond)
	signaled, err := worker.Submit(helperRequest(t, "signal"))
	if err != nil {
		t.Fatal(err)
	}
	signalRecord := waitForTerminalRecord(t, worker, signaled.ID)
	if signalRecord.State != StateSignaled || signalRecord.Signal == nil || *signalRecord.Signal != int(syscall.SIGTERM) {
		t.Fatalf("signal result = %#v", signalRecord)
	}

	request := helperRequest(t, "exit", "0")
	request.Executable = "/hidhogg-test-does-not-exist"
	failed, err := worker.Submit(request)
	if err != nil {
		t.Fatal(err)
	}
	failureRecord := waitForTerminalRecord(t, worker, failed.ID)
	if failureRecord.State != StateStartFailed || failureRecord.ExitCode != nil || failureRecord.Signal != nil {
		t.Fatalf("start failure result = %#v", failureRecord)
	}
}

func TestWorkerRejectsBusyWithoutStartingAnotherChild(t *testing.T) {
	worker := newTestWorker(t, 20*time.Millisecond)
	active, err := worker.Submit(helperRequest(t, "block"))
	if err != nil {
		t.Fatal(err)
	}
	waitForRunningRecord(t, worker, active.ID)
	busy, err := worker.Submit(helperRequest(t, "exit", "0"))
	if err != nil {
		t.Fatal(err)
	}
	if busy.State != StateRejectedBusy || busy.FinishedAt.IsZero() {
		t.Fatalf("busy result = %#v", busy)
	}
	if err := worker.Close(); err != nil {
		t.Fatal(err)
	}
	if finished := mustGetRecord(t, worker, active.ID); finished.State != StateCanceled {
		t.Fatalf("active result after close = %#v", finished)
	}
}

func TestWorkerRetainsExactOutputTails(t *testing.T) {
	worker := newTestWorker(t, 50*time.Millisecond)
	count := OutputTailLimit + 333
	record, err := worker.Submit(helperRequest(t, "output", strconv.Itoa(count)))
	if err != nil {
		t.Fatal(err)
	}
	finished := waitForTerminalRecord(t, worker, record.ID)
	assertOutput(t, finished.Stdout, uint64(count), 'o')
	assertOutput(t, finished.Stderr, uint64(count+1), 'e')
}

func TestWorkerTimeoutAndCloseAreDistinct(t *testing.T) {
	t.Run("timeout", func(t *testing.T) {
		worker := newTestWorker(t, 20*time.Millisecond)
		request := helperRequest(t, "block")
		request.Timeout = time.Second
		record, err := worker.Submit(request)
		if err != nil {
			t.Fatal(err)
		}
		finished := waitForTerminalRecordWithDeadline(t, worker, record.ID, 2*time.Second)
		if finished.State != StateTimedOut || finished.Signal == nil {
			t.Fatalf("timeout result = %#v", finished)
		}
	})
	t.Run("close", func(t *testing.T) {
		worker := newTestWorker(t, 20*time.Millisecond)
		record, err := worker.Submit(helperRequest(t, "block"))
		if err != nil {
			t.Fatal(err)
		}
		waitForRunningRecord(t, worker, record.ID)
		if err := worker.Close(); err != nil {
			t.Fatal(err)
		}
		if finished := mustGetRecord(t, worker, record.ID); finished.State != StateCanceled || finished.Signal == nil {
			t.Fatalf("close result = %#v", finished)
		}
		if _, err := worker.Submit(helperRequest(t, "exit", "0")); !errors.Is(err, ErrClosed) {
			t.Fatalf("submit after close error = %v", err)
		}
	})
}

func TestWorkerValidationDoesNotCreateHistory(t *testing.T) {
	worker := newTestWorker(t, 20*time.Millisecond)
	invalid := helperRequest(t, "exit", "0")
	invalid.Executable = "relative"
	if _, err := worker.Submit(invalid); !errors.Is(err, ErrInvalidRequest) {
		t.Fatalf("invalid request error = %v", err)
	}
	if records := worker.List(); len(records) != 0 {
		t.Fatalf("history after invalid request = %#v", records)
	}
}

func TestWorkerHistoryEvictionOrderAndCopies(t *testing.T) {
	worker := newTestWorker(t, 20*time.Millisecond)
	ids := make([]string, 0, HistoryLimit+3)
	for index := 0; index < HistoryLimit+3; index++ {
		record, err := worker.Submit(helperRequest(t, "exit", "0"))
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, record.ID)
		waitForTerminalRecord(t, worker, record.ID)
	}
	records := worker.List()
	if len(records) != HistoryLimit {
		t.Fatalf("history length = %d", len(records))
	}
	if records[0].ID != ids[len(ids)-1] || records[len(records)-1].ID != ids[3] {
		t.Fatalf("history endpoints = %s/%s", records[0].ID, records[len(records)-1].ID)
	}
	if _, ok := worker.Get(ids[2]); ok {
		t.Fatal("evicted execution remained queryable")
	}
	records[0].Stdout.Tail[0] = 'x'
	again := mustGetRecord(t, worker, ids[len(ids)-1])
	if len(again.Stdout.Tail) > 0 && again.Stdout.Tail[0] == 'x' {
		t.Fatal("history output was not defensively copied")
	}
}

func TestWorkerConcurrentAdmissionHistoryAndClose(t *testing.T) {
	worker := newTestWorker(t, 20*time.Millisecond)
	active, err := worker.Submit(helperRequest(t, "block"))
	if err != nil {
		t.Fatal(err)
	}
	waitForRunningRecord(t, worker, active.ID)
	busyRequest := helperRequest(t, "exit", "0")

	start := make(chan struct{})
	errorsFound := make(chan error, 8)
	var group sync.WaitGroup
	for workerIndex := 0; workerIndex < 8; workerIndex++ {
		group.Add(1)
		go func() {
			defer group.Done()
			<-start
			for iteration := 0; iteration < 100; iteration++ {
				_ = worker.List()
				if _, summaryErr := worker.ListSummaries(HistoryLimit); summaryErr != nil {
					errorsFound <- summaryErr
					return
				}
				_, _ = worker.Get(active.ID)
				result, submitErr := worker.Submit(busyRequest)
				if submitErr != nil && !errors.Is(submitErr, ErrClosed) {
					errorsFound <- submitErr
					return
				}
				if submitErr == nil && result.State != StateRejectedBusy {
					errorsFound <- fmt.Errorf("concurrent submission state = %s", result.State)
					return
				}
			}
		}()
	}
	close(start)
	time.Sleep(5 * time.Millisecond)
	if err := worker.Close(); err != nil {
		t.Fatal(err)
	}
	group.Wait()
	close(errorsFound)
	for concurrentErr := range errorsFound {
		t.Fatal(concurrentErr)
	}
	terminal := mustGetRecord(t, worker, active.ID)
	if terminal.State != StateCanceled {
		t.Fatalf("active record after concurrent close = %#v", terminal)
	}
}

func TestBusyPressureRetainsActiveRecordThroughTerminalUpdate(t *testing.T) {
	worker := newTestWorker(t, 20*time.Millisecond)
	active, err := worker.Submit(helperRequest(t, "block"))
	if err != nil {
		t.Fatal(err)
	}
	waitForRunningRecord(t, worker, active.ID)
	for index := 0; index < 64; index++ {
		busy, submitErr := worker.Submit(helperRequest(t, "exit", "0"))
		if submitErr != nil {
			t.Fatal(submitErr)
		}
		if busy.State != StateRejectedBusy {
			t.Fatalf("busy attempt %d state = %s", index, busy.State)
		}
	}
	if records := worker.List(); len(records) != HistoryLimit {
		t.Fatalf("history length under busy pressure = %d", len(records))
	}
	if current := mustGetRecord(t, worker, active.ID); current.State != StateRunning {
		t.Fatalf("active record under busy pressure = %#v", current)
	}
	if err := worker.Close(); err != nil {
		t.Fatal(err)
	}
	finished := mustGetRecord(t, worker, active.ID)
	if finished.State != StateCanceled || finished.FinishedAt.IsZero() {
		t.Fatalf("retained active terminal result = %#v", finished)
	}
}

func TestListSummariesIsBoundedOutputFreeAndImmutable(t *testing.T) {
	worker := newTestWorker(t, 20*time.Millisecond)
	for _, code := range []string{"0", "17"} {
		record, err := worker.Submit(helperRequest(t, "exit", code))
		if err != nil {
			t.Fatal(err)
		}
		waitForTerminalRecord(t, worker, record.ID)
	}
	for _, invalid := range []int{0, HistoryLimit + 1} {
		if _, err := worker.ListSummaries(invalid); !errors.Is(err, ErrInvalidRequest) {
			t.Fatalf("summary limit %d error = %v", invalid, err)
		}
	}
	summaries, err := worker.ListSummaries(1)
	if err != nil {
		t.Fatal(err)
	}
	if len(summaries) != 1 || summaries[0].ExitCode == nil || *summaries[0].ExitCode != 17 {
		t.Fatalf("summaries = %#v", summaries)
	}
	summaryType := reflect.TypeFor[Summary]()
	if _, exists := summaryType.FieldByName("Stdout"); exists {
		t.Fatal("Summary exposes stdout")
	}
	if _, exists := summaryType.FieldByName("Stderr"); exists {
		t.Fatal("Summary exposes stderr")
	}
	*summaries[0].ExitCode = 99
	again, err := worker.ListSummaries(1)
	if err != nil {
		t.Fatal(err)
	}
	if *again[0].ExitCode != 17 {
		t.Fatal("summary exit code was not defensively copied")
	}
}

func TestTerminationSignalFailuresAreReportedAfterConfirmedReap(t *testing.T) {
	worker := newTestWorker(t, 10*time.Millisecond)
	var signals []syscall.Signal
	worker.signal = func(pid int, signal syscall.Signal) error {
		signals = append(signals, signal)
		_ = signalProcessGroup(pid, signal)
		return errors.New("injected signal failure")
	}
	record, err := worker.Submit(helperRequest(t, "block"))
	if err != nil {
		t.Fatal(err)
	}
	waitForRunningRecord(t, worker, record.ID)
	if err := worker.Close(); !errors.Is(err, ErrTermination) {
		t.Fatalf("close error = %v", err)
	}
	finished := mustGetRecord(t, worker, record.ID)
	if finished.State != StateCanceled || !finished.SupervisionError {
		t.Fatalf("signal-failure record = %#v", finished)
	}
	if len(signals) != 2 || signals[0] != syscall.SIGTERM || signals[1] != syscall.SIGKILL {
		t.Fatalf("signals = %v", signals)
	}
}

func TestCloseReportsStableUnconfirmedReapWithoutFalseTerminalState(t *testing.T) {
	worker := newTestWorker(t, 10*time.Millisecond)
	var childPID int
	worker.signal = func(pid int, _ syscall.Signal) error {
		childPID = pid
		return nil
	}
	record, err := worker.Submit(helperRequest(t, "block"))
	if err != nil {
		t.Fatal(err)
	}
	waitForRunningRecord(t, worker, record.ID)
	defer func() {
		if childPID != 0 {
			_ = signalProcessGroup(childPID, syscall.SIGKILL)
		}
	}()
	if err := worker.Close(); !errors.Is(err, ErrReapUnconfirmed) {
		t.Fatalf("first close error = %v", err)
	}
	select {
	case fault := <-worker.Faults():
		if !errors.Is(fault, ErrReapUnconfirmed) {
			t.Fatalf("worker fault = %v", fault)
		}
	default:
		t.Fatal("unconfirmed reap did not publish a worker fault")
	}
	select {
	case fault := <-worker.Faults():
		t.Fatalf("duplicate worker fault = %v", fault)
	default:
	}
	if err := worker.Close(); !errors.Is(err, ErrReapUnconfirmed) {
		t.Fatalf("repeated close error = %v", err)
	}
	current := mustGetRecord(t, worker, record.ID)
	if current.State != StateRunning || !current.FinishedAt.IsZero() || !current.SupervisionError {
		t.Fatalf("unconfirmed-reap record = %#v", current)
	}
}

func TestWorkerFaultsExcludesOrdinaryLifecycleOutcomes(t *testing.T) {
	worker := newTestWorker(t, 10*time.Millisecond)
	for _, request := range []Request{
		helperRequest(t, "exit", "0"),
		helperRequest(t, "exit", "17"),
		helperRequest(t, "signal"),
	} {
		record, err := worker.Submit(request)
		if err != nil {
			t.Fatal(err)
		}
		waitForTerminalRecord(t, worker, record.ID)
	}
	startFailure := helperRequest(t, "exit", "0")
	startFailure.Executable = "/hidhogg-test-does-not-exist"
	record, err := worker.Submit(startFailure)
	if err != nil {
		t.Fatal(err)
	}
	waitForTerminalRecord(t, worker, record.ID)
	timeoutRequest := helperRequest(t, "block")
	timeoutRequest.Timeout = time.Second
	timedOut, err := worker.Submit(timeoutRequest)
	if err != nil {
		t.Fatal(err)
	}
	if finished := waitForTerminalRecordWithDeadline(t, worker, timedOut.ID, 2*time.Second); finished.State != StateTimedOut {
		t.Fatalf("timeout result = %#v", finished)
	}
	active, err := worker.Submit(helperRequest(t, "block"))
	if err != nil {
		t.Fatal(err)
	}
	waitForRunningRecord(t, worker, active.ID)
	if _, err := worker.Submit(helperRequest(t, "exit", "0")); err != nil {
		t.Fatal(err)
	}
	if err := worker.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case fault := <-worker.Faults():
		t.Fatalf("ordinary lifecycle published fault %v", fault)
	default:
	}
	var nilWorker *Worker
	if nilWorker.Faults() != nil {
		t.Fatal("nil worker returned a non-nil fault channel")
	}
}

func helperArguments(arguments []string) []string {
	for index, argument := range arguments {
		if argument == helperMarker && index+1 < len(arguments) {
			return arguments[index+1:]
		}
	}
	return nil
}

func helperRequest(t *testing.T, mode string, arguments ...string) Request {
	t.Helper()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	childArguments := []string{"-test.run=^TestExecutionHelperProcess$", "--", helperMarker, mode}
	childArguments = append(childArguments, arguments...)
	return Request{
		ProfileID:  "default",
		PositionID: "button-0",
		Executable: executable,
		Arguments:  childArguments,
		Timeout:    5 * time.Second,
	}
}

func newTestWorker(t *testing.T, grace time.Duration) *Worker {
	t.Helper()
	worker, err := newWorker(time.Now, bytes.NewReader(bytes.Repeat([]byte{0x42}, 32)), grace)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = worker.Close() })
	return worker
}

func waitForRunningRecord(t *testing.T, worker *Worker, id string) Record {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		record := mustGetRecord(t, worker, id)
		if !record.StartedAt.IsZero() {
			return record
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("execution did not start")
	return Record{}
}

func waitForTerminalRecord(t *testing.T, worker *Worker, id string) Record {
	t.Helper()
	return waitForTerminalRecordWithDeadline(t, worker, id, 6*time.Second)
}

func waitForTerminalRecordWithDeadline(t *testing.T, worker *Worker, id string, duration time.Duration) Record {
	t.Helper()
	deadline := time.Now().Add(duration)
	for time.Now().Before(deadline) {
		record := mustGetRecord(t, worker, id)
		if record.State != StateRunning {
			return record
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("execution did not finish")
	return Record{}
}

func mustGetRecord(t *testing.T, worker *Worker, id string) Record {
	t.Helper()
	record, ok := worker.Get(id)
	if !ok {
		t.Fatalf("execution %q not found", id)
	}
	return record
}

func assertOutput(t *testing.T, output Output, total uint64, value byte) {
	t.Helper()
	if output.TotalBytes != total || !output.Truncated || len(output.Tail) != OutputTailLimit {
		t.Fatalf("output metadata = %#v", output)
	}
	if !bytes.Equal(output.Tail, bytes.Repeat([]byte{value}, OutputTailLimit)) {
		t.Fatal("output tail mismatch")
	}
}
