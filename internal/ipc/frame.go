package ipc

import (
	"bytes"
	"errors"
	"io"
)

var (
	errFrameTooLarge   = errors.New("frame exceeds maximum size")
	errFrameIncomplete = errors.New("frame ended before LF")
)

func readFrame(reader io.Reader) ([]byte, error) {
	frame := make([]byte, 0, MaxFrameBytes)
	var chunk [4096]byte
	for {
		read, err := reader.Read(chunk[:])
		if read > 0 {
			part := chunk[:read]
			if index := bytes.IndexByte(part, '\n'); index >= 0 {
				frameSize := len(frame) + index + 1
				if frameSize > MaxFrameBytes {
					return nil, errFrameTooLarge
				}
				frame = append(frame, part[:index+1]...)
				return frame, nil
			}
			if len(frame)+len(part) > MaxFrameBytes {
				return nil, errFrameTooLarge
			}
			frame = append(frame, part...)
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				return nil, errFrameIncomplete
			}
			return nil, err
		}
		if read == 0 {
			return nil, io.ErrNoProgress
		}
	}
}

func writeFrame(writer io.Writer, frame []byte) error {
	if len(frame) == 0 || frame[len(frame)-1] != '\n' {
		return errors.New("frame is not LF terminated")
	}
	if len(frame) > MaxFrameBytes {
		return errFrameTooLarge
	}
	for len(frame) > 0 {
		written, err := writer.Write(frame)
		if written > 0 {
			frame = frame[written:]
		}
		if err != nil {
			return err
		}
		if written == 0 {
			return io.ErrShortWrite
		}
	}
	return nil
}
