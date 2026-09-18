// Package diagnostic contains the bounded, operator-assisted firmware wake
// matrix. It owns the only input read loop for a diagnostic run and exposes no
// arbitrary D200X commands or payloads.
package diagnostic

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	appconfig "hidhogg/internal/config"
	"hidhogg/internal/d200x"
)

const (
	defaultStageTimeout       = 30 * time.Second
	defaultObservationBytes   = 1024
	maximumObservationBytes   = 4 * 1024
	maximumObservationCount   = 64
	maximumCapturedInputCount = 48
	maximumFramesPerInputStep = 32
)

var (
	ErrConfirmationRequired            = errors.New("explicit confirmation is required before D200X enumeration")
	ErrInvalidMode                     = errors.New("diagnostic mode must be brightness-zero, firmware-wake, or keepalive-prevention")
	ErrInvalidWakeCandidate            = errors.New("wake candidate is not allowlisted")
	ErrInvalidKeepaliveInterval        = errors.New("keepalive interval must be positive")
	ErrInvalidKeepaliveDuration        = errors.New("keepalive duration must be positive")
	ErrKeepaliveDurationTooLong        = errors.New("keepalive duration must not exceed 60 minutes")
	ErrKeepaliveScheduleMismatch       = errors.New("keepalive duration must equal four keepalive intervals")
	ErrKeepaliveScheduleEmpty          = errors.New("keepalive duration must include at least one interval boundary")
	ErrKeepaliveScheduleTooLong        = errors.New("keepalive schedule exceeds the bounded 48-boundary limit")
	ErrKeepaliveArgumentsOnly          = errors.New("keepalive interval and duration are only valid for keepalive-prevention mode")
	ErrInvalidKeepaliveTimingContract  = errors.New("keepalive timing contract is not supported")
	ErrKeepaliveTimingContractMismatch = errors.New("k1-50-v1 requires a 50-second interval and 200-second duration")
)

// Mode is one of the closed bounded diagnostic modes.
type Mode string

const (
	ModeBrightnessZero      Mode = "brightness-zero"
	ModeFirmwareWake        Mode = "firmware-wake"
	ModeKeepalivePrevention Mode = "keepalive-prevention"
)

func (mode Mode) Valid() bool {
	return mode == ModeBrightnessZero || mode == ModeFirmwareWake || mode == ModeKeepalivePrevention
}

func ParseMode(value string) (Mode, error) {
	mode := Mode(strings.TrimSpace(value))
	if !mode.Valid() {
		return "", ErrInvalidMode
	}
	return mode, nil
}

// WakeCandidate is one explicitly allowlisted frame that may be sent after a
// fresh firmware-screensaver trigger. The type prevents callers from passing
// raw protocol command IDs or payloads into the runner.
type WakeCandidate string

const (
	WakeBrightness         WakeCandidate = "brightness"
	WakeInputEnable        WakeCandidate = "input-enable"
	WakeUnlock             WakeCandidate = "unlock"
	WakeCompletePageUpload WakeCandidate = "complete-page-upload"

	WakeCandidateBrightness         = WakeBrightness
	WakeCandidateInputEnable        = WakeInputEnable
	WakeCandidateUnlock             = WakeUnlock
	WakeCandidateCompletePageUpload = WakeCompletePageUpload
)

var wakeCandidates = [...]WakeCandidate{
	WakeBrightness,
	WakeInputEnable,
	WakeUnlock,
	WakeCompletePageUpload,
}

func (candidate WakeCandidate) Valid() bool {
	for _, allowed := range wakeCandidates {
		if candidate == allowed {
			return true
		}
	}
	return false
}

func ParseWakeCandidate(value string) (WakeCandidate, error) {
	candidate := WakeCandidate(strings.TrimSpace(value))
	if !candidate.Valid() {
		return "", ErrInvalidWakeCandidate
	}
	return candidate, nil
}

// WakeCandidates returns the closed allowlist in deterministic order.
func WakeCandidates() []WakeCandidate {
	return append([]WakeCandidate(nil), wakeCandidates[:]...)
}

// Status is the result vocabulary used in JSON observations and Result.
type Status string

const (
	StatusPass          Status = "pass"
	StatusFail          Status = "fail"
	StatusClassFailure  Status = "class-failure"
	StatusPartial       Status = "partial"
	StatusNotRun        Status = "not-run"
	StatusIndeterminate Status = "indeterminate"
	StatusInvalidated   Status = "invalidated"
)

// InputClass is the bounded physical input grouping used by the brightness
// zero matrix. It intentionally contains no device identity.
type InputClass string

const (
	InputSquare         InputClass = "square"
	InputWide           InputClass = "wide"
	InputPhysicalButton InputClass = "physical-button"
	InputEncoder        InputClass = "encoder"
)

// CapturePhase identifies the bounded interval in which a continuously
// captured input was observed. It is deliberately independent of operator
// prompts so stale and boundary-overlapping input remains attributable.
type CapturePhase string

const (
	CapturePhasePreReady         CapturePhase = "pre-ready"
	CapturePhaseBaseline         CapturePhase = "baseline"
	CapturePhaseZeroWriteOverlap CapturePhase = "zero-write-overlap"
	CapturePhaseZeroState        CapturePhase = "zero-state"
	// restore-overlap also names the firmware restoration transition caused by
	// the first encoder rotation; explicit host brightness restore remains in
	// the same archive vocabulary for compatibility with existing validators.
	CapturePhaseRestoreOverlap CapturePhase = "restore-overlap"
	CapturePhaseRecovery       CapturePhase = "recovery"
	CapturePhaseTrailing       CapturePhase = "trailing"
)

const (
	inputClassificationExpected     = "expected"
	inputClassificationStale        = "stale"
	inputClassificationDuplicate    = "duplicate"
	inputClassificationMalformed    = "malformed"
	inputClassificationWrong        = "wrong-input"
	inputClassificationWriteOverlap = "write-overlap"
	inputClassificationNonInput     = "non-input"
	inputClassificationTrailing     = "trailing"
)

// DisplayState is the operator's bounded observation of the display after a
// firmware-wake candidate. Input-enable may leave the display unchanged while
// the other candidates may visibly recover it.
type DisplayState string

const (
	DisplayRecovered DisplayState = "recovered"
	DisplayUnchanged DisplayState = "unchanged"
)

type inputProbe struct {
	stage            string
	prompt           string
	expectedClass    InputClass
	expectedWire     *byte
	expectedAction   []d200x.InputAction
	expectedSequence []d200x.InputAction
}

func newInputProbe(stage, prompt string, expectedClass InputClass, wireIndex byte, actions ...d200x.InputAction) inputProbe {
	wire := wireIndex
	return inputProbe{
		stage:            stage,
		prompt:           prompt,
		expectedClass:    expectedClass,
		expectedWire:     &wire,
		expectedAction:   append([]d200x.InputAction(nil), actions...),
		expectedSequence: append([]d200x.InputAction(nil), actions...),
	}
}

func newInputClassProbe(stage, prompt string, expectedClass InputClass, actions ...d200x.InputAction) inputProbe {
	return inputProbe{
		stage:          stage,
		prompt:         prompt,
		expectedClass:  expectedClass,
		expectedAction: append([]d200x.InputAction(nil), actions...),
	}
}

func newInputClassSequenceProbe(stage, prompt string, expectedClass InputClass, actions ...d200x.InputAction) inputProbe {
	return inputProbe{
		stage:            stage,
		prompt:           prompt,
		expectedClass:    expectedClass,
		expectedAction:   append([]d200x.InputAction(nil), actions...),
		expectedSequence: append([]d200x.InputAction(nil), actions...),
	}
}

func brightnessZeroBeforeProbes() []inputProbe {
	return []inputProbe{
		newInputProbe("brightness-zero-before-square", "trigger the square control", InputSquare, 0, d200x.InputActionPressed, d200x.InputActionReleased),
		newInputProbe("brightness-zero-before-wide", "trigger the wide control", InputWide, 13, d200x.InputActionPressed, d200x.InputActionReleased),
		newInputProbe("brightness-zero-before-physical-button-1", "trigger physical button one", InputPhysicalButton, 15, d200x.InputActionPressed, d200x.InputActionReleased),
		newInputProbe("brightness-zero-before-physical-button-2", "trigger physical button two", InputPhysicalButton, 16, d200x.InputActionPressed, d200x.InputActionReleased),
		newInputClassProbe("brightness-zero-before-encoder-left", "rotate the encoder left", InputEncoder, d200x.InputActionRotatedLeft),
		newInputClassProbe("brightness-zero-before-encoder-right", "rotate the encoder right", InputEncoder, d200x.InputActionRotatedRight),
		newInputClassSequenceProbe("brightness-zero-before-encoder-press", "press the encoder", InputEncoder, d200x.InputActionPressed, d200x.InputActionReleased),
	}
}

func brightnessZeroAfterProbes() []inputProbe {
	probes := brightnessZeroBeforeProbes()
	for index := range probes {
		probes[index].stage = strings.Replace(probes[index].stage, "brightness-zero-before-", "brightness-zero-after-", 1)
	}
	return probes
}

func brightnessRestoreProbes() []inputProbe {
	return []inputProbe{
		newInputProbe("brightness-zero-after-restore-square", "trigger the restored square control", InputSquare, 0, d200x.InputActionPressed, d200x.InputActionReleased),
		newInputProbe("brightness-zero-after-restore-physical-button", "trigger the restored physical button", InputPhysicalButton, 15, d200x.InputActionPressed, d200x.InputActionReleased),
		newInputClassProbe("brightness-zero-after-restore-encoder", "rotate the restored encoder", InputEncoder, d200x.InputActionRotatedLeft, d200x.InputActionRotatedRight),
	}
}

func firmwareWakeAfterProbes() []inputProbe {
	return []inputProbe{
		newInputProbe("firmware-wake-after-square", "trigger the square control after the candidate", InputSquare, 0, d200x.InputActionPressed, d200x.InputActionReleased),
		newInputProbe("firmware-wake-after-physical-button", "trigger a physical button after the candidate", InputPhysicalButton, 15, d200x.InputActionPressed, d200x.InputActionReleased),
		newInputClassProbe("firmware-wake-after-encoder", "rotate the encoder after the candidate", InputEncoder, d200x.InputActionRotatedLeft, d200x.InputActionRotatedRight),
	}
}

