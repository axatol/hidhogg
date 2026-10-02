package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"hidhogg/internal/config"
)

func main() {
	output := flag.String("output", "schema/hidhogg-d200x-v4.json", "schema artifact path")
	flag.Parse()
	if flag.NArg() != 0 {
		panic("positional arguments are not permitted")
	}

	data, err := config.GenerateSchema()
	if err != nil {
		panic(fmt.Errorf("generate schema: %w", err))
	}
	if err := os.MkdirAll(filepath.Dir(*output), 0o755); err != nil {
		panic(fmt.Errorf("create schema directory: %w", err))
	}
	if err := os.WriteFile(*output, data, 0o644); err != nil {
		panic(fmt.Errorf("write schema artifact %q: %w", *output, err))
	}
}
