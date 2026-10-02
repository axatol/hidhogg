package ipc

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"time"

	"hidhogg/internal/execution"
	"hidhogg/internal/notification"
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

type DisplayHostStateService interface {
	SetDisplayHostState(context.Context, bool) (DisplayHostStateResult, error)
}

// ConfigEditorService exposes only bounded editor views and typed profile edits.
// Implementations own source access, concurrency checks, validation, commit,
// and reload coordination.
type ConfigEditorService interface {
	Snapshot(context.Context) (ConfigEditorSnapshot, error)
	ListPositions(context.Context, string, string) (ConfigEditorPositions, error)
	GetProfile(context.Context, string, string) (ConfigEditorProfile, error)
	GetPositionLabel(context.Context, string, string, string) (ConfigEditorPositionLabel, error)
	SetProfileLabel(context.Context, string, string, string) (ConfigEditorLabelResult, error)
	SetPositionLabel(context.Context, string, string, string, string) (ConfigEditorPositionLabelResult, error)
	CreateProfile(ctx context.Context, expectedDigest, sourceID, newID, label string) (ConfigEditorMutationResult, error)
	DeleteProfile(ctx context.Context, expectedDigest, targetID string) (ConfigEditorMutationResult, error)
}

// ConfigurationService is an explicit descriptive alias.
type ConfigurationService = ConfigService

// NotificationService is the narrow runtime boundary used by notification
// emission and clearing. The service owns validation, admission, storage, and
// device lifecycle; IPC only projects the bounded wire result.
type NotificationService interface {
	EmitNotification(context.Context, notification.EmitRequest) (notification.EmitResult, error)
	ClearNotification(context.Context, string) (notification.ClearResult, error)
}

type ServerConfig struct {
	SocketPath          string
	InstanceID          string
	Deadlines           Deadlines
	MaxConnections      int
	Handler             Handler
	ProfileService      ProfileService
	ExecutionHistory    ExecutionHistory
	ConfigService       ConfigService
	ConfigEditorService ConfigEditorService
	DisplayHostState    DisplayHostStateService
	InputService        InputService
	NotificationService NotificationService
	PeerVerifier        func(net.Conn) error
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
	var disconnectWatcherDone chan struct{}
	defer func() {
		_ = connection.Close()
		if disconnectWatcherDone != nil {
			<-disconnectWatcherDone
		}
		<-s.slots
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

	requestContext := context.Background()
	if isConfigEditorMutationMethod(request.Method) {
		if err := connection.SetReadDeadline(time.Time{}); err != nil {
			return
		}
		mutationContext, cancel := context.WithCancel(requestContext)
		requestContext = mutationContext
		defer cancel()
		disconnectWatcherDone = make(chan struct{})
		go func() {
			defer close(disconnectWatcherDone)
			watchConfigEditorMutationDisconnect(connection, cancel)
		}()
	}

	response := s.handleRequestWithContext(requestContext, request)
	s.writeResponse(connection, response)
}

func (s *Server) handleRequest(request Request) (response Response) {
	return s.handleRequestWithContext(context.Background(), request)
}

func (s *Server) handleRequestWithContext(ctx context.Context, request Request) (response Response) {
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
	if isConfigEditorMethod(request.Method) {
		editorContext := context.Background()
		if isConfigEditorMutationMethod(request.Method) {
			editorContext = ctx
		}
		return s.handleConfigEditorRequest(editorContext, request)
	}
	if request.Method == MethodDisplayHostStateSet {
		return s.handleDisplayHostStateRequest(ctx, request)
	}
	if request.Method == MethodInputStatus || request.Method == MethodInputRequestPermission || request.Method == MethodDoctor {
		return s.handleInputRequest(request)
	}
	if request.Method == MethodNotificationsEmit || request.Method == MethodNotificationsClear {
		return s.handleNotificationRequest(request)
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

func (s *Server) handleDisplayHostStateRequest(ctx context.Context, request Request) Response {
	if s.config.DisplayHostState == nil {
		return internalResponse(request.RequestID)
	}
	result, err := s.config.DisplayHostState.SetDisplayHostState(ctx, request.DisplayAwake)
	if err != nil {
		return internalResponse(request.RequestID)
	}
	if result.InstanceID != request.InstanceID || result.DisplayAwake != request.DisplayAwake {
		return internalResponse(request.RequestID)
	}
	responseResult := Result{
		InstanceID:       result.InstanceID,
		DisplayAwake:     result.DisplayAwake,
		Changed:          result.Changed,
		displayHostState: true,
	}
	if err := validateResultForMethod(responseResult, request.Method, request.InstanceID); err != nil {
		return internalResponse(request.RequestID)
	}
	requestID := request.RequestID
	return Response{ProtocolVersion: ProtocolVersion, RequestID: &requestID, Result: &responseResult}
}

func (s *Server) handleNotificationRequest(request Request) Response {
	if s.config.NotificationService == nil {
		return internalResponse(request.RequestID)
	}
	requestID := request.RequestID
	switch request.Method {
	case MethodNotificationsEmit:
		result, err := s.config.NotificationService.EmitNotification(context.Background(), notification.EmitRequest{
			Source:     request.Source,
			Text:       request.Text,
			TTLSeconds: cloneOptionalInt(request.TTLSeconds),
		})
		if err != nil {
			return notificationErrorResponse(request.RequestID, err)
		}
		responseResult := Result{
			InstanceID:         request.InstanceID,
			NotificationID:     result.NotificationID,
			MatchedCount:       result.MatchedCount,
			notificationMethod: MethodNotificationsEmit,
		}
		if err := validateResultForMethod(responseResult, request.Method, request.InstanceID); err != nil {
			return internalResponse(request.RequestID)
		}
		return Response{ProtocolVersion: ProtocolVersion, RequestID: &requestID, Result: &responseResult}
	case MethodNotificationsClear:
		result, err := s.config.NotificationService.ClearNotification(context.Background(), request.NotificationID)
		if err != nil {
			return notificationErrorResponse(request.RequestID, err)
		}
		responseResult := Result{
			InstanceID:         request.InstanceID,
			ClearedCount:       result.ClearedCount,
			notificationMethod: MethodNotificationsClear,
		}
		if err := validateResultForMethod(responseResult, request.Method, request.InstanceID); err != nil {
			return internalResponse(request.RequestID)
		}
		return Response{ProtocolVersion: ProtocolVersion, RequestID: &requestID, Result: &responseResult}
	default:
		return internalResponse(request.RequestID)
	}
}

func cloneOptionalInt(value *int) *int {
	if value == nil {
		return nil
	}
	clone := *value
	return &clone
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
			Diagnostic: result.Diagnostic,
		}}
		if err := validateResultForMethod(*response.Result, request.Method, request.InstanceID); err != nil {
			return internalResponse(request.RequestID)
		}
		return response
	default:
		return internalResponse(request.RequestID)
	}
}

