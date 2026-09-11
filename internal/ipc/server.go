package ipc

import (
	"context"
	"errors"
	"fmt"
	"net"
	"sync"
	"time"

	"hidhogg/internal/execution"
)

type Deadlines struct {
	Connect time.Duration
	Read    time.Duration
	Write   time.Duration
}

func DefaultDeadlines() Deadlines {
	return Deadlines{Connect: time.Second, Read: time.Second, Write: time.Second}
}

func (d Deadlines) normalized() Deadlines {
	defaults := DefaultDeadlines()
	if d.Connect <= 0 {
		d.Connect = defaults.Connect
	}
	if d.Read <= 0 {
		d.Read = defaults.Read
	}
	if d.Write <= 0 {
		d.Write = defaults.Write
	}
	return d
}

type Handler interface {
	Handle(context.Context, Request) (Result, error)
}

type HandlerFunc func(context.Context, Request) (Result, error)

func (f HandlerFunc) Handle(ctx context.Context, request Request) (Result, error) {
	return f(ctx, request)
}

// ProfileService is the narrow runtime boundary used by the profile IPC
// methods. Implementations return summaries in configured order and preserve
// profile identifier case.
type ProfileService interface {
	ListProfiles() []ProfileSummary
	ActivateProfile(context.Context, string) (ActivationResult, error)
}

// ExecutionHistory is the read-only history boundary consumed by the IPC
// server. The execution worker owns admission and lifecycle; IPC only queries
// its defensive copies.
type ExecutionHistory interface {
	ListSummaries(int) ([]execution.Summary, error)
	Get(string) (execution.Record, bool)
}

// ConfigService is the narrow runtime boundary used by configuration reload
// and status IPC methods. Reload never receives source content or options;
// Status is read-only.
type ConfigService interface {
	Reload(context.Context) (ConfigReloadResult, error)
	Status() ConfigStatus
}

// ConfigurationService is an explicit descriptive alias.
type ConfigurationService = ConfigService

type ServerConfig struct {
	SocketPath       string
	InstanceID       string
	Deadlines        Deadlines
	MaxConnections   int
	Handler          Handler
	ProfileService   ProfileService
	ExecutionHistory ExecutionHistory
	ConfigService    ConfigService
	PeerVerifier     func(net.Conn) error
}

type Server struct {
	config      ServerConfig
	endpoint    *endpoint
	slots       chan struct{}
	connections sync.WaitGroup
	serving     chan struct{}
	servingOnce sync.Once

	mu           sync.Mutex
	closed       bool
	closeDone    chan struct{}
	peerVerifier func(net.Conn) error
}

func NewServer(config ServerConfig) (*Server, error) {
	if !isCanonicalUUID(config.InstanceID) {
		return nil, errors.New("instance ID must be a canonical UUID")
	}
	if config.SocketPath == "" {
		return nil, errors.New("socket path is required")
	}
	if config.MaxConnections == 0 {
		config.MaxConnections = 8
	}
	if config.MaxConnections < 1 || config.MaxConnections > 8 {
		return nil, errors.New("maximum connections must be between one and eight")
	}
	if config.Handler == nil {
		config.Handler = HandlerFunc(defaultHandler)
	}
	peerVerifier := config.PeerVerifier
	if peerVerifier == nil {
		peerVerifier = verifyPeerUID
	}
	config.Deadlines = config.Deadlines.normalized()
	return &Server{
		config:       config,
		slots:        make(chan struct{}, config.MaxConnections),
		closeDone:    make(chan struct{}),
		serving:      make(chan struct{}),
		peerVerifier: peerVerifier,
	}, nil
}

func defaultHandler(_ context.Context, request Request) (Result, error) {
	result := Result{InstanceID: request.InstanceID, State: ReadyState}
	if request.Method == MethodStatus {
		version := ProtocolVersion
		result.ProtocolVersion = &version
	}
	return result, nil
}

func (s *Server) Start() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return errors.New("IPC server is closed")
	}
	if s.endpoint != nil {
		return errors.New("IPC server is already started")
	}
	endpoint, err := newEndpoint(s.config.SocketPath)
	if err != nil {
		return err
	}
	if err := endpoint.listen(); err != nil {
		return err
	}
	s.endpoint = endpoint
	return nil
}

