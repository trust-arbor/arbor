defmodule Arbor.Agent.Capabilities do
  @moduledoc """
  Capability taxonomy for the Mind/Host cognitive loop.

  Maps `{capability, op}` pairs to action modules, providing the stable
  interface between Mind (LLM reasoning) and Host (action execution).

  ## Three Categories

  - **Physical**: Side effects in the external world. Routed to Host, one per action cycle.
  - **Mental**: Internal state changes only. No Host routing, unlimited per cycle.
  - **Host-only**: Infrastructure actions the Mind never sees.

  ## Progressive Disclosure

  Capability descriptions at three verbosity levels for token-efficient prompts:

  - Level 0: Just capability names (~30 tokens)
  - Level 1: Names + operations (~100 tokens)
  - Level 2: Full details with params (~200+ tokens per capability)
  """

  @type category :: :physical | :mental | :host_only

  @type resolution ::
          {:action, module()}
          | {:mental, atom()}
          | {:host_only, module() | atom()}

  # ── Physical Capabilities ────────────────────────────────────────────
  # External world side effects. Routed to Host, one per action cycle.

  @physical_capabilities %{
    # fs — File System
    {"fs", :read} => Arbor.Actions.File.Read,
    {"fs", :write} => Arbor.Actions.File.Write,
    {"fs", :edit} => Arbor.Actions.File.Edit,
    {"fs", :list} => Arbor.Actions.File.List,
    {"fs", :glob} => Arbor.Actions.File.Glob,
    {"fs", :search} => Arbor.Actions.File.Search,
    {"fs", :exists} => Arbor.Actions.File.Exists,
    # shell — Command Execution
    {"shell", :execute} => Arbor.Actions.Shell.Execute,
    {"shell", :script} => Arbor.Actions.Shell.ExecuteScript,
    # code — Code Operations
    {"code", :compile} => Arbor.Actions.Code.CompileAndTest,
    {"code", :test} => Arbor.Actions.Code.CompileAndTest,
    {"code", :hot_load} => Arbor.Actions.Code.HotLoad,
    {"code", :analyze} => Arbor.Actions.AI.AnalyzeCode,
    # git — Version Control
    {"git", :status} => Arbor.Actions.Git.Status,
    {"git", :diff} => Arbor.Actions.Git.Diff,
    {"git", :log} => Arbor.Actions.Git.Log,
    {"git", :commit} => Arbor.Actions.Git.Commit,
    # comms — Communication
    {"comms", :send} => Arbor.Actions.Comms.SendMessage,
    {"comms", :poll} => Arbor.Actions.Comms.PollMessages,
    # council — Advisory Council
    {"council", :consult} => Arbor.Actions.Council.Consult,
    {"council", :consult_one} => Arbor.Actions.Council.ConsultOne,
    {"council", :propose} => Arbor.Actions.Proposal.Submit,
    {"council", :revise} => Arbor.Actions.Proposal.Revise,
    # pipeline — DOT Orchestrator
    {"pipeline", :run} => Arbor.Actions.Pipeline.Run,
    {"pipeline", :validate} => Arbor.Actions.Pipeline.Validate,
    {"pipeline", :compile_skill} => Arbor.Actions.Skill.Compile,
    # identity — Cryptographic Identity (side effects)
    {"identity", :sign} => Arbor.Actions.Identity.SignPublicKey,
    {"identity", :endorse} => Arbor.Actions.Identity.RequestEndorsement,
    # web — Web Interaction
    {"web", :browse} => Arbor.Actions.Web.Browse,
    {"web", :search} => Arbor.Actions.Web.Search,
    {"web", :snapshot} => Arbor.Actions.Web.Snapshot,
    # historian — Event Log Queries
    {"historian", :query} => Arbor.Actions.Historian.QueryEvents,
    {"historian", :causality} => Arbor.Actions.Historian.CausalityTree,
    {"historian", :reconstruct} => Arbor.Actions.Historian.ReconstructState,
    {"historian", :taint_trace} => Arbor.Actions.Historian.TaintTrace,
    # judge — Quality Evaluation (calls LLM)
    {"judge", :evaluate} => Arbor.Actions.Judge.Evaluate,
    {"judge", :quick} => Arbor.Actions.Judge.Quick,
    # acp — ACP Coding Agent Sessions
    {"acp", :start_session} => Arbor.Actions.Acp.StartSession,
    {"acp", :send_message} => Arbor.Actions.Acp.SendMessage,
    {"acp", :session_status} => Arbor.Actions.Acp.SessionStatus,
    {"acp", :close_session} => Arbor.Actions.Acp.CloseSession
  }

  # ── Mental Capabilities (Action-backed) ──────────────────────────────
  # Mind-only operations that have corresponding action modules.
  # No Host routing, unlimited per cycle.

  @mental_action_capabilities %{
    # memory — Core Memory Operations
    {"memory", :recall} => Arbor.Actions.Memory.Recall,
    {"memory", :remember} => Arbor.Actions.Memory.Remember,
    {"memory", :connect} => Arbor.Actions.Memory.Connect,
    {"memory", :reflect} => Arbor.Actions.Memory.Reflect,
    {"memory", :pin} => Arbor.Actions.MemoryCognitive.PinMemory,
    {"memory", :adjust_preferences} => Arbor.Actions.MemoryCognitive.AdjustPreference,
    {"memory", :read_self} => Arbor.Actions.MemoryIdentity.ReadSelf,
    {"memory", :add_insight} => Arbor.Actions.MemoryIdentity.AddInsight,
    # proposal — Review Proposals (Mind reviews queued suggestions)
    {"proposal", :review_queue} => Arbor.Actions.MemoryReview.ReviewQueue,
    {"proposal", :review_suggestions} => Arbor.Actions.MemoryReview.ReviewSuggestions,
    # docs — Documentation Lookup
    {"docs", :lookup} => Arbor.Actions.Docs.Lookup
  }

  # ── Mental Capabilities (Store-backed) ───────────────────────────────
  # Mind-only operations dispatched directly to memory stores.
  # Phase 2 will implement the actual handlers.

  @mental_handler_capabilities %{
    # goal — Goal Management (GoalStore)
    {"goal", :add} => :goal_add,
    {"goal", :update} => :goal_update,
    {"goal", :list} => :goal_list,
    {"goal", :assess} => :goal_assess,
    # plan — Working Plan (IntentStore)
    {"plan", :add} => :plan_add,
    {"plan", :list} => :plan_list,
    {"plan", :update} => :plan_update,
    {"plan", :assess} => :plan_assess,
    # proposal — Review decisions (store-backed mental handlers)
    {"proposal", :list} => :proposal_list,
    {"proposal", :accept} => :proposal_accept,
    {"proposal", :reject} => :proposal_reject,
    {"proposal", :defer} => :proposal_defer,
    # compute — Dune Sandbox
    {"compute", :run} => :compute_run,
    # think — Reasoning & Self-Examination
    {"think", :reflect} => :think_reflect,
    {"think", :observe} => :think_observe,
    {"think", :describe} => :think_describe,
    {"think", :introspect} => :think_introspect
  }

  # ── Host-Only Capabilities ───────────────────────────────────────────
  # Infrastructure actions the Mind never sees.

  @host_only_capabilities %{
    {"memory_consolidate", :run} => :memory_consolidate_run,
    {"sandbox", :create} => Arbor.Actions.Sandbox.Create,
    {"sandbox", :destroy} => Arbor.Actions.Sandbox.Destroy,
    {"background_checks", :run} => Arbor.Actions.BackgroundChecks.Run,
    {"monitor", :read} => Arbor.Actions.Monitor.Read,
    {"eval", :check} => Arbor.Actions.Eval.Check,
    {"eval", :list_runs} => Arbor.Actions.Eval.ListRuns,
    {"eval", :get_run} => Arbor.Actions.Eval.GetRun,
    {"skill", :search} => Arbor.Actions.Skill.Search,
    {"skill", :activate} => Arbor.Actions.Skill.Activate,
    {"skill", :deactivate} => Arbor.Actions.Skill.Deactivate,
    {"skill", :list_active} => Arbor.Actions.Skill.ListActive,
    {"skill", :import} => Arbor.Actions.Skill.Import,
    {"memory_code", :store} => Arbor.Actions.MemoryCode.StoreCode,
    {"memory_code", :list} => Arbor.Actions.MemoryCode.ListCode,
    {"memory_code", :delete} => Arbor.Actions.MemoryCode.DeleteCode,
    {"memory_code", :view} => Arbor.Actions.MemoryCode.ViewCode
  }

  # ── Combined Lookup Map ──────────────────────────────────────────────

  @all_capabilities Map.new(@physical_capabilities, fn {k, v} -> {k, {:action, v}} end)
                    |> Map.merge(
                      Map.new(@mental_action_capabilities, fn {k, v} -> {k, {:action, v}} end)
                    )
                    |> Map.merge(
                      Map.new(@mental_handler_capabilities, fn {k, v} -> {k, {:mental, v}} end)
                    )
                    |> Map.merge(
                      Map.new(@host_only_capabilities, fn {k, v} -> {k, {:host_only, v}} end)
                    )

  @physical_names @physical_capabilities |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
  @mental_names (Map.keys(@mental_action_capabilities) ++ Map.keys(@mental_handler_capabilities))
                |> Enum.map(&elem(&1, 0))
                |> Enum.uniq()
  @host_only_names @host_only_capabilities |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

  # ── Resolution API ──────────────────────────────────────────────────

  @doc """
  Resolve a capability/op pair to its action module or handler.

  Returns `{:ok, {:action, module}}` for action-backed capabilities,
  `{:ok, {:mental, handler_atom}}` for store-backed mental capabilities,
  `{:ok, {:host_only, module_or_atom}}` for host-only capabilities,
  or `{:error, :unknown_capability}`.

  ## Examples

      iex> Arbor.Agent.Capabilities.resolve("fs", :read)
      {:ok, {:action, Arbor.Actions.File.Read}}

      iex> Arbor.Agent.Capabilities.resolve("goal", :add)
      {:ok, {:mental, :goal_add}}

      iex> Arbor.Agent.Capabilities.resolve("nope", :nope)
      {:error, :unknown_capability}
  """
  @spec resolve(String.t(), atom()) :: {:ok, resolution()} | {:error, :unknown_capability}
  def resolve(capability, op) when is_binary(capability) and is_atom(op) do
    case Map.get(@all_capabilities, {capability, op}) do
      nil -> {:error, :unknown_capability}
      resolution -> {:ok, resolution}
    end
  end

  @doc """
  Resolve directly to an action module (for physical and action-backed mental ops).

  Returns `{:ok, module}` or `{:error, reason}`.
  """
  @spec resolve_action(String.t(), atom()) :: {:ok, module()} | {:error, atom()}
  def resolve_action(capability, op) do
    case resolve(capability, op) do
      {:ok, {:action, module}} -> {:ok, module}
      {:ok, {:mental, _}} -> {:error, :mental_not_action}
      {:ok, {:host_only, _}} -> {:error, :host_only}
      {:error, _} = err -> err
    end
  end

  # ── Classification API ──────────────────────────────────────────────

  @doc "Returns true if the capability is physical (routed to Host)."
  @spec physical?(String.t()) :: boolean()
  def physical?(capability), do: capability in @physical_names

  @doc "Returns true if the capability is mental (Mind-only)."
  @spec mental?(String.t()) :: boolean()
  def mental?(capability), do: capability in @mental_names

  @doc "Returns true if the capability is host-only (Mind never sees)."
  @spec host_only?(String.t()) :: boolean()
  def host_only?(capability), do: capability in @host_only_names

  @doc "Returns the category of a capability."
  @spec category(String.t()) :: category() | nil
  def category(capability) do
    cond do
      physical?(capability) -> :physical
      mental?(capability) -> :mental
      host_only?(capability) -> :host_only
      true -> nil
    end
  end

  # ── Discovery API ──────────────────────────────────────────────────

  @doc "List all capability names visible to the Mind (physical + mental)."
  @spec mind_capabilities() :: [String.t()]
  def mind_capabilities, do: Enum.sort(@physical_names ++ @mental_names)

  @doc "List all physical capability names."
  @spec physical_capabilities() :: [String.t()]
  def physical_capabilities, do: Enum.sort(@physical_names)

  @doc "List all mental capability names."
  @spec mental_capabilities() :: [String.t()]
  def mental_capabilities, do: Enum.sort(@mental_names)

  @doc "List all capability names (including host-only)."
  @spec all_capability_names() :: [String.t()]
  def all_capability_names, do: Enum.sort(@physical_names ++ @mental_names ++ @host_only_names)

  @doc "List all operations for a capability."
  @spec ops(String.t()) :: [atom()]
  def ops(capability) do
    @all_capabilities
    |> Map.keys()
    |> Enum.filter(fn {cap, _op} -> cap == capability end)
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort()
  end

  @doc "Return the total number of capability/op pairs."
  @spec count() :: non_neg_integer()
  def count, do: map_size(@all_capabilities)

  # ── Progressive Disclosure ──────────────────────────────────────────

  @descriptions %{
    "fs" => %{
      name: "File System",
      summary: "Read, write, and search files",
      ops: %{
        read: "Read file contents (path)",
        write: "Write content to file (path, content)",
        edit: "Replace text in file (path, old_string, new_string)",
        list: "List directory contents (path)",
        glob: "Find files by pattern (pattern)",
        search: "Search file contents (pattern, path)",
        exists: "Check if path exists (path)"
      }
    },
    "shell" => %{
      name: "Shell",
      summary: "Execute commands",
      ops: %{
        execute: "Run shell command (command)",
        script: "Run multi-line script (script)"
      }
    },
    "code" => %{
      name: "Code",
      summary: "Compile, test, and analyze code",
      ops: %{
        compile: "Compile and test in worktree (path)",
        test: "Run tests in worktree (path)",
        hot_load: "Hot-load module with rollback (module)",
        analyze: "Analyze code with LLM (code, question)"
      }
    },
    "git" => %{
      name: "Git",
      summary: "Version control operations",
      ops: %{
        status: "Repository status (path)",
        diff: "Show changes (path, ref)",
        log: "Commit history (path, limit)",
        commit: "Create commit (path, message)"
      }
    },
    "comms" => %{
      name: "Communications",
      summary: "Send and receive messages",
      ops: %{
        send: "Send message (channel, message)",
        poll: "Poll for messages (channel)"
      }
    },
    "council" => %{
      name: "Advisory Council",
      summary: "Consult perspectives and submit proposals",
      ops: %{
        consult: "Query all perspectives (question)",
        consult_one: "Query single perspective (perspective, question)",
        propose: "Submit proposal (title, description)",
        revise: "Resubmit after feedback (proposal_id, changes)"
      }
    },
    "pipeline" => %{
      name: "Pipeline",
      summary: "Run and validate DOT pipelines",
      ops: %{
        run: "Execute pipeline (dot_source)",
        validate: "Validate without executing (dot_source)",
        compile_skill: "Compile skill to DOT (skill_name)"
      }
    },
    "identity" => %{
      name: "Identity",
      summary: "Cryptographic identity operations",
      ops: %{
        sign: "Sign another agent's key (target_key)",
        endorse: "Request endorsement (target_agent)"
      }
    },
    "web" => %{
      name: "Web",
      summary: "Browse, search, and snapshot web pages",
      ops: %{
        browse: "Navigate to URL (url)",
        search: "Web search (query)",
        snapshot: "Capture page snapshot (url)"
      }
    },
    "historian" => %{
      name: "Historian",
      summary: "Query event logs and trace causality",
      ops: %{
        query: "Query events (filters)",
        causality: "Build causal chain (event_id)",
        reconstruct: "State at point in time (timestamp)",
        taint_trace: "Trace taint provenance (record_id)"
      }
    },
    "judge" => %{
      name: "Judge",
      summary: "Evaluate quality with LLM-as-judge",
      ops: %{
        evaluate: "Full evaluation (content, rubric)",
        quick: "Quick quality check (content)"
      }
    },
    "acp" => %{
      name: "ACP",
      summary: "Manage coding agent sessions",
      ops: %{
        start_session: "Start new coding session (task)",
        send_message: "Send message to session (session_id, message)",
        session_status: "Check session status (session_id)",
        close_session: "Close session (session_id)"
      }
    },
    "delegate" => %{
      name: "Delegate",
      summary: "Execute via CLI agent",
      ops: %{
        execute: "Run prompt through CLI agent (prompt, provider)"
      }
    },
    "memory" => %{
      name: "Memory",
      summary: "Store, retrieve, and manage knowledge",
      ops: %{
        recall: "Semantic search retrieval (query)",
        remember: "Store in knowledge graph (content, type)",
        connect: "Link two knowledge nodes (from, to, relation)",
        reflect: "Review memories and graph stats",
        pin: "Pin memory from decay (memory_id)",
        adjust_preferences: "Adjust cognitive preferences (setting, value)",
        read_self: "Read self-knowledge (category)",
        add_insight: "Record self-insight (content, type)"
      }
    },
    "goal" => %{
      name: "Goals",
      summary: "Manage objectives and track progress",
      ops: %{
        add: "Create new goal (description, priority)",
        update: "Update goal state (goal_id, changes)",
        list: "List current goals",
        assess: "Assess goal progress (goal_id)"
      }
    },
    "plan" => %{
      name: "Plan",
      summary: "Manage working plan (intents)",
      ops: %{
        add: "Add intent to plan (description, target)",
        list: "List pending intentions",
        update: "Update intent (intent_id, changes)",
        assess: "Assess plan coherence"
      }
    },
    "proposal" => %{
      name: "Proposals",
      summary: "Review queued suggestions about goals/memories",
      ops: %{
        list: "List pending proposals",
        accept: "Accept suggestion (suggestion_id)",
        reject: "Reject suggestion (suggestion_id)",
        defer: "Defer for later (suggestion_id)",
        review_queue: "Review pending facts/learnings",
        review_suggestions: "Review insight suggestions"
      }
    },
    "compute" => %{
      name: "Compute",
      summary: "Execute code in sandboxed session",
      ops: %{
        run: "Evaluate Elixir expression (code)"
      }
    },
    "think" => %{
      name: "Think",
      summary: "Reason, reflect, and explore capabilities",
      ops: %{
        reflect: "Self-reflection on current state",
        observe: "Notice patterns in context",
        describe: "Explore capability details (capability_name)",
        introspect: "Deep self-examination"
      }
    },
    "docs" => %{
      name: "Documentation",
      summary: "Look up module and function docs",
      ops: %{
        lookup: "Search documentation (query)"
      }
    }
  }

  @doc """
  Get capability description at given verbosity level.

  - Level 0: Just the capability name
  - Level 1: Name + comma-separated operations
  - Level 2: Full details with operation descriptions and params

  ## Examples

      iex> Arbor.Agent.Capabilities.describe("fs", 0)
      "fs"

      iex> Arbor.Agent.Capabilities.describe("fs", 1)
      "fs: edit, exists, glob, list, read, search, write"
  """
  @spec describe(String.t(), 0 | 1 | 2) :: String.t()
  def describe(capability, level \\ 0)

  def describe(capability, 0), do: capability

  def describe(capability, 1) do
    case Map.get(@descriptions, capability) do
      nil -> capability
      info -> "#{capability}: #{info.ops |> Map.keys() |> Enum.sort() |> Enum.join(", ")}"
    end
  end

  def describe(capability, 2) do
    case Map.get(@descriptions, capability) do
      nil ->
        capability

      info ->
        header = "#{capability} (#{info.name}) — #{info.summary}"

        ops =
          info.ops
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map(fn {op, desc} -> "  #{op} — #{desc}" end)

        Enum.join([header | ops], "\n")
    end
  end

  @doc """
  Generate the capability prompt for the Mind at a given verbosity level.

  Includes only Mind-visible capabilities (physical + mental).

  ## Options

  - `:goals` — list of current goals for goal-aware auto-expansion
  - `:only` — `:physical` or `:mental` to filter
  """
  @spec prompt(0 | 1 | 2, keyword()) :: String.t()
  def prompt(level \\ 0, opts \\ []) do
    caps = filter_caps(opts)

    case level do
      0 ->
        names = Enum.join(caps, ", ")
        "Available: #{names}\nUse {think, describe, \"<name>\"} for details."

      1 ->
        Enum.map_join(caps, "\n", &describe(&1, 1))

      2 ->
        Enum.map_join(caps, "\n\n", &describe(&1, 2))
    end
  end

  @doc """
  Generate a goal-aware prompt that auto-expands relevant capabilities.

  Capabilities matching goal keywords get Level 1, others get Level 0.
  """
  @spec goal_aware_prompt(list()) :: String.t()
  def goal_aware_prompt(goals) when is_list(goals) do
    keywords = extract_goal_keywords(goals)
    caps = mind_capabilities()

    lines =
      Enum.map(caps, fn cap ->
        if relevant_to_goals?(cap, keywords) do
          describe(cap, 1)
        else
          cap
        end
      end)

    expanded = Enum.filter(lines, &String.contains?(&1, ":"))
    compact = Enum.reject(lines, &String.contains?(&1, ":"))

    parts = []
    parts = if compact != [], do: parts ++ ["Available: #{Enum.join(compact, ", ")}"], else: parts
    parts = if expanded != [], do: parts ++ expanded, else: parts
    parts = parts ++ ["Use {think, describe, \"<name>\"} for details."]

    Enum.join(parts, "\n")
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp filter_caps(opts) do
    case opts[:only] do
      :physical -> physical_capabilities()
      :mental -> mental_capabilities()
      _ -> mind_capabilities()
    end
  end

  @goal_keywords %{
    "fs" => ~w(file read write edit path directory),
    "shell" => ~w(command execute run shell terminal),
    "code" => ~w(compile test code module function),
    "git" => ~w(git commit branch diff status),
    "comms" => ~w(message send communicate channel),
    "council" => ~w(council consult advise perspective),
    "pipeline" => ~w(pipeline dot graph workflow),
    "identity" => ~w(identity sign key endorse),
    "web" => ~w(web browse search url page),
    "historian" => ~w(event log history causality trace),
    "judge" => ~w(evaluate quality judge grade),
    "delegate" => ~w(delegate cli agent),
    "memory" => ~w(memory remember recall knowledge),
    "goal" => ~w(goal objective target progress),
    "plan" => ~w(plan intent step task),
    "proposal" => ~w(proposal suggest review accept),
    "compute" => ~w(compute eval calculate sandbox),
    "think" => ~w(think reflect observe describe introspect),
    "docs" => ~w(documentation doc lookup module)
  }

  defp extract_goal_keywords(goals) do
    goals
    |> Enum.flat_map(fn
      goal when is_binary(goal) -> String.downcase(goal) |> String.split()
      goal when is_map(goal) -> extract_goal_text(goal)
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp extract_goal_text(goal) do
    text =
      [
        Map.get(goal, :description) || Map.get(goal, "description"),
        Map.get(goal, :title) || Map.get(goal, "title")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    String.downcase(text) |> String.split()
  end

  defp relevant_to_goals?(capability, keywords) do
    cap_keywords = Map.get(@goal_keywords, capability, [])
    Enum.any?(cap_keywords, fn kw -> Enum.any?(keywords, &String.contains?(&1, kw)) end)
  end
end
