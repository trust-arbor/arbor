defmodule Arbor.AI.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # ExMCP debug-logs entire unsupported provider notifications. Native agents
    # can include account or credential-bearing settings in those payloads.
    :ok = Logger.put_module_level(ExMCP.ACP.Client, :info)

    # Propagate API keys from environment to ReqLLM
    propagate_api_keys()

    children =
      if Application.get_env(:arbor_ai, :start_children, true) do
        buffered_store_child() ++
          [
            Arbor.AI.QuotaTracker,
            Arbor.AI.RouteFailureStore,
            {Task.Supervisor, name: Arbor.AI.ProviderRouteEvidence.TaskSupervisor},
            Arbor.AI.ProviderRouteEvidence,
            # Exact-route OAuth ProviderModelCatalog cache (no network on read).
            Arbor.AI.ProviderModelCatalogStore,
            {Task.Supervisor, name: Arbor.AI.ProviderRouteReadiness.TaskSupervisor},
            Arbor.AI.ProviderRouteReadiness,
            # Node-local exact-route concurrency authority (not cluster-global).
            Arbor.AI.RouteConcurrency
          ] ++
          budget_tracker_child() ++
          llm_usage_consumer_child() ++
          usage_stats_child() ++
          managed_acp_children() ++
          acp_pool_children()
      else
        []
      end

    opts = [strategy: :one_for_one, name: Arbor.AI.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Always-on managed ACP session registry + DynamicSupervisor for non-pooled
  # managed AcpSession children. Independent of optional AcpPool.
  @doc false
  def managed_acp_children do
    [
      Arbor.AI.AcpManaged.Supervisor,
      Arbor.AI.AcpManaged.SessionRegistry
    ]
  end

  # Propagate API keys from environment variables to ReqLLM. The coding-plan
  # alias is Arbor-specific because ReqLLM's provider expects ZAI_API_KEY.
  @doc false
  def propagate_api_keys do
    key_mappings = [
      {"OPENROUTER_API_KEY", :openrouter_api_key},
      {"ANTHROPIC_API_KEY", :anthropic_api_key},
      {"OPENAI_API_KEY", :openai_api_key},
      {"GOOGLE_API_KEY", :google_api_key},
      {"GEMINI_API_KEY", :google_api_key},
      {"ZAI_API_KEY", :zai_api_key},
      {"ZAI_API_KEY", :zai_coding_plan_api_key},
      {"ZAI_CODING_PLAN_API_KEY", :zai_coding_plan_api_key}
    ]

    Enum.each(key_mappings, fn {env_var, config_key} ->
      case System.get_env(env_var) do
        nil -> :ok
        "" -> :ok
        value -> ReqLLM.put_key(config_key, value)
      end
    end)
  end

  # BufferedStore for quota + budget persistence.
  # Must start before QuotaTracker and BudgetTracker so they can restore on init.
  defp buffered_store_child do
    backend = Application.get_env(:arbor_ai, :persistence_backend)

    if backend do
      [
        {Arbor.Persistence.BufferedStore,
         name: :arbor_ai_tracking, backend: backend, write_mode: :async, collection: "ai_tracking"}
      ]
    else
      [
        {Arbor.Persistence.BufferedStore,
         name: :arbor_ai_tracking, backend: nil, write_mode: :async, collection: "ai_tracking"}
      ]
    end
  end

  # Conditionally add BudgetTracker based on config
  defp budget_tracker_child do
    if Application.get_env(:arbor_ai, :enable_budget_tracking, true) do
      [Arbor.AI.BudgetTracker]
    else
      []
    end
  end

  defp llm_usage_consumer_child do
    if Application.get_env(:arbor_ai, :enable_llm_usage_tracking, true) do
      [Arbor.AI.LLMUsageConsumer]
    else
      []
    end
  end

  # Conditionally add UsageStats based on config
  defp usage_stats_child do
    if Application.get_env(:arbor_ai, :enable_stats_tracking, true) do
      [Arbor.AI.UsageStats]
    else
      []
    end
  end

  # Conditionally add ACP session pool based on config.
  # Auto-enables when a catalog CLI is on PATH, unless explicitly disabled
  # with `enable_acp_pool: false`. Detection uses `AcpSession.Config` so new
  # native providers (and executable overrides) are picked up without a
  # second stale name list. Adapted providers still count only when their
  # CLI is present — never merely because adapter modules compiled.
  @doc false
  def acp_pool_children(opts \\ []) do
    enabled =
      case Application.get_env(:arbor_ai, :enable_acp_pool) do
        true -> true
        false -> false
        nil -> acp_agents_detected?(opts)
      end

    if enabled do
      pool_config = Application.get_env(:arbor_ai, :acp_pool_config, [])

      [
        Arbor.AI.AcpPool.Supervisor,
        {Arbor.AI.AcpPool, pool_config}
      ]
    else
      []
    end
  end

  defp acp_agents_detected?(opts) do
    case Keyword.get(opts, :executable_checker, &System.find_executable/1) do
      checker when is_function(checker, 1) ->
        Arbor.AI.AcpSession.Config.list_providers()
        |> Enum.any?(fn {provider, _kind} -> catalog_cli_present?(provider, checker) end)

      _invalid ->
        false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp catalog_cli_present?(provider, checker) do
    case Arbor.AI.AcpSession.Config.resolve(provider) do
      {:ok, resolved} when is_list(resolved) ->
        resolved
        |> detection_executables(provider)
        |> Enum.any?(&executable_present?(checker, &1))

      _other ->
        false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp detection_executables(resolved, provider) do
    cond do
      command = Keyword.get(resolved, :command) ->
        case command_executable(command) do
          nil -> []
          executable -> [executable]
        end

      Keyword.has_key?(resolved, :adapter) or Keyword.has_key?(resolved, :transport_mod) ->
        adapted_detection_executables(resolved, provider)

      true ->
        []
    end
  end

  defp command_executable([executable | _rest])
       when is_binary(executable) and executable != "",
       do: executable

  defp command_executable(executable) when is_binary(executable) and executable != "",
    do: executable

  defp command_executable(_command), do: nil

  # Adapted providers historically auto-enabled the pool when their CLI name
  # was on PATH (claude, codex). Honor an explicit `cli_path` override, else
  # use the catalog provider atom as that CLI name. Do not treat loaded
  # adapter modules as evidence the CLI is installed.
  defp adapted_detection_executables(resolved, provider) do
    adapter_opts = Keyword.get(resolved, :adapter_opts, [])

    case Keyword.get(adapter_opts, :cli_path) do
      path when is_binary(path) and path != "" ->
        [path]

      _missing ->
        [Atom.to_string(provider)]
    end
  end

  defp executable_present?(checker, name) when is_function(checker, 1) and is_binary(name) do
    case checker.(name) do
      path when is_binary(path) and path != "" -> true
      true -> true
      _other -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp executable_present?(_checker, _name), do: false
end
