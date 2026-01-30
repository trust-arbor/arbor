# Arbor Dashboard

Run the following commands to get the current state of the Arbor system, then present a concise orientation summary.

## Commands to run

Run these in order. If a command fails (e.g., server not running), note that in the dashboard rather than stopping.

1. `mix arbor.status` -- Server health and connection state
2. `mix arbor.jobs --status active` -- Currently executing work
3. `mix arbor.jobs --status created` -- Pending work waiting to be picked up
4. `mix arbor.signals --limit 10` -- Recent signal activity
5. `ls .arbor/roadmap/3-in-progress/ 2>/dev/null` -- Work items currently in progress
6. `ls .arbor/roadmap/2-planned/ 2>/dev/null` -- Work items ready to start
7. `mix arbor.hands` -- Active Hands (independent Claude sessions)
8. `git status --short` -- Uncommitted changes

## How to present

Format the results as a single dashboard using this structure:

```
## Arbor Dashboard

**Server:** [running/stopped/unreachable] — [uptime or error detail]

**Active Jobs ([count]):**
- [job id] [type] — [description or target] (since [timestamp])
- ...or "None"

**Pending Jobs ([count]):**
- [job id] [type] — [description or target] (created [timestamp])
- ...or "None"

**Recent Signals ([count] shown):**
- [timestamp] [signal type] — [brief summary]
- ...or "No recent signals"

**Roadmap:**
- In Progress: [list filenames without .md extension, or "None"]
- Planned: [list filenames without .md extension, or "None"]

**Hands:** [list active hands with type, or "None"]

**Git:** [summary of uncommitted changes, or "Clean"]

**Needs Attention:**
- [anything that looks stuck, failed, or unusual — or "All clear"]
- [roadmap items in 3-in-progress that may be complete — suggest moving to 5-completed]
- [uncommitted changes that should be committed]
```

## Guidelines

- Keep it concise. One line per item, no extra commentary.
- If the server is not running, say so clearly and skip the jobs/signals commands since they will not work. Still show roadmap, hands, and git status.
- Highlight anything that looks abnormal: jobs stuck for a long time, error signals, server issues.
- Flag roadmap items that may need moving (in-progress items whose work appears done, planned items that are being worked on).
- Note uncommitted changes as a gentle reminder, not an urgent action.
- Do not suggest next steps unless something requires immediate attention.
- This is orientation, not analysis. Present facts, not opinions.