// Observation is a redacted, bounded record of one diagnostic stage. Device
// paths, serials, raw HID reports, and raw payloads are not representable.
type Observation struct {
	Event                    string                    `json:"event"`
	Mode                     Mode                      `json:"mode"`
	Candidate                WakeCandidate             `json:"candidate,omitempty"`
	Stage                    string                    `json:"stage"`
	Status                   Status                    `json:"status"`
	InputClass               InputClass                `json:"input_class,omitempty"`
	WireIndex                *int                      `json:"wire_index,omitempty"`
	Marker                   string                    `json:"marker,omitempty"`
	Action                   string                    `json:"action,omitempty"`
	Command                  string                    `json:"command,omitempty"`
	Display                  DisplayState              `json:"display,omitempty"`
	Detail                   string                    `json:"detail,omitempty"`
	Sequence                 uint64                    `json:"sequence,omitempty"`
	Phase                    CapturePhase              `json:"phase,omitempty"`
	Decoded                  bool                      `json:"decoded"`
	Malformed                bool                      `json:"malformed"`
	Classification           string                    `json:"classification,omitempty"`
	Boundary                 uint64                    `json:"boundary,omitempty"`
	TimingContract           string                    `json:"timing_contract,omitempty"`
	BrightnessAttestation    BrightnessZeroAttestation `json:"brightness_attestation,omitempty"`
	PlannedBoundaryElapsedNS int64                     `json:"planned_boundary_elapsed_ns,omitempty"`
	WriteStartElapsedNS      int64                     `json:"write_start_elapsed_ns,omitempty"`
	WriteCompletionElapsedNS int64                     `json:"write_completion_elapsed_ns,omitempty"`
	Attestation              EndpointAttestation       `json:"attestation,omitempty"`
	CueStartElapsedNS        int64                     `json:"cue_start_elapsed_ns,omitempty"`
	CueCompletionElapsedNS   int64                     `json:"cue_completion_elapsed_ns,omitempty"`
	CueDurationNS            int64                     `json:"cue_duration_ns,omitempty"`
	WindowStartElapsedNS     int64                     `json:"window_start_elapsed_ns,omitempty"`
	PlannedCloseElapsedNS    int64                     `json:"planned_close_elapsed_ns,omitempty"`
	ActualTimerWakeNS        int64                     `json:"actual_timer_wake_elapsed_ns,omitempty"`
	ActualCaptureStopNS      int64                     `json:"actual_capture_stop_elapsed_ns,omitempty"`
	WindowDurationNS         int64                     `json:"window_duration_ns,omitempty"`
	InputElapsedNS           int64                     `json:"input_elapsed_ns,omitempty"`
}

