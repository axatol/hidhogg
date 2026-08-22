package configediting

import (
	"bytes"
	_ "embed"
)

//go:embed fixtures/root.toml
var rootTOML []byte

//go:embed fixtures/device.toml
var deviceTOML []byte

//go:embed fixtures/root.jsonc
var rootJSONC []byte

//go:embed fixtures/device.jsonc
var deviceJSONC []byte

type fixture struct {
	Name  string
	TOML  []byte
	JSONC []byte
}

var fixtures = map[string]fixture{
	"root": {
		Name:  "root",
		TOML:  rootTOML,
		JSONC: rootJSONC,
	},
	"device": {
		Name:  "device",
		TOML:  deviceTOML,
		JSONC: deviceJSONC,
	},
}

func sourceWithLineEnding(source []byte, lineEnding string) []byte {
	source = bytes.ReplaceAll(source, []byte("\r\n"), []byte("\n"))
	if lineEnding == "CRLF" {
		return bytes.ReplaceAll(source, []byte("\n"), []byte("\r\n"))
	}
	return bytes.Clone(source)
}

func lineSpan(source []byte, marker string) []byte {
	markerOffset := bytes.Index(source, []byte(marker))
	if markerOffset < 0 {
		return nil
	}
	start := bytes.LastIndexByte(source[:markerOffset], '\n')
	if start < 0 {
		start = 0
	} else {
		start++
	}
	endOffset := bytes.IndexByte(source[markerOffset:], '\n')
	if endOffset < 0 {
		return bytes.Clone(source[start:])
	}
	return bytes.Clone(source[start : markerOffset+endOffset+1])
}
