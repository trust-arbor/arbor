// Session Search Tool
// Search through Claude Code session JSONL files for specific content
//
// Build: go build -o search_sessions search_sessions.go
//
// Usage:
//   ./search_sessions "search term"
//   ./search_sessions "search term" -all              # Search all sessions
//   ./search_sessions "search term" -file path.jsonl  # Search specific file
//   ./search_sessions "search term" -context 3        # Show N messages context
//   ./search_sessions "search term" -user             # Only user messages
//   ./search_sessions "search term" -assistant        # Only assistant messages
//   ./search_sessions "search term" -case-sensitive   # Case-sensitive search
//   ./search_sessions "search term" -limit 20         # Limit results

package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// Record represents a line in the JSONL transcript
type Record struct {
	Type      string  `json:"type"`
	Message   Message `json:"message"`
	Timestamp string  `json:"timestamp"`
	UUID      string  `json:"uuid"`
}

// Message contains the content of a user/assistant message
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

// ParsedRecord holds a parsed record with its line index
type ParsedRecord struct {
	Record    *Record
	LineIndex int
	RawLine   string
}

// Match represents a search result
type Match struct {
	FilePath      string
	FileName      string
	LineIndex     int
	Type          string
	Text          string
	SearchTerm    string
	ContextBefore []ContextItem
	ContextAfter  []ContextItem
}

// ContextItem represents a context message
type ContextItem struct {
	Index int
	Type  string
	Text  string
}

// Config holds search configuration
type Config struct {
	SearchTerm    string
	SearchAll     bool
	FilePath      string
	ContextSize   int
	UserOnly      bool
	AssistantOnly bool
	CaseSensitive bool
	Limit         int
	SessionsDir   string
}

func main() {
	config := parseFlags()

	if config.SearchTerm == "" {
		printUsage()
		os.Exit(1)
	}

	files := getSessionFiles(config)

	if len(files) == 0 {
		fmt.Println("No session files found.")
		os.Exit(1)
	}

	fmt.Printf("Searching for: \"%s\"\n", config.SearchTerm)
	fmt.Printf("Files to search: %d\n", len(files))
	fmt.Printf("Message filter: %s\n", getFilterName(config))
	fmt.Println(strings.Repeat("=", 70))

	var allMatches []Match
	for _, file := range files {
		matches := searchFile(file, config)
		allMatches = append(allMatches, matches...)

		if len(allMatches) >= config.Limit {
			allMatches = allMatches[:config.Limit]
			break
		}
	}

	if len(allMatches) == 0 {
		fmt.Println("\nNo matches found.")
	} else {
		fmt.Printf("\nFound %d matches:\n\n", len(allMatches))
		for _, match := range allMatches {
			printMatch(match)
		}
	}
}

func parseFlags() Config {
	config := Config{
		SessionsDir: filepath.Join(os.Getenv("HOME"), ".claude", "projects"),
	}

	flag.BoolVar(&config.SearchAll, "all", false, "Search all session files")
	flag.BoolVar(&config.SearchAll, "a", false, "Search all session files (shorthand)")
	flag.StringVar(&config.FilePath, "file", "", "Search specific file")
	flag.StringVar(&config.FilePath, "f", "", "Search specific file (shorthand)")
	flag.IntVar(&config.ContextSize, "context", 1, "Show N messages of context")
	flag.IntVar(&config.ContextSize, "c", 1, "Show N messages of context (shorthand)")
	flag.BoolVar(&config.UserOnly, "user", false, "Only search user messages")
	flag.BoolVar(&config.AssistantOnly, "assistant", false, "Only search assistant messages")
	flag.BoolVar(&config.CaseSensitive, "case-sensitive", false, "Case-sensitive search")
	flag.IntVar(&config.Limit, "limit", 50, "Limit number of results")
	flag.IntVar(&config.Limit, "l", 50, "Limit number of results (shorthand)")

	flag.Usage = printUsage
	flag.Parse()

	args := flag.Args()
	if len(args) > 0 {
		config.SearchTerm = args[0]
	}

	return config
}

func getFilterName(config Config) string {
	if config.UserOnly {
		return "user only"
	}
	if config.AssistantOnly {
		return "assistant only"
	}
	return "all"
}

func getSessionFiles(config Config) []string {
	// If specific file provided
	if config.FilePath != "" {
		if _, err := os.Stat(config.FilePath); err == nil {
			return []string{config.FilePath}
		}
		return nil
	}

	// Find all project directories
	var allFiles []string

	entries, err := os.ReadDir(config.SessionsDir)
	if err != nil {
		return nil
	}

	for _, entry := range entries {
		if entry.IsDir() {
			projectDir := filepath.Join(config.SessionsDir, entry.Name())
			jsonlFiles, _ := filepath.Glob(filepath.Join(projectDir, "*.jsonl"))
			allFiles = append(allFiles, jsonlFiles...)
		}
	}

	if len(allFiles) == 0 {
		return nil
	}

	// Sort by modification time (newest first)
	sort.Slice(allFiles, func(i, j int) bool {
		infoI, errI := os.Stat(allFiles[i])
		infoJ, errJ := os.Stat(allFiles[j])
		if errI != nil || errJ != nil {
			return false
		}
		return infoI.ModTime().After(infoJ.ModTime())
	})

	if config.SearchAll {
		return allFiles
	}

	// Default: return most recent file only
	if len(allFiles) > 0 {
		return []string{allFiles[0]}
	}
	return nil
}

