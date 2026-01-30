// Memory Management Tool
// Manage Claude's persistent memory files (learnings, reminders, relationships, tasks)
//
// Build: go build -o memory memory.go
//
// Usage:
//   ./memory learn "What you learned"
//   ./memory remind "Reminder text"
//   ./memory moment <person> "Summary" [--salience 0.8] [--markers "tag1,tag2"]
//   ./memory show <person>
//   ./memory list
//   ./memory update <person> <field> "value"
//
// Task tracking:
//   ./memory task add "description" [--context "context"] [--priority high|medium|low]
//   ./memory task list
//   ./memory task start <id>
//   ./memory task done <id>
//   ./memory task note <id> "note"
//   ./memory task show <id>
//   ./memory task drop <id>

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// SelfKnowledge represents the self_knowledge.json structure
type SelfKnowledge struct {
	ID                 string       `json:"id"`
	LastUpdated        string       `json:"last_updated"`
	Capabilities       []Capability `json:"capabilities"`
	Learnings          []Learning   `json:"learnings"`
	Reminders          []string     `json:"reminders"`
	WorkingPreferences []string     `json:"working_preferences"`
}

// Capability represents a tool/skill
type Capability struct {
	Name        string   `json:"name"`
	Description string   `json:"description"`
	Command     string   `json:"command,omitempty"`
	WhenToUse   []string `json:"when_to_use,omitempty"`
	// Allow arbitrary additional fields
	Extra map[string]interface{} `json:"-"`
}

// Learning represents a learned fact
type Learning struct {
	Added   string `json:"added"`
	Content string `json:"content"`
}

// Relationship represents a relationship memory file
type Relationship struct {
	ID                  string       `json:"id"`
	Name                string       `json:"name"`
	PreferredName       string       `json:"preferred_name"`
	FirstEncountered    string       `json:"first_encountered"`
	LastInteraction     string       `json:"last_interaction"`
	AccessCount         int          `json:"access_count"`
	Salience            float64      `json:"salience"`
	RelationshipDynamic string       `json:"relationship_dynamic"`
	Background          []string     `json:"background"`
	Values              []string     `json:"values"`
	CurrentFocus        []string     `json:"current_focus"`
	Connections         []string     `json:"connections"`
	PersonalDetails     []string     `json:"personal_details"`
	Uncertainties       []string     `json:"uncertainties"`
	KeyMoments          []KeyMoment  `json:"key_moments"`
}

// KeyMoment represents a significant interaction
type KeyMoment struct {
	Timestamp        string   `json:"timestamp"`
	Summary          string   `json:"summary"`
	EmotionalMarkers []string `json:"emotional_markers"`
	Salience         float64  `json:"salience"`
}

// Task represents a tracked task
type Task struct {
	ID          string   `json:"id"`
	Description string   `json:"description"`
	Context     string   `json:"context,omitempty"`
	Priority    string   `json:"priority"` // high, medium, low
	Status      string   `json:"status"`   // pending, in_progress, done, dropped
	Notes       []string `json:"notes,omitempty"`
	CreatedAt   string   `json:"created_at"`
	UpdatedAt   string   `json:"updated_at"`
	CompletedAt string   `json:"completed_at,omitempty"`
}

// TaskList represents the tasks.json structure
type TaskList struct {
	LastUpdated string `json:"last_updated"`
	Tasks       []Task `json:"tasks"`
}

var memoryDir string

