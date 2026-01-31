# Arbor Memory

Memory system for the Arbor agent orchestration platform.

## Overview

Arbor Memory provides semantic memory capabilities for AI agents:

- **Index** - ETS-backed vector storage for fast semantic search
- **KnowledgeGraph** - Semantic network with decay and reinforcement
- **Signals** - Transient operational notifications
- **Events** - Permanent history records
- **TokenBudget** - Model-agnostic budget allocation

## Quick Start

```elixir
# Initialize memory for an agent
{:ok, _pid} = Arbor.Memory.init_for_agent("agent_001")

# Index content
{:ok, entry_id} = Arbor.Memory.index("agent_001", "Important fact", %{type: :fact})

# Recall similar content
{:ok, results} = Arbor.Memory.recall("agent_001", "fact query")

# Add to knowledge graph
{:ok, node_id} = Arbor.Memory.add_knowledge("agent_001", %{
  type: :fact,
  content: "The sky is blue"
})

# Cleanup when done
:ok = Arbor.Memory.cleanup_for_agent("agent_001")
```

## Phase 1 Features

This is Phase 1 (Foundation) of the memory system:

- [x] Vector index with cosine similarity search
- [x] Per-agent isolation via Registry
- [x] Knowledge graph with nodes and edges
- [x] Relevance decay and reinforcement
- [x] Pending queues for proposal mechanism
- [x] Signal emissions for memory events
- [x] Event logging with dual-emit pattern
- [x] Token budget management

See `.arbor/roadmap/2-planned/memory-system/phase-1-foundation.md` for the full specification.
