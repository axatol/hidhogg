package d200x

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"sync"
)

// Session owns at most one open matching HID transport. Opening is single-use;
// callers create a new session after close or transport failure.
type Session struct {
	factory     TransportFactory
	diagnostics sessionDiagnostics

	mu           sync.RWMutex
	lifecycleMu  sync.Mutex
	writeMu      sync.Mutex
	diagnosticMu sync.Mutex
	transport    Transport
	candidate    Candidate
	closed       bool
	transportErr error
	activeReads  map[*readOperation]struct{}
}

type sessionDiagnostics struct {
	verbose bool
	options SessionOptions
}

type readOperation struct {
	transport Transport
	context   context.Context
	cancel    context.CancelFunc
	done      chan struct{}
}

func NewSession(factory TransportFactory, options ...SessionOptions) *Session {
	var diagnostics SessionOptions
	if len(options) > 0 {
		diagnostics = options[0]
	}
	return &Session{
		factory: factory,
		diagnostics: sessionDiagnostics{
			verbose: diagnostics.Verbose && diagnostics.Writer != nil,
			options: diagnostics,
		},
	}
}

// Open selects and opens one validated candidate. A session is deliberately
// single-use: reconnecting after close or transport failure requires a new
// Session, which keeps lifecycle ownership explicit and avoids hidden retry.
func (s *Session) Open(ctx context.Context, candidate Candidate) error {
	if s == nil {
		return &ProtocolError{Kind: ErrorSessionClosed}
	}
	if s.factory == nil {
		return fmt.Errorf("open D200X HID: transport factory is nil")
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
	s.mu.RLock()
	if s.closed {
		s.mu.RUnlock()
		s.lifecycleMu.Unlock()
		return &ProtocolError{Kind: ErrorSessionClosed}
	}
	if s.transport != nil {
		s.mu.RUnlock()
		s.lifecycleMu.Unlock()
		return fmt.Errorf("D200X session already has an active transport")
	}
	s.mu.RUnlock()
	s.lifecycleMu.Unlock()

	next, err := s.factory.Open(ctx, candidate)
	if err != nil {
		var hidOpenFailure *HIDOpenPathFailure
		if errors.As(err, &hidOpenFailure) {
			s.logHIDOpenPathCause(hidOpenFailure)
		}
		failure := sanitizeAdapterError("open D200X HID", err)
		s.setTransportFailure(failure)
		return failure
	}
	if nilTransport(next) {
		failure := errors.New("open D200X HID returned an uninitialized transport")
		s.setTransportFailure(failure)
		return failure
	}

	s.mu.Lock()
	if s.closed || s.transport != nil {
		s.mu.Unlock()
		_ = next.Close()
		if s.closed {
			return &ProtocolError{Kind: ErrorSessionClosed}
		}
		return fmt.Errorf("D200X session already has an active transport")
	}
	s.transport = next
	s.candidate = candidate
	s.transportErr = nil
	s.mu.Unlock()
	return nil
}

func (s *Session) logHIDOpenPathCause(failure *HIDOpenPathFailure) {
	if s == nil || failure == nil || !s.diagnostics.verbose {
		return
	}

	writer := s.diagnostics.options.Writer
	const prefix = "D200X_HID_OPEN_PATH_CAUSE: "
	lineLimit := s.diagnostics.options.lineLimit()
	if writer == nil || lineLimit <= len(prefix)+1 {
		return
	}

	causeLimit := lineLimit - len(prefix) - 1
	line := make([]byte, 0, lineLimit)
	line = append(line, prefix...)
	line = append(line, escapeVerboseHIDCause(failure.cause, failure.causeTruncated, causeLimit)...)
	line = append(line, '\n')
	writeBoundedDiagnostic(writer, line, lineLimit)
}

func escapeVerboseHIDCause(cause string, truncated bool, limit int) []byte {
	if limit <= 0 {
		return nil
	}

	inputLimit := min(len(cause), maximumVerboseHIDCauseBytes)
	truncated = truncated || inputLimit < len(cause)
	output := make([]byte, 0, limit)
	ellipsisReserve := min(3, limit)
	const digits = "0123456789abcdef"
	for index := 0; index < inputLimit; index++ {
		value := cause[index]
		encoded := [4]byte{}
		encodedLength := 1
		switch {
		case value >= 0x20 && value <= 0x7e && value != '\\':
			encoded[0] = value
		case value == '\\':
			encoded[0], encoded[1] = '\\', '\\'
			encodedLength = 2
		default:
			encoded[0], encoded[1] = '\\', 'x'
			encoded[2], encoded[3] = digits[value>>4], digits[value&0x0f]
			encodedLength = 4
		}
		if len(output)+encodedLength > limit-ellipsisReserve {
			truncated = true
			break
		}
		output = append(output, encoded[:encodedLength]...)
	}
	if truncated && limit >= 3 {
		output = append(output, '.', '.', '.')
	}
	return output
}

func nilTransport(transport Transport) bool {
	if transport == nil {
		return true
	}
	value := reflect.ValueOf(transport)
	switch value.Kind() {
	case reflect.Chan, reflect.Func, reflect.Interface, reflect.Map, reflect.Pointer, reflect.Slice:
		return value.IsNil()
	default:
		return false
	}
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
	n, err := operation.transport.Read(operation.context, report)
	if err != nil {
		return n, sanitizeAdapterError("read D200X HID", err)
	}
	if validationErr := validateReadCount(n, len(report)); validationErr != nil {
		return 0, validationErr
	}
	return n, nil
}

// ReadFrame reads and assembles one complete D200X frame. It allocates only a
// bounded report buffer and returns a protocol error for malformed or
// truncated input; callers may decide whether to continue reading afterward.
func (s *Session) ReadFrame(ctx context.Context) (Frame, error) {
	report := make([]byte, TransportReportSize)
	n, err := s.Read(ctx, report)
	if err != nil {
		return Frame{}, err
	}
	if err := validateReadCount(n, len(report)); err != nil {
		return Frame{}, err
	}
	assembler, err := NewFrameAssembler(report[:n])
	if err != nil {
		return Frame{}, &InboundMalformedError{Err: err}
	}
	for !assembler.Complete() {
		n, err = s.Read(ctx, report)
		if err != nil {
			return Frame{}, err
		}
		if err := validateReadCount(n, len(report)); err != nil {
			return Frame{}, err
		}
		if err := assembler.Append(report[:n]); err != nil {
			return Frame{}, &InboundMalformedError{Err: err}
		}
	}
	frame, err := assembler.Frame()
	if err != nil {
		return Frame{}, &InboundMalformedError{Err: err}
	}
	return frame, nil
}

func validateReadCount(actual, capacity int) error {
	if actual >= 0 && actual <= capacity {
		return nil
	}
	return &ProtocolError{Kind: ErrorInvalidReportLength, Actual: actual, Expected: capacity}
}

// ReadInput reads one complete frame and decodes input events. Non-input
// frames return ok=false. Unknown marker/action values remain lossless in the
// returned event and are safe for callers to ignore.
func (s *Session) ReadInput(ctx context.Context) (InputEvent, bool, error) {
	frame, err := s.ReadFrame(ctx)
	if err != nil {
		return InputEvent{}, false, err
	}
	event, ok, err := DecodeInput(frame)
	if err != nil {
		return event, ok, &InboundMalformedError{Err: err}
	}
	if ok && err == nil {
		s.logInputEvent(event)
	}
	return event, ok, err
}

func (s *Session) SendFrame(ctx context.Context, frame Frame) error {
	if s == nil {
		return &ProtocolError{Kind: ErrorSessionClosed}
	}
	if frame.Command == CommandCompleteDisplayUpload || frame.Command == CommandPartialDisplayUpload {
		return &ProtocolError{Kind: ErrorUnsafeOutboundCommand, Command: frame.Command}
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	return s.sendFrameLocked(ctx, frame)
}

func (s *Session) sendFrameLocked(ctx context.Context, frame Frame) error {
	if !frame.Command.IsSafeOutbound() {
		return &ProtocolError{Kind: ErrorUnsafeOutboundCommand, Command: frame.Command}
	}
	reports, err := EncodeFrame(frame)
	if err != nil {
		return err
	}
	ctx = normalizeContext(ctx)
	for packetIndex, report := range reports {
		if err := s.writeReportLocked(ctx, report); err != nil {
			return err
		}
		s.logOutboundPacket(frame.Command, packetIndex, len(reports), report)
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
		failure := sanitizeAdapterError("write D200X HID", err)
		s.invalidateLocked(transport, failure)
		return failure
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
	closeErr := sanitizeAdapterError("close D200X HID transport", transport.Close())
	drainReads(reads)
	return closeErr
}

func normalizeContext(ctx context.Context) context.Context {
	if ctx == nil {
		return context.Background()
	}
	return ctx
}