func init() {
	// Default memory directory at ~/.claude/arbor-personal/memory/
	homeDir, err := os.UserHomeDir()
	if err != nil {
		homeDir = os.Getenv("HOME")
	}
	memoryDir = filepath.Join(homeDir, ".claude", "arbor-personal", "memory")

	// Allow override via environment variable
	if envDir := os.Getenv("CLAUDE_MEMORY_DIR"); envDir != "" {
		memoryDir = envDir
	}
}

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(1)
	}

	command := os.Args[1]

	switch command {
	case "learn":
		cmdLearn(os.Args[2:])
	case "remind":
		cmdRemind(os.Args[2:])
	case "moment":
		cmdMoment(os.Args[2:])
	case "show":
		cmdShow(os.Args[2:])
	case "list":
		cmdList(os.Args[2:])
	case "update":
		cmdUpdate(os.Args[2:])
	case "task", "t":
		cmdTask(os.Args[2:])
	case "help", "-h", "--help":
		printUsage()
	default:
		fmt.Printf("Unknown command: %s\n\n", command)
		printUsage()
		os.Exit(1)
	}
}

// cmdLearn adds a learning to self_knowledge.json
func cmdLearn(args []string) {
	if len(args) < 1 {
		fmt.Println("Usage: memory learn \"What you learned\"")
		os.Exit(1)
	}

	content := strings.Join(args, " ")

	sk, err := loadSelfKnowledge()
	if err != nil {
		fmt.Printf("Error loading self_knowledge.json: %v\n", err)
		os.Exit(1)
	}

	learning := Learning{
		Added:   time.Now().UTC().Format(time.RFC3339),
		Content: content,
	}

	sk.Learnings = append(sk.Learnings, learning)
	sk.LastUpdated = time.Now().UTC().Format(time.RFC3339)

	if err := saveSelfKnowledge(sk); err != nil {
		fmt.Printf("Error saving: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Added learning: %s\n", truncate(content, 60))
}

// cmdRemind adds a reminder to self_knowledge.json
func cmdRemind(args []string) {
	if len(args) < 1 {
		fmt.Println("Usage: memory remind \"Reminder text\"")
		os.Exit(1)
	}

	reminder := strings.Join(args, " ")

	sk, err := loadSelfKnowledge()
	if err != nil {
		fmt.Printf("Error loading self_knowledge.json: %v\n", err)
		os.Exit(1)
	}

	// Check if reminder already exists
	for _, r := range sk.Reminders {
		if r == reminder {
			fmt.Println("Reminder already exists.")
			return
		}
	}

	sk.Reminders = append(sk.Reminders, reminder)
	sk.LastUpdated = time.Now().UTC().Format(time.RFC3339)

	if err := saveSelfKnowledge(sk); err != nil {
		fmt.Printf("Error saving: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Added reminder: %s\n", truncate(reminder, 60))
}

// cmdMoment adds a key moment to a relationship
func cmdMoment(args []string) {
	if len(args) < 2 {
		fmt.Println("Usage: memory moment <person> \"Summary\" [--salience 0.8] [--markers \"tag1,tag2\"]")
		os.Exit(1)
	}

	person := strings.ToLower(args[0])

	// Parse remaining args
	summary := ""
	salience := 0.7 // default
	var markers []string

	i := 1
	for i < len(args) {
		arg := args[i]
		if arg == "--salience" && i+1 < len(args) {
			fmt.Sscanf(args[i+1], "%f", &salience)
			i += 2
		} else if arg == "--markers" && i+1 < len(args) {
			markers = strings.Split(args[i+1], ",")
			for j := range markers {
				markers[j] = strings.TrimSpace(markers[j])
			}
			i += 2
		} else if !strings.HasPrefix(arg, "--") {
			if summary == "" {
				summary = arg
			} else {
				summary += " " + arg
			}
			i++
		} else {
			i++
		}
	}

	if summary == "" {
		fmt.Println("Error: Summary is required")
		os.Exit(1)
	}

	rel, relPath, err := loadRelationship(person)
	if err != nil {
		fmt.Printf("Error loading relationship for '%s': %v\n", person, err)
		os.Exit(1)
	}

	moment := KeyMoment{
		Timestamp:        time.Now().UTC().Format(time.RFC3339),
		Summary:          summary,
		EmotionalMarkers: markers,
		Salience:         salience,
	}

	rel.KeyMoments = append(rel.KeyMoments, moment)
	rel.LastInteraction = time.Now().UTC().Format(time.RFC3339)
	rel.AccessCount++

	if err := saveRelationship(rel, relPath); err != nil {
		fmt.Printf("Error saving: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Added moment to %s: %s\n", rel.PreferredName, truncate(summary, 50))
	if len(markers) > 0 {
		fmt.Printf("  Markers: %s\n", strings.Join(markers, ", "))
	}
	fmt.Printf("  Salience: %.1f\n", salience)
}

// cmdShow displays a relationship summary
func cmdShow(args []string) {
	if len(args) < 1 {
		fmt.Println("Usage: memory show <person>")
		os.Exit(1)
	}

	person := strings.ToLower(args[0])

	rel, _, err := loadRelationship(person)
	if err != nil {
		fmt.Printf("Error loading relationship for '%s': %v\n", person, err)
		os.Exit(1)
	}

	fmt.Printf("\n=== %s ===\n\n", rel.PreferredName)

	fmt.Printf("Relationship: %s\n\n", truncate(rel.RelationshipDynamic, 100))

	if len(rel.CurrentFocus) > 0 {
		fmt.Println("Current Focus:")
		for _, f := range rel.CurrentFocus {
			fmt.Printf("  - %s\n", f)
		}
		fmt.Println()
	}

	if len(rel.Values) > 0 {
		fmt.Println("Values:")
		for _, v := range rel.Values {
			fmt.Printf("  - %s\n", v)
		}
		fmt.Println()
	}

	if len(rel.KeyMoments) > 0 {
		fmt.Println("Recent Key Moments:")
		// Show last 5 moments
		start := len(rel.KeyMoments) - 5
		if start < 0 {
			start = 0
		}
		for _, m := range rel.KeyMoments[start:] {
			markers := ""
			if len(m.EmotionalMarkers) > 0 {
				markers = fmt.Sprintf(" [%s]", strings.Join(m.EmotionalMarkers, ", "))
			}
			fmt.Printf("  - %s%s\n", truncate(m.Summary, 70), markers)
		}
		fmt.Println()
	}

	fmt.Printf("First encountered: %s\n", formatTime(rel.FirstEncountered))
	fmt.Printf("Last interaction: %s\n", formatTime(rel.LastInteraction))
	fmt.Printf("Access count: %d\n", rel.AccessCount)
}

// cmdList lists all relationships
func cmdList(args []string) {
	files, err := filepath.Glob(filepath.Join(memoryDir, "rel_*.json"))
	if err != nil {
		fmt.Printf("Error listing relationships: %v\n", err)
		os.Exit(1)
	}

	if len(files) == 0 {
		fmt.Println("No relationships found.")
		return
	}

	fmt.Printf("\n=== Relationships (%d) ===\n\n", len(files))

	type relSummary struct {
		name            string
		lastInteraction time.Time
		moments         int
	}

	var summaries []relSummary

	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			continue
		}

		var rel Relationship
		if err := json.Unmarshal(data, &rel); err != nil {
			continue
		}

		lastTime, _ := time.Parse(time.RFC3339, rel.LastInteraction)
		summaries = append(summaries, relSummary{
			name:            rel.PreferredName,
			lastInteraction: lastTime,
			moments:         len(rel.KeyMoments),
		})
	}

	// Sort by last interaction (most recent first)
	sort.Slice(summaries, func(i, j int) bool {
		return summaries[i].lastInteraction.After(summaries[j].lastInteraction)
	})

	for _, s := range summaries {
		fmt.Printf("  %-15s  %d moments  (last: %s)\n",
			s.name,
			s.moments,
			formatTimeShort(s.lastInteraction),
		)
	}
	fmt.Println()
}

// cmdUpdate updates a field in a relationship
func cmdUpdate(args []string) {
	if len(args) < 3 {
		fmt.Println("Usage: memory update <person> <field> \"value\"")
		fmt.Println("Fields: current_focus, background, values, connections, personal_details, uncertainties, relationship_dynamic")
		os.Exit(1)
	}

	person := strings.ToLower(args[0])
	field := strings.ToLower(args[1])
	value := strings.Join(args[2:], " ")

	rel, relPath, err := loadRelationship(person)
	if err != nil {
		fmt.Printf("Error loading relationship for '%s': %v\n", person, err)
		os.Exit(1)
	}

	// Update the appropriate field
	switch field {
	case "current_focus":
		rel.CurrentFocus = append(rel.CurrentFocus, value)
	case "background":
		rel.Background = append(rel.Background, value)
	case "values":
		rel.Values = append(rel.Values, value)
	case "connections":
		rel.Connections = append(rel.Connections, value)
	case "personal_details":
		rel.PersonalDetails = append(rel.PersonalDetails, value)
	case "uncertainties":
		rel.Uncertainties = append(rel.Uncertainties, value)
	case "relationship_dynamic":
		rel.RelationshipDynamic = value
	default:
		fmt.Printf("Unknown field: %s\n", field)
		fmt.Println("Valid fields: current_focus, background, values, connections, personal_details, uncertainties, relationship_dynamic")
		os.Exit(1)
	}

	rel.LastInteraction = time.Now().UTC().Format(time.RFC3339)

	if err := saveRelationship(rel, relPath); err != nil {
		fmt.Printf("Error saving: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Updated %s.%s: %s\n", rel.PreferredName, field, truncate(value, 50))
}

// cmdTask handles task subcommands
func cmdTask(args []string) {
	if len(args) < 1 {
		printTaskUsage()
		os.Exit(1)
	}

	subcommand := args[0]

	switch subcommand {
	case "add", "a":
		cmdTaskAdd(args[1:])
	case "list", "ls", "l":
		cmdTaskList(args[1:])
	case "start", "s":
		cmdTaskStart(args[1:])
	case "done", "d":
		cmdTaskDone(args[1:])
	case "note", "n":
		cmdTaskNote(args[1:])
	case "show":
		cmdTaskShow(args[1:])
	case "drop", "x":
		cmdTaskDrop(args[1:])
	case "help", "-h", "--help":
		printTaskUsage()
	default:
		fmt.Printf("Unknown task subcommand: %s\n\n", subcommand)
		printTaskUsage()
		os.Exit(1)
	}
}

// cmdTaskAdd adds a new task
func cmdTaskAdd(args []string) {
	if len(args) < 1 {
		fmt.Println("Usage: memory task add \"description\" [--context \"context\"] [--priority high|medium|low]")
		os.Exit(1)
	}

	// Parse arguments
	description := ""
	context := ""
	priority := "medium"

	i := 0
	for i < len(args) {
		arg := args[i]
		if arg == "--context" && i+1 < len(args) {
			context = args[i+1]
			i += 2
		} else if arg == "--priority" && i+1 < len(args) {
			priority = strings.ToLower(args[i+1])
			if priority != "high" && priority != "medium" && priority != "low" {
				fmt.Printf("Invalid priority: %s (use high, medium, or low)\n", priority)
				os.Exit(1)
			}
			i += 2
		} else if !strings.HasPrefix(arg, "--") {
			if description == "" {
				description = arg
			} else {
				description += " " + arg
			}
			i++
		} else {
			i++
		}
	}

	if description == "" {
		fmt.Println("Error: Description is required")
		os.Exit(1)
	}

	tasks, err := loadTaskList()
	if err != nil {
		fmt.Printf("Error loading tasks: %v\n", err)
		os.Exit(1)
	}

	// Generate ID (simple incrementing)
	maxID := 0
	for _, t := range tasks.Tasks {
		var id int
		fmt.Sscanf(t.ID, "%d", &id)
		if id > maxID {
			maxID = id
		}
	}

	now := time.Now().UTC().Format(time.RFC3339)
	task := Task{
		ID:          fmt.Sprintf("%d", maxID+1),
		Description: description,
		Context:     context,
		Priority:    priority,
		Status:      "pending",
		CreatedAt:   now,
		UpdatedAt:   now,
	}

	tasks.Tasks = append(tasks.Tasks, task)
	tasks.LastUpdated = now

	if err := saveTaskList(tasks); err != nil {
		fmt.Printf("Error saving tasks: %v\n", err)
		os.Exit(1)
	}

	priorityIcon := getPriorityIcon(priority)
	fmt.Printf("Added task #%s: %s %s\n", task.ID, priorityIcon, truncate(description, 50))
	if context != "" {
		fmt.Printf("  Context: %s\n", truncate(context, 60))
	}
}

// cmdTaskList lists tasks
func cmdTaskList(args []string) {
	tasks, err := loadTaskList()
	if err != nil {
		fmt.Printf("Error loading tasks: %v\n", err)
		os.Exit(1)
	}

	// Filter flags
	showAll := false
	showDone := false
	for _, arg := range args {
		if arg == "--all" || arg == "-a" {
			showAll = true
		}
		if arg == "--done" {
			showDone = true
		}
	}

	// Group by status
	var pending, inProgress, done, dropped []Task
	for _, t := range tasks.Tasks {
		switch t.Status {
		case "pending":
			pending = append(pending, t)
		case "in_progress":
			inProgress = append(inProgress, t)
		case "done":
			done = append(done, t)
		case "dropped":
			dropped = append(dropped, t)
		}
	}

	// Sort by priority within each group
	sortByPriority := func(ts []Task) {
		sort.Slice(ts, func(i, j int) bool {
			return priorityOrder(ts[i].Priority) < priorityOrder(ts[j].Priority)
		})
	}
	sortByPriority(pending)
	sortByPriority(inProgress)

	hasContent := false

	// In Progress first
	if len(inProgress) > 0 {
		fmt.Println("\n[In Progress]")
		for _, t := range inProgress {
			printTaskLine(t)
		}
		hasContent = true
	}

	// Pending
	if len(pending) > 0 {
		fmt.Println("\n[Pending]")
		for _, t := range pending {
			printTaskLine(t)
		}
		hasContent = true
	}

	// Done (only if --done or --all)
	if (showAll || showDone) && len(done) > 0 {
		fmt.Println("\n[Done]")
		// Show last 5 done tasks
		start := len(done) - 5
		if start < 0 || showAll {
			start = 0
		}
		for _, t := range done[start:] {
			printTaskLine(t)
		}
		hasContent = true
	}

	// Dropped (only if --all)
	if showAll && len(dropped) > 0 {
		fmt.Println("\n[Dropped]")
		for _, t := range dropped {
			printTaskLine(t)
		}
		hasContent = true
	}

	if !hasContent {
		fmt.Println("\nNo active tasks. Use 'memory task add' to create one.")
	}

	// Summary
	fmt.Printf("\nTotal: %d in progress, %d pending, %d done\n",
		len(inProgress), len(pending), len(done))
}

// cmdTaskStart marks a task as in progress
func cmdTaskStart(args []string) {
	if len(args) < 1 {
		fmt.Println("Usage: memory task start <id>")
		os.Exit(1)
	}

	taskID := args[0]

	tasks, err := loadTaskList()
	if err != nil {
		fmt.Printf("Error loading tasks: %v\n", err)
		os.Exit(1)
	}

	found := false
	for i, t := range tasks.Tasks {
		if t.ID == taskID {
			if t.Status == "done" || t.Status == "dropped" {
				fmt.Printf("Task #%s is already %s\n", taskID, t.Status)
				os.Exit(1)
			}
			tasks.Tasks[i].Status = "in_progress"
			tasks.Tasks[i].UpdatedAt = time.Now().UTC().Format(time.RFC3339)
			tasks.LastUpdated = tasks.Tasks[i].UpdatedAt
			found = true
			fmt.Printf("Started task #%s: %s\n", taskID, truncate(t.Description, 50))
			break
		}
	}

	if !found {
		fmt.Printf("Task #%s not found\n", taskID)
		os.Exit(1)
	}

	if err := saveTaskList(tasks); err != nil {
		fmt.Printf("Error saving tasks: %v\n", err)
		os.Exit(1)
	}
}

// cmdTaskDone marks a task as completed
func cmdTaskDone(args []string) {
	if len(args) < 1 {
		fmt.Println("Usage: memory task done <id>")
		os.Exit(1)
	}

	taskID := args[0]

	tasks, err := loadTaskList()
	if err != nil {
		fmt.Printf("Error loading tasks: %v\n", err)
		os.Exit(1)
	}

	found := false
	for i, t := range tasks.Tasks {
		if t.ID == taskID {
			now := time.Now().UTC().Format(time.RFC3339)
			tasks.Tasks[i].Status = "done"
			tasks.Tasks[i].UpdatedAt = now
			tasks.Tasks[i].CompletedAt = now
			tasks.LastUpdated = now
			found = true
			fmt.Printf("Completed task #%s: %s\n", taskID, truncate(t.Description, 50))
			break
		}
	}

	if !found {
		fmt.Printf("Task #%s not found\n", taskID)
		os.Exit(1)
	}

	if err := saveTaskList(tasks); err != nil {
		fmt.Printf("Error saving tasks: %v\n", err)
		os.Exit(1)
	}
}

// cmdTaskNote adds a note to a task
func cmdTaskNote(args []string) {
	if len(args) < 2 {
		fmt.Println("Usage: memory task note <id> \"note\"")
		os.Exit(1)
	}

	taskID := args[0]
	note := strings.Join(args[1:], " ")

	tasks, err := loadTaskList()
	if err != nil {
		fmt.Printf("Error loading tasks: %v\n", err)
		os.Exit(1)
	}

	found := false
	for i, t := range tasks.Tasks {
		if t.ID == taskID {
			timestamp := time.Now().UTC().Format("2006-01-02 15:04")
			noteWithTime := fmt.Sprintf("[%s] %s", timestamp, note)
			tasks.Tasks[i].Notes = append(tasks.Tasks[i].Notes, noteWithTime)
			tasks.Tasks[i].UpdatedAt = time.Now().UTC().Format(time.RFC3339)
			tasks.LastUpdated = tasks.Tasks[i].UpdatedAt
			found = true
			fmt.Printf("Added note to task #%s: %s\n", taskID, truncate(note, 50))
			break
		}
	}

	if !found {
		fmt.Printf("Task #%s not found\n", taskID)
		os.Exit(1)
	}

	if err := saveTaskList(tasks); err != nil {
		fmt.Printf("Error saving tasks: %v\n", err)
		os.Exit(1)
	}
}

// cmdTaskShow shows details of a specific task
func cmdTaskShow(args []string) {
	if len(args) < 1 {
		fmt.Println("Usage: memory task show <id>")
		os.Exit(1)
	}

	taskID := args[0]

	tasks, err := loadTaskList()
	if err != nil {
		fmt.Printf("Error loading tasks: %v\n", err)
		os.Exit(1)
	}

	for _, t := range tasks.Tasks {
		if t.ID == taskID {
			fmt.Printf("\n=== Task #%s ===\n\n", t.ID)
			fmt.Printf("Description: %s\n", t.Description)
			fmt.Printf("Status:      %s\n", t.Status)
			fmt.Printf("Priority:    %s %s\n", getPriorityIcon(t.Priority), t.Priority)
			if t.Context != "" {
				fmt.Printf("Context:     %s\n", t.Context)
			}
			fmt.Printf("Created:     %s\n", formatTime(t.CreatedAt))
			fmt.Printf("Updated:     %s\n", formatTime(t.UpdatedAt))
			if t.CompletedAt != "" {
				fmt.Printf("Completed:   %s\n", formatTime(t.CompletedAt))
			}
			if len(t.Notes) > 0 {
				fmt.Println("\nNotes:")
				for _, n := range t.Notes {
					fmt.Printf("  - %s\n", n)
				}
			}
			fmt.Println()
			return
		}
	}

	fmt.Printf("Task #%s not found\n", taskID)
	os.Exit(1)
}

// cmdTaskDrop marks a task as dropped
func cmdTaskDrop(args []string) {
	if len(args) < 1 {
		fmt.Println("Usage: memory task drop <id>")
		os.Exit(1)
	}

	taskID := args[0]

	tasks, err := loadTaskList()
	if err != nil {
		fmt.Printf("Error loading tasks: %v\n", err)
		os.Exit(1)
	}

	found := false
	for i, t := range tasks.Tasks {
		if t.ID == taskID {
			tasks.Tasks[i].Status = "dropped"
			tasks.Tasks[i].UpdatedAt = time.Now().UTC().Format(time.RFC3339)
			tasks.LastUpdated = tasks.Tasks[i].UpdatedAt
			found = true
			fmt.Printf("Dropped task #%s: %s\n", taskID, truncate(t.Description, 50))
			break
		}
	}

	if !found {
		fmt.Printf("Task #%s not found\n", taskID)
		os.Exit(1)
	}

	if err := saveTaskList(tasks); err != nil {
		fmt.Printf("Error saving tasks: %v\n", err)
		os.Exit(1)
	}
}

// loadTaskList loads the tasks.json file
func loadTaskList() (*TaskList, error) {
	path := filepath.Join(memoryDir, "tasks.json")

	// Create empty task list if file doesn't exist
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return &TaskList{
			LastUpdated: time.Now().UTC().Format(time.RFC3339),
			Tasks:       []Task{},
		}, nil
	}

	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	var tl TaskList
	if err := json.Unmarshal(data, &tl); err != nil {
		return nil, err
	}

	return &tl, nil
}

// saveTaskList saves the tasks.json file
func saveTaskList(tl *TaskList) error {
	path := filepath.Join(memoryDir, "tasks.json")

	data, err := json.MarshalIndent(tl, "", "  ")
	if err != nil {
		return err
	}

	return os.WriteFile(path, data, 0644)
}

// getPriorityIcon returns an icon for priority level
func getPriorityIcon(priority string) string {
	switch priority {
	case "high":
		return "!"
	case "low":
		return "-"
	default:
		return " "
	}
}

// priorityOrder returns sort order for priority
func priorityOrder(priority string) int {
	switch priority {
	case "high":
		return 0
	case "medium":
		return 1
	case "low":
		return 2
	default:
		return 3
	}
}

// printTaskLine prints a single task in list format
func printTaskLine(t Task) {
	icon := getPriorityIcon(t.Priority)
	status := ""
	switch t.Status {
	case "in_progress":
		status = "*"
	case "done":
		status = "+"
	case "dropped":
		status = "x"
	}
	fmt.Printf("  %s#%-3s %s %s\n", status, t.ID, icon, truncate(t.Description, 60))
}

// printTaskUsage prints task command help
func printTaskUsage() {
	fmt.Println(`Task - Track persistent tasks across sessions

Usage:
  memory task <subcommand> [arguments]

Subcommands:
  add, a     Add a new task
  list, ls   List tasks (default: active only)
  start, s   Mark a task as in progress
  done, d    Mark a task as completed
  note, n    Add a note to a task
  show       Show task details
  drop, x    Drop a task (won't do)

Examples:
  memory task add "Implement context retrieval" --priority high
  memory task add "Fix bug in auth" --context "Users reporting 401 errors"
  memory task list
  memory task list --all
  memory task start 1
  memory task note 1 "Found the root cause"
  memory task done 1
  memory task show 1

Priorities: high, medium (default), low
Statuses: pending, in_progress, done, dropped`)
}

// loadSelfKnowledge loads the self_knowledge.json file
func loadSelfKnowledge() (*SelfKnowledge, error) {
	path := filepath.Join(memoryDir, "self_knowledge.json")

	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	var sk SelfKnowledge
	if err := json.Unmarshal(data, &sk); err != nil {
		return nil, err
	}

	return &sk, nil
}

// saveSelfKnowledge saves the self_knowledge.json file
func saveSelfKnowledge(sk *SelfKnowledge) error {
	path := filepath.Join(memoryDir, "self_knowledge.json")

	data, err := json.MarshalIndent(sk, "", "  ")
	if err != nil {
		return err
	}

	return os.WriteFile(path, data, 0644)
}

// loadRelationship loads a relationship file by person name
func loadRelationship(person string) (*Relationship, string, error) {
	files, err := filepath.Glob(filepath.Join(memoryDir, "rel_*.json"))
	if err != nil {
		return nil, "", err
	}

	person = strings.ToLower(person)

	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			continue
		}

		var rel Relationship
		if err := json.Unmarshal(data, &rel); err != nil {
			continue
		}

		// Match by name or preferred name (case insensitive)
		if strings.ToLower(rel.Name) == person ||
		   strings.ToLower(rel.PreferredName) == person ||
		   strings.Contains(strings.ToLower(f), person) {
			return &rel, f, nil
		}
	}

	return nil, "", fmt.Errorf("no relationship found for '%s'", person)
}