func (observation Observation) MarshalJSON() ([]byte, error) {
	type observationJSON Observation
	encoded, err := json.Marshal(observationJSON(observation))
	if err != nil || observation.Event == "input" {
		return encoded, err
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(encoded, &fields); err != nil {
		return nil, err
	}
	delete(fields, "decoded")
	delete(fields, "malformed")
	if observation.Stage == keepaliveCueStage && observation.CueDurationNS == 0 {
		fields["cue_duration_ns"] = json.RawMessage("0")
	}
	return json.Marshal(fields)
}

// Result is the bounded in-memory report for one diagnostic run. A firmware
// wake run names exactly one selected candidate; the output observations also
// include not-run records for the other allowlisted candidates.
type Result struct {
	Mode         Mode          `json:"mode"`
	Candidate    WakeCandidate `json:"candidate,omitempty"`
	Status       Status        `json:"status"`
	Observations []Observation `json:"observations"`
}

// Options contains all injected dependencies and operator choices. Confirm
// must be true before a run can enumerate, open, or write to HID. Reader is
// owned by the returned Runner after New succeeds and is closed exactly once
// when the run ends or a read is canceled.
type Options struct {
	Mode                    Mode
	ConfigPath              string
	WakeCandidate           WakeCandidate
	Confirm                 bool
	Factory                 d200x.TransportFactory
	Reader                  io.ReadCloser
	PromptWriter            io.Writer
	ObservationWriter       io.Writer
	StageTimeout            time.Duration
	MaxObservationBytes     int
	Now                     func() time.Time
	KeepaliveInterval       time.Duration
	KeepaliveDuration       time.Duration
	KeepaliveTimingContract string
	KeepaliveClock          KeepaliveClock
	EndpointCue             EndpointCue
}

// Config is an alias retained for callers that prefer configuration-shaped
// naming at construction sites.
type Config = Options

// Runner owns one diagnostic session. A Runner is single-use; a fresh
// firmware-wake generation requires a fresh Runner and HID session.
type Runner struct {
	options                   Options
	reader                    lineReader
	readerCloser              io.ReadCloser
	readerCloseOnce           sync.Once
	sink                      observationSink
	result                    Result
	critical                  []Status
	observationErr            error
	ran                       bool
	keepaliveBoundaries       int64
	keepaliveHealthTest       func(string, uint64, captureHealth) captureHealth
	keepaliveCommitTest       func(string)
	brightnessZeroAttestation BrightnessZeroAttestation
}

type lineReader interface {
	ReadString(byte) (string, error)
}

// New validates only static options and performs no HID activity. Device
// enumeration starts only from Run after confirmation has been checked.
func New(options Options) (*Runner, error) {
	if !options.Mode.Valid() {
		return nil, ErrInvalidMode
	}
	if options.ConfigPath == "" {
		return nil, errors.New("configuration path is required")
	}
	if !filepath.IsAbs(options.ConfigPath) {
		return nil, errors.New("configuration path must be absolute")
	}
	if options.Mode == ModeFirmwareWake {
		if !options.WakeCandidate.Valid() {
			return nil, ErrInvalidWakeCandidate
		}
	} else if options.WakeCandidate != "" {
		return nil, errors.New("wake candidate is only valid for firmware-wake mode")
	}
	keepaliveBoundaries := int64(0)
	if options.Mode == ModeKeepalivePrevention {
		var err error
		keepaliveBoundaries, err = keepaliveScheduleBoundaries(options.KeepaliveInterval, options.KeepaliveDuration)
		if err != nil {
			return nil, err
		}
		if options.KeepaliveTimingContract == "" {
			options.KeepaliveTimingContract = keepaliveTimingContractForSchedule(options.KeepaliveInterval, options.KeepaliveDuration)
		}
		if options.KeepaliveTimingContract != "" && options.KeepaliveTimingContract != keepaliveTimingContractK150V1 {
			return nil, ErrInvalidKeepaliveTimingContract
		}
		if options.KeepaliveTimingContract == keepaliveTimingContractK150V1 &&
			(options.KeepaliveInterval != keepaliveK150Interval || options.KeepaliveDuration != keepaliveK150Duration) {
			return nil, ErrKeepaliveTimingContractMismatch
		}
	} else if options.KeepaliveInterval != 0 || options.KeepaliveDuration != 0 {
		return nil, ErrKeepaliveArgumentsOnly
	}
	if options.StageTimeout < 0 {
		return nil, errors.New("stage timeout cannot be negative")
	}
	if options.Factory == nil {
		options.Factory = d200x.NewHIDFactory()
	}
	if options.Reader == nil {
		options.Reader = io.NopCloser(strings.NewReader(""))
	}
	if options.PromptWriter == nil {
		options.PromptWriter = io.Discard
	}
	if options.ObservationWriter == nil {
		options.ObservationWriter = io.Discard
	}
	if options.StageTimeout == 0 {
		options.StageTimeout = defaultStageTimeout
	}
	if options.Now == nil {
		options.Now = time.Now
	}
	if options.Mode == ModeKeepalivePrevention && options.EndpointCue == nil {
		options.EndpointCue = FixedEndpointCue{}
	}
	reader, ok := options.Reader.(lineReader)
	if !ok {
		reader = bufio.NewReader(options.Reader)
	}
	return &Runner{
		options:      options,
		reader:       reader,
		readerCloser: options.Reader,
		sink: observationSink{
			writer: options.ObservationWriter,
			limit:  boundedObservationBytes(options.MaxObservationBytes),
		},
		result: Result{
			Mode:      options.Mode,
			Candidate: options.WakeCandidate,
			Status:    StatusNotRun,
		},
		keepaliveBoundaries: keepaliveBoundaries,
	}, nil
}

// NewRunner is a descriptive constructor alias.
func NewRunner(options Options) (*Runner, error) {
	return New(options)
}

// Run executes one matrix. It validates and prebuilds the exact configured
// page before HID enumeration, then performs one normal startup sequence. All
// subsequent input reads are owned by this Runner, and every opened session is
// closed before Run returns.
func (runner *Runner) Run(ctx context.Context) (result Result, err error) {
	if runner == nil {
		return Result{}, errors.New("diagnostic runner is nil")
	}
	defer runner.closeReader()
	if runner.ran {
		return Result{}, errors.New("diagnostic runner is single-use")
	}
	runner.ran = true
	if ctx == nil {
		ctx = context.Background()
	}
	runner.result = Result{
		Mode:      runner.options.Mode,
		Candidate: runner.options.WakeCandidate,
		Status:    StatusNotRun,
	}
	runner.critical = nil
	runner.observationErr = nil
	runner.brightnessZeroAttestation = ""
	if err := ctx.Err(); err != nil {
		runner.recordMatrixNotRun("run canceled before confirmation")
		return runner.finish(StatusIndeterminate), safeOperationError("start diagnostic", err)
	}
	if !runner.options.Confirm {
		return runner.finish(StatusPartial), ErrConfirmationRequired
	}
	plan, err := buildPlan(runner.options.ConfigPath)
	if err != nil {
		runner.recordMatrixNotRun("configuration did not validate")
		return runner.finish(StatusFail), safeOperationError("load diagnostic configuration", err)
	}
	if err := ctx.Err(); err != nil {
		runner.recordMatrixNotRun("run canceled before enumeration")
		return runner.finish(StatusIndeterminate), safeOperationError("load diagnostic configuration", err)
	}
	candidates, err := runner.options.Factory.Enumerate(ctx)
	if err != nil {
		runner.recordMatrixNotRun("enumeration did not complete")
		return runner.finish(StatusFail), safeOperationError("enumerate D200X device", err)
	}
	if err := ctx.Err(); err != nil {
		runner.recordMatrixNotRun("run canceled after enumeration")
		return runner.finish(StatusIndeterminate), safeOperationError("enumerate D200X device", err)
	}
	candidate, err := d200x.SelectSingle(candidates)
	if err != nil {
		runner.recordMatrixNotRun("exact D200X selection did not complete")
		return runner.finish(StatusFail), safeOperationError("select D200X device", err)
	}
	if err := ctx.Err(); err != nil {
		runner.recordMatrixNotRun("run canceled before open")
		return runner.finish(StatusIndeterminate), safeOperationError("select D200X device", err)
	}
	session := d200x.NewSession(runner.options.Factory, runner.sessionOptions())
	if err := session.Open(ctx, candidate); err != nil {
		_ = session.Close()
		runner.recordMatrixNotRun("D200X open did not complete")
		return runner.finish(StatusFail), safeOperationError("open D200X device", err)
	}
	defer func() {
		closeErr := session.Close()
		if closeErr == nil {
			return
		}
		runner.addCritical(StatusIndeterminate)
		_ = runner.observe(Observation{
			Event:     "diagnostic",
			Mode:      runner.options.Mode,
			Candidate: runner.options.WakeCandidate,
			Stage:     "close",
			Status:    StatusIndeterminate,
			Detail:    "controlled close failed",
		})
		if err == nil {
			result = runner.finish(StatusIndeterminate)
			err = safeOperationError("close D200X device", closeErr)
		}
	}()

	if err := runner.sendStartup(ctx, session, plan); err != nil {
		runner.addCritical(StatusIndeterminate)
		_ = runner.observe(Observation{
			Event:     "diagnostic",
			Mode:      runner.options.Mode,
			Candidate: runner.options.WakeCandidate,
			Stage:     "normal-startup",
			Status:    StatusIndeterminate,
			Detail:    "startup write outcome is indeterminate",
		})
		runner.recordMatrixNotRun("normal startup did not complete")
		return runner.finish(StatusIndeterminate), safeOperationError("initialize D200X device", err)
	}
	if err := runner.observe(Observation{
		Event:     "diagnostic",
		Mode:      runner.options.Mode,
		Candidate: runner.options.WakeCandidate,
		Stage:     "normal-startup",
		Status:    StatusPass,
		Detail:    "configured page and input stream initialized",
	}); err != nil {
		return runner.finish(StatusIndeterminate), safeOperationError("write diagnostic observation", err)
	}
	runner.addCritical(StatusPass)

	switch runner.options.Mode {
	case ModeBrightnessZero:
		err = runner.runBrightnessZero(ctx, session, plan)
	case ModeFirmwareWake:
		err = runner.runFirmwareWake(ctx, session, plan)
	case ModeKeepalivePrevention:
		err = runner.runKeepalivePrevention(ctx, session)
	}
	if runner.observationErr != nil {
		runner.addCritical(StatusIndeterminate)
		if err == nil {
			err = safeOperationError("write diagnostic observation", runner.observationErr)
		}
	}
	if err != nil {
		return runner.finish(runner.derivedStatus()), err
	}
	return runner.finish(runner.derivedStatus()), nil
}

// Run is a convenience wrapper for one-shot callers.
func Run(ctx context.Context, options Options) (Result, error) {
	runner, err := New(options)
	if err != nil {
		return Result{}, err
	}
	return runner.Run(ctx)
}

type devicePlan struct {
	page       d200x.Page
	pageFrame  d200x.Frame
	brightness int
}

func buildPlan(path string) (devicePlan, error) {
	configuration, err := appconfig.Load(path)
	if err != nil {
		return devicePlan{}, errors.New("configuration could not be loaded")
	}
	catalog, err := configuration.ProfileCatalog()
	if err != nil {
		return devicePlan{}, errors.New("invalid configuration")
	}
	defaultProfile, ok := catalog.Default()
	if !ok {
		return devicePlan{}, errors.New("invalid configuration")
	}
	positions := make([]d200x.Position, 0, len(defaultProfile.Values))
	for _, source := range defaultProfile.Values {
		positions = append(positions, d200x.Position{
			ID:             source.ID,
			Position:       source.Position,
			Label:          source.Label,
			Background:     source.Background,
			LabelAlignment: source.LabelAlignment,
			LabelSize:      source.LabelSize,
		})
	}
	page := d200x.NewPage(positions)
	if err := d200x.ValidatePage(page); err != nil {
		return devicePlan{}, errors.New("invalid configuration")
	}
	pageFrame, err := d200x.PageFrame(page)
	if err != nil {
		return devicePlan{}, errors.New("configured page could not be prepared")
	}
	return devicePlan{page: page, pageFrame: pageFrame, brightness: configuration.Brightness}, nil
}

func (runner *Runner) sessionOptions() d200x.SessionOptions {
	return d200x.SessionOptions{}
}

func (runner *Runner) sendStartup(ctx context.Context, session *d200x.Session, plan devicePlan) error {
	if err := session.SendPageUpload(ctx, plan.page); err != nil {
		return err
	}
	for _, frame := range []d200x.Frame{
		d200x.BrightnessFrame(plan.brightness),
		d200x.UnlockScreenFrame(),
		d200x.EnableInputStreamFrame(),
	} {
		if err := session.SendFrame(ctx, frame); err != nil {
			return err
		}
	}
	return nil
}

func (runner *Runner) runBrightnessZero(ctx context.Context, session *d200x.Session, plan devicePlan) (runErr error) {
	capture := newContinuousCapture(runner.options.Now)
	captureContext, stopCapture := context.WithCancel(ctx)
	var boundaries captureObservationBoundaries
	defer stopCapture()
	defer func() {
		stopCapture()
		<-capture.done
		runner.observeCapturedInputs(capture.snapshot(), boundaries)
	}()
	go capture.run(captureContext, session)

	if err := runner.prompt("perform exactly one press and release on square position 0_0 for the baseline"); err != nil {
		runner.recordCaptureStage("brightness-zero-baseline", StatusIndeterminate, "baseline phase prompt failed", capture.lastBoundary())
		runner.recordBrightnessTailNotRun("baseline phase prompt did not complete", true)
		return safeOperationError("write diagnostic prompt", err)
	}
	baselineReady := capture.markPromptReady()
	boundaries.ready = baselineReady
	if !capture.waitForEventsAfter(ctx, baselineReady, 2, runner.options.StageTimeout) {
		status := capture.waitStatus(ctx)
		runner.recordCaptureStage("brightness-zero-baseline", status, "exact baseline square pair was not captured", capture.lastBoundary())
		runner.recordBrightnessTailNotRun("baseline did not complete", true)
		return capture.waitError(ctx, "capture brightness-zero baseline")
	}
	baselineBoundary := capture.boundaryAfterEvents(baselineReady, 2)
	baselineEnd := capture.markSequenceBoundary()
	boundaries.baselineEnd = baselineEnd
	baselineStatus := validateCapturedEvents(recordsBetween(capture.snapshot(), baselineReady, baselineEnd), baselineTrace())
	if baselineStatus != StatusPass {
		runner.recordCaptureStage("brightness-zero-baseline", baselineStatus, "baseline must be one exact square pair after prompt readiness", baselineEnd)
		runner.recordBrightnessTailNotRun("baseline was not exact", true)
		return nil
	}
	runner.recordCaptureStage("brightness-zero-baseline", StatusPass, "exact square pair captured continuously after prompt readiness", baselineEnd)
	if runner.observationErr != nil {
		runner.addCritical(StatusIndeterminate)
		runner.recordBrightnessTailNotRun("baseline observation did not complete", true)
		return safeOperationError("write diagnostic observation", runner.observationErr)
	}

	zeroStart := capture.markBoundary()
	boundaries.zeroStart = zeroStart
	if capture.elapsedSince(baselineBoundary, zeroStart) >= runner.options.StageTimeout {
		runner.recordCaptureStage("brightness-zero-write", StatusInvalidated, "firmware idle window elapsed before brightness zero", zeroStart)
		runner.recordBrightnessTailNotRun("brightness-zero timing was invalidated", false)
		return nil
	}
	if err := session.SendFrame(ctx, d200x.BrightnessFrame(0)); err != nil {
		zeroEnd := capture.markBoundary()
		runner.recordCaptureStage("brightness-zero-write", StatusIndeterminate, "brightness-zero write outcome is indeterminate", zeroEnd)
		runner.recordBrightnessTailNotRun("brightness-zero write did not complete", false)
		return safeOperationError("write brightness-zero frame", err)
	}
	zeroEnd := capture.markBoundary()
	boundaries.zeroEnd = zeroEnd
	zeroDefinitive := true
	restoreAttempted := false
	restore := func() (captureBoundary, captureBoundary, error) {
		if restoreAttempted || !zeroDefinitive {
			return captureBoundary{}, captureBoundary{}, nil
		}
		restoreAttempted = true
		start := capture.markBoundary()
		restoreContext, cancelRestore := context.WithTimeout(context.Background(), runner.options.StageTimeout)
		defer cancelRestore()
		err := session.SendFrame(restoreContext, d200x.BrightnessFrame(plan.brightness))
		end := capture.markBoundary()
		if err != nil {
			runner.recordCaptureStage("brightness-restore", StatusIndeterminate, "configured brightness restore outcome is indeterminate", end)
			return start, end, err
		}
		runner.recordCaptureStage("brightness-restore", StatusPass, "configured brightness restored exactly once", end)
		return start, end, nil
	}
	defer func() {
		if restoreAttempted || !zeroDefinitive {
			return
		}
		_, _, restoreErr := restore()
		if restoreErr != nil {
			runErr = joinOperationError(runErr, "restore configured brightness", restoreErr)
		}
	}()

	writeInvalidated := capture.hasTraceRecordBetween(zeroStart, zeroEnd)
	writeStatus := StatusPass
	writeDetail := "brightness set to zero exactly once"
	if writeInvalidated {
		writeStatus = StatusInvalidated
		writeDetail = "input arrived during brightness-zero write interval"
	}
	runner.recordCaptureStage("brightness-zero-write", writeStatus, writeDetail, zeroEnd)
	if runner.observationErr != nil {
		runner.addCritical(StatusIndeterminate)
		_, _, restoreErr := restore()
		return joinOperationError(safeOperationError("write diagnostic observation", runner.observationErr), "restore configured brightness", restoreErr)
	}

	if err := runner.prompt("perform, in order: wide position 13 press/release; physical buttons 15 and 16 press/release; square position 0_0 press/release; then rotate exactly one encoder at position 17, 18, or 19 once, left or right. Stop all physical input immediately after that single rotation and wait for the owner-attestation prompt"); err != nil {
		_, _, restoreErr := restore()
		return joinOperationError(safeOperationError("write diagnostic prompt", err), "restore configured brightness", restoreErr)
	}
	rotationBoundary, rotationStatus := capture.waitForBrightnessZeroEncoderRotation(ctx, zeroEnd, runner.options.StageTimeout)
	runner.brightnessZeroAttestation = ""
	attestationStatus := StatusNotRun
	attestationDetail := "owner attestation=not-run; encoder rotation was not captured"
	if rotationStatus == StatusPass {
		attestation, status, detail := runner.readBrightnessZeroAttestation(ctx)
		runner.brightnessZeroAttestation = attestation
		attestationStatus = status
		attestationDetail = detail
	}
	phaseEnd := capture.markBoundary()
	boundaries.phaseEnd = phaseEnd
	matrixRecords := recordsBetween(capture.snapshot(), zeroEnd, phaseEnd)
	matrixStatus, encoderRotation := evaluateBrightnessZeroMatrixWithAttestation(matrixRecords, runner.brightnessZeroAttestation)
	if encoderRotation.sequence == 0 {
		encoderRotation = rotationBoundary
	}
	boundaries.encoderRotation = encoderRotation
	if rotationStatus == StatusPass {
		matrixStatus = combineStatuses(matrixStatus, attestationStatus)
		if attestationStatus == StatusPass && matrixStatus == StatusPass {
			boundaries.encoderRestore = encoderRotation
		}
	}
	matrixStatus = combineStatuses(matrixStatus, rotationStatus)
	runner.recordBrightnessZeroAttestation(attestationStatus, runner.brightnessZeroAttestation, attestationDetail, phaseEnd)
	restoreStart, restoreEnd, restoreErr := restore()
	boundaries.restoreStart = restoreStart
	boundaries.restoreEnd = restoreEnd
	if restoreErr != nil {
		var prior error
		if runner.observationErr != nil {
			prior = safeOperationError("write diagnostic observation", runner.observationErr)
		}
		return joinOperationError(prior, "restore configured brightness", restoreErr)
	}
	matrixStageBoundary := capture.markBoundary()
	if err := runner.prompt("perform one square press and release to confirm recovery"); err != nil {
		runner.recordCaptureStage("brightness-zero-recovery", StatusIndeterminate, "recovery phase prompt failed", restoreEnd)
		return safeOperationError("write diagnostic prompt", err)
	}
	recoveryReady := capture.markPromptReady()
	boundaries.recoveryReady = recoveryReady
	if !capture.waitForEventsAfter(ctx, recoveryReady, 2, runner.options.StageTimeout) {
		status := capture.waitStatus(ctx)
		runner.recordCaptureStage("brightness-zero-recovery", status, "restored square pair was not captured", capture.lastBoundary())
		return capture.waitError(ctx, "capture restored square pair")
	}
	recoveryEnd := capture.markSequenceBoundary()
	boundaries.recoveryEnd = recoveryEnd
	stopCapture()
	<-capture.done

	captureStop := capture.stopBoundary()
	records := capture.snapshot()
	if ctx.Err() != nil || capture.terminalFailure() {
		matrixStatus = StatusIndeterminate
	}
	recoveryStatus := validateCapturedEvents(recordsBetween(records, recoveryReady, recoveryEnd), baselineTrace())
	zeroBoundaryInvalidated := traceRecordsBetweenExist(records, baselineBoundary, zeroEnd)
	postTransitionInvalidated := traceRecordsBetweenExist(records, phaseEnd, recoveryReady)
	postRecoveryInputInvalidated := traceRecordsBetweenExist(records, recoveryEnd, captureStop)
	if writeInvalidated || zeroBoundaryInvalidated || postTransitionInvalidated || postRecoveryInputInvalidated || traceRecordsBetweenExist(records, restoreStart, restoreEnd) {
		matrixStatus = StatusInvalidated
		recoveryStatus = StatusInvalidated
	}
	runner.recordCaptureStage("brightness-zero-matrix", matrixStatus, "post-hoc ordered zero-persistent input validation; "+attestationDetail, matrixStageBoundary)
	runner.recordCaptureStage("brightness-zero-recovery", recoveryStatus, "post-hoc exact restored square pair validation", recoveryEnd)
	return nil
}

type captureBoundary struct {
	sequence uint64
	moment   time.Time
}

type capturedInput struct {
	boundary  captureBoundary
	event     d200x.InputEvent
	decoded   bool
	malformed bool
}

type captureObservationBoundaries struct {
	ready           captureBoundary
	baselineEnd     captureBoundary
	zeroStart       captureBoundary
	zeroEnd         captureBoundary
	phaseEnd        captureBoundary
	encoderRotation captureBoundary
	encoderRestore  captureBoundary
	restoreStart    captureBoundary
	restoreEnd      captureBoundary
	recoveryReady   captureBoundary
	recoveryEnd     captureBoundary
}

func (boundaries captureObservationBoundaries) phase(sequence uint64) CapturePhase {
	if boundaries.ready.sequence == 0 || sequence <= boundaries.ready.sequence {
		return CapturePhasePreReady
	}
	if boundaries.baselineEnd.sequence == 0 || sequence <= boundaries.baselineEnd.sequence {
		return CapturePhaseBaseline
	}
	if boundaries.zeroStart.sequence == 0 || sequence <= boundaries.zeroStart.sequence {
		return CapturePhaseBaseline
	}
	if boundaries.zeroEnd.sequence == 0 || sequence <= boundaries.zeroEnd.sequence {
		return CapturePhaseZeroWriteOverlap
	}
	if boundaries.phaseEnd.sequence == 0 || sequence <= boundaries.phaseEnd.sequence {
		encoderRotation := boundaries.encoderRotation
		if encoderRotation.sequence == 0 {
			encoderRotation = boundaries.encoderRestore
		}
		if encoderRotation.sequence > 0 && sequence >= encoderRotation.sequence {
			return CapturePhaseRestoreOverlap
		}
		return CapturePhaseZeroState
	}
	if boundaries.restoreStart.sequence == 0 {
		return CapturePhaseTrailing
	}
	if boundaries.restoreEnd.sequence == 0 || sequence <= boundaries.restoreEnd.sequence {
		return CapturePhaseRestoreOverlap
	}
	if boundaries.recoveryReady.sequence == 0 || sequence < boundaries.recoveryReady.sequence {
		return CapturePhaseTrailing
	}
	if boundaries.recoveryEnd.sequence == 0 || sequence <= boundaries.recoveryEnd.sequence {
		return CapturePhaseRecovery
	}
	return CapturePhaseTrailing
}

type continuousCapture struct {
	mu          sync.Mutex
	clockMu     sync.Mutex
	now         func() time.Time
	next        uint64
	records     []capturedInput
	notify      chan struct{}
	done        chan struct{}
	terminalErr error
	health      captureHealth
	stopped     bool
	stoppedAt   captureBoundary
}

type captureHealth string

const (
	captureHealthy           captureHealth = "healthy"
	captureTerminalError     captureHealth = "terminal-error"
	captureCapacityExhausted captureHealth = "capacity-exhausted"
)

func newContinuousCapture(now func() time.Time) *continuousCapture {
	return &continuousCapture{now: now, notify: make(chan struct{}, 1), done: make(chan struct{}), health: captureHealthy}
}

func (capture *continuousCapture) nextBoundary() captureBoundary {
	capture.clockMu.Lock()
	defer capture.clockMu.Unlock()
	capture.next++
	return captureBoundary{sequence: capture.next, moment: capture.now()}
}

func (capture *continuousCapture) markBoundary() captureBoundary {
	return capture.nextBoundary()
}

func (capture *continuousCapture) markPromptReady() captureBoundary {
	return capture.markBoundary()
}

func (capture *continuousCapture) markSequenceBoundary() captureBoundary {
	capture.clockMu.Lock()
	defer capture.clockMu.Unlock()
	capture.next++
	return captureBoundary{sequence: capture.next}
}

func (capture *continuousCapture) run(ctx context.Context, session *d200x.Session) {
	defer func() {
		stoppedAt := capture.nextBoundary()
		capture.mu.Lock()
		capture.stopped = true
		capture.stoppedAt = stoppedAt
		capture.mu.Unlock()
		capture.signal()
		close(capture.done)
	}()
	for len(capture.snapshot()) < maximumCapturedInputCount {
		event, decoded, err := session.ReadInput(ctx)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			if d200x.IsInboundMalformed(err) {
				capture.append(capturedInput{malformed: true})
				continue
			}
			capture.mu.Lock()
			capture.terminalErr = err
			capture.health = captureTerminalError
			capture.mu.Unlock()
			capture.signal()
			return
		}
		capture.append(capturedInput{event: event, decoded: decoded})
	}
	capture.mu.Lock()
	capture.health = captureCapacityExhausted
	capture.mu.Unlock()
	capture.signal()
}

