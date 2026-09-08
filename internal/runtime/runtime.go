package runtime

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
	"time"

	appconfig "hidhogg/internal/config"
	"hidhogg/internal/d200x"
	"hidhogg/internal/discovery"
	"hidhogg/internal/execution"
	"hidhogg/internal/ipc"
	"hidhogg/internal/profile"
)

const maximumEventLineBytes = 4 * 1024

var errExecutionSupervisionFailed = errors.New("runtime execution supervision failed")

type executionWorker interface {
	executionSubmitter
	Faults() <-chan error
	ListSummaries(int) ([]execution.Summary, error)
	Get(string) (execution.Record, bool)
	Close() error
}

type executionWorkerFactory func() (executionWorker, error)

// Config contains the process-owned runtime dependencies. ConfigPath is
// intentionally explicit: the runtime never discovers or watches a config
// file. TransportFactory, Stdout, and Stderr are injectable for deterministic
// tests; nil values select the production HID factory and process streams.
type Config struct {
	RuntimeDir       string
	SocketPath       string
	InstanceID       string
	Deadlines        ipc.Deadlines
	ConfigPath       string
	Verbose          bool
	Clock            Clock
	TransportFactory d200x.TransportFactory
	Stdout           io.Writer
	Stderr           io.Writer
	// Terminal is called once when an activation write leaves device state
	// uncertain or execution supervision cannot confirm child reap. Runtime
	// withdraws readiness and cancels serving before invoking this callback.
	Terminal func(error)
}

// Runtime owns one configured D200X session, one execution worker generation,
// and the IPC server. The endpoint is preflighted and bound before HID access,
// while discovery metadata is withheld until device initialization and IPC
// serving are ready.
type Runtime struct {
	server           *ipc.Server
	generation       *discovery.Generation
	config           Config
	factory          d200x.TransportFactory
	stdout           io.Writer
	stderr           io.Writer
	clock            Clock
	executionFactory executionWorkerFactory

	startMu          sync.Mutex
	mu               sync.Mutex
	started          bool
	closed           bool
	session          *d200x.Session
	profileService   *RuntimeProfileService
	executionWorker  executionWorker
	defaultProfileID string
	plan             devicePlan
	startupCompleted time.Time
	terminalCancel   context.CancelFunc
	terminalErr      error
	terminalOnce     sync.Once
}

type devicePlan struct {
	page        d200x.Page
	brightness  int
	idleTimeout time.Duration
	positions   map[byte]eventPosition
	positionsFn func() map[byte]eventPosition
}

type eventPosition struct {
	id       string
	position string
}

// New constructs an injectable runtime. It does not enumerate or open HID;
// all device activity begins in Start or Run after configuration validation.
func New(config Config) (*Runtime, error) {
	normalized, err := normalizeConfig(config)
	if err != nil {
		return nil, err
	}
	factory := config.TransportFactory
	if factory == nil {
		factory = d200x.NewHIDFactory()
	}
	stdout := config.Stdout
	if stdout == nil {
		stdout = os.Stdout
	}
	stderr := config.Stderr
	if stderr == nil {
		stderr = os.Stderr
	}
	clock := config.Clock
	if clock == nil {
		clock = realClock{}
	}
	runtime := &Runtime{
		config:           normalized,
		factory:          factory,
		stdout:           stdout,
		stderr:           stderr,
		clock:            clock,
		executionFactory: func() (executionWorker, error) { return execution.New() },
	}
	if normalized.RuntimeDir == "" {
		runtime.server, err = ipc.NewServer(ipc.ServerConfig{
			SocketPath:       normalized.SocketPath,
			InstanceID:       normalized.InstanceID,
			Deadlines:        normalized.Deadlines,
			ProfileService:   runtimeIPCProfileService{runtime: runtime},
			ExecutionHistory: runtimeExecutionHistory{runtime: runtime},
		})
		if err != nil {
			return nil, err
		}
	}
	return runtime, nil
}