func (s *Server) handleConfigEditorRequest(ctx context.Context, request Request) Response {
	if s.config.ConfigEditorService == nil {
		return internalResponse(request.RequestID)
	}
	requestID := request.RequestID
	service := s.config.ConfigEditorService
	var result Result
	switch request.Method {
	case MethodConfigEditorSnapshot:
		snapshot, err := service.Snapshot(ctx)
		if err != nil {
			return configEditorErrorResponse(requestID, err)
		}
		result = Result{InstanceID: request.InstanceID, EditorSnapshot: &snapshot}
	case MethodConfigEditorPositionsList:
		positions, err := service.ListPositions(ctx, request.SourceDigest, request.ProfileID)
		if err != nil {
			return configEditorErrorResponse(requestID, err)
		}
		if positions.SourceDigest != request.SourceDigest || positions.ProfileID != request.ProfileID {
			return internalResponse(requestID)
		}
		result = Result{InstanceID: request.InstanceID, EditorPositions: &positions}
	case MethodConfigEditorProfileGet:
		profile, err := service.GetProfile(ctx, request.SourceDigest, request.ProfileID)
		if err != nil {
			return configEditorErrorResponse(requestID, err)
		}
		if profile.SourceDigest != request.SourceDigest || profile.ProfileID != request.ProfileID {
			return internalResponse(requestID)
		}
		result = Result{InstanceID: request.InstanceID, EditorProfile: &profile}
	case MethodConfigEditorPositionGet:
		positionLabel, err := service.GetPositionLabel(ctx, request.SourceDigest, request.ProfileID, request.PositionID)
		if err != nil {
			return configEditorErrorResponse(requestID, err)
		}
		if positionLabel.SourceDigest != request.SourceDigest || positionLabel.ProfileID != request.ProfileID || positionLabel.PositionID != request.PositionID {
			return internalResponse(requestID)
		}
		result = Result{InstanceID: request.InstanceID, EditorPositionLabel: &positionLabel}
	case MethodConfigEditorLabelSet:
		labelResult, err := service.SetProfileLabel(ctx, request.ExpectedDigest, request.ProfileID, request.Label)
		if err != nil {
			return configEditorErrorResponse(requestID, err)
		}
		result = Result{InstanceID: request.InstanceID, EditorLabelResult: &labelResult}
	case MethodConfigEditorPositionLabelSet:
		positionLabelResult, err := service.SetPositionLabel(ctx, request.ExpectedDigest, request.ProfileID, request.PositionID, request.Label)
		if err != nil {
			return configEditorErrorResponse(requestID, err)
		}
		result = Result{InstanceID: request.InstanceID, EditorPositionLabelResult: &positionLabelResult}
	case MethodConfigEditorProfileCreate:
		createResult, err := service.CreateProfile(ctx, request.ExpectedDigest, request.SourceProfileID, request.ProfileID, request.Label)
		if err != nil {
			return configEditorErrorResponse(requestID, err)
		}
		result = Result{InstanceID: request.InstanceID, EditorProfileCreateResult: &createResult}
	case MethodConfigEditorProfileDelete:
		deleteResult, err := service.DeleteProfile(ctx, request.ExpectedDigest, request.ProfileID)
		if err != nil {
			return configEditorErrorResponse(requestID, err)
		}
		result = Result{InstanceID: request.InstanceID, EditorProfileDeleteResult: &deleteResult}
	default:
		return internalResponse(requestID)
	}
	if err := validateResultForMethod(result, request.Method, request.InstanceID); err != nil {
		return internalResponse(requestID)
	}
	return Response{ProtocolVersion: ProtocolVersion, RequestID: &requestID, Result: &result}
}

