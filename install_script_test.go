package main_test

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

const (
	pinnedInstallTag     = "v2.1.1"
	checksumsAsset       = "checksums.txt"
	latestReleaseAPIPath = "releases/latest"
)

func readInstallScript(t *testing.T, name string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("docs", name))
	if err != nil {
		t.Fatalf("reading docs/%s: %v", name, err)
	}
	return string(data)
}

func TestInstallScriptsPinReleaseAndRequireChecksums(t *testing.T) {
	for _, name := range []string{"install.sh", "install.ps1"} {
		script := readInstallScript(t, name)
		if strings.Contains(script, latestReleaseAPIPath) {
			t.Errorf("%s must not follow /%s", name, latestReleaseAPIPath)
		}
		pinnedURL := "https://github.com/kunchenguid/treehouse/releases/download/" + pinnedInstallTag
		if !strings.Contains(script, pinnedURL) {
			t.Errorf("%s must pin %s", name, pinnedURL)
		}
		if !strings.Contains(script, checksumsAsset) {
			t.Errorf("%s must download %s", name, checksumsAsset)
		}
		lower := strings.ToLower(script)
		for _, banned := range []string{
			"skip checksum",
			"checksum optional",
			"warn and continue",
			"ignoring checksum",
		} {
			if strings.Contains(lower, banned) {
				t.Errorf("%s must fail closed; found %q", name, banned)
			}
		}
		if !strings.Contains(lower, "refusing to install") {
			t.Errorf("%s must refuse to install when checksums do not match", name)
		}
	}
}

func TestVerifyArchiveChecksumFailClosed(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("install.sh verification uses POSIX sha256 tools")
	}
	if _, err := exec.LookPath("sh"); err != nil {
		t.Skip("sh not available")
	}

	script, err := os.ReadFile(filepath.Join("docs", "install.sh"))
	if err != nil {
		t.Fatal(err)
	}
	fn, err := extractMarkedBlock(string(script), "verify_archive_checksum")
	if err != nil {
		t.Fatal(err)
	}

	dir := t.TempDir()
	archive := filepath.Join(dir, "treehouse-v2.1.1-linux-amd64.tar.gz")
	payload := []byte("treehouse-archive-fixture")
	if err := os.WriteFile(archive, payload, 0o644); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(payload)
	goodHash := hex.EncodeToString(sum[:])
	goodChecksums := filepath.Join(dir, "checksums-good.txt")
	if err := os.WriteFile(goodChecksums, []byte(goodHash+"  "+filepath.Base(archive)+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	badChecksums := filepath.Join(dir, "checksums-bad.txt")
	if err := os.WriteFile(badChecksums, []byte(strings.Repeat("0", 64)+"  "+filepath.Base(archive)+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	emptyChecksums := filepath.Join(dir, "checksums-empty.txt")
	if err := os.WriteFile(emptyChecksums, []byte(""), 0o644); err != nil {
		t.Fatal(err)
	}
	missingEntry := filepath.Join(dir, "checksums-other.txt")
	if err := os.WriteFile(missingEntry, []byte(goodHash+"  other-file.tar.gz\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	run := func(t *testing.T, checksums string) error {
		t.Helper()
		wrapper := filepath.Join(t.TempDir(), "verify.sh")
		body := fn + "\nverify_archive_checksum \"$1\" \"$2\"\n"
		if err := os.WriteFile(wrapper, []byte(body), 0o755); err != nil {
			t.Fatal(err)
		}
		cmd := exec.Command("sh", wrapper, archive, checksums)
		cmd.Stderr = os.Stderr
		return cmd.Run()
	}

	if err := run(t, goodChecksums); err != nil {
		t.Fatalf("expected matching checksums to pass, got %v", err)
	}
	if err := run(t, badChecksums); err == nil {
		t.Fatal("expected checksum mismatch to fail")
	}
	if err := run(t, emptyChecksums); err == nil {
		t.Fatal("expected empty checksums.txt to fail")
	}
	if err := run(t, missingEntry); err == nil {
		t.Fatal("expected missing archive entry to fail")
	}
	if err := run(t, filepath.Join(dir, "does-not-exist.txt")); err == nil {
		t.Fatal("expected missing checksums.txt to fail")
	}
}

func extractMarkedBlock(script, name string) (string, error) {
	begin := "# --- begin " + name + " ---"
	end := "# --- end " + name + " ---"
	start := strings.Index(script, begin)
	stop := strings.Index(script, end)
	if start < 0 || stop < 0 || stop <= start {
		return "", fmt.Errorf("docs/install.sh is missing the %s marked block", name)
	}
	return strings.TrimSpace(script[start+len(begin) : stop]), nil
}