// ProfileService returns the runtime-owned profile boundary once startup has
// completed. The nil result is expected before Start and after Close.
func (r *Runtime) ProfileService() ProfileService {
	if r == nil {
		return nil
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.profileService
}

func (r *Runtime) profileTransitionGate() *profileTransitionGate {
	if r == nil {
		return nil
	}
	r.mu.Lock()
	service := r.profileService
	r.mu.Unlock()
	if service == nil {
		return nil
	}
	return service.profileTransitionGate()
}

// ListProfiles returns the configured profile definitions in order.
func (r *Runtime) ListProfiles() []profile.Profile {
	service := r.ProfileService()
	if service == nil {
		return nil
	}
	return service.ListProfiles()
}

// CurrentProfile returns the last successfully committed profile.
func (r *Runtime) CurrentProfile() (profile.Profile, bool) {
	service := r.ProfileService()
	if service == nil {
		return profile.Profile{}, false
	}
	return service.CurrentProfile()
}

// CurrentProfileID returns the last successfully committed profile ID.
func (r *Runtime) CurrentProfileID() (string, bool) {
	service := r.ProfileService()
	if service == nil {
		return "", false
	}
	return service.CurrentProfileID()
}

// CurrentBindings returns the action bindings of the last committed profile.
func (r *Runtime) CurrentBindings() []profile.Binding {
	service := r.ProfileService()
	if service == nil {
		return nil
	}
	return service.CurrentBindings()
}

// ActivateProfile requests one serialized profile transition.
func (r *Runtime) ActivateProfile(ctx context.Context, profileID string) (ActivationResult, error) {
	service := r.ProfileService()
	if service == nil {
		return ActivationResult{}, ErrProfileServiceClosed
	}
	return service.ActivateProfile(ctx, profileID)
}

type runtimeIPCProfileService struct {
	runtime *Runtime
}

type runtimeExecutionHistory struct {
	runtime *Runtime
}

func (history runtimeExecutionHistory) ListSummaries(limit int) ([]execution.Summary, error) {
	worker := history.worker()
	if worker == nil {
		return nil, execution.ErrClosed
	}
	return worker.ListSummaries(limit)
}

func (history runtimeExecutionHistory) Get(id string) (execution.Record, bool) {
	worker := history.worker()
	if worker == nil {
		return execution.Record{}, false
	}
	return worker.Get(id)
}

func (history runtimeExecutionHistory) worker() executionWorker {
	if history.runtime == nil {
		return nil
	}
	history.runtime.mu.Lock()
	defer history.runtime.mu.Unlock()
	return history.runtime.executionWorker
}

func (service runtimeIPCProfileService) ListProfiles() []ipc.ProfileSummary {
	if service.runtime == nil {
		return nil
	}
	service.runtime.mu.Lock()
	profileService := service.runtime.profileService
	defaultID := service.runtime.defaultProfileID
	service.runtime.mu.Unlock()
	if profileService == nil {
		return nil
	}
	profiles := profileService.ListProfiles()
	currentID, _ := profileService.CurrentProfileID()
	summaries := make([]ipc.ProfileSummary, len(profiles))
	for index, current := range profiles {
		summaries[index] = ipc.ProfileSummary{
			ID:        current.ID,
			Label:     current.Label,
			IsDefault: current.ID == defaultID,
			IsCurrent: current.ID == currentID,
		}
	}
	return summaries
}

func (service runtimeIPCProfileService) ActivateProfile(ctx context.Context, profileID string) (ipc.ActivationResult, error) {
	if service.runtime == nil {
		return ipc.ActivationResult{}, ipc.ErrShuttingDown
	}
	profileService := service.runtime.ProfileService()
	if profileService == nil {
		return ipc.ActivationResult{}, ipc.ErrShuttingDown
	}
	concrete, _ := profileService.(*RuntimeProfileService)
	result, err := profileService.ActivateProfile(ctx, profileID)
	if err == nil {
		return ipc.ActivationResult{ProfileID: result.ProfileID, Changed: result.Changed}, nil
	}
	switch {
	case errors.Is(err, ErrUnknownProfile):
		return ipc.ActivationResult{}, fmt.Errorf("%w: %v", ipc.ErrProfileNotFound, err)
	case errors.Is(err, ErrProfileServiceClosed):
		return ipc.ActivationResult{}, fmt.Errorf("%w: %v", ipc.ErrShuttingDown, err)
	case errors.Is(err, ErrProfileStateUncertain):
		return ipc.ActivationResult{}, fmt.Errorf("%w: %v", ipc.ErrDeviceWriteFailed, err)
	case concrete != nil && concrete.Uncertain():
		return ipc.ActivationResult{}, fmt.Errorf("%w: %v", ipc.ErrDeviceWriteFailed, err)
	case errors.Is(err, context.DeadlineExceeded):
		return ipc.ActivationResult{}, fmt.Errorf("%w: %v", ipc.ErrBusy, err)
	case errors.Is(err, context.Canceled):
		return ipc.ActivationResult{}, fmt.Errorf("%w: %v", ipc.ErrShuttingDown, err)
	default:
		return ipc.ActivationResult{}, fmt.Errorf("%w: %v", ipc.ErrActivationFailed, err)
	}
}

func normalizeConfig(config Config) (Config, error) {
	if config.RuntimeDir != "" {
		if config.SocketPath != "" {
			return Config{}, errors.New("runtime directory and socket path are mutually exclusive")
		}
		if _, err := discovery.NewPaths(config.RuntimeDir); err != nil {
			return Config{}, err
		}
		if config.InstanceID != "" {
			canonical, err := discovery.NormalizeInstanceID(config.InstanceID)
			if err != nil {
				return Config{}, err
			}
			config.InstanceID = canonical
		}
	} else {
		if config.SocketPath == "" || config.InstanceID == "" {
			return Config{}, errors.New("socket path and instance ID are required")
		}
		canonical, err := discovery.NormalizeInstanceID(config.InstanceID)
		if err != nil {
			return Config{}, err
		}
		config.InstanceID = canonical
	}
	if config.ConfigPath != "" && !filepath.IsAbs(config.ConfigPath) {
		return Config{}, errors.New("configuration path must be absolute")
	}
	return config, nil
}

// Start performs configuration loading, preflights and binds IPC, then
// selects, opens, and initializes the device. Discovery metadata is published
// by Run after IPC serving has started.
func (r *Runtime) Start() error {
	if r == nil {
		return errors.New("runtime is not initialized")
	}
	return r.start(context.Background())
}

// Run starts the runtime when necessary, serves health/status IPC, and reads
// decoded D200X input until cancellation or a device/output failure.
func (r *Runtime) Run(ctx context.Context) error {
	if r == nil {
		return errors.New("runtime is not initialized")
	}
	if ctx == nil {
		ctx = context.Background()
	}
	if err := r.start(ctx); err != nil {
		if ctx.Err() != nil || errors.Is(err, context.Canceled) {
			return r.Close()
		}
		return errors.Join(err, r.Close())
	}

	serveContext, cancelServe := context.WithCancel(ctx)
	defer cancelServe()
	r.mu.Lock()
	server := r.server
	generation := r.generation
	terminalErr := r.terminalErr
	if terminalErr == nil {
		r.terminalCancel = cancelServe
	}
	r.mu.Unlock()
	if terminalErr != nil {
		return errors.Join(terminalErr, r.Close())
	}
	if server == nil {
		return errors.Join(errors.New("runtime IPC server is unavailable"), r.Close())
	}
	serveDone := make(chan error, 1)
	go func() {
		serveDone <- server.Serve(serveContext)
	}()
	readyErr, serveDoneConsumed := waitForServing(ctx, server, serveDone)
	if readyErr != nil {
		cancelServe()
		var serveErr error
		if !serveDoneConsumed {
			serveErr = <-serveDone
		}
		closeErr := r.Close()
		return joinRuntimeFailures(readyErr, serveErr, r.terminalError(), closeErr)
	}
	if terminalErr := r.terminalError(); terminalErr != nil {
		cancelServe()
		serveErr := <-serveDone
		closeErr := r.Close()
		return joinRuntimeFailures(terminalErr, serveErr, closeErr)
	}
	if generation != nil {
		if err := generation.PublishMetadata(); err != nil {
			cancelServe()
			serveErr := <-serveDone
			closeErr := r.Close()
			return joinRuntimeFailures(err, serveErr, r.terminalError(), closeErr)
		}
		if terminalErr := r.terminalError(); terminalErr != nil {
			metadataErr := withdrawRuntimeMetadata(generation)
			cancelServe()
			serveErr := <-serveDone
			closeErr := r.Close()
			return joinRuntimeFailures(terminalErr, metadataErr, serveErr, closeErr)
		}
	}
	inputObservations := make(chan inputObservation)
	inputDone := make(chan error, 1)
	go func() {
		inputDone <- r.readInputObservations(serveContext, inputObservations)
	}()
	policyDone := make(chan error, 1)
	r.mu.Lock()
	policySession := r.session
	policyPlan := r.plan
	startupCompleted := r.startupCompleted
	policyActionService := r.profileService
	policyExecutionWorker := r.executionWorker
	r.mu.Unlock()
	go func() {
		policyDone <- runIdlePolicyWithExecutor(serveContext, r.clock, policySession, policyPlan, startupCompleted, inputObservations, r.stdout, policyActionService, policyExecutionWorker)
	}()
	executionFaults := policyExecutionWorker.Faults()

	select {
	case <-ctx.Done():
		metadataErr := withdrawRuntimeMetadata(generation)
		cancelServe()
		<-policyDone
		<-serveDone
		closeErr := r.Close()
		<-inputDone
		return joinRuntimeFailures(metadataErr, r.terminalError(), closeErr)
	case err := <-inputDone:
		metadataErr := withdrawRuntimeMetadata(generation)
		cancelServe()
		policyErr := <-policyDone
		serveErr := <-serveDone
		closeErr := r.Close()
		return joinRuntimeFailures(err, policyErr, serveErr, metadataErr, r.terminalError(), closeErr)
	case err := <-policyDone:
		metadataErr := withdrawRuntimeMetadata(generation)
		cancelServe()
		serveErr := <-serveDone
		closeErr := r.Close()
		inputErr := <-inputDone
		return joinRuntimeFailures(err, inputErr, serveErr, metadataErr, r.terminalError(), closeErr)
	case err := <-serveDone:
		metadataErr := withdrawRuntimeMetadata(generation)
		cancelServe()
		policyErr := <-policyDone
		closeErr := r.Close()
		inputErr := <-inputDone
		return joinRuntimeFailures(err, policyErr, inputErr, metadataErr, r.terminalError(), closeErr)
	case <-executionFaults:
		r.signalExecutionFault()
		metadataErr := withdrawRuntimeMetadata(generation)
		cancelServe()
		policyErr := <-policyDone
		serveErr := <-serveDone
		closeErr := r.Close()
		inputErr := <-inputDone
		return joinRuntimeFailures(errExecutionSupervisionFailed, policyErr, inputErr, serveErr, metadataErr, r.terminalError(), closeErr)
	}
}

func withdrawRuntimeMetadata(generation *discovery.Generation) error {
	if generation == nil {
		return nil
	}
	return generation.WithdrawMetadata()
}

func (r *Runtime) terminalError() error {
	if r == nil {
		return nil
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.terminalErr
}

func (r *Runtime) signalTerminal(err error) {
	r.signalTerminalFailure(ErrProfileStateUncertain, err)
}

func (r *Runtime) signalExecutionFault() {
	r.signalTerminalFailure(errExecutionSupervisionFailed, errExecutionSupervisionFailed)
}

func (r *Runtime) signalTerminalFailure(terminalErr, callbackErr error) {
	if r == nil {
		return
	}
	r.terminalOnce.Do(func() {
		if terminalErr == nil {
			terminalErr = ErrProfileStateUncertain
		}
		if callbackErr == nil {
			callbackErr = terminalErr
		}
		r.mu.Lock()
		r.terminalErr = terminalErr
		generation := r.generation
		cancel := r.terminalCancel
		callback := r.config.Terminal
		r.mu.Unlock()
		// Readiness is withdrawn before cancellation so a caller cannot observe
		// a healthy generation after the uncertain write has been reported.
		_ = withdrawRuntimeMetadata(generation)
		if cancel != nil {
			cancel()
		}
		if callback != nil {
			callback(callbackErr)
		}
	})
}

type servingReadiness interface {
	ServingReady() <-chan struct{}
}

func waitForServing(ctx context.Context, server servingReadiness, done <-chan error) (error, bool) {
	select {
	case <-server.ServingReady():
		return nil, false
	case err := <-done:
		if err == nil {
			return errors.New("IPC server stopped before serving"), true
		}
		return err, true
	case <-ctx.Done():
		return ctx.Err(), false
	}
}

// Close cancels active reads, closes the D200X transport, and then closes the
// IPC endpoint. It is safe to call more than once.
func (r *Runtime) Close() error {
	if r == nil {
		return nil
	}
	r.startMu.Lock()
	defer r.startMu.Unlock()
	return r.closeLocked()
}

func (r *Runtime) closeLocked() error {
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return nil
	}
	r.closed = true
	session := r.session
	r.session = nil
	profileService := r.profileService
	r.profileService = nil
	executionWorker := r.executionWorker
	r.executionWorker = nil
	r.terminalCancel = nil
	server := r.server
	generation := r.generation
	r.mu.Unlock()

	var failures []error
	if generation != nil {
		if err := generation.WithdrawMetadata(); err != nil {
			failures = append(failures, sanitizeFailure("withdraw runtime metadata", err))
		}
	}
	if executionWorker != nil {
		if err := executionWorker.Close(); err != nil {
			if errors.Is(err, execution.ErrReapUnconfirmed) {
				r.signalExecutionFault()
				failures = append(failures, errExecutionSupervisionFailed)
			} else {
				failures = append(failures, sanitizeFailure("close execution worker", err))
			}
		}
	}
	if profileService != nil {
		if err := profileService.Close(); err != nil {
			failures = append(failures, sanitizeFailure("close profile service", err))
		}
	}
	if session != nil {
		if err := session.Close(); err != nil {
			failures = append(failures, sanitizeFailure("close D200X device", err))
		}
	}
	if server != nil {
		if err := server.Close(); err != nil {
			failures = append(failures, sanitizeFailure("close IPC server", err))
		}
	}
	if generation != nil {
		if err := generation.Close(); err != nil {
			failures = append(failures, sanitizeFailure("close runtime discovery", err))
		}
	}
	return errors.Join(failures...)
}

func (r *Runtime) start(ctx context.Context) error {
	if ctx == nil {
		ctx = context.Background()
	}
	r.startMu.Lock()
	defer r.startMu.Unlock()

	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return errors.New("runtime is closed")
	}
	if r.terminalErr != nil {
		err := r.terminalErr
		r.mu.Unlock()
		return err
	}
	if r.started {
		r.mu.Unlock()
		return nil
	}
	r.mu.Unlock()

	plan, catalog, defaultProfile, err := buildStartupPlan(r.config.ConfigPath)
	if err != nil {
		return r.startFailure(err)
	}
	if err := ctx.Err(); err != nil {
		return r.startFailure(err)
	}
	executionWorker, err := r.executionFactory()
	if err != nil {
		return r.startFailure(sanitizeFailure("initialize execution worker", err))
	}
	if executionWorker == nil {
		return r.startFailure(errors.New("initialize execution worker failed"))
	}
	r.mu.Lock()
	r.executionWorker = executionWorker
	r.mu.Unlock()

	if err := r.prepareIPC(); err != nil {
		return r.startFailure(err)
	}
	if err := ctx.Err(); err != nil {
		return r.startFailure(err)
	}
	candidates, err := r.factory.Enumerate(ctx)
	if err != nil {
		return r.startFailure(sanitizeFailure("enumerate D200X device", err))
	}
	candidate, err := d200x.SelectSingle(candidates)
	if err != nil {
		return r.startFailure(sanitizeFailure("select D200X device", err))
	}
	session := d200x.NewSession(r.factory, d200x.SessionOptions{
		Verbose: r.config.Verbose,
		Writer:  r.stderr,
	})
	r.mu.Lock()
	r.session = session
	r.mu.Unlock()
	if err := session.Open(ctx, candidate); err != nil {
		return r.startFailure(sanitizeFailure("open D200X device", err))
	}
	if err := session.SendPage(ctx, plan.page, plan.brightness); err != nil {
		return r.startFailure(sanitizeFailure("initialize D200X device", err))
	}
	profileService, err := NewProfileService(ProfileServiceOptions{
		Catalog:          catalog,
		Sender:           session,
		InitialProfileID: defaultProfile.ID,
		Terminal:         r.signalTerminal,
		Verbose:          r.config.Verbose,
		Logger:           r.stderr,
	})
	if err != nil {
		return r.startFailure(err)
	}
	r.mu.Lock()
	r.profileService = profileService
	r.defaultProfileID = defaultProfile.ID
	r.mu.Unlock()
	plan.positionsFn = profileService.CurrentEventPositions
	startupCompleted := r.clock.Now()
	if err := ctx.Err(); err != nil {
		return r.startFailure(err)
	}

	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return errors.New("runtime is closed")
	}
	r.plan = plan
	r.startupCompleted = startupCompleted
	r.started = true
	r.mu.Unlock()
	return nil
}

