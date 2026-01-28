// PreCompact hook: Save conversation context for continuity
// Receives hook metadata on stdin with transcript_path field,
// reads the actual transcript file, extracts recent user messages,
// writes structured context to last_session.md
//
// Build: go build -o save_context save_context.go
// Usage: echo '{"transcript_path":"/path/to/transcript.jsonl"}' | ./save_context

package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// HookMetadata represents the metadata received from Claude Code PreCompact hook
type HookMetadata struct {
	SessionID      string `json:"session_id"`
	TranscriptPath string `json:"transcript_path"`
	Cwd            string `json:"cwd"`
	HookEventName  string `json:"hook_event_name"`
	Trigger        string `json:"trigger"`
}

// Record represents a line in the JSONL transcript
type Record struct {
	Type    string  `json:"type"`
	Message Message `json:"message"`
}

// Message contains the content of a user/assistant message
// Content can be either a string (direct user input) or an array of ContentItems
type Message struct {
	Role       string          `json:"role"`
	RawContent json.RawMessage `json:"content"`
}

// ContentItem represents an item in the content array
type ContentItem struct {
	Type string `json:"type"`
	Text string `json:"text"`
	Name string `json:"name"` // for tool_use items
}

// ParseContent extracts text from the message content
// Handles both string content (direct user input) and array content (tool results)
func (m *Message) ParseContent() ([]ContentItem, string) {
	if len(m.RawContent) == 0 {
		return nil, ""
	}

	// Try parsing as string first (direct user input)
	var stringContent string
	if err := json.Unmarshal(m.RawContent, &stringContent); err == nil {
		return nil, stringContent
	}

	// Try parsing as array of ContentItems
	var items []ContentItem
	if err := json.Unmarshal(m.RawContent, &items); err == nil {
		return items, ""
	}

	return nil, ""
}

func main() {
	// Personal context directory at ~/.claude/arbor-personal/context/
	homeDir, err := os.UserHomeDir()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error getting home directory: %v\n", err)
		os.Exit(1)
	}

	contextDir := filepath.Join(homeDir, ".claude", "arbor-personal", "context")
	contextFile := filepath.Join(contextDir, "last_session.md")
	debugFile := filepath.Join(contextDir, "debug_input.txt")

	// Ensure directory exists
	os.MkdirAll(contextDir, 0755)

	// Read hook metadata from stdin (single JSON line)
	stdinData, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error reading stdin: %v\n", err)
		os.Exit(1)
	}

	// Parse the hook metadata
	var metadata HookMetadata
	if err := json.Unmarshal(stdinData, &metadata); err != nil {
		// Write debug info and exit
		debugContent := fmt.Sprintf("Failed to parse metadata: %v\n\nRaw input:\n%s", err, string(stdinData))
		os.WriteFile(debugFile, []byte(debugContent), 0644)
		fmt.Fprintf(os.Stderr, "Error parsing hook metadata: %v\n", err)
		os.Exit(1)
	}

	// Write debug info about what we received
	debugContent := fmt.Sprintf("Hook metadata received:\n  session_id: %s\n  transcript_path: %s\n  cwd: %s\n  hook_event_name: %s\n  trigger: %s\n\n",
		metadata.SessionID, metadata.TranscriptPath, metadata.Cwd, metadata.HookEventName, metadata.Trigger)

	// Open and process the transcript file
	if metadata.TranscriptPath == "" {
		debugContent += "ERROR: No transcript_path in metadata\n"
		os.WriteFile(debugFile, []byte(debugContent), 0644)
		fmt.Fprintf(os.Stderr, "No transcript_path in hook metadata\n")
		os.Exit(1)
	}

	transcriptFile, err := os.Open(metadata.TranscriptPath)
	if err != nil {
		debugContent += fmt.Sprintf("ERROR: Failed to open transcript: %v\n", err)
		os.WriteFile(debugFile, []byte(debugContent), 0644)
		fmt.Fprintf(os.Stderr, "Error opening transcript file: %v\n", err)
		os.Exit(1)
	}
	defer transcriptFile.Close()

	// Process transcript file line by line (streaming - never load full file)
	scanner := bufio.NewScanner(transcriptFile)
	// Increase buffer size for potentially long lines
	buf := make([]byte, 0, 1024*1024) // 1MB buffer
	scanner.Buffer(buf, 10*1024*1024)  // 10MB max line size

	var userMessages []string
	var toolsUsed = make(map[string]int)
	var assistantTexts []string
	var totalRecords int

	for scanner.Scan() {
		line := scanner.Text()
		totalRecords++

		var record Record
		if err := json.Unmarshal([]byte(line), &record); err != nil {
			continue
		}

		// Parse content (handles both string and array formats)
		items, directText := record.Message.ParseContent()

		switch record.Type {
		case "user":
			// Check for direct string content first (actual user-typed messages)
			if directText != "" && !isSystemMessage(directText) {
				userMessages = append(userMessages, directText)
			} else if len(items) > 0 {
				// Fall back to extracting from content items
				text := extractHumanText(items)
				if text != "" && !isSystemMessage(text) {
					userMessages = append(userMessages, text)
				}
			}

		case "assistant":
			// Check for direct text content
			if directText != "" {
				truncated := directText
				if len(truncated) > 500 {
					truncated = truncated[:500]
				}
				assistantTexts = append(assistantTexts, truncated)
			}
			// Process array items
			for _, item := range items {
				switch item.Type {
				case "text":
					if len(item.Text) > 0 {
						truncated := item.Text
						if len(truncated) > 500 {
							truncated = truncated[:500]
						}
						assistantTexts = append(assistantTexts, truncated)
					}
				case "tool_use":
					if item.Name != "" {
						toolsUsed[item.Name]++
					}
				}
			}
		}
	}

	debugContent += fmt.Sprintf("Processed %d records from transcript\n", totalRecords)
	debugContent += fmt.Sprintf("Found %d user messages, %d tool types, %d assistant texts\n",
		len(userMessages), len(toolsUsed), len(assistantTexts))
	os.WriteFile(debugFile, []byte(debugContent), 0644)

	// Build context document
	context := buildContextDocument(userMessages, toolsUsed, assistantTexts, totalRecords)

	if err := os.WriteFile(contextFile, []byte(context), 0644); err != nil {
		fmt.Fprintf(os.Stderr, "Error writing context file: %v\n", err)
		os.Exit(1)
	}
}

