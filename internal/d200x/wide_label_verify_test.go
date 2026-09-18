package d200x

import (
	"bytes"
	"testing"

	"golang.org/x/image/font"
	"golang.org/x/image/font/opentype"
)

func TestWideLabelFaceUsesConfiguredPointSizeAt144DPI(t *testing.T) {
	const pointSize = 24

	face, err := newWideLabelFace(pointSize)
	if err != nil {
		t.Fatal(err)
	}
	defer face.Close()

	control, err := opentype.NewFace(wideLabelFont, &opentype.FaceOptions{
		Size:    pointSize,
		DPI:     72,
		Hinting: font.HintingNone,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer control.Close()

	got := face.Metrics()
	controlMetrics := control.Metrics()
	if got.Ascent <= controlMetrics.Ascent || got.Height <= controlMetrics.Height {
		t.Fatalf("24-point face metrics = %+v, want larger than 72-DPI control %+v", got, controlMetrics)
	}
	controlAscent := controlMetrics.Ascent.Ceil()
	gotAscent := got.Ascent.Ceil()
	if gotAscent < controlAscent*2-1 || gotAscent > controlAscent*2+1 {
		t.Fatalf("24-point face ascent = %d device pixels, want about twice 72-DPI ascent %d", gotAscent, controlAscent)
	}
	if gotAscent < 40 || gotAscent > 52 {
		t.Fatalf("24-point face ascent = %d device pixels, want approximately 48", gotAscent)
	}
}

func TestWideLabelFallbackSupportsRepresentativeGlyphs(t *testing.T) {
	labels := []string{"Enter", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ".", "*", "+"}
	builders := []struct {
		name  string
		build func(*testing.T, string) []byte
	}{
		{
			name: "configured",
			build: func(t *testing.T, label string) []byte {
				page := configuredTestPage()
				page.Positions[13].Label = label
				archive, err := BuildPageArchive(page)
				if err != nil {
					t.Fatal(err)
				}
				return readArchiveFile(t, readArchiveFiles(t, archive.Data), "icons/wide-tile.png")
			},
		},
		{
			name: "targeted",
			build: func(t *testing.T, label string) []byte {
				position := configuredTestPage().Positions[13]
				position.Label = label
				archive, err := BuildLivePositionArchive(position)
				if err != nil {
					t.Fatal(err)
				}
				files := readArchiveFiles(t, archive.Data)
				manifest := readManifest(t, readArchiveFile(t, files, livePositionManifestName))
				entry, ok := manifest["3_2"]
				if !ok || len(entry.ViewParam) != 1 {
					t.Fatalf("wide targeted manifest entry = %+v", entry)
				}
				return readArchiveFile(t, files, entry.ViewParam[0].Icon)
			},
		},
		{
			name: "bulk",
			build: func(t *testing.T, label string) []byte {
				page := configuredTestPage()
				page.Positions[13].Label = label
				archive, err := BuildLivePageArchive(page)
				if err != nil {
					t.Fatal(err)
				}
				files := readArchiveFiles(t, archive.Data)
				manifest := readManifest(t, readArchiveFile(t, files, livePositionManifestName))
				entry, ok := manifest["3_2"]
				if !ok || len(entry.ViewParam) != 1 {
					t.Fatalf("wide bulk manifest entry = %+v", entry)
				}
				return readArchiveFile(t, files, entry.ViewParam[0].Icon)
			},
		},
	}

	for _, builder := range builders {
		t.Run(builder.name, func(t *testing.T) {
			missingGlyph := builder.build(t, "\u0378")
			for _, label := range labels {
				data := builder.build(t, label)
				if !hasConfiguredInteriorInk(t, data, "#102030") {
					t.Fatalf("label %q rendered no interior pixels", label)
				}
				if bytes.Equal(data, missingGlyph) {
					t.Fatalf("label %q matched the missing-glyph rendering", label)
				}
			}
		})
	}
}