func (r *Runtime) prepareIPC() error {
	r.mu.Lock()
	config := r.config
	server := r.server
	r.mu.Unlock()

	var generation *discovery.Generation
	if config.RuntimeDir != "" {
		opened, err := discovery.Open(discovery.Options{
			RuntimeDir: config.RuntimeDir,
			InstanceID: config.InstanceID,
		})
		if err != nil {
			return fmt.Errorf("open runtime discovery: %w", err)
		}
		generation = opened
		r.mu.Lock()
		r.generation = generation
		r.mu.Unlock()
		config.SocketPath = generation.SocketPath()
		config.InstanceID = generation.InstanceID()
		if server == nil {
			server, err = ipc.NewServer(ipc.ServerConfig{
				SocketPath:       config.SocketPath,
				InstanceID:       config.InstanceID,
				Deadlines:        config.Deadlines,
				ProfileService:   runtimeIPCProfileService{runtime: r},
				ExecutionHistory: runtimeExecutionHistory{runtime: r},
			})
			if err != nil {
				return err
			}
		}
		r.mu.Lock()
		r.generation = generation
		r.config = config
		r.server = server
		r.mu.Unlock()
	} else if server == nil {
		return errors.New("runtime IPC server is unavailable")
	}

	if err := server.Start(); err != nil {
		return sanitizeFailure("start IPC server", err)
	}
	if generation != nil {
		if _, err := generation.RecordSocket(); err != nil {
			return fmt.Errorf("record runtime socket: %w", err)
		}
	}
	return nil
}

