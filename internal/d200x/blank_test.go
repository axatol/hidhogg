package d200x

import (
	"bytes"
	"image/color"
	"testing"
)

func TestBlankPageArchivesClearEveryPosition(t *testing.T) {
	page := configuredTestPage()
	for index := range page.Positions {
		page.Positions[index].Label = ""
		page.Positions[index].Background = "#000000"
	}

	for _, test := range []struct {
		name  string
		build func(Page) (DisplayArchive, error)
	}{
		{name: "startup diagnostic", build: BuildPageArchive},
		{name: "live bulk", build: BuildLivePageArchive},
	} {
		t.Run(test.name, func(t *testing.T) {
			archive, err := test.build(page)
			if err != nil {
				t.Fatal(err)
			}
			files := readArchiveFiles(t, archive.Data)
			manifest := readManifest(t, readArchiveFile(t, files, "manifest.json"))
			if len(manifest) != DisplayPositionCount {
				t.Fatalf("manifest contains %d positions, want %d", len(manifest), DisplayPositionCount)
			}
			for _, spec := range SupportedPositions() {
				entry, exists := manifest[spec.Name]
				if !exists || len(entry.ViewParam) != 1 {
					t.Fatalf("blank position %s has no complete replacement entry", spec.Name)
				}
				view := entry.ViewParam[0]
				if view.Text != "" || view.Font.ShowTitle {
					t.Fatalf("blank position %s retains title/text: %+v", spec.Name, view)
				}
				assertUniformArchivePNG(t, files, view.Icon, color.RGBA{A: 255})
			}
			repeated, err := test.build(page)
			if err != nil || !bytes.Equal(archive.Data, repeated.Data) {
				t.Fatalf("blank page rendering is not deterministic: %v", err)
			}
		})
	}
}

func TestBlankTargetedUpdatesClearSquareAndWide(t *testing.T) {
	page := configuredTestPage()
	for _, index := range []int{0, 13} {
		position := page.Positions[index]
		position.Label = ""
		position.Background = "#000000"
		update, err := BuildLivePositionUpdate(position)
		if err != nil {
			t.Fatal(err)
		}
		files := readArchiveFiles(t, update.Archive().Data)
		entry := readManifest(t, readArchiveFile(t, files, "manifest.json"))[position.Position]
		if len(entry.ViewParam) != 1 || entry.ViewParam[0].Text != "" || entry.ViewParam[0].Font.ShowTitle {
			t.Fatalf("blank targeted update retains content: %+v", entry)
		}
		assertUniformArchivePNG(t, files, entry.ViewParam[0].Icon, color.RGBA{A: 255})
	}
}

func assertUniformArchivePNG(t *testing.T, files []archiveFile, name string, expected color.RGBA) {
	t.Helper()
	decoded := decodeArchivePNG(t, files, name)
	for y := decoded.Bounds().Min.Y; y < decoded.Bounds().Max.Y; y++ {
		for x := decoded.Bounds().Min.X; x < decoded.Bounds().Max.X; x++ {
			actual := color.RGBAModel.Convert(decoded.At(x, y)).(color.RGBA)
			if actual != expected {
				t.Fatalf("blank PNG %s pixel %d,%d = %v, want %v", name, x, y, actual, expected)
			}
		}
	}
}