func (capture *continuousCapture) append(record capturedInput) {
	capture.clockMu.Lock()
	capture.next++
	record.boundary = captureBoundary{sequence: capture.next, moment: capture.now()}
	capture.mu.Lock()
	capture.records = append(capture.records, record)
	capture.mu.Unlock()
	capture.clockMu.Unlock()
	capture.signal()
}

func (capture *continuousCapture) signal() {
	select {
	case capture.notify <- struct{}{}:
	default:
	}
}

func (capture *continuousCapture) snapshot() []capturedInput {
	capture.mu.Lock()
	defer capture.mu.Unlock()
	return append([]capturedInput(nil), capture.records...)
}

func (capture *continuousCapture) snapshotThrough(boundary captureBoundary) []capturedInput {
	return recordsBetween(capture.snapshot(), captureBoundary{}, boundary)
}

func (capture *continuousCapture) lastBoundary() captureBoundary {
	capture.mu.Lock()
	defer capture.mu.Unlock()
	if len(capture.records) == 0 {
		return captureBoundary{}
	}
	return capture.records[len(capture.records)-1].boundary
}

func (capture *continuousCapture) waitForEvents(ctx context.Context, count int, timeout time.Duration) bool {
	return capture.waitForEventsAfter(ctx, captureBoundary{}, count, timeout)
}