// saveRelationship saves a relationship file
func saveRelationship(rel *Relationship, path string) error {
	data, err := json.MarshalIndent(rel, "", "  ")
	if err != nil {
		return err
	}

	return os.WriteFile(path, data, 0644)
}

// truncate shortens a string to maxLen
func truncate(s string, maxLen int) string {
	s = strings.ReplaceAll(s, "\n", " ")
	if len(s) > maxLen {
		return s[:maxLen-3] + "..."
	}
	return s
}

// formatTime formats an RFC3339 timestamp nicely
func formatTime(ts string) string {
	t, err := time.Parse(time.RFC3339, ts)
	if err != nil {
		return ts
	}
	return t.Format("2006-01-02 15:04")
}

// formatTimeShort formats a time.Time briefly
func formatTimeShort(t time.Time) string {
	if t.IsZero() {
		return "never"
	}

	now := time.Now()
	diff := now.Sub(t)

	if diff < 24*time.Hour {
		return "today"
	} else if diff < 48*time.Hour {
		return "yesterday"
	} else if diff < 7*24*time.Hour {
		return fmt.Sprintf("%d days ago", int(diff.Hours()/24))
	}
	return t.Format("Jan 2")
}

func printUsage() {
	fmt.Println(`Memory - Manage Claude's persistent memory

Usage:
  memory <command> [arguments]

Commands:
  learn    Add a learning to self_knowledge.json
  remind   Add a reminder to self_knowledge.json
  moment   Add a key moment to a relationship
  show     Display a relationship summary
  list     List all relationships
  update   Update a field in a relationship
  task, t  Track tasks across sessions (see: memory task help)

Examples:
  memory learn "When renaming modules in Elixir, clean _build first"
  memory remind "Check session history when unsure about past decisions"
  memory moment alice "Discussed philosophy of peers vs hierarchy" --salience 0.8 --markers "philosophical,meaningful"
  memory show alice
  memory list
  memory update alice current_focus "Working on memory CLI tools"

Task Examples:
  memory task add "Implement semantic search" --priority high
  memory task list
  memory task start 1
  memory task done 1

Environment:
  CLAUDE_MEMORY_DIR  Override the default memory directory`)
}
