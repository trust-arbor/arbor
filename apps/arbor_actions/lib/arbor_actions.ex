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
  | Jobs | `Arbor.Actions.Jobs` | Persistent task tracking |
  | AI | `Arbor.Actions.AI` | AI/LLM text generation and code analysis |
  | Sandbox | `Arbor.Actions.Sandbox` | Docker sandbox environment management |
  | Historian | `Arbor.Actions.Historian` | Event log querying and causality tracing |
  | Code | `Arbor.Actions.Code` | Code compilation, testing, and hot-loading |
  | Proposal | `Arbor.Actions.Proposal` | Proposal submission for consensus |

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

  alias Arbor.Signals
  alias Arbor.Actions.Taint
  alias Arbor.Actions.TaintEvents

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
    action_name = action_module_to_name(action_module)
    resource = "arbor://actions/execute/#{action_name}"

    case Arbor.Security.authorize(agent_id, resource, :execute) do
      {:ok, :authorized} ->
        # Check taint before executing
        case check_taint(action_module, params, context) do
          :ok ->
            result = execute_action(action_module, params, context)
            maybe_emit_taint_propagated(action_module, context, result)
            result

          {:error, {:taint_blocked, param, level, role}} = taint_error ->
            TaintEvents.emit_taint_blocked(action_module, param, level, role, context)
            taint_error
        end

      {:ok, :pending_approval, proposal_id} ->
        {:ok, :pending_approval, proposal_id}

      {:error, _reason} ->
        {:error, :unauthorized}
    end
  end

  @doc """
  Execute an action directly (unchecked).

  Use for system-level callers that don't require authorization.
  Emits started/completed/failed signals for observability.
  """
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
      jobs: [
        Arbor.Actions.Jobs.CreateJob,
        Arbor.Actions.Jobs.ListJobs,
        Arbor.Actions.Jobs.GetJob,
        Arbor.Actions.Jobs.UpdateJob
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

  # ===========================================================================
  # Taint Enforcement
  # ===========================================================================

  # Check if action parameters comply with taint policy.
  # Returns :ok if execution should proceed, {:error, {:taint_blocked, ...}} if blocked.
  defp check_taint(action_module, params, context) do
    taint_context = extract_taint_context(context)

    case taint_context do
      nil ->
        # No taint metadata — backward compatible, allow execution
        :ok

      %{taint: nil} ->
        # Taint context exists but no taint level — allow execution
        :ok

      %{taint: taint_level} ->
        policy = Map.get(context, :taint_policy, :permissive)
        check_taint_with_policy(action_module, params, taint_level, policy, context)
    end
  end

  # Extract taint context from the context map.
  # Looks for :taint key directly or in :taint_context sub-map.
  defp extract_taint_context(nil), do: nil
  defp extract_taint_context(context) when not is_map(context), do: nil

  defp extract_taint_context(context) do
    cond do
      Map.has_key?(context, :taint) ->
        %{taint: Map.get(context, :taint)}

      Map.has_key?(context, :taint_context) and is_map(context.taint_context) ->
        context.taint_context

      true ->
        nil
    end
  end

  # Apply taint policy to parameter check.
  defp check_taint_with_policy(action_module, params, taint_level, :audit_only, context) do
    # Audit-only: log violations but don't block
    case Taint.check_params(action_module, params, %{taint: taint_level}) do
      :ok ->
        :ok

      {:error, {:taint_blocked, param, level, _role}} ->
        # Log the violation but allow execution
        TaintEvents.emit_taint_audited(action_module, param, level, context)
        :ok
    end
  end

  defp check_taint_with_policy(action_module, params, taint_level, :strict, context) do
    # Strict: block derived, untrusted, hostile on control params
    # Only trusted is allowed for control parameters
    if taint_level == :trusted do
      :ok
    else
      roles = Taint.roles_for(action_module)
      check_strict_taint(params, roles, taint_level, context, action_module)
    end
  end

  defp check_taint_with_policy(action_module, params, taint_level, _permissive, context) do
    # Permissive (default): use standard check from Taint module
    # This blocks untrusted/hostile on control, but allows derived
    case Taint.check_params(action_module, params, %{taint: taint_level}) do
      :ok ->
        # If derived was used on control params, emit audit signal
        if taint_level == :derived do
          maybe_emit_derived_audit(action_module, params, context)
        end

        :ok

      error ->
        error
    end
  end

  # Strict mode: any non-trusted taint on control params is blocked
  defp check_strict_taint(params, roles, taint_level, _context, _action_module) do
    # Find first control param (under strict, any non-trusted is blocked)
    violation =
      Enum.find_value(params, fn {param_name, _value} ->
        role = Map.get(roles, param_name, :data)

        if role == :control do
          {:taint_blocked, param_name, taint_level, :control}
        else
          nil
        end
      end)

    case violation do
      nil -> :ok
      blocked -> {:error, blocked}
    end
  end

  # Emit audit signal for derived data used on control params (permissive mode)
  defp maybe_emit_derived_audit(action_module, params, context) do
    roles = Taint.roles_for(action_module)

    Enum.each(params, fn {param_name, _value} ->
      if Map.get(roles, param_name) == :control do
        TaintEvents.emit_taint_audited(action_module, param_name, :derived, context)
      end
    end)
  end

  # After successful execution, emit taint propagation signal if context had taint
  defp maybe_emit_taint_propagated(action_module, context, {:ok, _result}) do
    input_taint = extract_taint_level(context)

    if input_taint do
      output_taint = Arbor.Signals.Taint.propagate([input_taint])
      TaintEvents.emit_taint_propagated(action_module, input_taint, output_taint, context)
    else
      :ok
    end
  end

  defp maybe_emit_taint_propagated(_action_module, _context, _error_result), do: :ok

  # Extract taint level from context, checking both flat and nested forms.
  # Reuses same extraction logic as check_taint for consistency.
  defp extract_taint_level(nil), do: nil
  defp extract_taint_level(context) when not is_map(context), do: nil

  defp extract_taint_level(context) do
    Map.get(context, :taint) || get_in(context, [:taint_context, :taint])
  end
end
