package execution

import (
	"encoding/binary"
	"fmt"
	"io"
	"time"
)

type monotonicUUIDs struct {
	lastMillis uint64
	entropy    [10]byte
}

func newMonotonicUUIDs(random io.Reader) (monotonicUUIDs, error) {
	var ids monotonicUUIDs
	if _, err := io.ReadFull(random, ids.entropy[:]); err != nil {
		return monotonicUUIDs{}, fmt.Errorf("seed execution IDs: %w", err)
	}
	return ids, nil
}

func (ids *monotonicUUIDs) next(now time.Time) string {
	millis := uint64(now.UnixMilli())
	if millis < ids.lastMillis {
		millis = ids.lastMillis
	}
	if millis == ids.lastMillis {
		if incrementEntropy(&ids.entropy) {
			millis++
		}
	} else {
		incrementEntropy(&ids.entropy)
	}
	ids.lastMillis = millis

	var value [16]byte
	value[0] = byte(millis >> 40)
	value[1] = byte(millis >> 32)
	value[2] = byte(millis >> 24)
	value[3] = byte(millis >> 16)
	value[4] = byte(millis >> 8)
	value[5] = byte(millis)
	value[6] = ids.entropy[0]&0x0f | 0x70
	value[7] = ids.entropy[1]
	value[8] = ids.entropy[2]&0x3f | 0x80
	copy(value[9:], ids.entropy[3:])

	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x",
		binary.BigEndian.Uint32(value[0:4]),
		binary.BigEndian.Uint16(value[4:6]),
		binary.BigEndian.Uint16(value[6:8]),
		binary.BigEndian.Uint16(value[8:10]),
		value[10:16],
	)
}

func incrementEntropy(entropy *[10]byte) bool {
	for index := len(entropy) - 1; index >= 3; index-- {
		entropy[index]++
		if entropy[index] != 0 {
			return false
		}
	}
	entropy[2] = (entropy[2] + 1) & 0x3f
	if entropy[2] != 0 {
		return false
	}
	entropy[1]++
	if entropy[1] != 0 {
		return false
	}
	entropy[0] = (entropy[0] + 1) & 0x0f
	if entropy[0] != 0 {
		return false
	}
	return true
}