func (s *Server) Serve(ctx context.Context) error {
	if ctx == nil {
		ctx = context.Background()
	}
	s.mu.Lock()
	started := s.endpoint != nil
	closed := s.closed
	s.mu.Unlock()
	if closed {
		return errors.New("IPC server is closed")
	}
	if !started {
		if err := s.Start(); err != nil {
			return err
		}
	}
	s.mu.Lock()
	listener := s.endpoint.getListener()
	s.mu.Unlock()
	if listener == nil {
		return errors.New("IPC server listener is unavailable")
	}
	s.servingOnce.Do(func() { close(s.serving) })
	stop := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			_ = s.Close()
		case <-stop:
		}
	}()
	err := s.acceptLoop(listener)
	close(stop)
	if errors.Is(err, errServerClosed) || (ctx.Err() != nil && errors.Is(err, net.ErrClosed)) {
		_ = s.Close()
		return nil
	}
	if err != nil && !errors.Is(err, net.ErrClosed) {
		_ = s.Close()
		return err
	}
	_ = s.Close()
	return nil
}

// ServingReady returns a channel that closes once Serve has acquired the
// bound listener and is about to accept connections. Start only binds the
// endpoint; callers that publish readiness metadata should wait for this
// signal after launching Serve.
func (s *Server) ServingReady() <-chan struct{} {
	if s == nil {
		return nil
	}
	return s.serving
}

var errServerClosed = errors.New("IPC server closed")

func (s *Server) acceptLoop(listener *net.UnixListener) error {
	for {
		connection, err := listener.AcceptUnix()
		if err != nil {
			if s.isClosed() || errors.Is(err, net.ErrClosed) {
				return errServerClosed
			}
			return fmt.Errorf("accept Unix connection: %w", err)
		}
		select {
		case s.slots <- struct{}{}:
			s.mu.Lock()
			closed := s.closed
			if !closed {
				s.connections.Add(1)
			}
			s.mu.Unlock()
			if closed {
				<-s.slots
				_ = connection.Close()
				return errServerClosed
			}
			go s.serveConnection(connection)
		default:
			_ = connection.Close()
		}
	}
}

func (s *Server) serveConnection(connection *net.UnixConn) {
	defer s.connections.Done()
	defer func() {
		<-s.slots
		_ = connection.Close()
	}()
	if err := s.peerVerifier(connection); err != nil {
		return
	}
	_ = connection.SetReadDeadline(time.Now().Add(s.config.Deadlines.Read))
	frame, err := readFrame(connection)
	if err != nil {
		if errors.Is(err, errFrameTooLarge) {
			s.writeResponse(connection, newProtocolError(ErrorMessageTooLarge, messageMessageTooLarge).response())
		}
		return
	}
	request, failure, err := ValidateRequest(frame, s.config.InstanceID)
	if err != nil {
		s.writeResponse(connection, newProtocolError(ErrorInternal, messageInternal).response())
		return
	}
	if failure.Error != nil {
		s.writeResponse(connection, failure)
		return
	}

	response := s.handleRequest(request)
	s.writeResponse(connection, response)
}

func (s *Server) handleRequest(request Request) (response Response) {
	defer func() {
		if recover() != nil {
			response = internalResponse(request.RequestID)
		}
	}()
	if isProfileMethod(request.Method) {
		return s.handleProfileRequest(request)
	}
	if isExecutionMethod(request.Method) {
		return s.handleExecutionRequest(request)
	}
	if isConfigMethod(request.Method) {
		return s.handleConfigRequest(request)
	}
	result, err := s.config.Handler.Handle(context.Background(), request)
	if err != nil {
		return internalResponse(request.RequestID)
	}
	response = Response{ProtocolVersion: ProtocolVersion}
	requestID := request.RequestID
	response.RequestID = &requestID
	response.Result = &result
	if err := validateResponseShape(response, request.RequestID, request.InstanceID, true); err != nil || validateResultForMethod(result, request.Method, request.InstanceID) != nil {
		return internalResponse(request.RequestID)
	}
	return response
}

