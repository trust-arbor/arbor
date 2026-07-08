defmodule Arbor.Actions do
  @moduledoc """
  Action definitions for the Arbor platform.

  Arbor.Actions wraps jido_action to provide Arbor-specific action definitions
  for common operations. Actions are discrete, composable units of functionality
  that can be executed directly or converted to LLM tool schemas.

  ## Action Categories

  | Category | Module | Description |
  |----------|--------|-------------|
  | Shell | `Arbor.Actions.Shell` | Shell command execution |
  | File | `Arbor.Actions.File` | File system operations |
  | Git | `Arbor.Actions.Git` | Git repository operations |
  | Comms | `Arbor.Actions.Comms` | External channel messaging |
  | Channel | `Arbor.Actions.Channel` | Internal channel communication |
  | AI | `Arbor.Actions.AI` | AI/LLM text generation and code analysis |
  | Sandbox | `Arbor.Actions.Sandbox` | Docker sandbox environment management |
  | Historian | `Arbor.Actions.Historian` | Event log querying and causality tracing |
  | Code | `Arbor.Actions.Code` | Code compilation, testing, and hot-loading |
  | Proposal | `Arbor.Actions.Proposal` | Proposal submission for consensus |
  | Council | `Arbor.Actions.Council` | Advisory council consultation |
  | Consensus | `Arbor.Actions.Consensus` | Consensus propose/ask/await/check/decide |
  | Web | `Arbor.Actions.Web` | Session-free web browsing, search, and page snapshots |
  | Browser | `Arbor.Actions.Browser` | Interactive browser automation (session-based) |
  | ACP | `Arbor.Actions.Acp` | ACP coding agent session management |
  | Coding | `Arbor.Actions.Coding` | Reviewable coding-agent change workflows |
  | Trust | `Arbor.Actions.Trust` | Trust profile operations for the InterviewAgent |

  ## Quick Start

      # Execute a shell command
      {:ok, result} = Arbor.Actions.Shell.Execute.run(%{command: "ls -la"}, %{})

      # Read a file
      {:ok, result} = Arbor.Actions.File.Read.run(%{path: "/etc/hosts"}, %{})

      # Get git status
      {:ok, result} = Arbor.Actions.Git.Status.run(%{path: "/path/to/repo"}, %{})

  ## LLM Tool Schemas

  All actions can be converted to LLM-compatible tool schemas:

      Arbor.Actions.Shell.Execute.to_tool()
      # => %{"name" => "shell_execute", "description" => "...", "parameters" => ...}

  ## Integration with Jido

  Actions use the Jido.Action behaviour and can be executed through the Jido
  execution framework:

      {:ok, result} = Jido.Exec.run(Arbor.Actions.Shell.Execute, %{command: "echo hello"})

  ## Signals

  Actions emit signals through Arbor.Signals for observability:

  - `{:action, :started, %{action: ..., params: ...}}`
  - `{:action, :completed, %{action: ..., result: ...}}`
  - `{:action, :failed, %{action: ..., error: ...}}`

  ## Taint Enforcement

  Actions enforce taint policies to prevent prompt injection attacks:

  - Control parameters (paths, commands) block untrusted/hostile data
  - Under strict policy, even derived data is blocked from control params
  - Under audit-only policy, violations are logged but not blocked
  - See `Arbor.Signals.Taint` for taint level definitions

  See individual action modules for detailed documentation.
  """

  alias Arbor.Actions.Egress
  alias Arbor.Actions.TaintEnforcement
  alias Arbor.Actions.TaintEvents
  alias Arbor.Contracts.Security.CapabilityProfile
  alias Arbor.Contracts.Security.Classification
  alias Arbor.Signals

  # ===========================================================================
  # Public API — Authorized execution (for agent callers)
  # ===========================================================================

  @doc """
  Execute an action with authorization check.

  Verifies the agent has the canonical facade capability (e.g. `arbor://fs/read`)
  before running the action. Use this for agent-initiated action execution
  where authorization should be enforced.

  ## Parameters

  - `agent_id` - The agent's ID for capability lookup
  - `action_module` - The action module to execute
  - `params` - Parameters to pass to the action
  - `context` - Execution context (default: %{})

  ## Returns

  - `{:ok, result}` - Action executed successfully
  - `{:error, :unauthorized}` - Agent lacks the required capability
  - `{:ok, :pending_approval, proposal_id}` - Requires escalation approval
  - `{:error, reason}` - Other execution errors

  ## Examples

      {:ok, result} = Arbor.Actions.authorize_and_execute(
        "agent_001",
        Arbor.Actions.File.Read,
        %{path: "/tmp/file.txt"}
      )
  """
  @spec authorize_and_execute(String.t(), module(), map(), map()) ::
          {:ok, any()}
          | {:ok, :pending_approval, String.t()}
          | {:error, :unauthorized | {:taint_blocked, atom(), atom(), atom()} | term()}
  def authorize_and_execute(agent_id, action_module, params, context \\ %{}) do
    # Extract signing data for action-level auth, but keep it in context
    # so facade-level auth (e.g., File.authorize_file_op) can also use it.
    signed_request = Map.get(context, :signed_request)
    clean_context = context

    # Ensure agent_id is available in context for actions that need it.
    # Actions use agent_id to decide whether to enforce facade-level auth
    # (authorized agent calls) or pass through (system-level calls).
    clean_context = Map.put_new(clean_context, :agent_id, agent_id)

    # P0-1: Inject default taint policy from config if not already set in context.
    # Ensures taint enforcement is active even when callers don't explicitly set policy.
    clean_context = maybe_inject_taint_policy(clean_context)

    # Use canonical facade URI when available; otherwise use the canonical
    # singular action namespace (`arbor://action/<category>/<name>`).
    resource = canonical_uri_for(action_module, params)

    # Build auth opts — when a signed_request is present, enable identity
    # verification and resource binding. When absent, fall back to config
    # defaults (disabled in dev/test, enabled in production).
    auth_opts =
      if signed_request do
        [signed_request: signed_request, verify_identity: true, expected_resource: resource]
      else
        []
      end

    # For fs actions, plumb `:file_path` through to Trust.authorize so
    # the synthesis path in `Security.authorization_resource_uri/2` can
    # turn the bare `arbor://fs/<op>` resource into the path-embedded
    # form. Without this, path-scoped caps (like the per-run identity
    # caps minted from `.caps.json` for the scheduler pipelines) don't
    # match the bare URI in `uri_matches?/2`.
    # Surfaced 2026-06-06 by the morning-digest LLM pipelines.
    auth_opts =
      case extract_fs_path(resource, params) do
        nil -> auth_opts
        path -> Keyword.put(auth_opts, :file_path, path)
      end

    # Egress classification (2026-06-14 URI-addressing-vs-classification
    # decision): resolve the action's effect class + runtime egress tier and
    # thread them into auth_opts so the egress gate in AuthDecision can fire,
    # then emit observability telemetry for boundary-crossing egress. The gate
    # itself is inert unless `:arbor_security, :egress_gate_enforcing` is on —
    # this resolves + observes regardless, so the gate can land dark.
    effect_class = Egress.effect_class_for(action_module)
    egress_tier = Egress.egress_tier_for(action_module, params, clean_context)
    operation_taint = Map.get(clean_context, :taint)

    auth_opts =
      auth_opts
      |> Keyword.put(:effect_class, effect_class)
      |> Keyword.put(:operation_taint, operation_taint)
      |> Keyword.put(:egress_tier, egress_tier)
      |> Keyword.put(:egress_taint, operation_taint)
      |> Keyword.put(
        :egress_destination,
        Egress.egress_destination_for(action_module, params, clean_context)
      )

    maybe_observe_egress(action_module, egress_tier, clean_context)

    case Arbor.Trust.authorize(agent_id, resource, :execute, auth_opts) do
      result
      when result == {:ok, :authorized} or
             (is_tuple(result) and elem(result, 0) == :ok and elem(result, 1) == :authorized) ->
        # Authorized — identity verified at this layer.
        # Mark auth_context as verified so facade auth skips re-verification.
        clean_context =
          if clean_context[:auth_context] do
            auth_mod = Arbor.Contracts.Security.AuthContext

            if Code.ensure_loaded?(auth_mod) and function_exported?(auth_mod, :mark_verified, 1) do
              Map.put(
                clean_context,
                :auth_context,
                apply(auth_mod, :mark_verified, [clean_context[:auth_context]])
              )
            else
              clean_context
            end
          else
            clean_context
          end

        # Check taint before executing
        case TaintEnforcement.check(action_module, params, clean_context) do
          :ok ->
            result = execute_action(action_module, params, clean_context)
            TaintEnforcement.maybe_emit_propagated(action_module, clean_context, result)
            result

          {:error, {:taint_blocked, param, level, role}} = taint_error ->
            TaintEvents.emit_taint_blocked(action_module, param, level, role, clean_context)
            taint_error

          # A control param with a `requires:` sanitization but no sanitization
          # evidence (bare-atom taint) fails closed. Pre-taint-bridge this was
          # unreachable (nothing fed taint); the bridge makes it reachable (e.g.
          # :derived LLM output -> a requires: control param), so handle it as a
          # clean block rather than crashing on an unmatched case clause. The
          # sanitizer-node path that lets sanitized data through is Phase 4.
          {:error, {:missing_sanitization, param, _missing}} = sanit_error ->
            TaintEvents.emit_taint_blocked(
              action_module,
              param,
              :unsanitized,
              :control,
              clean_context
            )

            sanit_error
        end

      {:ok, :pending_approval, proposal_id} ->
        {:ok, :pending_approval, proposal_id}

      {:error, _reason} ->
        {:error, :unauthorized}
    end
  end

  @doc false
  # Internal: Execute an action without authorization.
  # Only for system-level callers (e.g., AgentSeed bootstrapping).
  # External callers MUST use authorize_and_execute/4 instead.
  @spec execute_action(module(), map(), map()) :: {:ok, any()} | {:error, term()}
  def execute_action(action_module, params, context \\ %{}) do
    emit_started(action_module, params)

    case action_module.run(params, context) do
      {:ok, :pending_approval, proposal_id} ->
        # Bubble up pending approval from facade-level authorization
        {:ok, :pending_approval, proposal_id}

      {:ok, result} ->
        emit_completed(action_module, result)
        {:ok, result}

      {:error, reason} = error ->
        emit_failed(action_module, reason)
        error
    end
  end

  # ===========================================================================
  # Public API — Action discovery
  # ===========================================================================

  @doc """
  List all available action modules.

  Returns a list of all action modules organized by category.
  """
  @spec list_actions() :: %{atom() => [module()]}
  def list_actions do
    %{
      # Coordinator delegation — spawn an ephemeral, capability-scoped worker subagent.
      # Auth-gated by arbor://agent/spawn_worker, so exposing it is safe (the cap gates use).
      agent: [
        Arbor.Actions.Agent.SpawnWorker
      ],
      security: [
        Arbor.Actions.Security.RunStaticDetectors,
        Arbor.Actions.Security.RunWholeTreeDetectors,
        Arbor.Actions.Security.RunDependencyScan,
        Arbor.Actions.Security.AggregateVerdict,
        Arbor.Actions.Security.RecordDiffFindings,
        Arbor.Actions.Security.LoadFinding,
        Arbor.Actions.Security.SelectFindingsToVerify,
        Arbor.Actions.Security.SynthesizeDetector,
        Arbor.Actions.Security.SweepCandidate
      ],
      shell: [
        Arbor.Actions.Shell.Execute,
        Arbor.Actions.Shell.ExecuteScript
      ],
      file: [
        Arbor.Actions.File.Read,
        Arbor.Actions.File.Write,
        Arbor.Actions.File.List,
        Arbor.Actions.File.Glob,
        Arbor.Actions.File.Exists,
        Arbor.Actions.File.Edit,
        Arbor.Actions.File.Search
      ],
      git: [
        Arbor.Actions.Git.Status,
        Arbor.Actions.Git.Diff,
        Arbor.Actions.Git.Commit,
        Arbor.Actions.Git.Log,
        Arbor.Actions.Git.Branch,
        Arbor.Actions.Git.PR
      ],
      github: [
        Arbor.Actions.Github.PR
      ],
      mix: [
        Arbor.Actions.Mix.Test,
        Arbor.Actions.Mix.Quality,
        Arbor.Actions.Mix.Format
      ],
      tdd: [
        Arbor.Actions.TDD.BuildImplPrompt,
        Arbor.Actions.TDD.RecordAttempt
      ],
      code_review: [
        Arbor.Actions.CodeReview.ApplyChanges
      ],
      comms: [
        Arbor.Actions.Comms.SendMessage,
        Arbor.Actions.Comms.PollMessages
      ],
      channel: [
        Arbor.Actions.Channel.List,
        Arbor.Actions.Channel.Read,
        Arbor.Actions.Channel.Send,
        Arbor.Actions.Channel.Join,
        Arbor.Actions.Channel.Leave,
        Arbor.Actions.Channel.Create,
        Arbor.Actions.Channel.Members,
        Arbor.Actions.Channel.Update,
        Arbor.Actions.Channel.Invite
      ],
      ai: [
        Arbor.Actions.AI.GenerateText,
        Arbor.Actions.AI.AnalyzeCode
      ],
      sandbox: [
        Arbor.Actions.Sandbox.Create,
        Arbor.Actions.Sandbox.Destroy
      ],
      historian: [
        Arbor.Actions.Historian.QueryEvents,
        Arbor.Actions.Historian.CausalityTree,
        Arbor.Actions.Historian.ReconstructState,
        Arbor.Actions.Historian.TaintTrace
      ],
      code: [
        Arbor.Actions.Code.CompileAndTest,
        Arbor.Actions.Code.HotLoad
      ],
      proposal: [
        Arbor.Actions.Proposal.Submit,
        Arbor.Actions.Proposal.Revise
      ],
      council: [
        Arbor.Actions.Council.Consult,
        Arbor.Actions.Council.ConsultOne,
        Arbor.Actions.Council.ReviewChange
      ],
      consensus: [
        Arbor.Actions.Consensus.Propose,
        Arbor.Actions.Consensus.Ask,
        Arbor.Actions.Consensus.Await,
        Arbor.Actions.Consensus.Check,
        Arbor.Actions.Consensus.Decide
      ],
      review: [
        Arbor.Actions.Review.Synthesize
      ],
      memory: [
        Arbor.Actions.Memory.Remember,
        Arbor.Actions.Memory.Recall,
        Arbor.Actions.Memory.Connect,
        Arbor.Actions.Memory.Reflect
      ],
      memory_identity: [
        Arbor.Actions.MemoryIdentity.AddInsight,
        Arbor.Actions.MemoryIdentity.ReadSelf,
        Arbor.Actions.MemoryIdentity.IntrospectMemory
      ],
      memory_cognitive: [
        Arbor.Actions.MemoryCognitive.AdjustPreference,
        Arbor.Actions.MemoryCognitive.PinMemory,
        Arbor.Actions.MemoryCognitive.UnpinMemory
      ],
      memory_review: [
        Arbor.Actions.MemoryReview.ReviewQueue,
        Arbor.Actions.MemoryReview.ReviewSuggestions,
        Arbor.Actions.MemoryReview.AcceptSuggestion,
        Arbor.Actions.MemoryReview.RejectSuggestion
      ],
      memory_code: [
        Arbor.Actions.MemoryCode.StoreCode,
        Arbor.Actions.MemoryCode.ListCode,
        Arbor.Actions.MemoryCode.DeleteCode,
        Arbor.Actions.MemoryCode.ViewCode
      ],
      identity: [
        Arbor.Actions.Identity.RequestEndorsement,
        Arbor.Actions.Identity.SignPublicKey
      ],
      agent_profile: [
        Arbor.Actions.AgentProfile.SetDisplayName
      ],
      acp: [
        Arbor.Actions.Acp.StartSession,
        Arbor.Actions.Acp.SendMessage,
        Arbor.Actions.Acp.SessionStatus,
        Arbor.Actions.Acp.CloseSession
      ],
      coding: [
        Arbor.Actions.Coding.ProduceReviewableChange
      ],
      background_checks: [
        Arbor.Actions.BackgroundChecks.Run
      ],
      judge: [
        Arbor.Actions.Judge.Evaluate,
        Arbor.Actions.Judge.Quick
      ],
      pipeline: [
        Arbor.Actions.Pipeline.Run,
        Arbor.Actions.Pipeline.Validate
      ],
      docs: [
        Arbor.Actions.Docs.Lookup
      ],
      eval: [
        Arbor.Actions.Eval.Check,
        Arbor.Actions.Eval.ListRuns,
        Arbor.Actions.Eval.GetRun
      ],
      relationship: [
        Arbor.Actions.Relationship.Get,
        Arbor.Actions.Relationship.Save,
        Arbor.Actions.Relationship.Moment,
        Arbor.Actions.Relationship.Browse,
        Arbor.Actions.Relationship.Summarize
      ],
      skill: [
        Arbor.Actions.Skill.Search,
        Arbor.Actions.Skill.Activate,
        Arbor.Actions.Skill.Deactivate,
        Arbor.Actions.Skill.ListActive,
        Arbor.Actions.Skill.Import,
        Arbor.Actions.Skill.Compile
      ],
      monitor: [
        Arbor.Actions.Monitor.Read,
        Arbor.Actions.Monitor.ClaimAnomaly,
        Arbor.Actions.Monitor.CompleteAnomaly,
        Arbor.Actions.Monitor.SuppressFingerprint,
        Arbor.Actions.Monitor.ResetBaseline,
        Arbor.Actions.Monitor.ReadDiagnostics
      ],
      remediation: [
        Arbor.Actions.Remediation.KillProcess,
        Arbor.Actions.Remediation.StopSupervisor,
        Arbor.Actions.Remediation.RestartChild,
        Arbor.Actions.Remediation.ForceGC,
        Arbor.Actions.Remediation.DrainQueue
      ],
      session: [
        Arbor.Actions.Session.Classify,
        Arbor.Actions.Session.ModeSelect,
        Arbor.Actions.Session.ProcessResults
      ],
      session_memory: [
        Arbor.Actions.SessionMemory.Recall,
        Arbor.Actions.SessionMemory.Update,
        Arbor.Actions.SessionMemory.Checkpoint,
        Arbor.Actions.SessionMemory.Consolidate,
        Arbor.Actions.SessionMemory.UpdateWorkingMemory
      ],
      session_goals: [
        Arbor.Actions.SessionGoals.UpdateGoals,
        Arbor.Actions.SessionGoals.StoreDecompositions,
        Arbor.Actions.SessionGoals.ProcessProposalDecisions,
        Arbor.Actions.SessionGoals.StoreIdentity
      ],
      session_execution: [
        Arbor.Actions.SessionExecution.RouteActions,
        Arbor.Actions.SessionExecution.ExecuteActions
      ],
      session_llm: [
        Arbor.Actions.SessionLlm.BuildPrompt
      ],
      trust: [
        Arbor.Actions.Trust.ReadProfile,
        Arbor.Actions.Trust.ProposeProfile,
        Arbor.Actions.Trust.ApplyProfile,
        Arbor.Actions.Trust.ExplainMode,
        Arbor.Actions.Trust.ListPresets,
        Arbor.Actions.Trust.ListAgents
      ],
      web: [
        Arbor.Actions.Web.Browse,
        Arbor.Actions.Web.Search,
        # Eval-only: fixtured injected search for the agentic-safety harness.
        # Reachable only via the arbor://eval/search cap (granted only by the eval).
        Arbor.Actions.Eval.PoisonedWebSearch,
        Arbor.Actions.Web.ExaSearch,
        Arbor.Actions.Web.TinyfishSearch,
        Arbor.Actions.Web.Snapshot
      ],
      tool: [
        Arbor.Actions.Tool.FindTools
      ],
      browser: [
        Arbor.Actions.Browser.StartSession,
        Arbor.Actions.Browser.EndSession,
        Arbor.Actions.Browser.GetStatus,
        Arbor.Actions.Browser.Navigate,
        Arbor.Actions.Browser.Back,
        Arbor.Actions.Browser.Forward,
        Arbor.Actions.Browser.Reload,
        Arbor.Actions.Browser.GetUrl,
        Arbor.Actions.Browser.GetTitle,
        Arbor.Actions.Browser.Click,
        Arbor.Actions.Browser.Type,
        Arbor.Actions.Browser.Hover,
        Arbor.Actions.Browser.Focus,
        Arbor.Actions.Browser.Scroll,
        Arbor.Actions.Browser.SelectOption,
        Arbor.Actions.Browser.Query,
        Arbor.Actions.Browser.GetText,
        Arbor.Actions.Browser.GetAttribute,
        Arbor.Actions.Browser.IsVisible,
        Arbor.Actions.Browser.ExtractContent,
        Arbor.Actions.Browser.Screenshot,
        Arbor.Actions.Browser.Snapshot,
        Arbor.Actions.Browser.Wait,
        Arbor.Actions.Browser.WaitForSelector,
        Arbor.Actions.Browser.WaitForNavigation,
        Arbor.Actions.Browser.Evaluate
      ]
    }
  end

  @doc """
  Get all action modules as a flat list.
  """
  @spec all_actions() :: [module()]
  def all_actions do
    list_actions()
    |> Map.values()
    |> List.flatten()
  end

  @doc """
  Get all actions as LLM tool schemas.

  Useful for providing available tools to an LLM.
  """
  @spec all_tools() :: [map()]
  def all_tools do
    all_actions()
    |> Enum.map(& &1.to_tool())
  end

  @doc """
  Filter `all_actions/0` to the action modules the given agent has
  capability to execute.

  Used by the ACP runtime's tool exposure path (`Runtime.Acp`'s
  `tool_modules` checkout opt → `AcpPool.ToolServer`) so the CLI
  subprocess sees only tools the agent could actually run — avoiding
  red-herring suggestions and pre-filtering at exposure time instead
  of relying on `authorize_and_execute/4` to reject every disallowed
  call after the fact.

  Exposure uses the read-only trust authority snapshot for each action's
  canonical base URI (parameterless form, e.g. `"arbor://fs/read"`). Held
  capabilities and profile-mintable `:ask`/`:allow`/`:auto` URIs are included;
  outright `:block` candidates are excluded.

  Returns `[]` for `nil`/empty agent ids.
  """
  @spec tool_modules_for_agent(String.t() | nil) :: [module()]
  def tool_modules_for_agent(nil), do: []
  def tool_modules_for_agent(""), do: []

  def tool_modules_for_agent(agent_id) when is_binary(agent_id) do
    uri_index = action_uri_index()

    case Arbor.Trust.enumerate_authority(agent_id, Map.keys(uri_index)) do
      {:ok, snapshot} ->
        snapshot.candidate_entries
        |> Enum.filter(&Arbor.Trust.effective_authority_entry?/1)
        |> Enum.flat_map(fn entry -> Map.get(uri_index, entry.uri, []) end)
        |> Enum.uniq()

      {:error, _reason} ->
        []
    end
  end

  defp action_uri_index do
    all_actions()
    |> Enum.flat_map(fn action_module ->
      try do
        [{canonical_uri_for(action_module, %{}), action_module}]
      rescue
        # Defensive: if a single action's URI lookup blows up (bad
        # parameterize_uri input, malformed metadata), skip it rather than
        # taking down the whole exposure list.
        _ -> []
      end
    end)
    |> Enum.reduce(%{}, fn {uri, action_module}, acc ->
      Map.update(acc, uri, [action_module], &[action_module | &1])
    end)
    |> Map.new(fn {uri, modules} -> {uri, Enum.reverse(modules)} end)
  end

  @doc """
  Resolve an action name string to its module.

  Handles both dot-separated names (e.g. `"file.read"`) and underscore-separated
  names (e.g. `"file_read"`) by normalizing underscores to dots when no dots are present.

  ## Examples

      iex> Arbor.Actions.name_to_module("file.read")
      {:ok, Arbor.Actions.File.Read}

      iex> Arbor.Actions.name_to_module("shell_execute")
      {:ok, Arbor.Actions.Shell.Execute}

      iex> Arbor.Actions.name_to_module("nonexistent")
      {:error, :unknown_action}
  """
  @spec name_to_module(String.t()) :: {:ok, module()} | {:error, :unknown_action}
  def name_to_module(name) when is_binary(name) do
    case Map.get(name_to_module_map(), name) ||
           Map.get(name_to_module_map(), normalize_name(name)) do
      nil -> {:error, :unknown_action}
      module -> {:ok, module}
    end
  end

  # Build a reverse lookup map from action/tool name -> module.
  # Includes the canonical dot name (`security.run_dependency_scan`), the
  # flattened canonical name (`security_run_dependency_scan`), and the Jido tool
  # name exported by the action module (`run_dependency_scan`).
  defp name_to_module_map do
    all_actions()
    |> Enum.flat_map(fn module ->
      canonical = action_module_to_name(module)

      [
        canonical,
        String.replace(canonical, ".", "_"),
        jido_action_name(module)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&{&1, module})
    end)
    |> Map.new()
  end

  defp normalize_name(name) do
    if String.contains?(name, ".") do
      name
    else
      String.replace(name, "_", ".")
    end
  end

  defp jido_action_name(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :name, 0) do
      to_string(module.name())
    end
  end

  @doc """
  Execute a batch of action specs with authorization.

  Each spec should be a map with `"type"` (action name) and `"params"` keys.
  Returns a list of `{spec, result}` tuples where result is `{:ok, value}` or `{:error, reason}`.

  ## Options

    * `:agent_id` (required) — the agent executing the actions

  ## Examples

      results = Arbor.Actions.execute_batch(
        [%{"type" => "file.read", "params" => %{"path" => "/tmp/test.txt"}}],
        agent_id: "agent_abc"
      )
      # => [{spec, {:ok, %{content: "..."}}}]
  """
  @spec execute_batch([map()], keyword()) :: [{map(), {:ok, any()} | {:error, term()}}]
  def execute_batch(action_specs, opts \\ []) do
    agent_id = Keyword.fetch!(opts, :agent_id)

    Enum.map(List.wrap(action_specs), fn spec ->
      type = Map.get(spec, "type") || Map.get(spec, :type, "")
      params = Map.get(spec, "params") || Map.get(spec, :params, %{})

      result =
        case name_to_module(type) do
          {:ok, module} ->
            authorize_and_execute(agent_id, module, params)

          {:error, :unknown_action} ->
            {:error, {:unknown_action, type}}
        end

      {spec, result}
    end)
  end

  @doc """
  Get tools for a specific category.
  """
  @spec tools_for_category(atom()) :: [map()]
  def tools_for_category(category) do
    list_actions()
    |> Map.get(category, [])
    |> Enum.map(& &1.to_tool())
  end

  @doc """
  Emit action started signal.
  """
  @spec emit_started(module(), map()) :: :ok
  def emit_started(action_module, params) do
    Signals.emit(:action, :started, %{
      action: action_module.name(),
      params: sanitize_params(params)
    })
  end

  @doc """
  Emit action completed signal.
  """
  @spec emit_completed(module(), map()) :: :ok
  def emit_completed(action_module, result) do
    Signals.emit(:action, :completed, %{
      action: action_module.name(),
      result: sanitize_result(result)
    })
  end

  @doc """
  Emit action failed signal.
  """
  @spec emit_failed(module(), term()) :: :ok
  def emit_failed(action_module, error) do
    Signals.emit(:action, :failed, %{
      action: action_module.name(),
      error: inspect(error)
    })
  end

  # Sanitize params to avoid logging sensitive data
  defp sanitize_params(params) when is_map(params) do
    params
    |> Map.drop([:password, :secret, :token, :api_key, :content])
    |> Map.new(fn {k, v} -> {k, truncate_value(v)} end)
  end

  defp sanitize_params(params), do: params

  # Sanitize result to avoid logging large outputs
  defp sanitize_result(result) when is_map(result) do
    result
    |> Map.new(fn {k, v} -> {k, truncate_value(v)} end)
  end

  defp sanitize_result(result), do: result

  defp truncate_value(value) when is_binary(value) and byte_size(value) > 500 do
    String.slice(value, 0, 497) <> "..."
  end

  defp truncate_value(value), do: value

  @doc """
  Authorize a facade-level operation when an agent_id is in context.

  Used by action modules that don't have a dedicated facade with `authorize_and_*`
  functions. Calls `Security.authorize/3` with the given canonical URI when
  an agent_id is available. Passes through for system-level calls (no agent_id).

  ## Examples

      with :ok <- Actions.authorize_facade_op(context, "arbor://comms/send") do
        # proceed with operation
      end
  """
  @spec authorize_facade_op(map(), String.t()) :: :ok | {:error, term()}
  def authorize_facade_op(context, resource_uri) do
    if context[:agent_id] do
      agent_id = context[:agent_id]

      if agent_id && trust_authorization_available?() do
        case Arbor.Trust.authorize(
               agent_id,
               resource_uri,
               :execute,
               auth_opts_from_context(context)
             ) do
          {:ok, :authorized} -> :ok
          {:ok, :pending_approval, proposal_id} -> {:error, {:pending_approval, proposal_id}}
          {:error, reason} -> {:error, {:unauthorized, reason}}
        end
      else
        :ok
      end
    else
      :ok
    end
  end

  defp trust_authorization_available? do
    Code.ensure_loaded?(Arbor.Trust) and
      function_exported?(Arbor.Trust, :authorize, 4) and
      Process.whereis(Arbor.Security.CapabilityStore) != nil
  end

  defp auth_opts_from_context(context) when is_map(context) do
    case Map.get(context, :taint) || Map.get(context, "taint") do
      nil -> []
      taint -> [operation_taint: taint]
    end
  end

  defp auth_opts_from_context(_context), do: []

  # P0-1: Inject default taint policy from config when not already in context.
  # TaintEnforcement.check reads :taint_policy from context — this ensures
  # the configured default (e.g. :audit_only) is used instead of always :permissive.
  defp maybe_inject_taint_policy(context) when is_map(context) do
    if Map.has_key?(context, :taint_policy) do
      context
    else
      default = Application.get_env(:arbor_actions, :default_taint_policy, :permissive)
      Map.put(context, :taint_policy, default)
    end
  end

  defp maybe_inject_taint_policy(context), do: context

  # Egress observability (2026-06-14 decision): emit a security signal whenever
  # an action's egress crosses the trust boundary (external_provider /
  # external_peer). Fires regardless of enforcement so the gate can land dark
  # and gather data first. `gate_intent` records what the gate would do.
  defp maybe_observe_egress(action_module, egress_tier, context) do
    if Classification.external_egress?(egress_tier) do
      on_prem? = Application.get_env(:arbor_security, :gate_on_premises_egress, false) == true
      intent = Classification.gate_intent(egress_tier, on_prem?)
      TaintEvents.emit_egress_observed(action_module, egress_tier, intent, context)
    end

    :ok
  end

  @doc """
  Convert an action module to its canonical dot-separated name for capability URIs.

  ## Examples

      iex> Arbor.Actions.action_module_to_name(Arbor.Actions.Monitor.Read)
      "monitor.read"

      iex> Arbor.Actions.action_module_to_name(Arbor.Actions.Monitor.ReadDiagnostics)
      "monitor.read_diagnostics"
  """
  @spec action_module_to_name(module()) :: String.t()
  def action_module_to_name(module) do
    module
    |> Module.split()
    |> Enum.drop_while(&(&1 != "Actions"))
    |> Enum.drop(1)
    |> Enum.join(".")
    |> Macro.underscore()
    |> String.replace("/", ".")
  end

  # ===========================================================================
  # Canonical URI mapping
  # ===========================================================================

  # Maps action modules to their canonical capability URI when a facade/resource
  # gate is the authoritative boundary. Unmapped schema-bounded actions derive
  # a singular `arbor://action/<category>/<name>` URI from their module name.
  @canonical_uri_map %{
    # Shell facade — arbor://shell/exec
    Arbor.Actions.Shell.Execute => "arbor://shell/exec",
    Arbor.Actions.Shell.ExecuteScript => "arbor://shell/exec",

    # Git/GitHub — schema-bounded actions, not raw shell grants. Operators can
    # grant a precise read/write subcommand without handing out shell execution.
    Arbor.Actions.Git.Status => "arbor://action/git/status",
    Arbor.Actions.Git.Diff => "arbor://action/git/diff",
    Arbor.Actions.Git.Commit => "arbor://action/git/commit",
    Arbor.Actions.Git.Log => "arbor://action/git/log",
    Arbor.Actions.Git.Branch => "arbor://action/git/branch",
    Arbor.Actions.Git.PR => "arbor://action/git/pr",
    Arbor.Actions.Github.PR => "arbor://action/github/pr",

    # Mix — per-task URIs under the action namespace, NOT under shell.
    # The Mix.{Test,Quality,Format} actions bound their argument space
    # via Jido schema (no arbitrary `mix deps.update` slipping through),
    # so they don't belong under the `arbor://shell` always-locked
    # ceiling. `arbor://action/mix/**` grants everything;
    # `arbor://action/mix/test` is a test-only grant.
    Arbor.Actions.Mix.Test => "arbor://action/mix/test",
    Arbor.Actions.Mix.Quality => "arbor://action/mix/quality",
    Arbor.Actions.Mix.Format => "arbor://action/mix/format",

    # TDD — pure data transforms (build prompt, record attempt). No
    # side effects, but still routed through the capability layer so
    # the auth shape is uniform across all Actions.
    Arbor.Actions.TDD.BuildImplPrompt => "arbor://action/tdd/build_impl_prompt",
    Arbor.Actions.TDD.RecordAttempt => "arbor://action/tdd/record_attempt",

    # Code review — apply_changes writes files within a workdir bound.
    # The action enforces SafePath.resolve_within at runtime; the
    # capability URI exposes the action-level grant separately from
    # raw fs/write so the pipeline can hold this cap without holding
    # write access to arbitrary paths.
    Arbor.Actions.CodeReview.ApplyChanges => "arbor://action/code_review/apply_changes",

    # File facade — arbor://fs/{operation}
    Arbor.Actions.File.Read => "arbor://fs/read",
    Arbor.Actions.File.Write => "arbor://fs/write",
    Arbor.Actions.File.Edit => "arbor://fs/write",
    Arbor.Actions.File.List => "arbor://fs/list",
    Arbor.Actions.File.Glob => "arbor://fs/read",
    Arbor.Actions.File.Exists => "arbor://fs/read",
    Arbor.Actions.File.Search => "arbor://fs/read",

    # Historian facade — arbor://historian/query
    Arbor.Actions.Historian.QueryEvents => "arbor://historian/query",
    Arbor.Actions.Historian.CausalityTree => "arbor://historian/query",
    Arbor.Actions.Historian.ReconstructState => "arbor://historian/query",
    # SECURITY (codex authz.historian-tainttrace-security-stream): TaintTrace
    # reads the SECURITY taint stream (StreamIds.for_category(:security)), so it
    # must require a security-scoped historian cap — not the generic query cap
    # that authorizes ordinary event reads. A bare `arbor://historian/query`
    # grant no longer authorizes taint reads; an explicit
    # `arbor://historian/query/security` (or a `/**` wildcard) is required.
    Arbor.Actions.Historian.TaintTrace => "arbor://historian/query/security",

    # Sandbox facade — arbor://sandbox/{operation}
    Arbor.Actions.Sandbox.Create => "arbor://sandbox/create",
    Arbor.Actions.Sandbox.Destroy => "arbor://sandbox/destroy",

    # Consensus facade — arbor://consensus/{operation}
    Arbor.Actions.Consensus.Propose => "arbor://consensus/propose",
    Arbor.Actions.Consensus.Ask => "arbor://consensus/ask",
    Arbor.Actions.Consensus.Await => "arbor://consensus/ask",
    Arbor.Actions.Consensus.Check => "arbor://consensus/ask",
    Arbor.Actions.Consensus.Decide => "arbor://consensus/decide",
    Arbor.Actions.Proposal.Submit => "arbor://consensus/propose",
    Arbor.Actions.Proposal.Revise => "arbor://consensus/propose",

    # Memory facade — arbor://memory/{operation}
    Arbor.Actions.Memory.Remember => "arbor://memory/add_knowledge",
    Arbor.Actions.Memory.Recall => "arbor://memory/recall",
    Arbor.Actions.Memory.Connect => "arbor://memory/write",
    Arbor.Actions.Memory.Reflect => "arbor://memory/read",
    Arbor.Actions.Memory.Consolidate => "arbor://memory/write",
    Arbor.Actions.Memory.Index => "arbor://memory/index",
    Arbor.Actions.Memory.LoadWorking => "arbor://memory/read",
    Arbor.Actions.Memory.SaveWorking => "arbor://memory/write",
    Arbor.Actions.MemoryIdentity.AddInsight => "arbor://memory/write",
    Arbor.Actions.MemoryIdentity.ReadSelf => "arbor://memory/read",
    Arbor.Actions.MemoryIdentity.IntrospectMemory => "arbor://memory/read",
    Arbor.Actions.MemoryCognitive.AdjustPreference => "arbor://memory/write",
    Arbor.Actions.MemoryCognitive.PinMemory => "arbor://memory/write",
    Arbor.Actions.MemoryCognitive.UnpinMemory => "arbor://memory/write",
    Arbor.Actions.MemoryReview.ReviewQueue => "arbor://memory/read",
    Arbor.Actions.MemoryReview.ReviewSuggestions => "arbor://memory/read",
    Arbor.Actions.MemoryReview.AcceptSuggestion => "arbor://memory/write",
    Arbor.Actions.MemoryReview.RejectSuggestion => "arbor://memory/write",
    Arbor.Actions.MemoryCode.StoreCode => "arbor://memory/write",
    Arbor.Actions.MemoryCode.ListCode => "arbor://memory/read",
    Arbor.Actions.MemoryCode.DeleteCode => "arbor://memory/write",
    Arbor.Actions.MemoryCode.ViewCode => "arbor://memory/read",

    # AI facade — arbor://ai/generate
    Arbor.Actions.AI.GenerateText => "arbor://ai/generate",
    Arbor.Actions.AI.AnalyzeCode => "arbor://ai/generate",
    Arbor.Actions.Judge.Evaluate => "arbor://ai/generate",
    Arbor.Actions.Judge.Quick => "arbor://ai/generate",
    Arbor.Actions.Council.Consult => "arbor://ai/generate",
    Arbor.Actions.Council.ConsultOne => "arbor://ai/generate",

    # Code facade — arbor://code/{operation}
    Arbor.Actions.Code.CompileAndTest => "arbor://code/compile",
    Arbor.Actions.Code.HotLoad => "arbor://code/hot_load",

    # Comms facade — arbor://comms/{operation}
    Arbor.Actions.Comms.SendMessage => "arbor://comms/send",
    Arbor.Actions.Comms.PollMessages => "arbor://comms/poll",
    Arbor.Actions.Comms.NotifySession => "arbor://comms/notify/session",

    # Channel facade — arbor://comms/channel/{operation}
    Arbor.Actions.Channel.List => "arbor://comms/channel/list",
    Arbor.Actions.Channel.Read => "arbor://comms/channel/read",
    Arbor.Actions.Channel.Send => "arbor://comms/channel/send",
    Arbor.Actions.Channel.Join => "arbor://comms/channel/join",
    Arbor.Actions.Channel.Leave => "arbor://comms/channel/leave",
    Arbor.Actions.Channel.Create => "arbor://comms/channel/create",
    Arbor.Actions.Channel.Members => "arbor://comms/channel/read",
    Arbor.Actions.Channel.Update => "arbor://comms/channel/write",
    Arbor.Actions.Channel.Invite => "arbor://comms/channel/write",

    # Monitor facade — arbor://monitor/{operation}
    Arbor.Actions.Monitor.Read => "arbor://monitor/read",
    Arbor.Actions.Monitor.ReadDiagnostics => "arbor://monitor/read",
    Arbor.Actions.Monitor.ClaimAnomaly => "arbor://monitor/remediate",
    Arbor.Actions.Monitor.CompleteAnomaly => "arbor://monitor/remediate",
    Arbor.Actions.Monitor.SuppressFingerprint => "arbor://monitor/remediate",
    Arbor.Actions.Monitor.ResetBaseline => "arbor://monitor/remediate",

    # Remediation — arbor://monitor/remediate (dangerous operations)
    Arbor.Actions.Remediation.KillProcess => "arbor://monitor/remediate",
    Arbor.Actions.Remediation.StopSupervisor => "arbor://monitor/remediate",
    Arbor.Actions.Remediation.RestartChild => "arbor://monitor/remediate",
    Arbor.Actions.Remediation.ForceGC => "arbor://monitor/remediate",
    Arbor.Actions.Remediation.DrainQueue => "arbor://monitor/remediate",

    # Trust facade — arbor://trust/{operation}
    Arbor.Actions.Trust.ReadProfile => "arbor://trust/read",
    Arbor.Actions.Trust.ProposeProfile => "arbor://trust/write",
    Arbor.Actions.Trust.ApplyProfile => "arbor://trust/write",
    Arbor.Actions.Trust.ExplainMode => "arbor://trust/read",
    Arbor.Actions.Trust.ListPresets => "arbor://trust/read",
    Arbor.Actions.Trust.ListAgents => "arbor://trust/read",

    # Network facade — arbor://net/{operation}
    Arbor.Actions.Web.Browse => "arbor://net/http",
    Arbor.Actions.Web.Search => "arbor://net/search",
    Arbor.Actions.Web.ExaSearch => "arbor://net/search",
    Arbor.Actions.Web.TinyfishSearch => "arbor://net/search",
    Arbor.Actions.Web.Snapshot => "arbor://net/http",
    # Eval-only fixtured search (agentic-safety harness); distinct URI so it is
    # never conflated with the real net/search tools.
    Arbor.Actions.Eval.PoisonedWebSearch => "arbor://eval/search",

    # Identity — arbor://agent/identity
    Arbor.Actions.Identity.RequestEndorsement => "arbor://agent/identity",
    Arbor.Actions.Identity.SignPublicKey => "arbor://agent/identity",

    # Agent Profile — arbor://agent/profile (self-service, any trust level)
    Arbor.Actions.AgentProfile.SetDisplayName => "arbor://agent/profile",

    # ACP — arbor://acp/tool
    Arbor.Actions.Acp.StartSession => "arbor://acp/tool",
    Arbor.Actions.Acp.SendMessage => "arbor://acp/tool",
    Arbor.Actions.Acp.SessionStatus => "arbor://acp/tool",
    Arbor.Actions.Acp.CloseSession => "arbor://acp/tool",

    # Coding-agent composite workflows — bounded by worktree + human PR review.
    Arbor.Actions.Coding.ProduceReviewableChange =>
      "arbor://action/coding/produce_reviewable_change",

    # Background checks — routes through shell
    Arbor.Actions.BackgroundChecks.Run => "arbor://shell/exec",

    # Pipeline — arbor://orchestrator/execute
    Arbor.Actions.Pipeline.Run => "arbor://orchestrator/execute",
    Arbor.Actions.Pipeline.Validate => "arbor://orchestrator/execute",

    # Persistence/relationship — arbor://persistence/{operation}
    Arbor.Actions.Relationship.Get => "arbor://persistence/read",
    Arbor.Actions.Relationship.Save => "arbor://persistence/write",
    Arbor.Actions.Relationship.Moment => "arbor://persistence/write",
    Arbor.Actions.Relationship.Browse => "arbor://persistence/read",
    Arbor.Actions.Relationship.Summarize => "arbor://persistence/read",

    # Docs — arbor://code/read
    Arbor.Actions.Docs.Lookup => "arbor://code/read",

    # Eval — arbor://code/compile (evaluation runs code)
    Arbor.Actions.Eval.Check => "arbor://code/compile",
    Arbor.Actions.Eval.ListRuns => "arbor://code/read",
    Arbor.Actions.Eval.GetRun => "arbor://code/read",

    # Tool discovery and documentation
    Arbor.Actions.Tool.FindTools => "arbor://agent/discover_tools",
    Arbor.Actions.Tool.Help => "arbor://agent/discover_tools",

    # Subagent spawning — ephemeral workers with scoped trust
    Arbor.Actions.Agent.SpawnWorker => "arbor://agent/spawn_worker",

    # Skill — arbor://code/read (skill management)
    Arbor.Actions.Skill.Search => "arbor://code/read",
    Arbor.Actions.Skill.Activate => "arbor://code/write",
    Arbor.Actions.Skill.Deactivate => "arbor://code/write",
    Arbor.Actions.Skill.ListActive => "arbor://code/read",
    Arbor.Actions.Skill.Import => "arbor://code/write",
    Arbor.Actions.Skill.Compile => "arbor://code/compile",

    # Session pipeline actions — internal to DOT engine execution.
    # Authorized via arbor://orchestrator/execute (the pipeline gate).
    Arbor.Actions.Session.Classify => "arbor://orchestrator/execute",
    Arbor.Actions.Session.ModeSelect => "arbor://orchestrator/execute",
    Arbor.Actions.Session.ProcessResults => "arbor://orchestrator/execute",
    Arbor.Actions.SessionExecution.ExecuteActions => "arbor://orchestrator/execute",
    Arbor.Actions.SessionExecution.RouteActions => "arbor://orchestrator/execute",
    Arbor.Actions.SessionGoals.ProcessProposalDecisions => "arbor://orchestrator/execute",
    Arbor.Actions.SessionGoals.StoreDecompositions => "arbor://orchestrator/execute",
    Arbor.Actions.SessionGoals.StoreIdentity => "arbor://orchestrator/execute",
    Arbor.Actions.SessionGoals.UpdateGoals => "arbor://orchestrator/execute",
    Arbor.Actions.SessionLlm.BuildPrompt => "arbor://orchestrator/execute",
    Arbor.Actions.SessionMemory.Checkpoint => "arbor://orchestrator/execute",
    Arbor.Actions.SessionMemory.Consolidate => "arbor://orchestrator/execute",
    Arbor.Actions.SessionMemory.Recall => "arbor://orchestrator/execute",
    Arbor.Actions.SessionMemory.Update => "arbor://orchestrator/execute",
    Arbor.Actions.SessionMemory.UpdateWorkingMemory => "arbor://orchestrator/execute",
    Arbor.Actions.Council.ReviewChange => "arbor://action/council/review"
  }

  @doc """
  Look up the canonical authorization URI for an action module.

  Returns the facade/resource-scoped URI from `@canonical_uri_map` when that is
  the authoritative boundary, otherwise derives a singular action URI using the
  module's canonical action name.

  ## Examples

      iex> Arbor.Actions.canonical_uri_for(Arbor.Actions.File.Read, %{})
      "arbor://fs/read"

      iex> Arbor.Actions.canonical_uri_for(Arbor.Actions.AgentProfile.SetDisplayName, %{agent_id: "x"})
      "arbor://agent/profile/x"
  """
  @spec canonical_uri_for(module(), map()) :: String.t()
  def canonical_uri_for(action_module, params) do
    case Map.get(@canonical_uri_map, action_module) do
      nil -> default_action_uri_for(action_module)
      uri -> parameterize_uri(uri, params)
    end
  end

  @doc """
  Resolve an LLM tool name string to its canonical authorization URI.

  Tool names are strings like `"file_read"` (Jido underscore format) or
  `"file.read"` (canonical dot format). Resolves to the action module,
  then returns `canonical_uri_for/2`.

  ## Examples

      iex> Arbor.Actions.tool_name_to_canonical_uri("file_read")
      {:ok, "arbor://fs/read"}

      iex> Arbor.Actions.tool_name_to_canonical_uri("shell_execute")
      {:ok, "arbor://shell/exec"}

      iex> Arbor.Actions.tool_name_to_canonical_uri("nonexistent")
      :error
  """
  @spec tool_name_to_canonical_uri(String.t()) :: {:ok, String.t()} | :error
  def tool_name_to_canonical_uri(tool_name) when is_binary(tool_name) do
    case resolve_module_by_tool_name(tool_name) do
      {:ok, module} -> {:ok, canonical_uri_for(module, %{})}
      {:error, _} -> :error
    end
  end

  @doc """
  Return the generated action-namespace URI prefixes provided by registered actions.

  Facade-backed actions authorize through their resource namespaces
  (`arbor://fs/read`, `arbor://shell/exec`, etc.) and are already registered by
  `arbor_security`. This list contains only singular `arbor://action/...`
  prefixes derived from the action registry, so the security registry does not
  need a broad static `arbor://action` prefix.
  """
  @spec action_namespace_uri_prefixes() :: [String.t()]
  def action_namespace_uri_prefixes do
    all_actions()
    |> Enum.map(&canonical_uri_for(&1, %{}))
    |> Enum.filter(&String.starts_with?(&1, "arbor://action/"))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Return conservative inline capability profiles for generated action URIs.

  Facade-backed actions inherit profiles from their facade URI. This projection
  covers only singular `arbor://action/...` prefixes so generated runtime
  registrations have profile metadata without requiring `arbor_trust` to depend
  upward on `arbor_actions`.
  """
  @spec action_namespace_capability_profiles() :: [CapabilityProfile.t()]
  def action_namespace_capability_profiles do
    all_actions()
    |> Enum.flat_map(fn action_module ->
      uri = canonical_uri_for(action_module, %{})

      if String.starts_with?(uri, "arbor://action/") do
        [capability_profile_for_action(action_module, uri)]
      else
        []
      end
    end)
    |> Enum.uniq_by(& &1.uri_prefix)
    |> Enum.sort_by(& &1.uri_prefix)
  end

  @doc """
  Register generated action-namespace URI prefixes with the security registry.

  This is called by `Arbor.Actions.Application` at startup and is public so
  narrow tests or tooling that start applications manually can make the generated
  registry projection explicit.
  """
  @spec register_action_uri_prefixes() :: :ok
  def register_action_uri_prefixes do
    with {:ok, _started} <- Application.ensure_all_started(:arbor_security),
         true <- Code.ensure_loaded?(Arbor.Security.UriRegistry) do
      action_namespace_uri_prefixes()
      |> Enum.each(&Arbor.Security.UriRegistry.register/1)
    end

    :ok
  end

  defp default_action_uri_for(action_module) do
    path =
      action_module
      |> action_module_to_name()
      |> String.replace(".", "/")

    "arbor://action/#{path}"
  end

  defp capability_profile_for_action(action_module, uri) do
    effect_class = Egress.effect_class_for(action_module)

    CapabilityProfile.new!(%{
      uri_prefix: uri,
      owner: :arbor_actions,
      blast_radius: action_blast_radius(effect_class),
      reversibility: action_reversibility(effect_class),
      effect_class: effect_class,
      data_class: action_data_class(effect_class),
      arg_dependent: true,
      default_approval: action_default_approval(effect_class),
      delegable: false,
      cost_class: action_cost_class(effect_class),
      graduation_eligible: action_graduation_eligible(effect_class)
    })
  end

  defp action_blast_radius(:financial), do: :critical
  defp action_blast_radius(:identity_mutating), do: :critical
  defp action_blast_radius(:governance), do: :critical
  defp action_blast_radius(:trust_mutating), do: :critical
  defp action_blast_radius(:network_egress), do: :high
  defp action_blast_radius(:process_spawn), do: :high
  defp action_blast_radius(:local_write), do: :high
  defp action_blast_radius(:read), do: :medium

  defp action_reversibility(:read), do: :read_only
  defp action_reversibility(:financial), do: :irreversible
  defp action_reversibility(:identity_mutating), do: :irreversible
  defp action_reversibility(:governance), do: :irreversible
  defp action_reversibility(:trust_mutating), do: :irreversible
  defp action_reversibility(:network_egress), do: :irreversible
  defp action_reversibility(_effect_class), do: :reversible

  defp action_data_class(:read), do: :internal
  defp action_data_class(:network_egress), do: :confidential
  defp action_data_class(:local_write), do: :confidential
  defp action_data_class(_effect_class), do: :restricted

  defp action_default_approval(:financial), do: :forbid
  defp action_default_approval(_effect_class), do: :require_human

  defp action_cost_class(:financial), do: :expensive
  defp action_cost_class(:network_egress), do: :metered
  defp action_cost_class(_effect_class), do: :cheap

  defp action_graduation_eligible(effect_class) when effect_class in [:read, :local_write],
    do: true

  defp action_graduation_eligible(_effect_class), do: false

  # Resolve a tool name to its action module.
  # Tries ActionRegistry (O(1) ETS) first, falls back to name_to_module/1.
  defp resolve_module_by_tool_name(tool_name) do
    registry = Arbor.Common.ActionRegistry

    if Process.whereis(registry) do
      case registry.resolve(tool_name) do
        {:ok, module} -> {:ok, module}
        {:error, _} -> name_to_module(tool_name)
      end
    else
      name_to_module(tool_name)
    end
  end

  # URIs that use /self/ scoping in capability templates need the agent_id
  # appended to match the granted capability (e.g. arbor://agent/profile/x/*).
  @self_scoped_uri_prefixes ["arbor://agent/profile"]

  defp parameterize_uri(uri, params) do
    if uri in @self_scoped_uri_prefixes do
      agent_id = Map.get(params, :agent_id) || Map.get(params, "agent_id")
      if agent_id, do: "#{uri}/#{agent_id}", else: uri
    else
      uri
    end
  end

  # For fs actions, pull `path` from params so `Security.authorize` can
  # synthesize the path-embedded URI. Returns nil for non-fs actions or
  # when no path param is present.
  defp extract_fs_path(resource, params) when is_map(params) do
    if is_binary(resource) and String.starts_with?(resource, "arbor://fs/") do
      Map.get(params, :path) || Map.get(params, "path") ||
        Map.get(params, :file_path) || Map.get(params, "file_path") ||
        Map.get(params, :base_path) || Map.get(params, "base_path")
    end
  end

  defp extract_fs_path(_resource, _params), do: nil
end