func (r *Runtime) startFailure(err error) error {
	return errors.Join(err, r.closeLocked())
}

func buildDevicePlan(path string) (devicePlan, error) {
	configuration, err := loadConfiguration(path)
	if err != nil {
		return devicePlan{}, err
	}
	catalog, err := configuration.ProfileCatalog()
	if err != nil {
		return devicePlan{}, errors.New("invalid configuration")
	}
	defaultProfile, ok := catalog.Default()
	if !ok {
		return devicePlan{}, errors.New("invalid configuration")
	}
	return buildDevicePlanForProfile(configuration, defaultProfile)
}

func buildStartupPlan(path string) (devicePlan, profile.Catalog, profile.Profile, error) {
	configuration, err := loadConfiguration(path)
	if err != nil {
		return devicePlan{}, profile.Catalog{}, profile.Profile{}, err
	}
	catalog, err := configuration.ProfileCatalog()
	if err != nil {
		return devicePlan{}, profile.Catalog{}, profile.Profile{}, errors.New("invalid configuration")
	}
	defaultProfile, ok := catalog.Default()
	if !ok {
		return devicePlan{}, profile.Catalog{}, profile.Profile{}, errors.New("invalid configuration")
	}
	plan, err := buildDevicePlanForProfile(configuration, defaultProfile)
	if err != nil {
		return devicePlan{}, profile.Catalog{}, profile.Profile{}, err
	}
	return plan, catalog, defaultProfile, nil
}

