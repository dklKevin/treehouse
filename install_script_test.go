package main_test

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

const (
	pinnedInstallVersion = "v2.1.1"
	pinnedReleaseURL     = "https://github.com/kunchenguid/treehouse/releases/download/v2.1.1"
	installShPath        = "docs/install.sh"
	installPs1Path       = "docs/install.ps1"
	readmePath           = "README.md"
)

func TestInstallScriptsPinReleaseAndRejectLatest(t *testing.T) {
	for _, path := range []string{installShPath, installPs1Path, readmePath} {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read %s: %v", path, err)
		}
		text := string(data)
		if strings.Contains(text, "/releases/latest") {
			t.Errorf("%s must not follow /releases/latest", path)
		}
		if !strings.Contains(text, pinnedReleaseURL) {
			t.Errorf("%s must pin %s", path, pinnedReleaseURL)
		}
		if !strings.Contains(text, "checksums.txt") {
			t.Errorf("%s must require checksums.txt", path)
		}
	}
}

func TestInstallShFailClosedOnChecksum(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("install.sh targets Unix")
	}
	if _, err := exec.LookPath("sh"); err != nil {
		t.Skip("sh not available")
	}

	osName := runtime.GOOS
	arch := runtime.GOARCH
	filename := fmt.Sprintf("treehouse-%s-%s-%s.tar.gz", pinnedInstallVersion, osName, arch)
	archive, sum := fakeTreehouseArchive(t)

	t.Run("match installs", func(t *testing.T) {
		installDir := t.TempDir()
		mustWritable(t, installDir)
		srv := serveRelease(t, filename, archive, sum+"  "+filename+"\n")
		runInstallSh(t, srv, installDir, 0)
		got, err := os.ReadFile(filepath.Join(installDir, "treehouse"))
		if err != nil {
			t.Fatalf("expected installed binary: %v", err)
		}
		if !bytes.Equal(got, []byte("fake-treehouse\n")) {
			t.Fatalf("installed contents = %q", got)
		}
	})

	t.Run("mismatch refuses install", func(t *testing.T) {
		installDir := t.TempDir()
		mustWritable(t, installDir)
		wrong := strings.Repeat("0", 64)
		srv := serveRelease(t, filename, archive, wrong+"  "+filename+"\n")
		out := runInstallSh(t, srv, installDir, 1)
		if !strings.Contains(out, "Checksum mismatch") {
			t.Fatalf("expected checksum mismatch, got:\n%s", out)
		}
		if _, err := os.Stat(filepath.Join(installDir, "treehouse")); err == nil {
			t.Fatal("binary must not be installed after checksum mismatch")
		}
	})

	t.Run("missing checksums.txt refuses install", func(t *testing.T) {
		installDir := t.TempDir()
		mustWritable(t, installDir)
		mux := http.NewServeMux()
		mux.HandleFunc("/"+filename, func(w http.ResponseWriter, r *http.Request) {
			_, _ = w.Write(archive)
		})
		srv := httptest.NewServer(mux)
		t.Cleanup(srv.Close)
		out := runInstallSh(t, srv, installDir, 1)
		if !strings.Contains(out, "checksums.txt") {
			t.Fatalf("expected checksums.txt failure, got:\n%s", out)
		}
		if _, err := os.Stat(filepath.Join(installDir, "treehouse")); err == nil {
			t.Fatal("binary must not be installed without checksums.txt")
		}
	})

	t.Run("checksums without this asset refuses install", func(t *testing.T) {
		installDir := t.TempDir()
		mustWritable(t, installDir)
		srv := serveRelease(t, filename, archive, sum+"  treehouse-v2.1.1-other-os.tar.gz\n")
		out := runInstallSh(t, srv, installDir, 1)
		if !strings.Contains(out, "no SHA256 entry") {
			t.Fatalf("expected missing entry failure, got:\n%s", out)
		}
		if _, err := os.Stat(filepath.Join(installDir, "treehouse")); err == nil {
			t.Fatal("binary must not be installed without a matching checksums.txt row")
		}
	})
}

func fakeTreehouseArchive(t *testing.T) ([]byte, string) {
	t.Helper()

	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	body := []byte("fake-treehouse\n")
	if err := tw.WriteHeader(&tar.Header{Name: "treehouse", Mode: 0755, Size: int64(len(body))}); err != nil {
		t.Fatal(err)
	}
	if _, err := tw.Write(body); err != nil {
		t.Fatal(err)
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	archive := buf.Bytes()
	sum := sha256.Sum256(archive)
	return archive, hex.EncodeToString(sum[:])
}

func serveRelease(t *testing.T, filename string, archive []byte, checksums string) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/"+filename, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(archive)
	})
	mux.HandleFunc("/checksums.txt", func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, checksums)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

func runInstallSh(t *testing.T, srv *httptest.Server, installDir string, wantCode int) string {
	t.Helper()
	cmd := exec.Command("sh", installShPath)
	cmd.Env = append(os.Environ(),
		"TREEHOUSE_RELEASE_BASE="+srv.URL,
		"TREEHOUSE_INSTALL_DIR="+installDir,
	)
	out, err := cmd.CombinedOutput()
	got := 0
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			got = ee.ExitCode()
		} else {
			t.Fatalf("run install.sh: %v\n%s", err, out)
		}
	}
	if got != wantCode {
		t.Fatalf("install.sh exit %d, want %d\n%s", got, wantCode, out)
	}
	return string(out)
}

func mustWritable(t *testing.T, dir string) {
	t.Helper()
	if err := os.Chmod(dir, 0755); err != nil {
		t.Fatal(err)
	}
}