func (s *Server) handleExecutionRequest(request Request) Response {
	requestID := request.RequestID
	if s.config.ExecutionHistory == nil {
		return historyErrorResponse(requestID, ErrHistoryUnavailable)
	}
	switch request.Method {
	case MethodExecutionsList:
		summaries, err := s.config.ExecutionHistory.ListSummaries(request.Limit)
		if err != nil {
			return historyErrorResponse(requestID, err)
		}
		if summaries == nil {
			summaries = make([]execution.Summary, 0)
		}
		result := Result{InstanceID: request.InstanceID, Executions: summaries}
		if err := validateResultForMethod(result, request.Method, request.InstanceID); err != nil {
			return internalResponse(requestID)
		}
		return Response{ProtocolVersion: ProtocolVersion, RequestID: &requestID, Result: &result}
	case MethodExecutionsGet:
		record, ok := s.config.ExecutionHistory.Get(request.ExecutionID)
		if !ok {
			return historyErrorResponse(requestID, ErrExecutionNotFound)
		}
		result := Result{InstanceID: request.InstanceID, Execution: &record}
		if err := validateResultForMethod(result, request.Method, request.InstanceID); err != nil {
			return internalResponse(requestID)
		}
		return Response{ProtocolVersion: ProtocolVersion, RequestID: &requestID, Result: &result}
	default:
		return internalResponse(requestID)
	}
}

func historyErrorResponse(requestID string, err error) Response {
	id := requestID
	code, message := classifyHistoryError(err)
	return Response{ProtocolVersion: ProtocolVersion, RequestID: &id, Error: &Error{Code: code, Message: message}}
}

func classifyHistoryError(err error) (string, string) {
	if errors.Is(err, ErrExecutionNotFound) {
		return ErrorExecutionNotFound, messageExecutionNotFound
	}
	return ErrorHistoryUnavailable, messageHistoryUnavailable
}

func (s *Server) handleProfileRequest(request Request) Response {
	if s.config.ProfileService == nil {
		return internalResponse(request.RequestID)
	}
	requestID := request.RequestID
	switch request.Method {
	case MethodProfilesList:
		summaries := s.config.ProfileService.ListProfiles()
		if summaries == nil {
			summaries = make([]ProfileSummary, 0)
		}
		result := Result{InstanceID: request.InstanceID, Profiles: summaries}
		if err := validateResultForMethod(result, request.Method, request.InstanceID); err != nil {
			return internalResponse(request.RequestID)
		}
		return Response{ProtocolVersion: ProtocolVersion, RequestID: &requestID, Result: &result}
	case MethodProfilesActivate:
		result, err := s.config.ProfileService.ActivateProfile(context.Background(), request.ProfileID)
		if err != nil {
			return profileErrorResponse(request.RequestID, err)
		}
		response := Response{ProtocolVersion: ProtocolVersion, RequestID: &requestID, Result: &Result{ProfileID: result.ProfileID, Changed: result.Changed}}
		if err := validateResultForMethod(*response.Result, request.Method, ""); err != nil {
			return internalResponse(request.RequestID)
		}
		return response
	default:
		return internalResponse(request.RequestID)
	}
}

func (s *Server) handleConfigRequest(request Request) Response {
	if s.config.ConfigService == nil {
		return internalResponse(request.RequestID)
	}
	requestID := request.RequestID
	switch request.Method {
	case MethodConfigReload:
		result, err := s.config.ConfigService.Reload(context.Background())
		if err != nil {
			return configErrorResponse(request.RequestID, err)
		}
		response := Response{ProtocolVersion: ProtocolVersion, RequestID: &requestID, Result: &Result{
			InstanceID:             request.InstanceID,
			Revision:               result.Revision,
			Changed:                result.Changed,
			Effect:                 result.Effect,
			CatalogChanged:         result.CatalogChanged,
			DefaultChanged:         result.DefaultChanged,
			CurrentProfileChanged:  result.CurrentProfileChanged,
			CurrentProfileFallback: result.CurrentProfileFallback,
			ActionChanged:          result.ActionChanged,
			DisplayChanged:         result.DisplayChanged,
			BrightnessChanged:      result.BrightnessChanged,
			IdleChanged:            result.IdleChanged,
			DisplayUpdated:         result.DisplayUpdated,
		}}
		if err := validateResultForMethod(*response.Result, request.Method, request.InstanceID); err != nil {
			return internalResponse(request.RequestID)
		}
		return response
	case MethodConfigStatus:
		result := s.config.ConfigService.Status()
		response := Response{ProtocolVersion: ProtocolVersion, RequestID: &requestID, Result: &Result{
			InstanceID: request.InstanceID,
			Revision:   result.Revision,
			Active:     result.Active,
			State:      result.State,
			Outcome:    result.Outcome,
			Reason:     result.Reason,
		}}
		if err := validateResultForMethod(*response.Result, request.Method, request.InstanceID); err != nil {
			return internalResponse(request.RequestID)
		}
		return response
	default:
		return internalResponse(request.RequestID)
	}
}