func (capture *continuousCapture) waitForEventsAfter(ctx context.Context, after captureBoundary, count int, timeout time.Duration) bool {
	waitContext, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	for {
		capture.mu.Lock()
		decoded := 0
		for _, record := range capture.records {
			if record.boundary.sequence > after.sequence && record.decoded {
				decoded++
			}
		}
		terminal := capture.terminalErr != nil || capture.stopped
		capture.mu.Unlock()
		if decoded >= count {
			return true
		}
		if terminal {
			return false
		}
		select {
		case <-waitContext.Done():
			return false
		case <-capture.notify:
		}
	}
}

func (capture *continuousCapture) boundaryAfterEvents(after captureBoundary, count int) captureBoundary {
	capture.mu.Lock()
	defer capture.mu.Unlock()
	for _, record := range capture.records {
		if record.boundary.sequence <= after.sequence || !record.decoded {
			continue
		}
		count--
		if count == 0 {
			return record.boundary
		}
	}
	return captureBoundary{}
}

func (capture *continuousCapture) hasTraceRecordBetween(start, end captureBoundary) bool {
	return traceRecordsBetweenExist(capture.snapshot(), start, end)
}

func (capture *continuousCapture) elapsedSince(start, end captureBoundary) time.Duration {
	if start.moment.IsZero() || end.moment.IsZero() || end.moment.Before(start.moment) {
		return 0
	}
	return end.moment.Sub(start.moment)
}

func (capture *continuousCapture) waitStatus(ctx context.Context) Status {
	if ctx.Err() != nil {
		return StatusIndeterminate
	}
	capture.mu.Lock()
	defer capture.mu.Unlock()
	if capture.terminalErr != nil {
		return StatusIndeterminate
	}
	return StatusClassFailure
}

func (capture *continuousCapture) waitError(ctx context.Context, operation string) error {
	if ctx.Err() != nil {
		return safeOperationError(operation, ctx.Err())
	}
	capture.mu.Lock()
	terminal := capture.terminalErr != nil
	capture.mu.Unlock()
	if terminal {
		return fmt.Errorf("%s failed", operation)
	}
	return nil
}

func (capture *continuousCapture) terminalFailure() bool {
	return capture.healthState() != captureHealthy
}

func (capture *continuousCapture) healthState() captureHealth {
	capture.mu.Lock()
	defer capture.mu.Unlock()
	if capture.health == "" {
		return captureHealthy
	}
	return capture.health
}

func (capture *continuousCapture) stopBoundary() captureBoundary {
	capture.mu.Lock()
	defer capture.mu.Unlock()
	return capture.stoppedAt
}

type expectedInput struct {
	wire   byte
	marker d200x.InputMarker
	action d200x.InputAction
}

func baselineTrace() []expectedInput {
	return []expectedInput{
		{wire: 0, marker: d200x.InputMarkerButton, action: d200x.InputActionPressed},
		{wire: 0, marker: d200x.InputMarkerButton, action: d200x.InputActionReleased},
	}
}

func validateCapturedEvents(records []capturedInput, expected []expectedInput) Status {
	records = decodedInputTraceRecords(records)
	if len(records) != len(expected) {
		return StatusClassFailure
	}
	for index, want := range expected {
		got := records[index]
		if got.malformed || !got.decoded || !got.event.Marker.IsKnown() || !got.event.Action.IsKnown() {
			return StatusClassFailure
		}
		if got.event.WireIndex != want.wire || got.event.Marker != want.marker || got.event.Action != want.action {
			return StatusClassFailure
		}
	}
	return StatusPass
}

func recordsBetween(records []capturedInput, start, end captureBoundary) []capturedInput {
	selected := make([]capturedInput, 0)
	for _, record := range records {
		if record.boundary.sequence > start.sequence && record.boundary.sequence <= end.sequence {
			selected = append(selected, record)
		}
	}
	return selected
}

func recordsBetweenExist(records []capturedInput, start, end captureBoundary) bool {
	return len(recordsBetween(records, start, end)) > 0
}

func traceRecordsBetweenExist(records []capturedInput, start, end captureBoundary) bool {
	for _, record := range recordsBetween(records, start, end) {
		if record.decoded || record.malformed {
			return true
		}
	}
	return false
}

func decodedInputTraceRecords(records []capturedInput) []capturedInput {
	selected := make([]capturedInput, 0, len(records))
	for _, record := range records {
		if record.decoded || record.malformed {
			selected = append(selected, record)
		}
	}
	return selected
}

func (runner *Runner) observeCapturedInputs(records []capturedInput, boundaries captureObservationBoundaries) {
	if runner.options.Mode == ModeBrightnessZero {
		runner.observeBrightnessZeroCapturedInputs(records, boundaries)
		return
	}
	ordered := append([]capturedInput(nil), records...)
	sort.SliceStable(ordered, func(left, right int) bool {
		return ordered[left].boundary.sequence < ordered[right].boundary.sequence
	})
	cursors := make(map[CapturePhase]int)
	for _, record := range ordered {
		phase := boundaries.phase(record.boundary.sequence)
		cursor := cursors[phase]
		expected := captureExpectedTrace(phase)
		status, classification, detail := classifyCapturedInput(record, phase, expected, &cursor)
		cursors[phase] = cursor

		observation := Observation{
			Event:          "input",
			Mode:           runner.options.Mode,
			Candidate:      runner.options.WakeCandidate,
			Stage:          "captured-input",
			Status:         status,
			InputClass:     classifyInput(record.event),
			Marker:         markerName(record.event.Marker),
			Action:         actionName(record.event.Action),
			Detail:         detail,
			Sequence:       record.boundary.sequence,
			Phase:          phase,
			Decoded:        record.decoded,
			Malformed:      record.malformed,
			Classification: classification,
			Boundary:       record.boundary.sequence,
		}
		if record.decoded {
			wireIndex := int(record.event.WireIndex)
			observation.WireIndex = &wireIndex
		}
		runner.observe(observation)
	}
}

func captureExpectedTrace(phase CapturePhase) []expectedInput {
	switch phase {
	case CapturePhaseBaseline, CapturePhaseRecovery:
		return baselineTrace()
	case CapturePhaseZeroState:
		return brightnessZeroTrace()
	default:
		return nil
	}
}

func classifyCapturedInput(record capturedInput, phase CapturePhase, expected []expectedInput, cursor *int) (Status, string, string) {
	if record.malformed {
		if phase == CapturePhaseZeroWriteOverlap || phase == CapturePhaseRestoreOverlap {
			return StatusInvalidated, inputClassificationMalformed, "malformed input arrived during an outbound write boundary"
		}
		return StatusClassFailure, inputClassificationMalformed, "malformed input was captured"
	}
	if !record.decoded {
		return StatusPass, inputClassificationNonInput, "non-input frame was captured"
	}
	if phase == CapturePhasePreReady {
		return StatusClassFailure, inputClassificationStale, "input arrived before the baseline prompt was ready"
	}
	if phase == CapturePhaseZeroWriteOverlap || phase == CapturePhaseRestoreOverlap {
		return StatusInvalidated, inputClassificationWriteOverlap, "input arrived during an outbound write boundary"
	}
	if phase == CapturePhaseTrailing {
		return StatusClassFailure, inputClassificationTrailing, "input arrived after the recovery boundary"
	}
	if !record.event.Marker.IsKnown() || !record.event.Action.IsKnown() {
		return StatusClassFailure, inputClassificationWrong, "input marker or action was unknown"
	}
	if cursor != nil && *cursor < len(expected) && expectedInputMatches(record.event, expected[*cursor]) {
		*cursor++
		return StatusPass, inputClassificationExpected, "expected input was captured"
	}
	if cursor != nil {
		for _, prior := range expected[:minInt(*cursor, len(expected))] {
			if expectedInputMatches(record.event, prior) {
				return StatusClassFailure, inputClassificationDuplicate, "duplicate input was captured"
			}
		}
	}
	return StatusClassFailure, inputClassificationWrong, "unexpected input wire, marker, or action was captured"
}

func expectedInputMatches(event d200x.InputEvent, expected expectedInput) bool {
	return event.WireIndex == expected.wire && event.Marker == expected.marker && event.Action == expected.action
}

func minInt(left, right int) int {
	if left < right {
		return left
	}
	return right
}

func (runner *Runner) recordCaptureStage(stage string, status Status, detail string, boundary captureBoundary) {
	_ = runner.observe(Observation{
		Event:    "diagnostic",
		Mode:     runner.options.Mode,
		Stage:    stage,
		Status:   status,
		Detail:   detail,
		Boundary: boundary.sequence,
	})
	runner.addCritical(status)
}

func (runner *Runner) recordBrightnessZeroAttestation(status Status, attestation BrightnessZeroAttestation, detail string, boundary captureBoundary) {
	_ = runner.observe(Observation{
		Event:                 "diagnostic",
		Mode:                  runner.options.Mode,
		Candidate:             runner.options.WakeCandidate,
		Stage:                 brightnessZeroAttestationStage,
		Status:                status,
		BrightnessAttestation: attestation,
		Detail:                detail,
		Boundary:              boundary.sequence,
	})
	runner.addCritical(status)
}

func (runner *Runner) recordBrightnessTailNotRun(detail string, includeWrite bool) {
	stages := []string{brightnessZeroAttestationStage, "brightness-restore", "brightness-zero-matrix", "brightness-zero-recovery"}
	if includeWrite {
		stages = append([]string{"brightness-zero-write"}, stages...)
	}
	for _, stage := range stages {
		runner.recordStageNotRun(stage, "", detail)
		runner.addCritical(StatusNotRun)
	}
}

