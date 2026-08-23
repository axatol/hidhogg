package ipc

import (
	"context"
	"errors"
	"fmt"
	"net"
	"sync"
	"time"
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

type ServerConfig struct {
	SocketPath     string
	InstanceID     string
	Deadlines      Deadlines
	MaxConnections int
	Handler        Handler
	PeerVerifier   func(net.Conn) error
}

type Server struct {
	config      ServerConfig
	endpoint    *endpoint
	slots       chan struct{}
	connections sync.WaitGroup

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
	return &Server{config: config, slots: make(chan struct{}, config.MaxConnections), closeDone: make(chan struct{}), peerVerifier: peerVerifier}, nil
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