func configErrorResponse(requestID string, err error) Response {
	code, message := classifyConfigError(err)
	id := requestID
	return Response{
		ProtocolVersion: ProtocolVersion,
		RequestID:       &id,
		Error:           &Error{Code: code, Message: message},
	}
}

func classifyConfigError(err error) (string, string) {
	switch {
	case errors.Is(err, ErrReloadRejected):
		return ErrorReloadRejected, messageReloadRejected
	case errors.Is(err, ErrBusy), errors.Is(err, context.DeadlineExceeded):
		return ErrorBusy, messageBusy
	case errors.Is(err, ErrShuttingDown), errors.Is(err, context.Canceled):
		return ErrorShuttingDown, messageShuttingDown
	case errors.Is(err, ErrDeviceWriteFailed):
		return ErrorDeviceWriteFailed, messageDeviceWriteFailed
	case err != nil:
		return ErrorReloadRejected, messageReloadRejected
	default:
		return ErrorInternal, messageInternal
	}
}

func profileErrorResponse(requestID string, err error) Response {
	code, message := classifyProfileError(err)
	id := requestID
	return Response{
		ProtocolVersion: ProtocolVersion,
		RequestID:       &id,
		Error:           &Error{Code: code, Message: message},
	}
}

func classifyProfileError(err error) (string, string) {
	switch {
	case errors.Is(err, ErrProfileNotFound):
		return ErrorProfileNotFound, messageProfileNotFound
	case errors.Is(err, ErrDeviceWriteFailed):
		return ErrorDeviceWriteFailed, messageDeviceWriteFailed
	case errors.Is(err, ErrShuttingDown), errors.Is(err, context.Canceled):
		return ErrorShuttingDown, messageShuttingDown
	case errors.Is(err, ErrBusy), errors.Is(err, context.DeadlineExceeded):
		return ErrorBusy, messageBusy
	case err != nil:
		return ErrorActivationFailed, messageActivationFailed
	default:
		return ErrorInternal, messageInternal
	}
}

func isProfileMethod(method Method) bool {
	return method == MethodProfilesList || method == MethodProfilesActivate
}

func isExecutionMethod(method Method) bool {
	return method == MethodExecutionsList || method == MethodExecutionsGet
}

func isConfigMethod(method Method) bool {
	return method == MethodConfigReload || method == MethodConfigStatus
}

func internalResponse(requestID string) Response {
	return Response{
		ProtocolVersion: ProtocolVersion,
		RequestID:       &requestID,
		Error:           &Error{Code: ErrorInternal, Message: messageInternal},
	}
}

func (s *Server) writeResponse(connection *net.UnixConn, response Response) {
	frame, err := EncodeResponse(response)
	if err != nil {
		frame, err = EncodeResponse(Response{
			ProtocolVersion: ProtocolVersion,
			Error:           &Error{Code: ErrorInternal, Message: messageInternal},
		})
		if err != nil {
			return
		}
	}
	_ = connection.SetWriteDeadline(time.Now().Add(s.config.Deadlines.Write))
	_ = writeFrame(connection, frame)
}

func (s *Server) isClosed() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.closed
}

func (s *Server) Close() error {
	s.mu.Lock()
	if s.closed {
		closeDone := s.closeDone
		s.mu.Unlock()
		<-closeDone
		return nil
	}
	s.closed = true
	endpoint := s.endpoint
	s.mu.Unlock()
	var err error
	if endpoint != nil {
		err = endpoint.close()
	}
	s.connections.Wait()
	close(s.closeDone)
	return err
}