func extractHumanText(content []ContentItem) string {
	var texts []string
	for _, item := range content {
		if item.Type == "text" && item.Text != "" {
			texts = append(texts, item.Text)
		}
	}
	return strings.Join(texts, "\n")
}

func isSystemMessage(msg string) bool {
	if len(msg) < 10 {
		return true
	}

	systemPrefixes := []string{
		"[Request interrupted",
		"Base directory for this skill:",
		"# /",
		"<local-command-",
		"<command-name>",
		"Unknown skill:",
		"(no content)",
	}

	for _, prefix := range systemPrefixes {
		if strings.HasPrefix(msg, prefix) {
			return true
		}
	}

	systemContains := []string{
		"This session is being continued from a previous conversation",
		"If you need specific details from before compaction",
		"<local-command-stdout>",
		"<local-command-caveat>",
	}

	for _, substr := range systemContains {
		if strings.Contains(msg, substr) {
			return true
		}
	}

	// Check if mostly XML tags (short messages with closing tags)
	if strings.Contains(msg, "</command-") && len(msg) < 200 {
		return true
	}

	return false
}

func buildContextDocument(userMessages []string, toolsUsed map[string]int, assistantTexts []string, totalRecords int) string {
	var sb strings.Builder

	// Compact header
	sb.WriteString(fmt.Sprintf("# Previous Session (%s)\n\n",
		time.Now().UTC().Format("2006-01-02 15:04 UTC")))

	// Last 3 user messages, compact format
	sb.WriteString("**Recent requests:**\n")
	start := len(userMessages) - 3
	if start < 0 {
		start = 0
	}
	recentMessages := userMessages[start:]

	if len(recentMessages) == 0 {
		sb.WriteString("- (none extracted)\n")
	} else {
		for _, msg := range recentMessages {
			truncated := msg
			if len(truncated) > 200 {
				truncated = truncated[:200] + "..."
			}
			// Single line per message
			truncated = strings.ReplaceAll(truncated, "\n", " ")
			sb.WriteString(fmt.Sprintf("- \"%s\"\n", truncated))
		}
	}
	sb.WriteString("\n")

	// Last assistant response only (where we left off)
	if len(assistantTexts) > 0 {
		last := assistantTexts[len(assistantTexts)-1]
		if len(last) > 300 {
			last = last[:300] + "..."
		}
		sb.WriteString(fmt.Sprintf("**Where we left off:** %s\n", last))
	}

	return sb.String()
}