func buildDevicePlanForProfile(configuration appconfig.Config, current profile.Profile) (devicePlan, error) {
	page, err := pageForProfile(current)
	if err != nil {
		return devicePlan{}, errors.New("invalid configuration")
	}
	return devicePlan{
		page:        page,
		brightness:  configuration.Brightness,
		idleTimeout: time.Duration(configuration.IdleTimeoutSeconds) * time.Second,
		positions:   eventPositionsForProfile(current),
	}, nil
}

func loadConfiguration(path string) (appconfig.Config, error) {
	if path == "" {
		return appconfig.Config{}, errors.New("configuration path is required")
	}
	if !filepath.IsAbs(path) {
		return appconfig.Config{}, errors.New("configuration path must be absolute")
	}
	configuration, err := appconfig.Load(path)
	if err != nil {
		// config.Load includes its source path in filesystem errors. Do not
		// return that error because paths can contain credentials or secrets.
		if appconfig.IsValidationError(err) {
			return appconfig.Config{}, errors.New("invalid configuration")
		}
		return appconfig.Config{}, errors.New("configuration could not be loaded")
	}
	return configuration, nil
}

func (r *Runtime) readInputs(ctx context.Context) error {
	r.mu.Lock()
	session := r.session
	plan := r.plan
	r.mu.Unlock()
	if session == nil {
		return errors.New("runtime has no active D200X device")
	}
	for {
		event, ok, err := session.ReadInput(ctx)
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, context.Canceled) {
				return nil
			}
			if isRecoverableInputError(err) {
				continue
			}
			return sanitizeFailure("read D200X input", err)
		}
		if !ok {
			continue
		}
		if err := writeInputEvent(r.stdout, plan, event); err != nil {
			_ = session.Close()
			return err
		}
	}
}

