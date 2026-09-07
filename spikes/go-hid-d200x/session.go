package d200x

import (
	"context"
	"fmt"
	"sync"
)

// Session owns at most one open matching HID transport. Replacement closes the
// previous handle before opening the next and serializes that swap with writes.
type Session struct {
	factory TransportFactory

	mu           sync.RWMutex
	lifecycleMu  sync.Mutex
	writeMu      sync.Mutex
	transport    Transport
	candidate    Candidate
	closed       bool
	transportErr error
	activeReads  map[*readOperation]struct{}
}

type readOperation struct {
	transport Transport
	context   context.Context
	cancel    context.CancelFunc
	done      chan struct{}
}

func NewSession(factory TransportFactory) *Session {
	return &Session{factory: factory}
}

func (s *Session) Replace(ctx context.Context, candidate Candidate) error {
	if s == nil {
		return &ProtocolError{Kind: ErrorSessionClosed}
	}
	if s.factory == nil {
		return fmt.Errorf("open replacement D200X HID: transport factory is nil")
	}
	if !candidate.IsEligible() {
		return &ProtocolError{Kind: ErrorIneligibleDevice}
	}
	if ctx == nil {
		ctx = context.Background()
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	s.lifecycleMu.Lock()
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		s.lifecycleMu.Unlock()
		return &ProtocolError{Kind: ErrorSessionClosed}
	}
	previous := s.transport
	s.transport = nil
	s.candidate = Candidate{}
	s.transportErr = nil
	s.mu.Unlock()
	reads := s.cancelActiveReadsLocked()
	s.lifecycleMu.Unlock()

	if previous != nil {
		if err := closeAndDrain(previous, reads); err != nil {
			failure := fmt.Errorf("close replaced D200X HID before opening replacement: %w", err)
			s.setTransportFailure(failure)
			return failure
		}
	} else {
		drainReads(reads)
	}

	next, err := s.factory.Open(ctx, candidate)
	if err != nil {
		failure := fmt.Errorf("open replacement D200X HID after closing previous: %w", err)
		s.setTransportFailure(failure)
		return failure
	}

	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		_ = next.Close()
		return &ProtocolError{Kind: ErrorSessionClosed}
	}
	s.transport = next
	s.candidate = candidate
	s.transportErr = nil
	s.mu.Unlock()
	return nil
}

func (s *Session) Current() (Candidate, bool) {
	if s == nil {
		return Candidate{}, false
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.candidate, s.transport != nil && !s.closed
}

func (s *Session) LastError() error {
	if s == nil {
		return &ProtocolError{Kind: ErrorSessionClosed}
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.transportErr
}

func (s *Session) Read(ctx context.Context, report []byte) (int, error) {
	if s == nil {
		return 0, &ProtocolError{Kind: ErrorSessionClosed}
	}
	s.lifecycleMu.Lock()
	transport, err := s.currentTransport()
	if err != nil {
		s.lifecycleMu.Unlock()
		return 0, err
	}
	readContext, cancel := context.WithCancel(normalizeContext(ctx))
	operation := &readOperation{
		transport: transport,
		context:   readContext,
		cancel:    cancel,
		done:      make(chan struct{}),
	}
	if s.activeReads == nil {
		s.activeReads = make(map[*readOperation]struct{})
	}
	s.activeReads[operation] = struct{}{}
	s.lifecycleMu.Unlock()

	defer s.finishRead(operation)
	return operation.transport.Read(operation.context, report)
}

func (s *Session) SendFrame(ctx context.Context, frame Frame) error {
	if s == nil {
		return &ProtocolError{Kind: ErrorSessionClosed}
	}
	if !frame.Command.IsSafeOutbound() {
		return &ProtocolError{Kind: ErrorUnsafeOutboundCommand, Command: frame.Command}
	}
	return s.sendFrame(ctx, frame)
}

func (s *Session) sendFrame(ctx context.Context, frame Frame) error {
	reports, err := EncodeFrame(frame)
	if err != nil {
		return err
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	ctx = normalizeContext(ctx)
	for _, report := range reports {
		if err := s.writeReportLocked(ctx, report); err != nil {
			return err
		}
	}
	return nil
}

func (s *Session) Close() error {
	if s == nil {
		return nil
	}
	s.writeMu.Lock()
	s.lifecycleMu.Lock()
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		s.lifecycleMu.Unlock()
		s.writeMu.Unlock()
		return nil
	}
	s.closed = true
	transport := s.transport
	s.transport = nil
	s.candidate = Candidate{}
	s.transportErr = nil
	s.mu.Unlock()
	reads := s.cancelActiveReadsLocked()
	s.lifecycleMu.Unlock()
	s.writeMu.Unlock()

	if transport == nil {
		drainReads(reads)
		return nil
	}
	return closeAndDrain(transport, reads)
}

func (s *Session) currentTransport() (Transport, error) {
	if s == nil {
		return nil, &ProtocolError{Kind: ErrorSessionClosed}
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.closed || s.transport == nil {
		if s.transportErr != nil {
			return nil, s.transportErr
		}
		if s.closed {
			return nil, &ProtocolError{Kind: ErrorSessionClosed}
		}
		return nil, &ProtocolError{Kind: ErrorNoActiveTransport}
	}
	return s.transport, nil
}

func (s *Session) writeReportLocked(ctx context.Context, report []byte) error {
	transport, err := s.currentTransport()
	if err != nil {
		return err
	}
	n, err := transport.Write(ctx, report)
	if err != nil {
		s.invalidateLocked(transport, err)
		return err
	}
	if n != len(report) {
		failure := &ProtocolError{
			Kind:     ErrorTransportShortWrite,
			Actual:   n,
			Expected: len(report),
		}
		s.invalidateLocked(transport, failure)
		return failure
	}
	return nil
}

func (s *Session) invalidateLocked(transport Transport, err error) {
	s.lifecycleMu.Lock()
	s.mu.Lock()
	if s.transport != transport {
		s.mu.Unlock()
		s.lifecycleMu.Unlock()
		return
	}
	s.transport = nil
	s.candidate = Candidate{}
	s.transportErr = fmt.Errorf("HID transport failed: %w", err)
	s.mu.Unlock()
	reads := s.cancelActiveReadsLocked()
	s.lifecycleMu.Unlock()
	_ = closeAndDrain(transport, reads)
}

func (s *Session) setTransportFailure(err error) {
	s.mu.Lock()
	if !s.closed {
		s.transportErr = err
	}
	s.mu.Unlock()
}

func (s *Session) cancelActiveReadsLocked() []*readOperation {
	if len(s.activeReads) == 0 {
		return nil
	}
	reads := make([]*readOperation, 0, len(s.activeReads))
	for operation := range s.activeReads {
		operation.cancel()
		reads = append(reads, operation)
	}
	return reads
}

func (s *Session) finishRead(operation *readOperation) {
	s.lifecycleMu.Lock()
	if _, ok := s.activeReads[operation]; ok {
		delete(s.activeReads, operation)
		close(operation.done)
	}
	s.lifecycleMu.Unlock()
	operation.cancel()
}

func drainReads(reads []*readOperation) {
	for _, operation := range reads {
		<-operation.done
	}
}

func closeAndDrain(transport Transport, reads []*readOperation) error {
	closeErr := transport.Close()
	drainReads(reads)
	return closeErr
}

func normalizeContext(ctx context.Context) context.Context {
	if ctx == nil {
		return context.Background()
	}
	return ctx
}