func configEditorErrorResponse(requestID string, err error) Response {
	code, message := classifyConfigEditorError(err)
	id := requestID
	return Response{
		ProtocolVersion: ProtocolVersion,
		RequestID:       &id,
		Error:           &Error{Code: code, Message: message},
	}
}

func classifyConfigEditorError(err error) (string, string) {
	switch {
	case errors.Is(err, ErrStaleSource):
		return ErrorStaleSource, messageStaleSource
	case errors.Is(err, ErrEditInvalid):
		return ErrorEditInvalid, messageEditInvalid
	case errors.Is(err, ErrFileCommitFailed):
		return ErrorFileCommitFailed, messageFileCommitFailed
	case errors.Is(err, ErrBusy), errors.Is(err, context.DeadlineExceeded):
		return ErrorBusy, messageBusy
	case errors.Is(err, ErrShuttingDown), errors.Is(err, context.Canceled):
		return ErrorShuttingDown, messageShuttingDown
	default:
		return ErrorInternal, messageInternal
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

func notificationErrorResponse(requestID string, err error) Response {
	code, message := classifyNotificationError(err)
	id := requestID
	return Response{
		ProtocolVersion: ProtocolVersion,
		RequestID:       &id,
		Error:           &Error{Code: code, Message: message},
	}
}

func classifyNotificationError(err error) (string, string) {
	switch {
	case errors.Is(err, notification.ErrInvalid):
		return ErrorNotificationInvalid, messageNotificationInvalid
	case errors.Is(err, notification.ErrBusy), errors.Is(err, context.DeadlineExceeded):
		return ErrorBusy, messageBusy
	case errors.Is(err, notification.ErrClosed), errors.Is(err, context.Canceled):
		return ErrorShuttingDown, messageShuttingDown
	case errors.Is(err, notification.ErrUncertain):
		return ErrorDeviceWriteFailed, messageDeviceWriteFailed
	case err != nil:
		return ErrorInternal, messageInternal
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

func isConfigEditorMethod(method Method) bool {
	switch method {
	case MethodConfigEditorSnapshot, MethodConfigEditorPositionsList, MethodConfigEditorProfileGet, MethodConfigEditorPositionGet, MethodConfigEditorProfileCreate, MethodConfigEditorProfileDelete, MethodConfigEditorLabelSet, MethodConfigEditorPositionLabelSet:
		return true
	default:
		return false
	}
}

func isConfigEditorMutationMethod(method Method) bool {
	switch method {
	case MethodConfigEditorLabelSet, MethodConfigEditorPositionLabelSet, MethodConfigEditorProfileCreate, MethodConfigEditorProfileDelete:
		return true
	default:
		return false
	}
}

func watchConfigEditorMutationDisconnect(connection *net.UnixConn, cancel context.CancelFunc) {
	// Mutation clients must keep their write side open through the reply; EOF includes CloseWrite.
	_, _ = io.Copy(io.Discard, connection)
	cancel()
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