func (runner *Runner) runFirmwareWake(ctx context.Context, session *d200x.Session, plan devicePlan) error {
	triggered, triggerStatus := runner.awaitTrigger(ctx, "firmware-screensaver", "allow the firmware screensaver to appear, then press Enter", "sleep")
	if triggerStatus != StatusPass {
		runner.recordFirmwareCandidatesNotRun("firmware-screensaver trigger was not staged")
		runner.recordFirmwareTailNotRun("firmware-screensaver trigger was not staged")
		runner.recordStageNotRun("wake-result", "", "firmware-screensaver trigger was not staged")
		runner.addCritical(triggerStatus)
		if ctx.Err() != nil {
			return safeOperationError("run firmware-wake matrix", ctx.Err())
		}
		return nil
	}
	if !triggered {
		return nil
	}

	preStatus, _, preObserved := runner.runNoInputProbe(ctx, session)
	runner.addCritical(preStatus)
	if preStatus != StatusPass {
		detail := "decoded input was observed before wake candidate"
		if !preObserved {
			detail = "pre-attempt square control test did not establish a quiet input stream"
		}
		runner.observeSelectedWake(StatusNotRun, detail)
		runner.recordUnselectedWakeCandidates()
		runner.recordFirmwareTailNotRun("pre-attempt square control test did not pass")
		wakeStatus := combineStatuses(preStatus, StatusPartial)
		_ = runner.observe(Observation{
			Event:     "diagnostic",
			Mode:      runner.options.Mode,
			Candidate: runner.options.WakeCandidate,
			Stage:     "wake-result",
			Status:    wakeStatus,
			Detail:    "candidate was withheld until the square control stream was quiet",
		})
		runner.addCritical(wakeStatus)
		if ctx.Err() != nil {
			return safeOperationError("run firmware-wake matrix", ctx.Err())
		}
		return nil
	}

	var command d200x.Command
	var writeErr error
	if runner.options.WakeCandidate == WakeCompletePageUpload {
		command = d200x.CommandCompleteDisplayUpload
		writeErr = session.SendPageUpload(ctx, plan.page)
	} else {
		frame, err := wakeFrame(runner.options.WakeCandidate, plan)
		if err != nil {
			runner.observeSelectedWake(StatusFail, "wake candidate could not be constructed")
			runner.recordUnselectedWakeCandidates()
			runner.recordFirmwareTailNotRun("wake candidate could not be constructed")
			runner.recordStageNotRun("wake-result", "", "wake candidate could not be constructed")
			runner.addCritical(StatusFail)
			return safeOperationError("construct wake candidate", err)
		}
		command = frame.Command
		writeErr = session.SendFrame(ctx, frame)
	}
	if writeErr != nil {
		runner.observeSelectedWake(StatusIndeterminate, "wake candidate write outcome is indeterminate")
		runner.recordUnselectedWakeCandidates()
		runner.recordFirmwareTailNotRun("wake candidate write did not complete")
		runner.recordStageNotRun("wake-result", "", "wake candidate write did not complete")
		runner.addCritical(StatusIndeterminate)
		return safeOperationError("write wake candidate", writeErr)
	}
	if err := runner.observe(Observation{
		Event:     "diagnostic",
		Mode:      runner.options.Mode,
		Candidate: runner.options.WakeCandidate,
		Stage:     "wake-candidate-write",
		Status:    StatusPass,
		Command:   command.String(),
		Detail:    "one allowlisted candidate frame sent after normal startup",
	}); err != nil {
		return safeOperationError("write diagnostic observation", err)
	}
	runner.addCritical(StatusPass)
	runner.recordUnselectedWakeCandidates()

	displayStatus, displayState := runner.awaitDisplayState(ctx)
	if displayState == DisplayUnchanged && runner.options.WakeCandidate != WakeInputEnable && displayStatus == StatusPass {
		displayStatus = runner.recordStageStatus("display-recovery", StatusFail, "display remained unchanged for a visual wake candidate")
	}
	runner.addCritical(displayStatus)
	if ctx.Err() != nil {
		runner.recordFirmwareTailNotRun("run canceled before post-candidate input")
		runner.recordStageNotRun("wake-result", "", "run canceled before post-candidate input")
		runner.addCritical(StatusIndeterminate)
		return safeOperationError("run firmware-wake matrix", ctx.Err())
	}

	postStatuses := make([]Status, 0, len(firmwareWakeAfterProbes()))
	postProbes := firmwareWakeAfterProbes()
	for index, probe := range postProbes {
		status := runner.runInputProbe(ctx, session, probe)
		postStatuses = append(postStatuses, status)
		runner.addCritical(status)
		if ctx.Err() != nil {
			runner.recordInputProbesNotRun(postProbes[index+1:], "run canceled before post-candidate input")
			runner.recordStageNotRun("wake-result", "", "run canceled before post-candidate input")
			runner.addCritical(StatusIndeterminate)
			return safeOperationError("run firmware-wake matrix", ctx.Err())
		}
	}

	wakeStatuses := append([]Status{displayStatus}, postStatuses...)
	wakeStatus := combineStatuses(wakeStatuses...)
	if err := runner.observe(Observation{
		Event:     "diagnostic",
		Mode:      runner.options.Mode,
		Candidate: runner.options.WakeCandidate,
		Stage:     "wake-result",
		Status:    wakeStatus,
		Detail:    "wake requires explicit display state and resumed decoded input",
	}); err != nil {
		return safeOperationError("write diagnostic observation", err)
	}
	runner.addCritical(wakeStatus)
	return nil
}

func wakeFrame(candidate WakeCandidate, plan devicePlan) (d200x.Frame, error) {
	switch candidate {
	case WakeBrightness:
		return d200x.BrightnessFrame(plan.brightness), nil
	case WakeInputEnable:
		return d200x.EnableInputStreamFrame(), nil
	case WakeUnlock:
		return d200x.UnlockScreenFrame(), nil
	case WakeCompletePageUpload:
		return plan.pageFrame, nil
	default:
		return d200x.Frame{}, ErrInvalidWakeCandidate
	}
}

func (runner *Runner) runInputProbes(ctx context.Context, session *d200x.Session, probes []inputProbe) bool {
	for index, probe := range probes {
		status := runner.runInputProbe(ctx, session, probe)
		runner.addCritical(status)
		if ctx.Err() == nil {
			continue
		}
		runner.recordInputProbesNotRun(probes[index+1:], "run canceled before input stage")
		return true
	}
	return false
}

func (runner *Runner) runInputProbe(ctx context.Context, session *d200x.Session, probe inputProbe) Status {
	run, status := runner.awaitTrigger(ctx, probe.stage+"-trigger", probe.prompt+" (Enter to run, skip to omit)", "run")
	if status != StatusPass {
		runner.observeInputNotRun(probe.stage, probe.expectedClass, "input stage was not staged")
		return status
	}
	if !run {
		runner.observeInputNotRun(probe.stage, probe.expectedClass, "input stage was skipped")
		return StatusNotRun
	}
	events, readStatus := runner.readInputSequence(ctx, session, probe.eventCount())
	if readStatus != StatusPass {
		event, ok := inputProbeObservationEvent(events, -1)
		detail := "decoded input sequence was not observed"
		if len(events) > 0 {
			detail = "decoded input sequence was not fully observed"
		}
		runner.observeInputEvent(probe.stage, probe.expectedClass, readStatus, event, ok, detail)
		return readStatus
	}
	invalidIndex := invalidInputProbeEvent(probe, events)
	status = StatusPass
	detail := inputSequenceDetail(probe, events, invalidIndex)
	event, ok := inputProbeObservationEvent(events, invalidIndex)
	if invalidIndex >= 0 {
		status = StatusFail
	}
	runner.observeInputEvent(probe.stage, probe.expectedClass, status, event, ok, detail)
	return status
}

func (runner *Runner) runNoInputProbe(ctx context.Context, session *d200x.Session) (Status, d200x.InputEvent, bool) {
	const stage = "firmware-wake-before-square"
	run, status := runner.awaitTrigger(ctx, stage+"-trigger", "confirm the square control is quiet, then press Enter", "run")
	if status != StatusPass {
		runner.observeInputNotRun(stage, InputSquare, "pre-attempt square control test was not staged")
		return status, d200x.InputEvent{}, false
	}
	if !run {
		runner.observeInputNotRun(stage, InputSquare, "pre-attempt square control test was skipped")
		return StatusNotRun, d200x.InputEvent{}, false
	}
	event, observed, readStatus := runner.readNoInput(ctx, session)
	if readStatus == StatusPass {
		runner.observeInputEvent(stage, InputSquare, StatusPass, event, false, "no decoded input observed before wake candidate")
		return StatusPass, event, false
	}
	detail := "pre-attempt input read did not establish a quiet stream"
	if observed {
		detail = "decoded input observed before wake candidate"
	}
	runner.observeInputEvent(stage, InputSquare, readStatus, event, observed, detail)
	return readStatus, event, observed
}

func (runner *Runner) readInput(ctx context.Context, session *d200x.Session) (d200x.InputEvent, bool, Status) {
	readContext, cancel := context.WithTimeout(ctx, runner.options.StageTimeout)
	defer cancel()
	for frameCount := 0; frameCount < maximumFramesPerInputStep; frameCount++ {
		event, ok, err := session.ReadInput(readContext)
		if err != nil {
			if ctx.Err() != nil {
				return d200x.InputEvent{}, false, StatusIndeterminate
			}
			return event, ok, StatusFail
		}
		if ok {
			return event, true, StatusPass
		}
	}
	return d200x.InputEvent{}, false, StatusFail
}

func (runner *Runner) readInputSequence(ctx context.Context, session *d200x.Session, eventCount int) ([]d200x.InputEvent, Status) {
	if eventCount <= 0 {
		eventCount = 1
	}
	readContext, cancel := context.WithTimeout(ctx, runner.options.StageTimeout)
	defer cancel()
	events := make([]d200x.InputEvent, 0, eventCount)
	for frameCount := 0; frameCount < maximumFramesPerInputStep && len(events) < eventCount; frameCount++ {
		event, ok, err := session.ReadInput(readContext)
		if err != nil {
			if ctx.Err() != nil {
				return events, StatusIndeterminate
			}
			return events, StatusFail
		}
		if ok {
			events = append(events, event)
		}
	}
	if len(events) != eventCount {
		return events, StatusFail
	}
	return events, StatusPass
}

