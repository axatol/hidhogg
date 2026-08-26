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

	appconfig "hidhogg/internal/config"
	"hidhogg/internal/d200x"
	"hidhogg/internal/ipc"
)

const maximumEventLineBytes = 4 * 1024

// Config contains the process-owned runtime dependencies. ConfigPath is
// intentionally explicit: the runtime never discovers or watches a config
// file. TransportFactory, Stdout, and Stderr are injectable for deterministic
// tests; nil values select the production HID factory and process streams.
type Config struct {
	SocketPath       string
	InstanceID       string
	Deadlines        ipc.Deadlines
	ConfigPath       string
	Verbose          bool
	TransportFactory d200x.TransportFactory
	Stdout           io.Writer
	Stderr           io.Writer
}

// Runtime owns one configured D200X session and the existing health/status
// IPC server. A session is opened and initialized before the IPC endpoint is
// bound, so an endpoint never advertises readiness for a failed device.
type Runtime struct {
	server  *ipc.Server
	config  Config
	factory d200x.TransportFactory
	stdout  io.Writer
	stderr  io.Writer

	startMu sync.Mutex
	mu      sync.Mutex
	started bool
	closed  bool
	session *d200x.Session
	plan    devicePlan
}

type devicePlan struct {
	page       d200x.Page
	brightness int
	positions  map[byte]eventPosition
}

type eventPosition struct {
	id       string
	position string
}

// New constructs an injectable runtime. It does not enumerate or open HID;
// all device activity begins in Start or Run after configuration validation.
func New(config Config) (*Runtime, error) {
	server, err := ipc.NewServer(ipc.ServerConfig{
		SocketPath: config.SocketPath,
		InstanceID: config.InstanceID,
		Deadlines:  config.Deadlines,
	})
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
	return &Runtime{
		server:  server,
		config:  config,
		factory: factory,
		stdout:  stdout,
		stderr:  stderr,
	}, nil
}

// Start performs configuration loading, device selection, opening, and the
// initial page sequence before binding the IPC endpoint.
func (r *Runtime) Start() error {
	if r == nil || r.server == nil {
		return errors.New("runtime is not initialized")
	}
	return r.start(context.Background())
}

// Run starts the runtime when necessary, serves health/status IPC, and reads
// decoded D200X input until cancellation or a device/output failure.
func (r *Runtime) Run(ctx context.Context) error {
	if r == nil || r.server == nil {
		return errors.New("runtime is not initialized")
	}
	if ctx == nil {
		ctx = context.Background()
	}
	if err := r.start(ctx); err != nil {
		if ctx.Err() != nil || errors.Is(err, context.Canceled) {
			_ = r.Close()
			return nil
		}
		_ = r.Close()
		return err
	}

	serveContext, cancelServe := context.WithCancel(ctx)
	defer cancelServe()
	serveDone := make(chan error, 1)
	go func() {
		serveDone <- r.server.Serve(serveContext)
	}()
	inputDone := make(chan error, 1)
	go func() {
		inputDone <- r.readInputs(serveContext)
	}()

	select {
	case <-ctx.Done():
		_ = r.Close()
		<-inputDone
		<-serveDone
		return nil
	case err := <-inputDone:
		cancelServe()
		closeErr := r.Close()
		serveErr := <-serveDone
		return joinRuntimeFailures(err, serveErr, closeErr)
	case err := <-serveDone:
		cancelServe()
		closeErr := r.Close()
		<-inputDone
		return joinRuntimeFailures(err, closeErr)
	}
}

// Close cancels active reads, closes the D200X transport, and then closes the
// IPC endpoint. It is safe to call more than once.
func (r *Runtime) Close() error {
	if r == nil || r.server == nil {
		return nil
	}
	r.startMu.Lock()
	defer r.startMu.Unlock()

	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return nil
	}
	r.closed = true
	session := r.session
	r.session = nil
	r.mu.Unlock()

	var failures []error
	if session != nil {
		if err := session.Close(); err != nil {
			failures = append(failures, sanitizeFailure("close D200X device", err))
		}
	}
	if err := r.server.Close(); err != nil {
		failures = append(failures, sanitizeFailure("close IPC server", err))
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
	if r.started {
		r.mu.Unlock()
		return nil
	}
	r.mu.Unlock()

	plan, err := buildDevicePlan(r.config.ConfigPath)
	if err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	candidates, err := r.factory.Enumerate(ctx)
	if err != nil {
		return sanitizeFailure("enumerate D200X device", err)
	}
	candidate, err := d200x.SelectSingle(candidates)
	if err != nil {
		return sanitizeFailure("select D200X device", err)
	}
	session := d200x.NewSession(r.factory, d200x.SessionOptions{
		Verbose: r.config.Verbose,
		Writer:  r.stderr,
	})
	if err := session.Open(ctx, candidate); err != nil {
		_ = session.Close()
		return sanitizeFailure("open D200X device", err)
	}
	if err := session.SendPage(ctx, plan.page, plan.brightness); err != nil {
		_ = session.Close()
		return sanitizeFailure("initialize D200X device", err)
	}
	if err := ctx.Err(); err != nil {
		_ = session.Close()
		return err
	}
	if err := r.server.Start(); err != nil {
		_ = session.Close()
		return sanitizeFailure("start IPC server", err)
	}

	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		_ = session.Close()
		_ = r.server.Close()
		return errors.New("runtime is closed")
	}
	r.plan = plan
	r.session = session
	r.started = true
	r.mu.Unlock()
	return nil
}

func buildDevicePlan(path string) (devicePlan, error) {
	configuration, err := loadConfiguration(path)
	if err != nil {
		return devicePlan{}, err
	}
	pageConfiguration := configuration.Pages[0]
	positions := make([]d200x.Position, 0, len(pageConfiguration.Positions))
	byWire := make(map[byte]eventPosition, len(pageConfiguration.Positions))
	for _, source := range pageConfiguration.Positions {
		spec, ok := d200x.LookupPosition(source.Position)
		if !ok {
			return devicePlan{}, errors.New("invalid configuration")
		}
		positions = append(positions, d200x.Position{
			ID:         source.ID,
			Position:   source.Position,
			Label:      source.Label,
			Background: source.Background,
		})
		byWire[spec.WireIndex] = eventPosition{id: source.ID, position: source.Position}
	}
	page := d200x.NewPage(positions)
	if err := d200x.ValidatePage(page); err != nil {
		return devicePlan{}, errors.New("invalid configuration")
	}
	return devicePlan{
		page:       page,
		brightness: configuration.Brightness,
		positions:  byWire,
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
	if position, ok := plan.positions[event.WireIndex]; ok {
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
		nonNil = append(nonNil, sanitizeFailure("runtime operation", failure))
	}
	return errors.Join(nonNil...)
}
