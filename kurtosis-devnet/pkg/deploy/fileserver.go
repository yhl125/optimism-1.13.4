package deploy

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"

	ktfs "github.com/ethereum-optimism/optimism/devnet-sdk/kt/fs"
	"github.com/ethereum-optimism/optimism/kurtosis-devnet/pkg/kurtosis"
	"github.com/ethereum-optimism/optimism/kurtosis-devnet/pkg/util"
	"github.com/spf13/afero"
	"go.opentelemetry.io/otel"
)

const FILESERVER_PACKAGE = "fileserver"

type FileServer struct {
	baseDir  string
	enclave  string
	dryRun   bool
	deployer DeployerFunc
	fs       afero.Fs
}

func (f *FileServer) URL(path ...string) string {
	return fmt.Sprintf("http://%s/%s", FILESERVER_PACKAGE, strings.Join(path, "/"))
}

func (f *FileServer) Deploy(ctx context.Context, sourceDir string, stateCh <-chan *fileserverState) (retErr error) {
	ctx, span := otel.Tracer("fileserver").Start(ctx, "deploy fileserver")
	defer span.End()

	if f.fs == nil {
		f.fs = afero.NewOsFs()
	}

	// Check if source directory is empty. If it is, then ie means we don't have
	// anything to serve, so we might as well not deploy the fileserver.
	entries, err := afero.ReadDir(f.fs, sourceDir)
	if err != nil {
		return fmt.Errorf("error reading source directory: %w", err)
	}
	if len(entries) == 0 {
		return nil
	}

	srcHash, err := calculateDirHashWithFs(sourceDir, f.fs)
	if err != nil {
		return fmt.Errorf("error calculating source directory hash: %w", err)
	}

	// Create a temp dir in the fileserver package
	baseDir := filepath.Join(f.baseDir, FILESERVER_PACKAGE)
	if err := f.fs.MkdirAll(baseDir, 0755); err != nil {
		return fmt.Errorf("error creating base directory: %w", err)
	}

	// Create the nginx directory structure
	nginxDir := filepath.Join(baseDir, "static_files", "nginx")
	if err := f.fs.MkdirAll(nginxDir, 0755); err != nil {
		return fmt.Errorf("error creating nginx directory: %w", err)
	}

	configHash, err := calculateDirHashWithFs(nginxDir, f.fs)
	if err != nil {
		return fmt.Errorf("error calculating base directory hash: %w", err)
	}

	refState := <-stateCh
	if refState.contentHash == srcHash && refState.configHash == configHash {
		log.Println("No changes to fileserver, skipping deployment")
		return nil
	}

	// Can't use MkdirTemp here because the directory name needs to always be the same
	// in order for kurtosis file artifact upload to be idempotent.
	// (i.e. the file upload and all its downstream dependencies can be SKIPPED on re-runs)
	tempDir := filepath.Join(baseDir, "upload-content")

	// Clean up any existing content
	if err := f.fs.RemoveAll(tempDir); err != nil {
		return fmt.Errorf("error cleaning up existing directory: %w", err)
	}

	// Create the directory
	if err := f.fs.MkdirAll(tempDir, 0755); err != nil {
		return fmt.Errorf("error creating temporary directory: %w", err)
	}
	defer func() {
		if err := f.fs.RemoveAll(tempDir); err != nil && retErr == nil {
			retErr = fmt.Errorf("error cleaning up temporary directory: %w", err)
		}
	}()

	// Copy build dir contents to tempDir
	if err := util.CopyDir(sourceDir, tempDir, f.fs); err != nil {
		return fmt.Errorf("error copying directory: %w", err)
	}

	buf := bytes.NewBuffer(nil)
	buf.WriteString(fmt.Sprintf("source_path: %s\n", filepath.Base(tempDir)))

	opts := []kurtosis.KurtosisDeployerOptions{
		kurtosis.WithKurtosisBaseDir(f.baseDir),
		kurtosis.WithKurtosisDryRun(f.dryRun),
		kurtosis.WithKurtosisPackageName(FILESERVER_PACKAGE),
		kurtosis.WithKurtosisEnclave(f.enclave),
	}

	d, err := f.deployer(opts...)
	if err != nil {
		return fmt.Errorf("error creating kurtosis deployer: %w", err)
	}

	_, err = d.Deploy(ctx, buf)
	if err != nil {
		return fmt.Errorf("error deploying kurtosis package: %w", err)
	}

	return
}