func (runner *Runner) readNoInput(ctx context.Context, session *d200x.Session) (d200x.InputEvent, bool, Status) {
	readContext, cancel := context.WithTimeout(ctx, runner.options.StageTimeout)
	defer cancel()
	for frameCount := 0; frameCount < maximumFramesPerInputStep; frameCount++ {
		event, ok, err := session.ReadInput(readContext)
		if err != nil {
			if ctx.Err() != nil {
				return d200x.InputEvent{}, false, StatusIndeterminate
			}
			if errors.Is(readContext.Err(), context.DeadlineExceeded) || errors.Is(err, context.DeadlineExceeded) {
				return d200x.InputEvent{}, false, StatusPass
			}
			return event, ok, StatusFail
		}
		if ok {
			return event, true, StatusFail
		}
	}
	return d200x.InputEvent{}, false, StatusPass
}

func classifyInput(event d200x.InputEvent) InputClass {
	switch event.Marker {
	case d200x.InputMarkerEncoder:
		return InputEncoder
	case d200x.InputMarkerButton:
		if spec, ok := d200x.PositionForWireIndex(event.WireIndex); ok {
			if spec.Wide {
				return InputWide
			}
			return InputSquare
		}
		if event.WireIndex == 15 || event.WireIndex == 16 {
			return InputPhysicalButton
		}
	}
	return ""
}

func inputDetail(probe inputProbe, event d200x.InputEvent, actual InputClass) string {
	if actual != probe.expectedClass {
		return "unexpected input class observed"
	}
	if probe.expectedWire != nil && event.WireIndex != *probe.expectedWire {
		return "unexpected input wire position observed"
	}
	if !matchesAction(probe.expectedAction, event.Action) {
		return "unexpected input action observed"
	}
	if !event.Marker.IsKnown() || !event.Action.IsKnown() {
		return "unknown input values observed"
	}
	return "expected input class, position, and action observed"
}

func invalidInputProbeEvent(probe inputProbe, events []d200x.InputEvent) int {
	if len(events) == 0 {
		return -1
	}
	for index, event := range events {
		actual := classifyInput(event)
		if !event.Marker.IsKnown() || !event.Action.IsKnown() || actual != probe.expectedClass {
			return index
		}
		if probe.expectedWire != nil && event.WireIndex != *probe.expectedWire {
			return index
		}
		if index > 0 {
			first := events[0]
			if event.WireIndex != first.WireIndex || actual != classifyInput(first) {
				return index
			}
		}
		if len(probe.expectedSequence) > 0 {
			if event.Action != probe.expectedSequence[index] {
				return index
			}
		} else if !matchesAction(probe.expectedAction, event.Action) {
			return index
		}
	}
	return -1
}

func inputSequenceDetail(probe inputProbe, events []d200x.InputEvent, invalidIndex int) string {
	if invalidIndex >= 0 {
		event := events[invalidIndex]
		actual := classifyInput(event)
		if actual != probe.expectedClass {
			return "unexpected input class observed"
		}
		if probe.expectedWire != nil && event.WireIndex != *probe.expectedWire {
			return "unexpected input wire position observed"
		}
		if invalidIndex > 0 {
			first := events[0]
			if event.WireIndex != first.WireIndex || actual != classifyInput(first) {
				return "input pair changed wire position or class"
			}
		}
		if len(probe.expectedSequence) > 0 {
			if len(probe.expectedSequence) > invalidIndex && event.Action != probe.expectedSequence[invalidIndex] {
				return "unexpected input action sequence observed"
			}
		} else if !matchesAction(probe.expectedAction, event.Action) {
			return "unexpected input action observed"
		}
		if !event.Marker.IsKnown() || !event.Action.IsKnown() {
			return "unknown input values observed"
		}
		return "unexpected input sequence observed"
	}
	if len(probe.expectedSequence) > 1 {
		return "expected pressed and released input pair observed"
	}
	if len(events) == 1 {
		return inputDetail(probe, events[0], classifyInput(events[0]))
	}
	return "expected input sequence observed"
}

func (probe inputProbe) eventCount() int {
	if len(probe.expectedSequence) > 0 {
		return len(probe.expectedSequence)
	}
	return 1
}

func inputProbeObservationEvent(events []d200x.InputEvent, invalidIndex int) (d200x.InputEvent, bool) {
	if len(events) == 0 {
		return d200x.InputEvent{}, false
	}
	if invalidIndex >= 0 && invalidIndex < len(events) {
		return events[invalidIndex], true
	}
	return events[0], true
}

func matchesAction(expected []d200x.InputAction, actual d200x.InputAction) bool {
	if len(expected) == 0 {
		return true
	}
	for _, action := range expected {
		if action == actual {
			return true
		}
	}
	return false
}

func (runner *Runner) awaitTrigger(ctx context.Context, stage, prompt, accepted string) (bool, Status) {
	if err := runner.prompt(prompt); err != nil {
		return false, runner.recordStageStatus(stage, StatusIndeterminate, "trigger prompt failed")
	}
	line, err := runner.readLine(ctx)
	if err != nil {
		if errors.Is(err, io.EOF) {
			return false, runner.recordStageStatus(stage, StatusNotRun, "operator did not stage trigger")
		}
		if ctx.Err() != nil {
			return false, runner.recordStageStatus(stage, StatusIndeterminate, "trigger was canceled")
		}
		return false, runner.recordStageStatus(stage, StatusFail, "trigger input failed")
	}
	value := strings.ToLower(strings.TrimSpace(line))
	if value == "skip" || value == "no" {
		return false, runner.recordStageStatus(stage, StatusNotRun, "operator skipped trigger")
	}
	if value == "" || value == "run" || value == "yes" || value == "y" || value == accepted || value == stage || value == "trigger" || value == "sleep" || value == "ready" {
		return true, runner.recordStageStatus(stage, StatusPass, "operator staged trigger")
	}
	return false, runner.recordStageStatus(stage, StatusFail, "operator entered an unknown trigger")
}

func (runner *Runner) awaitDisplayState(ctx context.Context) (Status, DisplayState) {
	const stage = "display-recovery"
	if err := runner.prompt("record the display state after the candidate: recovered, unchanged, or skip"); err != nil {
		return runner.recordDisplayStatus(stage, StatusIndeterminate, "display state prompt failed", ""), ""
	}
	line, err := runner.readLine(ctx)
	if err != nil {
		if errors.Is(err, io.EOF) {
			return runner.recordDisplayStatus(stage, StatusNotRun, "operator did not stage display state", ""), ""
		}
		if ctx.Err() != nil {
			return runner.recordDisplayStatus(stage, StatusIndeterminate, "display state was canceled", ""), ""
		}
		return runner.recordDisplayStatus(stage, StatusFail, "display state input failed", ""), ""
	}
	switch strings.ToLower(strings.TrimSpace(line)) {
	case "recovered", "yes", "y", "run":
		return runner.recordDisplayStatus(stage, StatusPass, "operator recorded display recovery", DisplayRecovered), DisplayRecovered
	case "unchanged":
		return runner.recordDisplayStatus(stage, StatusPass, "operator recorded unchanged display", DisplayUnchanged), DisplayUnchanged
	case "skip", "":
		return runner.recordDisplayStatus(stage, StatusNotRun, "operator did not record display state", ""), ""
	default:
		return runner.recordDisplayStatus(stage, StatusFail, "operator entered an unknown display state", ""), ""
	}
}

func (runner *Runner) recordDisplayStatus(stage string, status Status, detail string, display DisplayState) Status {
	_ = runner.observe(Observation{
		Event:     "diagnostic",
		Mode:      runner.options.Mode,
		Candidate: runner.options.WakeCandidate,
		Stage:     stage,
		Status:    status,
		Display:   display,
		Detail:    detail,
	})
	return status
}

func (runner *Runner) readLine(ctx context.Context) (string, error) {
	return runner.readLineContext(ctx, true)
}

type lineReadResult struct {
	line string
	err  error
}

func (runner *Runner) readLineContext(ctx context.Context, acceptPartialEOF bool) (string, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	result := make(chan lineReadResult, 1)
	go func() {
		line, err := runner.reader.ReadString('\n')
		if acceptPartialEOF && err == io.EOF && line != "" {
			err = nil
		}
		result <- lineReadResult{line: line, err: err}
	}()
	select {
	case <-ctx.Done():
		runner.closeReader()
		<-result
		return "", ctx.Err()
	case value := <-result:
		return value.line, value.err
	}
}

func (runner *Runner) closeReader() {
	if runner == nil || runner.readerCloser == nil {
		return
	}
	runner.readerCloseOnce.Do(func() {
		_ = runner.readerCloser.Close()
	})
}

func (runner *Runner) prompt(message string) error {
	if runner.options.PromptWriter == nil {
		return nil
	}
	if len(message) > maximumObservationBytes {
		message = message[:maximumObservationBytes]
	}
	prompt := message + "\n"
	n, err := io.WriteString(runner.options.PromptWriter, prompt)
	if err != nil {
		return err
	}
	if n != len(prompt) {
		return io.ErrShortWrite
	}
	return nil
}

func (runner *Runner) observeInputEvent(stage string, expected InputClass, status Status, event d200x.InputEvent, ok bool, detail string) {
	observation := Observation{
		Event:      "diagnostic",
		Mode:       runner.options.Mode,
		Candidate:  runner.options.WakeCandidate,
		Stage:      stage,
		Status:     status,
		InputClass: expected,
		Detail:     detail,
	}
	if ok {
		wireIndex := int(event.WireIndex)
		observation.WireIndex = &wireIndex
		observation.Marker = markerName(event.Marker)
		observation.Action = actionName(event.Action)
		if observation.InputClass == "" {
			observation.InputClass = classifyInput(event)
		}
	}
	_ = runner.observe(observation)
}

