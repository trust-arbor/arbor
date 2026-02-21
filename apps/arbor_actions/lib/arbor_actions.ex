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
  | Comms | `Arbor.Actions.Comms` | Channel messaging |
  | AI | `Arbor.Actions.AI` | AI/LLM text generation and code analysis |
  | Sandbox | `Arbor.Actions.Sandbox` | Docker sandbox environment management |
  | Historian | `Arbor.Actions.Historian` | Event log querying and causality tracing |
  | Code | `Arbor.Actions.Code` | Code compilation, testing, and hot-loading |
  | Proposal | `Arbor.Actions.Proposal` | Proposal submission for consensus |
  | Council | `Arbor.Actions.Council` | Advisory council consultation |
  | Web | `Arbor.Actions.Web` | Web browsing, search, and page snapshots |
  | CLI Agent | `Arbor.Actions.CliAgent` | CLI agent execution (Claude, OpenCode, Codex, etc.) |

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

  alias Arbor.Actions.TaintEnforcement
  alias Arbor.Actions.TaintEvents
  alias Arbor.Signals

  # ===========================================================================
  # Public API — Authorized execution (for agent callers)
  # ===========================================================================

  @doc """
  Execute an action with authorization check.

  Verifies the agent has the `arbor://actions/execute/{action_name}` capability
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
    # Extract signing data from context (if present) before passing to action
    {signed_request, clean_context} = Map.pop(context, :signed_request)

    # P0-1: Inject default taint policy from config if not already set in context.
    # Ensures taint enforcement is active even when callers don't explicitly set policy.
    clean_context = maybe_inject_taint_policy(clean_context)

    action_name = action_module_to_name(action_module)
    resource = "arbor://actions/execute/#{action_name}"

    # Build auth opts — when a signed_request is present, enable identity
    # verification and resource binding. When absent, fall back to config
    # defaults (disabled in dev/test, enabled in production).
    auth_opts =
      if signed_request do
        [signed_request: signed_request, verify_identity: true, expected_resource: resource]
      else
        []
      end

    case Arbor.Security.authorize(agent_id, resource, :execute, auth_opts) do
      {:ok, :authorized} ->
        # Check taint before executing
        case TaintEnforcement.check(action_module, params, clean_context) do
          :ok ->
            result = execute_action(action_module, params, clean_context)
            TaintEnforcement.maybe_emit_propagated(action_module, clean_context, result)
            result

          {:error, {:taint_blocked, param, level, role}} = taint_error ->
            TaintEvents.emit_taint_blocked(action_module, param, level, role, clean_context)
            taint_error
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
        Arbor.Actions.Git.Log
      ],
      comms: [
        Arbor.Actions.Comms.SendMessage,
        Arbor.Actions.Comms.PollMessages
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
        Arbor.Actions.Council.ConsultOne
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
      cli_agent: [
        Arbor.Actions.CliAgent.Execute
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
      skill: [
        Arbor.Actions.Skill.Search,
        Arbor.Actions.Skill.Activate,
        Arbor.Actions.Skill.Deactivate,
        Arbor.Actions.Skill.ListActive,
        Arbor.Actions.Skill.Import,
        Arbor.Actions.Skill.Compile
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
    # Normalize: if no dots, replace underscores with dots
    normalized =
      if String.contains?(name, ".") do
        name
      else
        String.replace(name, "_", ".")
      end

    case Map.get(name_to_module_map(), normalized) do
      nil -> {:error, :unknown_action}
      module -> {:ok, module}
    end
  end

  # Build a reverse lookup map from action name -> module.
  # Uses action_module_to_name/1 for each module in all_actions().
  defp name_to_module_map do
    all_actions()
    |> Map.new(fn module -> {action_module_to_name(module), module} end)
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

  # Convert an action module to its snake_case name for capability URIs
  defp action_module_to_name(module) do
    module
    |> Module.split()
    |> Enum.drop_while(&(&1 != "Actions"))
    |> Enum.drop(1)
    |> Enum.join(".")
    |> Macro.underscore()
    |> String.replace("/", ".")
  end
end
