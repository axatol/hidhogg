package runtime

import (
	"io"
	"sync"
)

type serializedOutput struct {
	mu     sync.Mutex
	writer io.Writer
}

func newSerializedOutput(writer io.Writer) io.Writer {
	if writer == nil {
		return nil
	}
	return &serializedOutput{writer: writer}
}

func (output *serializedOutput) Write(data []byte) (int, error) {
	if output == nil || output.writer == nil {
		return 0, io.ErrClosedPipe
	}
	output.mu.Lock()
	defer output.mu.Unlock()
	return output.writer.Write(data)
}