type fileserverState struct {
	contentHash string
	configHash  string
}

// downloadAndHashArtifact downloads an artifact and calculates its hash
func downloadAndHashArtifact(ctx context.Context, enclave, artifactName string) (hash string, retErr error) {
	fs, err := ktfs.NewEnclaveFS(ctx, enclave)
	if err != nil {
		return "", fmt.Errorf("failed to create enclave fs: %w", err)
	}

	// Create temp dir
	osFs := afero.NewOsFs()
	tempDir, err := afero.TempDir(osFs, "", artifactName+"-*")
	if err != nil {
		return "", fmt.Errorf("failed to create temp dir: %w", err)
	}
	defer func() {
		if err := osFs.RemoveAll(tempDir); err != nil && retErr == nil {
			retErr = fmt.Errorf("error cleaning up temporary directory: %w", err)
		}
	}()

	// Download artifact
	artifact, err := fs.GetArtifact(ctx, artifactName)
	if err != nil {
		return "", fmt.Errorf("failed to get artifact: %w", err)
	}

	// Ensure parent directories exist before extracting
	if err := osFs.MkdirAll(tempDir, 0755); err != nil {
		return "", fmt.Errorf("failed to create temp dir structure: %w", err)
	}

	// Extract to temp dir
	if err := artifact.Download(tempDir); err != nil {
		return "", fmt.Errorf("failed to download artifact: %w", err)
	}

	// Calculate hash
	hash, err = calculateDirHash(tempDir)
	if err != nil {
		return "", fmt.Errorf("failed to calculate hash: %w", err)
	}

	return
}

func (f *FileServer) getState(ctx context.Context) <-chan *fileserverState {
	stateCh := make(chan *fileserverState)

	go func(ctx context.Context) {
		st := &fileserverState{}
		var wg sync.WaitGroup

		type artifactInfo struct {
			name string
			dest *string
		}

		artifacts := []artifactInfo{
			{"fileserver-content", &st.contentHash},
			{"fileserver-nginx-conf", &st.configHash},
		}

		for _, art := range artifacts {
			wg.Add(1)
			go func(art artifactInfo) {
				defer wg.Done()
				hash, err := downloadAndHashArtifact(ctx, f.enclave, art.name)
				if err == nil {
					*art.dest = hash
				}
			}(art)
		}

		wg.Wait()
		stateCh <- st
	}(ctx)

	return stateCh
}

type entry struct {
	RelPath string `json:"rel_path"`
	Size    int64  `json:"size"`
	Mode    string `json:"mode"`
	Content []byte `json:"content"`
}

// calculateDirHash returns a SHA256 hash of the directory contents
// It walks through the directory, hashing file names and contents
func calculateDirHash(dir string) (string, error) {
	return calculateDirHashWithFs(dir, afero.NewOsFs())
}

// calculateDirHashWithFs is like calculateDirHash but accepts a custom filesystem
func calculateDirHashWithFs(dir string, fs afero.Fs) (string, error) {
	hash := sha256.New()

	err := afero.Walk(fs, dir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}

		// Get path relative to root dir
		relPath, err := filepath.Rel(dir, path)
		if err != nil {
			return err
		}

		// Skip the root directory
		if relPath == "." {
			return nil
		}

		// Add the relative path and file info to hash
		entry := entry{
			RelPath: relPath,
			Size:    info.Size(),
			Mode:    info.Mode().String(),
		}

		// If it's a regular file, add its contents to hash
		if !info.IsDir() {
			content, err := afero.ReadFile(fs, path)
			if err != nil {
				return err
			}
			entry.Content = content
		}

		jsonBytes, err := json.Marshal(entry)
		if err != nil {
			return err
		}
		_, err = hash.Write(jsonBytes)
		if err != nil {
			return err
		}

		return nil
	})

	if err != nil {
		return "", fmt.Errorf("error walking directory: %w", err)
	}

	hashStr := hex.EncodeToString(hash.Sum(nil))
	return hashStr, nil
}
