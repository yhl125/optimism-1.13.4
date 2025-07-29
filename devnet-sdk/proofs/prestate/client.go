package prestate

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"path/filepath"

	"github.com/ethereum-optimism/optimism/op-service/eth"
	"github.com/ethereum-optimism/optimism/op-supervisor/supervisor/backend/depset"
)

// These constants should be in sync with op-program/chainconfig/chaincfg.go
const (
	InteropDepSetName    = "depsets.json"
	rollupConfigSuffix   = "-rollup.json"
	genensisConfigSuffix = "-genesis-l2.json"
)

// PrestateManifest maps prestate identifiers to their hashes
type PrestateManifest map[string]string

// PrestateBuilderClient is a client for the prestate builder service
type PrestateBuilderClient struct {
	url    string
	client *http.Client
}

// NewPrestateBuilderClient creates a new client for the prestate builder service
func NewPrestateBuilderClient(url string) *PrestateBuilderClient {
	return &PrestateBuilderClient{
		url:    url,
		client: &http.Client{},
	}
}

// FileInput represents a file to be used in the build process
type FileInput struct {
	Name    string    // Name of the file (used for identification)
	Content io.Reader // Content of the file
	Type    string    // Type information (e.g., "rollup-config", "genesis-config", "interop")
}

// buildContext holds all the inputs for a build operation
type buildContext struct {
	chains                 []string
	files                  []FileInput
	generatedInteropDepSet bool
}

// PrestateBuilderOption is a functional option for configuring a build
type PrestateBuilderOption func(*buildContext)

// WithInteropDepSet adds an interop dependency set file to the build
func WithInteropDepSet(content io.Reader) PrestateBuilderOption {
	return func(c *buildContext) {
		c.files = append(c.files, FileInput{
			Name:    InteropDepSetName,
			Content: content,
			Type:    "interop",
		})
	}
}

func generateInteropDepSet(chains []string) ([]byte, error) {
	deps := make(map[eth.ChainID]*depset.StaticConfigDependency)
	for _, chain := range chains {
		id, err := eth.ParseDecimalChainID(chain)
		if err != nil {
			return nil, fmt.Errorf("failed to parse chain ID: %w", err)
		}
		deps[id] = &depset.StaticConfigDependency{}
	}

	interopDepSet, err := depset.NewStaticConfigDependencySet(deps)
	if err != nil {
		return nil, fmt.Errorf("failed to create interop dependency set: %w", err)
	}

	json, err := json.Marshal(interopDepSet)
	if err != nil {
		return nil, err
	}
	return json, nil
}

func WithGeneratedInteropDepSet() PrestateBuilderOption {
	return func(c *buildContext) {
		c.generatedInteropDepSet = true
	}
}

// WithChainConfig adds a pair of rollup and genesis config files to the build
func WithChainConfig(chainId string, rollupContent io.Reader, genesisContent io.Reader) PrestateBuilderOption {
	return func(c *buildContext) {
		c.chains = append(c.chains, chainId)
		c.files = append(c.files,
			FileInput{
				Name:    chainId + rollupConfigSuffix,
				Content: rollupContent,
				Type:    "rollup-config",
			},
			FileInput{
				Name:    chainId + genensisConfigSuffix,
				Content: genesisContent,
				Type:    "genesis-config",
			},
		)
	}
}

// BuildPrestate sends the files to the prestate builder service and returns a manifest of the built prestates
func (c *PrestateBuilderClient) BuildPrestate(ctx context.Context, opts ...PrestateBuilderOption) (PrestateManifest, error) {
	fmt.Println("Starting prestate build...")

	// Apply options to build context
	bc := &buildContext{
		files: []FileInput{},
	}

	for _, opt := range opts {
		opt(bc)
	}

	if bc.generatedInteropDepSet {
		depSet, err := generateInteropDepSet(bc.chains)
		if err != nil {
			return nil, fmt.Errorf("failed to generate interop dependency set: %w", err)
		}
		bc.files = append(bc.files, FileInput{
			Name:    InteropDepSetName,
			Content: bytes.NewReader(depSet),
			Type:    "interop",
		})
	}

	fmt.Printf("Preparing to upload %d files\n", len(bc.files))

	// Create a multipart form
	var b bytes.Buffer
	w := multipart.NewWriter(&b)

	// Add each file to the form
	for _, file := range bc.files {
		fmt.Printf("Adding file to form: %s (type: %s)\n", file.Name, file.Type)
		// Create a form file with the file's name
		fw, err := w.CreateFormFile("files[]", filepath.Base(file.Name))
		if err != nil {
			return nil, fmt.Errorf("failed to create form file: %w", err)
		}

		// Copy the file content to the form
		if _, err := io.Copy(fw, file.Content); err != nil {
			return nil, fmt.Errorf("failed to copy file content: %w", err)
		}
	}

	// Close the multipart writer
	if err := w.Close(); err != nil {
		return nil, fmt.Errorf("failed to close multipart writer: %w", err)
	}

	fmt.Printf("Sending build request to %s\n", c.url)

	// Create the HTTP request
	req, err := http.NewRequestWithContext(ctx, "POST", c.url, &b)
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	// Set the content type
	req.Header.Set("Content-Type", w.FormDataContentType())

	// Send the request
	resp, err := c.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("failed to send request: %w", err)
	}
	defer resp.Body.Close()

	// Check the response status
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusNotModified {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("unexpected status code: %d, body: %s", resp.StatusCode, string(body))
	}

	fmt.Println("Build request successful, fetching build manifest...")

	// If the build was successful, get the info.json file
	infoURL := c.url
	if infoURL[len(infoURL)-1] != '/' {
		infoURL += "/"
	}
	infoURL += "info.json"

	fmt.Printf("Requesting manifest from %s\n", infoURL)

	infoReq, err := http.NewRequestWithContext(ctx, "GET", infoURL, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create info request: %w", err)
	}

	infoResp, err := c.client.Do(infoReq)
	if err != nil {
		return nil, fmt.Errorf("failed to get info.json: %w", err)
	}
	defer infoResp.Body.Close()

	if infoResp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(infoResp.Body)
		return nil, fmt.Errorf("unexpected info.json status code: %d, body: %s", infoResp.StatusCode, string(body))
	}

	// Parse the JSON response
	var manifest PrestateManifest
	if err := json.NewDecoder(infoResp.Body).Decode(&manifest); err != nil {
		return nil, fmt.Errorf("failed to decode info.json response: %w", err)
	}

	fmt.Printf("Build complete. Generated %d prestate entries\n", len(manifest))

	return manifest, nil

}
