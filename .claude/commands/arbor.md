# Arbor Dashboard

Run the following commands to get the current state of the Arbor system, then present a concise orientation summary.

## Commands to run

Run these in order. If a command fails (e.g., server not running), note that in the dashboard rather than stopping.

1. `mix arbor.status` -- Server health and connection state
2. `mix arbor.jobs --status active` -- Currently executing work
3. `mix arbor.jobs --status created` -- Pending work waiting to be picked up
4. `mix arbor.signals --limit 10` -- Recent signal activity

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

**Needs Attention:**
- [anything that looks stuck, failed, or unusual — or "All clear"]
```

## Guidelines

- Keep it concise. One line per item, no extra commentary.
- If the server is not running, say so clearly and skip the jobs/signals commands since they will not work.
- Highlight anything that looks abnormal: jobs stuck for a long time, error signals, server issues.
- Do not suggest next steps unless something requires immediate attention.
- This is orientation, not analysis. Present facts, not opinions.