func isRecoverableInputError(err error) bool {
	var protocolErr *d200x.ProtocolError
	if !errors.As(err, &protocolErr) {
		return false
	}
	switch protocolErr.Kind {
	case d200x.ErrorInvalidReportLength,
		d200x.ErrorUnsupportedReportID,
		d200x.ErrorInvalidFrameMagic,
		d200x.ErrorPayloadTooLarge,
		d200x.ErrorTruncatedPayload,
		d200x.ErrorUnexpectedContinuation,
		d200x.ErrorMalformedInputPayload:
		return true
	default:
		return false
	}
}

type inputEventLine struct {
	Event      string `json:"event"`
	WireIndex  byte   `json:"wire_index"`
	ID         string `json:"id,omitempty"`
	Position   string `json:"position,omitempty"`
	Marker     string `json:"marker"`
	MarkerCode byte   `json:"marker_code"`
	Action     string `json:"action"`
	ActionCode byte   `json:"action_code"`
}

func writeInputEvent(writer io.Writer, plan devicePlan, event d200x.InputEvent) error {
	line := inputEventLine{
		Event:      "input",
		WireIndex:  event.WireIndex,
		Marker:     markerName(event.Marker),
		MarkerCode: byte(event.Marker),
		Action:     actionName(event.Action),
		ActionCode: byte(event.Action),
	}
	if position, ok := plan.eventPositions()[event.WireIndex]; ok {
		line.ID = position.id
		line.Position = position.position
	}
	encoded, err := json.Marshal(line)
	if err != nil {
		return errors.New("encode input event failed")
	}
	if len(encoded)+1 > maximumEventLineBytes {
		return errors.New("input event exceeds output limit")
	}
	encoded = append(encoded, '\n')
	if err := writeAll(writer, encoded); err != nil {
		return errors.New("write input event failed")
	}
	return nil
}