func (runner *Runner) observeInputNotRun(stage string, expected InputClass, detail string) {
	_ = runner.observe(Observation{
		Event:      "diagnostic",
		Mode:       runner.options.Mode,
		Candidate:  runner.options.WakeCandidate,
		Stage:      stage,
		Status:     StatusNotRun,
		InputClass: expected,
		Detail:     detail,
	})
}

func (runner *Runner) recordInputProbesNotRun(probes []inputProbe, detail string) {
	for _, probe := range probes {
		runner.observeInputNotRun(probe.stage, probe.expectedClass, detail)
		runner.addCritical(StatusPartial)
	}
}

func markerName(marker d200x.InputMarker) string {
	switch marker {
	case d200x.InputMarkerButton:
		return "button"
	case d200x.InputMarkerEncoder:
		return "encoder"
	default:
		return "unknown"
	}
}

func actionName(action d200x.InputAction) string {
	switch action {
	case d200x.InputActionReleased:
		return "released"
	case d200x.InputActionPressed:
		return "pressed"
	case d200x.InputActionRotatedLeft:
		return "rotated-left"
	case d200x.InputActionRotatedRight:
		return "rotated-right"
	default:
		return "unknown"
	}
}

func (runner *Runner) recordUnselectedWakeCandidates() {
	for _, candidate := range wakeCandidates {
		if candidate == runner.options.WakeCandidate {
			continue
		}
		_ = runner.observe(Observation{
			Event:     "diagnostic",
			Mode:      runner.options.Mode,
			Candidate: candidate,
			Stage:     "wake-candidate",
			Status:    StatusNotRun,
			Detail:    "candidate was not selected for this fresh generation",
		})
	}
}

func (runner *Runner) recordFirmwareCandidatesNotRun(detail string) {
	for _, candidate := range wakeCandidates {
		candidateDetail := detail
		if candidate != runner.options.WakeCandidate {
			candidateDetail = "candidate was not selected for this fresh generation"
		}
		_ = runner.observe(Observation{
			Event:     "diagnostic",
			Mode:      runner.options.Mode,
			Candidate: candidate,
			Stage:     "wake-candidate",
			Status:    StatusNotRun,
			Detail:    candidateDetail,
		})
		runner.addCritical(StatusPartial)
	}
}

func (runner *Runner) recordFirmwareTailNotRun(detail string) {
	runner.recordStageNotRun("display-recovery", "", detail)
	for _, probe := range firmwareWakeAfterProbes() {
		runner.observeInputNotRun(probe.stage, probe.expectedClass, detail)
		runner.addCritical(StatusPartial)
	}
}

func (runner *Runner) recordMatrixNotRun(detail string) {
	runner.addCritical(StatusPartial)
	if runner.options.Mode == ModeBrightnessZero {
		runner.recordStageNotRun("brightness-zero-baseline", InputSquare, detail)
		runner.recordStageNotRun("brightness-zero-write", "", detail)
		runner.recordStageNotRun(brightnessZeroAttestationStage, "", detail)
		runner.recordStageNotRun("brightness-restore", "", detail)
		runner.recordStageNotRun("brightness-zero-matrix", "", detail)
		runner.recordStageNotRun("brightness-zero-recovery", InputSquare, detail)
		return
	}
	if runner.options.Mode == ModeKeepalivePrevention {
		runner.recordStageNotRun("keepalive-prevention-start", "", detail)
		runner.recordStageNotRun("keepalive-prevention-schedule", "", detail)
		runner.recordStageNotRun("keepalive-prevention-final-verification", InputSquare, detail)
		runner.recordStageNotRun("keepalive-prevention-result", "", detail)
		return
	}
	runner.recordStageNotRun("firmware-screensaver", "", detail)
	runner.recordStageNotRun("firmware-wake-before-square", InputSquare, detail)
	runner.recordFirmwareCandidatesNotRun(detail)
	runner.recordFirmwareTailNotRun(detail)
	runner.recordStageNotRun("wake-result", "", detail)
}

func (runner *Runner) recordStageNotRun(stage string, inputClass InputClass, detail string) {
	_ = runner.observe(Observation{
		Event:      "diagnostic",
		Mode:       runner.options.Mode,
		Candidate:  runner.options.WakeCandidate,
		Stage:      stage,
		Status:     StatusNotRun,
		InputClass: inputClass,
		Detail:     detail,
	})
}

func (runner *Runner) observeSelectedWake(status Status, detail string) {
	_ = runner.observe(Observation{
		Event:     "diagnostic",
		Mode:      runner.options.Mode,
		Candidate: runner.options.WakeCandidate,
		Stage:     "wake-candidate",
		Status:    status,
		Detail:    detail,
	})
}

func (runner *Runner) recordStageStatus(stage string, status Status, detail string) Status {
	_ = runner.observe(Observation{
		Event:     "diagnostic",
		Mode:      runner.options.Mode,
		Candidate: runner.options.WakeCandidate,
		Stage:     stage,
		Status:    status,
		Detail:    detail,
	})
	return status
}

func (runner *Runner) addCritical(status Status) {
	runner.critical = append(runner.critical, status)
}

func (runner *Runner) derivedStatus() Status {
	if len(runner.critical) == 0 {
		return StatusPartial
	}
	return combineStatuses(runner.critical...)
}

func combineStatuses(statuses ...Status) Status {
	if len(statuses) == 0 {
		return StatusPartial
	}
	for _, status := range statuses {
		if status == StatusIndeterminate {
			return StatusIndeterminate
		}
	}
	for _, status := range statuses {
		if status == StatusInvalidated {
			return StatusInvalidated
		}
	}
	for _, status := range statuses {
		if status == StatusFail {
			return StatusFail
		}
	}
	for _, status := range statuses {
		if status == StatusClassFailure {
			return StatusClassFailure
		}
	}
	for _, status := range statuses {
		if status == StatusPartial || status == StatusNotRun {
			return StatusPartial
		}
	}
	return StatusPass
}

func (runner *Runner) finish(status Status) Result {
	if status == "" {
		status = runner.derivedStatus()
	}
	runner.result.Status = status
	runner.result.Observations = runner.sink.snapshot()
	return runner.result
}

func safeOperationError(operation string, err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, context.Canceled) {
		return fmt.Errorf("%s canceled", operation)
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return fmt.Errorf("%s deadline exceeded", operation)
	}
	return fmt.Errorf("%s failed", operation)
}

func joinOperationError(existing error, operation string, cause error) error {
	if cause == nil {
		return existing
	}
	safe := safeOperationError(operation, cause)
	if existing == nil {
		return safe
	}
	return errors.Join(existing, safe)
}

type observationSink struct {
	writer io.Writer
	limit  int
	items  []Observation
}

func boundedObservationBytes(requested int) int {
	if requested <= 0 {
		return defaultObservationBytes
	}
	if requested > maximumObservationBytes {
		return maximumObservationBytes
	}
	return requested
}

func (sink *observationSink) observe(observation Observation) error {
	if sink == nil {
		return errors.New("diagnostic observation sink is nil")
	}
	if sink.writer == nil {
		return errors.New("diagnostic observation writer is nil")
	}
	if len(sink.items) >= maximumObservationCount {
		return errors.New("diagnostic observation limit reached")
	}
	encoded, err := json.Marshal(observation)
	if err != nil {
		return errors.New("encode diagnostic observation failed")
	}
	if len(encoded)+1 > sink.limit {
		if observation.TimingContract != "" {
			return errors.New("timing contract observation exceeds output limit")
		}
		bounded := boundedObservations(observation)
		for _, candidate := range bounded {
			candidateEncoded, candidateErr := json.Marshal(candidate)
			if candidateErr != nil {
				return errors.New("encode bounded diagnostic observation failed")
			}
			if len(candidateEncoded)+1 <= sink.limit {
				observation = candidate
				encoded = candidateEncoded
				break
			}
		}
	}
	if len(encoded)+1 > sink.limit {
		return errors.New("diagnostic observation exceeds output limit")
	}
	encoded = append(encoded, '\n')
	n, writeErr := sink.writer.Write(encoded)
	if writeErr != nil {
		return errors.New("diagnostic observation output failed")
	}
	if n != len(encoded) {
		return io.ErrShortWrite
	}
	sink.items = append(sink.items, observation)
	return nil
}

func boundedObservations(observation Observation) []Observation {
	if observation.Event == "input" {
		metadata := Observation{
			Event:          "input",
			Mode:           observation.Mode,
			Candidate:      observation.Candidate,
			Status:         observation.Status,
			Sequence:       observation.Sequence,
			Phase:          observation.Phase,
			Decoded:        observation.Decoded,
			Malformed:      observation.Malformed,
			Classification: observation.Classification,
			Boundary:       observation.Boundary,
			Marker:         observation.Marker,
			Action:         observation.Action,
		}
		if observation.WireIndex != nil {
			wireIndex := *observation.WireIndex
			metadata.WireIndex = &wireIndex
		}
		return []Observation{
			metadata,
			{
				Event:          "input",
				Mode:           observation.Mode,
				Sequence:       observation.Sequence,
				Phase:          observation.Phase,
				Decoded:        observation.Decoded,
				Malformed:      observation.Malformed,
				Classification: observation.Classification,
			},
			{Event: "input", Mode: observation.Mode, Sequence: observation.Sequence, Phase: observation.Phase, Decoded: observation.Decoded, Malformed: observation.Malformed},
		}
	}
	return []Observation{
		{
			Event:                 "diagnostic",
			Mode:                  observation.Mode,
			Candidate:             observation.Candidate,
			Stage:                 observation.Stage,
			Status:                observation.Status,
			BrightnessAttestation: observation.BrightnessAttestation,
			Boundary:              observation.Boundary,
		},
		{
			Event:  "diagnostic",
			Stage:  observation.Stage,
			Status: observation.Status,
		},
		{Event: "diagnostic", Status: observation.Status},
	}
}

func (sink *observationSink) snapshot() []Observation {
	if sink == nil {
		return nil
	}
	return append([]Observation(nil), sink.items...)
}

func (runner *Runner) observe(observation Observation) error {
	err := runner.sink.observe(observation)
	if err != nil && runner.observationErr == nil {
		runner.observationErr = err
	}
	return err
}
