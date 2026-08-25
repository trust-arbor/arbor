defmodule Arbor.Agent.Executor.ActionDispatch do
  @moduledoc """
  Action dispatch for the executor.

  Maps intent actions to concrete execution: AI analysis, proposal submission,
  code hot-loading, and generic action module discovery. Uses runtime `apply/3`
  to avoid compile-time dependencies on higher-level libraries.
  """

  require Logger

  # ── Public API ──

  @doc """
  Resolve an action atom to its canonical dotted name for capability URIs.

  The canonical format uses facade URIs (e.g., `arbor://fs/read`,
  `arbor://shell/exec`). For full URI resolution, use `resolve_action_module/1`
  with `Arbor.Actions.canonical_uri_for/2`.

  ## Examples

      iex> ActionDispatch.canonical_action_name(:file_read)
      {:ok, "file.read"}

      iex> ActionDispatch.canonical_action_name(:proposal_submit)
      {:ok, "proposal.submit"}

      iex> ActionDispatch.canonical_action_name(:unknown_thing)
      :error
  """
  @spec canonical_action_name(atom() | String.t()) :: {:ok, String.t()} | :error
  def canonical_action_name(action) when is_atom(action) do
    # Check hardcoded dispatch mappings first (compound names like
    # :proposal_submit that find_action_module cannot discover,
    # and inline-handled actions like :proposal_status), then fall back
    # to naming convention discovery.
    case hardcoded_canonical_name(action) do
      {:ok, _} = result ->
        result

      :error ->
        case find_action_module(action) do
          nil -> :error
          module -> {:ok, module_to_dotted_name(module)}
        end
    end
  end

  def canonical_action_name(action) when is_binary(action) do
    case find_action_module_from_string(action) do
      nil -> :error
      module -> {:ok, module_to_dotted_name(module)}
    end
  end

  @doc """
  Resolve an action atom to its concrete module, if discoverable.

  Returns `{:ok, module}` when a matching action module is found via naming
  convention, or `:error` for inline-handled actions and unknown names.

  ## Examples

      iex> ActionDispatch.resolve_action_module(:file_read)
      {:ok, Arbor.Actions.File.Read}

      iex> ActionDispatch.resolve_action_module(:unknown_thing)
      :error
  """
  @spec resolve_action_module(atom() | String.t()) :: {:ok, module()} | :error
  def resolve_action_module(action) when is_atom(action) do
    case find_action_module(action) do
      nil -> :error
      module -> {:ok, module}
    end
  end

  def resolve_action_module(action) when is_binary(action) do
    case find_action_module_from_string(action) do
      nil -> :error
      module -> {:ok, module}
    end
  end

  @doc """
  Convert an action module to its canonical dotted name for capability URIs.

  Same logic as `arbor_actions.ex`'s `action_module_to_name/1` — drops
  everything up to and including "Actions", joins remainder with dots,
  then underscores.

  ## Examples

      iex> ActionDispatch.module_to_dotted_name(Arbor.Actions.File.Read)
      "file.read"

      iex> ActionDispatch.module_to_dotted_name(Arbor.Actions.Proposal.Submit)
      "proposal.submit"
  """
  @spec module_to_dotted_name(module()) :: String.t()
  def module_to_dotted_name(module) do
    module
    |> Module.split()
    |> Enum.drop_while(&(&1 != "Actions"))
    |> Enum.drop(1)
    |> Enum.join(".")
    |> Macro.underscore()
    |> String.replace("/", ".")
  end

  @doc """
  Dispatch an action with the given parameters.

  When `agent_id` is provided, routes through `authorize_and_execute`
  for full security enforcement. When nil, calls actions directly
  (system-level dispatch only). Identity and sandbox are passed as
  arguments — never the process dictionary.

  Returns `{:ok, result}`, `{:ok, :pending_approval, id}`, or `{:error, reason}`.

  `context` carries shell facts (currently `:sandbox_level`). Do not read
  executor identity from the process dictionary — pass `agent_id` explicitly.
  """
  @spec dispatch(atom() | term(), map(), String.t() | nil, map()) ::
          {:ok, map()} | {:ok, :pending_approval, term()} | {:error, term()}
  def dispatch(action, params, agent_id \\ nil, context \\ %{})

  def dispatch(:proposal_submit, params, agent_id, context) when is_map(context) do
    proposal = params[:proposal] || params["proposal"] || %{}
    submit_params = build_submit_params(proposal)

    run_runtime_action(
      Arbor.Actions.Proposal.Submit,
      submit_params,
      :proposal_submit_failed,
      :consensus_unavailable,
      agent_id,
      context
    )
  end

  def dispatch(:code_hot_load, params, agent_id, context) when is_map(context) do
    module = params[:module] || params["module"]
    code = params[:code] || params[:source] || params["code"] || params["source"]
    do_hot_load(module, code, params, agent_id, context)
  end

  def dispatch(:proposal_status, params, _agent_id, context) when is_map(context) do
    proposal_id = params[:proposal_id] || params["proposal_id"]
    do_proposal_status(proposal_id)
  end

  def dispatch(action, params, agent_id, context) when is_atom(action) and is_map(context) do
    action_module = find_action_module(action)
    run_discovered_action(action_module, action, params, agent_id, context)
  end

  def dispatch(action, params, agent_id, context) when is_binary(action) and is_map(context) do
    action_module = find_action_module_from_string(action)
    run_discovered_action(action_module, action, params, agent_id, context)
  end

  def dispatch(action, params, _agent_id, context) when is_map(context) do
    Logger.warning("ActionDispatch: invalid action type #{inspect(action)}")
    {:ok, %{action: action, status: :invalid_action_type, params: params}}
  end

  # ── AI Analysis Helpers ──

  # ── Proposal / Hot-load Helpers ──

  defp build_submit_params(proposal) do
    %{
      title: proposal[:title] || "Fix for detected anomaly",
      description: proposal[:description] || proposal[:rationale] || "Auto-generated fix",
      branch: proposal[:branch] || "main",
      evidence: proposal[:evidence] || [],
      urgency: proposal[:urgency] || "high",
      change_type: proposal[:change_type] || "code_modification"
    }
  end

  # H7: pre-fix, run_runtime_action called `apply(action_mod, :run, [params, %{}])`
  # directly — proposal_submit and code_hot_load all
  # bypassed action-layer taint enforcement, resource binding, invocation
  # receipts, and facade-level checks. Generic discovered actions DID go
  # through Arbor.Actions.authorize_and_execute; only the hardcoded compound
  # actions were exempt.
  #
  # The fix routes through authorize_and_execute when an agent_id is
  # available (the Executor now threads it from the agent's identity). When
  # nil — e.g. system-internal callers, tests that don't bootstrap Security —
  # falls back to the direct apply so existing system-level dispatch keeps
  # working.
  defp run_runtime_action(action_mod, params, error_tag, unavailable_tag, agent_id, context) do
    if is_binary(agent_id) and byte_size(agent_id) > 0 do
      run_via_authorize_and_execute(
        action_mod,
        params,
        error_tag,
        unavailable_tag,
        agent_id,
        context
      )
    else
      run_direct(action_mod, params, error_tag, unavailable_tag)
    end
  end

  defp run_via_authorize_and_execute(
         action_mod,
         params,
         error_tag,
         unavailable_tag,
         agent_id,
         context
       ) do
    case safe_call(fn ->
           Arbor.Actions.authorize_and_execute(
             agent_id,
             action_mod,
             params,
             executor_context(context)
           )
         end) do
      {:ok, :pending_approval, id} -> {:ok, :pending_approval, id}
      {:ok, {:ok, result}} -> {:ok, result}
      {:ok, {:error, reason}} -> {:error, {error_tag, reason}}
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {error_tag, reason}}
      nil -> {:error, unavailable_tag}
    end
  end

  defp run_direct(action_mod, params, error_tag, unavailable_tag) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case safe_call(fn -> apply(action_mod, :run, [params, %{}]) end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {error_tag, reason}}
      nil -> {:error, unavailable_tag}
    end
  end

  defp do_hot_load(module, code, _params, _agent_id, _context)
       when is_nil(module) or is_nil(code) do
    {:error, :missing_module_or_code}
  end

  defp do_hot_load(module, code, params, agent_id, context) do
    hot_load_params = %{
      module: to_string(module),
      source: code,
      verify_fn: params[:verify_fn],
      rollback_timeout_ms: params[:timeout] || 30_000
    }

    run_runtime_action(
      Arbor.Actions.Code.HotLoad,
      hot_load_params,
      :hot_load_failed,
      :code_service_unavailable,
      agent_id,
      context
    )
  end

  defp do_proposal_status(nil), do: {:error, :missing_proposal_id}

  defp do_proposal_status(proposal_id) do
    case safe_call(fn -> Arbor.Consensus.get_status(proposal_id) end) do
      {:ok, status} -> {:ok, %{proposal_id: proposal_id, status: status}}
      {:error, reason} -> {:error, {:status_query_failed, reason}}
      nil -> {:error, :consensus_unavailable}
    end
  end

  # ── Generic Action Module Discovery ──

  defp run_discovered_action(nil, action, params, _agent_id, _context) do
    Logger.warning("ActionDispatch: unknown action #{inspect(action)}, returning stub result")
    {:ok, %{action: action, status: :no_handler, params: params}}
  end

  defp run_discovered_action(action_module, action, params, agent_id, context) do
    if is_binary(agent_id) and byte_size(agent_id) > 0 do
      case Arbor.Actions.authorize_and_execute(
             agent_id,
             action_module,
             params,
             executor_context(context)
           ) do
        {:ok, :pending_approval, id} -> {:ok, :pending_approval, id}
        {:error, :unauthorized} -> {:error, {:unauthorized, action}}
        result -> result
      end
    else
      case safe_call(fn -> action_module.run(params, %{}) end) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, {action, reason}}
        nil -> {:error, {:action_failed, action}}
      end
    end
  end

  # Map actions with hardcoded dispatch clauses to canonical dotted names.
  # Covers compound namespace modules and inline-handled
  # actions (proposal_status) that find_action_module can't discover.
  defp hardcoded_canonical_name(:proposal_submit), do: {:ok, "proposal.submit"}
  defp hardcoded_canonical_name(:code_hot_load), do: {:ok, "code.hot_load"}

  defp hardcoded_canonical_name(:proposal_status), do: {:ok, "proposal.status"}
  defp hardcoded_canonical_name(_), do: :error

  # Find an action module from a string action name (dotted or underscore format)
  # e.g., "memory.remember" -> Arbor.Actions.Memory.Remember
  defp find_action_module_from_string(action_str) when is_binary(action_str) do
    candidates = [
      build_action_module_name(action_str),
      build_action_module_from_dotted(action_str)
    ]

    Enum.find(candidates, fn mod ->
      mod && Code.ensure_loaded?(mod) && function_exported?(mod, :run, 2)
    end)
  end

  # Try to find an action module by naming convention
  # e.g., :file_read -> Arbor.Actions.File.Read
  defp find_action_module(action) do
    action_str = Atom.to_string(action)

    candidates = [
      build_action_module_name(action_str),
      build_action_module_from_dotted(action_str)
    ]

    Enum.find(candidates, fn mod ->
      mod && Code.ensure_loaded?(mod) && function_exported?(mod, :run, 2)
    end)
  end

  # M12: Use String.to_existing_atom to prevent atom table exhaustion
  defp build_action_module_name(action_str) do
    parts = action_str |> String.split("_")

    case parts do
      [category | rest] when rest != [] ->
        category_mod = category |> String.capitalize()
        action_mod = Enum.map_join(rest, "", &String.capitalize/1)

        module =
          Module.concat([
            Arbor.Actions,
            String.to_existing_atom(category_mod),
            String.to_existing_atom(action_mod)
          ])

        if Code.ensure_loaded?(module), do: module, else: nil

      _ ->
        nil
    end
  rescue
    ArgumentError -> nil
    _ -> nil
  end

  defp build_action_module_from_dotted(action_str) do
    case String.split(action_str, ".") do
      [category, action_name] ->
        category_mod = category |> String.capitalize()
        action_mod = action_name |> Macro.camelize()

        module =
          Module.concat([
            Arbor.Actions,
            String.to_existing_atom(category_mod),
            String.to_existing_atom(action_mod)
          ])

        if Code.ensure_loaded?(module), do: module, else: nil

      _ ->
        nil
    end
  rescue
    ArgumentError -> nil
    _ -> nil
  end

  # ── Config ──

  # Thread the agent's declared sandbox level so sandbox-create can cap a
  # requested level. Empty for system-level callers that pass no context.
  defp executor_context(context) when is_map(context) do
    case fetch_sandbox_level(context) do
      nil -> context
      level -> Map.put(context, :sandbox_level, level)
    end
  end

  defp executor_context(_context), do: %{}

  defp fetch_sandbox_level(context) do
    Map.get(context, :sandbox_level) || Map.get(context, "sandbox_level")
  end

  # ── Safety ──

  defp safe_call(fun) do
    fun.()
  rescue
    e ->
      Logger.debug("ActionDispatch safe_call rescued: #{Exception.message(e)}")
      nil
  catch
    :exit, reason ->
      Logger.debug("ActionDispatch safe_call caught exit: #{inspect(reason)}")
      nil
  end
end