func (plan devicePlan) eventPositions() map[byte]eventPosition {
	if plan.positionsFn != nil {
		return plan.positionsFn()
	}
	return plan.positions
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
		return "rotated_left"
	case d200x.InputActionRotatedRight:
		return "rotated_right"
	default:
		return "unknown"
	}
}

func writeAll(writer io.Writer, data []byte) error {
	for len(data) > 0 {
		written, err := writer.Write(data)
		if err != nil {
			return err
		}
		if written <= 0 || written > len(data) {
			return io.ErrShortWrite
		}
		data = data[written:]
	}
	return nil
}

func sanitizeFailure(operation string, err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, context.Canceled) {
		return fmt.Errorf("%s: %w", operation, context.Canceled)
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return fmt.Errorf("%s: %w", operation, context.DeadlineExceeded)
	}
	var protocolErr *d200x.ProtocolError
	if errors.As(err, &protocolErr) {
		return fmt.Errorf("%s: %w", operation, protocolErr)
	}
	return errors.New(operation + " failed")
}

func joinRuntimeFailures(failures ...error) error {
	var nonNil []error
	for _, failure := range failures {
		if failure == nil || errors.Is(failure, context.Canceled) {
			continue
		}
		if errors.Is(failure, ErrProfileStateUncertain) {
			nonNil = append(nonNil, ErrProfileStateUncertain)
			continue
		}
		if errors.Is(failure, errExecutionSupervisionFailed) {
			nonNil = append(nonNil, errExecutionSupervisionFailed)
			continue
		}
		nonNil = append(nonNil, sanitizeFailure("runtime operation", failure))
	}
	return errors.Join(nonNil...)
}
