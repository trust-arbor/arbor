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

  The canonical format matches what ToolBridge/arbor_actions uses:
  `arbor://actions/execute/<dotted_name>`.

  ## Examples

      iex> ActionDispatch.canonical_action_name(:file_read)
      {:ok, "file.read"}

      iex> ActionDispatch.canonical_action_name(:background_checks_run)
      {:ok, "background_checks.run"}

      iex> ActionDispatch.canonical_action_name(:unknown_thing)
      :error
  """
  @spec canonical_action_name(atom()) :: {:ok, String.t()} | :error
  def canonical_action_name(action) when is_atom(action) do
    # Check hardcoded dispatch mappings first (compound names like
    # :background_checks_run that find_action_module can't discover,
    # and inline-handled actions like :ai_analyze), then fall back
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

  @doc """
  Convert an action module to its canonical dotted name for capability URIs.

  Same logic as `arbor_actions.ex`'s `action_module_to_name/1` — drops
  everything up to and including "Actions", joins remainder with dots,
  then underscores.

  ## Examples

      iex> ActionDispatch.module_to_dotted_name(Arbor.Actions.File.Read)
      "file.read"

      iex> ActionDispatch.module_to_dotted_name(Arbor.Actions.BackgroundChecks.Run)
      "background_checks.run"
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

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  @spec dispatch(atom() | term(), map()) :: {:ok, map()} | {:error, term()}
  def dispatch(action, params)

  # AI analysis — construct prompt from anomaly context and call LLM
  def dispatch(:ai_analyze, params) do
    anomaly = params[:anomaly] || params["anomaly"]
    context = params[:context] || params["context"] || %{}

    prompt = build_analysis_prompt(anomaly, context)
    ai_opts = build_ai_opts()

    Logger.debug("[ActionDispatch] AI analyze with opts: #{inspect(ai_opts)}")

    prompt
    |> call_ai_generate(ai_opts)
    |> normalize_ai_result()
  end

  # Proposal submission — map to Proposal.Submit action (runtime call to avoid Level 2 cycle)
  def dispatch(:proposal_submit, params) do
    proposal = params[:proposal] || params["proposal"] || %{}
    submit_params = build_submit_params(proposal)

    action_mod = Module.concat([Arbor, Actions, Proposal, Submit])
    run_runtime_action(action_mod, submit_params, :proposal_submit_failed, :consensus_unavailable)
  end

  # Code hot-load — map to Code.HotLoad action (runtime call to avoid Level 2 cycle)
  def dispatch(:code_hot_load, params) do
    module = params[:module] || params["module"]
    code = params[:code] || params[:source] || params["code"] || params["source"]
    do_hot_load(module, code, params)
  end

  # Proposal status — query the status of a submitted proposal
  def dispatch(:proposal_status, params) do
    proposal_id = params[:proposal_id] || params["proposal_id"]
    do_proposal_status(proposal_id)
  end

  # Background checks — compound module name doesn't match single-underscore naming convention
  def dispatch(:background_checks_run, params) do
    action_mod = Module.concat([Arbor, Actions, BackgroundChecks, Run])
    run_runtime_action(action_mod, params, :background_checks_failed, :health_checks_unavailable)
  end

  # Generic action dispatch — try to find a matching action module
  def dispatch(action, params) when is_atom(action) do
    action_module = find_action_module(action)
    run_discovered_action(action_module, action, params)
  end

  def dispatch(action, params) do
    Logger.warning("ActionDispatch: invalid action type #{inspect(action)}")
    {:ok, %{action: action, status: :invalid_action_type, params: params}}
  end

  # ── AI Analysis Helpers ──

  defp build_ai_opts do
    if demo_mode?() do
      demo_ai_opts()
    else
      [max_tokens: 2000]
    end
  end

  defp demo_ai_opts do
    case get_demo_llm_config() do
      %{provider: provider, model: model} ->
        [max_tokens: 2000, backend: :api, provider: provider, model: model]

      _ ->
        [max_tokens: 2000]
    end
  end

  defp call_ai_generate(prompt, ai_opts) do
    safe_call(fn -> Arbor.AI.generate_text(prompt, ai_opts) end)
  end

  defp normalize_ai_result({:ok, %{text: text}}) do
    {:ok, %{analysis: text, raw_response: text}}
  end

  defp normalize_ai_result({:ok, response}) when is_map(response) do
    text = response[:text] || response["text"] || inspect(response)
    {:ok, %{analysis: text, raw_response: response}}
  end

  defp normalize_ai_result({:error, reason}) do
    {:error, {:ai_analysis_failed, reason}}
  end

  defp normalize_ai_result(nil) do
    {:error, :ai_service_unavailable}
  end

  defp build_analysis_prompt(anomaly, context) do
    """
    You are a BEAM runtime diagnostic expert. Analyze this anomaly and suggest a fix.

    ## Anomaly Details
    #{format_anomaly(anomaly)}

    ## System Context
    #{format_context(context)}

    ## Your Task
    1. Identify the root cause of this anomaly
    2. Suggest a specific code fix
    3. Explain why this fix will resolve the issue

    Respond with:
    - ROOT_CAUSE: <one sentence>
    - FIX_MODULE: <module name to modify>
    - FIX_CODE: <the actual code change>
    - EXPLANATION: <why this works>
    """
  end

  defp format_anomaly(nil), do: "No anomaly data"

  defp format_anomaly(anomaly) when is_map(anomaly) do
    """
    - Skill: #{anomaly[:skill] || "unknown"}
    - Severity: #{anomaly[:severity] || "unknown"}
    - Metric: #{anomaly[:metric] || "unknown"}
    - Value: #{anomaly[:value] || "unknown"}
    - Threshold: #{anomaly[:threshold] || "unknown"}
    - Details: #{inspect(anomaly[:details] || %{})}
    """
  end

  defp format_anomaly(anomaly), do: inspect(anomaly)

  defp format_context(context) when is_map(context) do
    Enum.map_join(context, "\n", fn {k, v} -> "- #{k}: #{inspect(v)}" end)
  end

  defp format_context(_), do: "No additional context"

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

  defp run_runtime_action(action_mod, params, error_tag, unavailable_tag) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case safe_call(fn -> apply(action_mod, :run, [params, %{}]) end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {error_tag, reason}}
      nil -> {:error, unavailable_tag}
    end
  end

  defp do_hot_load(module, code, _params) when is_nil(module) or is_nil(code) do
    {:error, :missing_module_or_code}
  end

  defp do_hot_load(module, code, params) do
    hot_load_params = %{
      module: to_string(module),
      source: code,
      verify_fn: params[:verify_fn],
      rollback_timeout_ms: params[:timeout] || 30_000
    }

    action_mod = Module.concat([Arbor, Actions, Code, HotLoad])
    run_runtime_action(action_mod, hot_load_params, :hot_load_failed, :code_service_unavailable)
  end

  defp do_proposal_status(nil), do: {:error, :missing_proposal_id}

  defp do_proposal_status(proposal_id) do
    consensus_mod = Module.concat([Arbor, Consensus])

    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case safe_call(fn -> apply(consensus_mod, :get_status, [proposal_id]) end) do
      {:ok, status} -> {:ok, %{proposal_id: proposal_id, status: status}}
      {:error, reason} -> {:error, {:status_query_failed, reason}}
      nil -> {:error, :consensus_unavailable}
    end
  end

  # ── Generic Action Module Discovery ──

  defp run_discovered_action(nil, action, params) do
    Logger.warning("ActionDispatch: unknown action #{inspect(action)}, returning stub result")
    {:ok, %{action: action, status: :no_handler, params: params}}
  end

  defp run_discovered_action(action_module, action, params) do
    case safe_call(fn -> action_module.run(params, %{}) end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {action, reason}}
      nil -> {:error, {:action_failed, action}}
    end
  end

  # Map actions with hardcoded dispatch clauses to canonical dotted names.
  # Covers compound namespace modules (BackgroundChecks.Run) and inline-handled
  # actions (ai_analyze, proposal_status) that find_action_module can't discover.
  defp hardcoded_canonical_name(:background_checks_run), do: {:ok, "background_checks.run"}
  defp hardcoded_canonical_name(:proposal_submit), do: {:ok, "proposal.submit"}
  defp hardcoded_canonical_name(:code_hot_load), do: {:ok, "code.hot_load"}
  defp hardcoded_canonical_name(:ai_analyze), do: {:ok, "ai.analyze"}
  defp hardcoded_canonical_name(:proposal_status), do: {:ok, "proposal.status"}
  defp hardcoded_canonical_name(_), do: :error

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

  defp get_demo_llm_config do
    Application.get_env(:arbor_demo, :evaluator_llm_config, %{})
  end

  defp demo_mode? do
    Application.get_env(:arbor_demo, :demo_mode, false)
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