func searchFile(filePath string, config Config) []Match {
	file, err := os.Open(filePath)
	if err != nil {
		return nil
	}
	defer file.Close()

	// First pass: parse all records
	var parsed []ParsedRecord
	scanner := bufio.NewScanner(file)
	buf := make([]byte, 0, 1024*1024)
	scanner.Buffer(buf, 10*1024*1024)

	lineIndex := 0
	for scanner.Scan() {
		line := scanner.Text()
		var record Record
		if err := json.Unmarshal([]byte(line), &record); err == nil {
			parsed = append(parsed, ParsedRecord{
				Record:    &record,
				LineIndex: lineIndex,
				RawLine:   line,
			})
		}
		lineIndex++
	}

	// Second pass: find matches
	var matches []Match
	for i, pr := range parsed {
		if !matchesFilter(pr.Record, config) {
			continue
		}

		text := extractText(pr.Record)
		if text == "" {
			continue
		}

		if !containsTerm(text, config.SearchTerm, config.CaseSensitive) {
			continue
		}

		// Build match with context
		match := Match{
			FilePath:      filePath,
			FileName:      filepath.Base(filePath),
			LineIndex:     pr.LineIndex,
			Type:          getMessageType(pr.Record),
			Text:          text,
			SearchTerm:    config.SearchTerm,
			ContextBefore: getContextBefore(parsed, i, config.ContextSize),
			ContextAfter:  getContextAfter(parsed, i, config.ContextSize),
		}
		matches = append(matches, match)

		if len(matches) >= config.Limit {
			break
		}
	}

	return matches
}

func matchesFilter(record *Record, config Config) bool {
	msgType := getMessageType(record)
	if msgType != "user" && msgType != "assistant" {
		return false
	}

	if config.UserOnly && msgType != "user" {
		return false
	}
	if config.AssistantOnly && msgType != "assistant" {
		return false
	}

	return true
}

func getMessageType(record *Record) string {
	if record == nil {
		return "unknown"
	}
	switch record.Type {
	case "user":
		return "user"
	case "assistant":
		return "assistant"
	}
	return "unknown"
}

func extractText(record *Record) string {
	if record == nil {
		return ""
	}

	items, directText := record.Message.ParseContent()

	// Direct string content
	if directText != "" {
		return directText
	}

	// Array content - extract text items
	var texts []string
	for _, item := range items {
		if item.Type == "text" && item.Text != "" {
			texts = append(texts, item.Text)
		}
	}
	return strings.Join(texts, "\n")
}

func containsTerm(text, term string, caseSensitive bool) bool {
	if caseSensitive {
		return strings.Contains(text, term)
	}
	return strings.Contains(strings.ToLower(text), strings.ToLower(term))
}

func getContextBefore(parsed []ParsedRecord, currentIdx, count int) []ContextItem {
	var context []ContextItem
	found := 0

	for i := currentIdx - 1; i >= 0 && found < count; i-- {
		msgType := getMessageType(parsed[i].Record)
		if msgType == "user" || msgType == "assistant" {
			text := extractText(parsed[i].Record)
			if text != "" {
				context = append([]ContextItem{{
					Index: parsed[i].LineIndex,
					Type:  msgType,
					Text:  text,
				}}, context...)
				found++
			}
		}
	}

	return context
}

func getContextAfter(parsed []ParsedRecord, currentIdx, count int) []ContextItem {
	var context []ContextItem
	found := 0

	for i := currentIdx + 1; i < len(parsed) && found < count; i++ {
		msgType := getMessageType(parsed[i].Record)
		if msgType == "user" || msgType == "assistant" {
			text := extractText(parsed[i].Record)
			if text != "" {
				context = append(context, ContextItem{
					Index: parsed[i].LineIndex,
					Type:  msgType,
					Text:  text,
				})
				found++
			}
		}
	}

	return context
}

func printMatch(match Match) {
	fmt.Println(strings.Repeat("-", 70))
	fmt.Printf("File: %s | Line: %d | Type: %s\n", match.FileName, match.LineIndex, match.Type)
	fmt.Println(strings.Repeat("-", 70))

	// Print context before
	for _, ctx := range match.ContextBefore {
		preview := truncateAndClean(ctx.Text, 100)
		fmt.Printf("  [%s] %s...\n", ctx.Type, preview)
	}

	// Print the match with highlighting
	text := truncateAndClean(match.Text, 500)
	highlighted := highlightTerm(text, match.SearchTerm)
	fmt.Printf("\n>>> [%s] %s\n", match.Type, highlighted)

	if len(match.Text) > 500 {
		fmt.Printf("    ... (%d chars total)\n", len(match.Text))
	}

	// Print context after
	for _, ctx := range match.ContextAfter {
		preview := truncateAndClean(ctx.Text, 100)
		fmt.Printf("\n  [%s] %s...\n", ctx.Type, preview)
	}

	fmt.Println()
}

func truncateAndClean(text string, maxLen int) string {
	// Replace newlines with spaces
	text = strings.ReplaceAll(text, "\n", " ")
	// Collapse multiple spaces
	text = strings.Join(strings.Fields(text), " ")

	if len(text) > maxLen {
		return text[:maxLen]
	}
	return text
}

func highlightTerm(text, term string) string {
	// Case-insensitive replacement with ** markers
	re := regexp.MustCompile("(?i)" + regexp.QuoteMeta(term))
	return re.ReplaceAllString(text, "**$0**")
}

func printUsage() {
	fmt.Println(`Session Search - Search through Claude Code session files

Usage:
  search_sessions "search term" [options]

Options:
  -all, -a              Search all session files (default: most recent only)
  -file, -f PATH        Search specific file
  -context, -c N        Show N messages of context (default: 1)
  -limit, -l N          Limit results (default: 50)
  -user                 Only search user messages
  -assistant            Only search assistant messages
  -case-sensitive       Case-sensitive search

Examples:
  search_sessions "ArborMind"
  search_sessions "ArborMind" -all -context 2
  search_sessions "error" -assistant -limit 10
  search_sessions "TODO" -user -case-sensitive`)
}
