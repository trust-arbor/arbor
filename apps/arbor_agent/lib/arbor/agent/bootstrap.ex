defmodule Arbor.Agent.Bootstrap do
  @moduledoc """
  Auto-starts existing agents on application boot.

  No human is present at boot, so every start runs as the system lifecycle
  principal (`Arbor.Agent.SystemLifecycleAuthority`, decision D4). That
  principal never creates agents and starts only agents a human opted into
  auto_start with `Manager.set_auto_start/3`, which delegated it the per-agent
  rights the start needs.

  Two sources:

  1. **Persisted profiles** — agents with `auto_start: true` in their profile.

  2. **Config seeds** — infrastructure agents named in application config
     (e.g., diagnostician). A seed only selects an existing profile (by
     `display_name` and `template`) and overrides its `model_config`. A seed
     with no profile is skipped with a warning: an operator must create it
     (`mix arbor.agent start`) and enable auto_start. A seed whose profile is not
     opted in is refused by the principal and skipped with a warning.

  Seeds override `model_config` for matching agents (by `display_name`).
  Non-matching persisted agents pass through as-is.

  ## Configuration

      config :arbor_agent, :auto_start_agents, [
        %{
          display_name: "diagnostician",
          module: Arbor.Agent.APIAgent,
          template: "diagnostician",
          model_config: %{id: "model-id", provider: :openrouter, runtime: :arbor}
        }
      ]

      # Disable entirely (e.g., in tests):
      config :arbor_agent, bootstrap_enabled: false

  `start_link/1` takes `:system_lifecycle_token`, the startup token
  `Arbor.Agent.Application` shares with the principal. Test builds also accept
  `:start_opts` (extra resume options for every start).
  """

  use GenServer

  require Logger

  alias Arbor.Agent.{Manager, ProfileStore, SystemLifecycleAuthority}

  @boot_delay 3_000
  @max_retries 3
  @retry_delays [5_000, 15_000, 45_000]
  @test_seams_enabled Mix.env() == :test

  # Refusals a retry cannot fix: only a human (or an operator) can.
  @not_retriable [
    :auto_start_not_enabled,
    :auto_start_not_delegated,
    :not_found,
    :invalid_start_request,
    :system_lifecycle_unauthorized,
    :seed_profile_missing
  ]

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the current bootstrap status and started agents."
  @spec status() :: map()
  def status do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :status)
    else
      %{status: :not_running, agents: []}
    end
  end

  # ── GenServer callbacks ─────────────────────────────────────────────

  @impl true
  def init(opts) do
    delay = Keyword.get(opts, :boot_delay, @boot_delay)

    if Application.get_env(:arbor_agent, :bootstrap_enabled, true) do
      Process.send_after(self(), :bootstrap, delay)
    end

    {:ok,
     %{
       agents: [],
       status: :waiting,
       attempts: %{},
       system_lifecycle_token: Keyword.get(opts, :system_lifecycle_token),
       start_opts: start_opts(opts)
     }}
  end

  @impl true
  def handle_info(:bootstrap, state) do
    seeds = Application.get_env(:arbor_agent, :auto_start_agents, [])
    persisted = safe_list_auto_start()
    merged = merge_configs(seeds, persisted)

    {started, new_state} = start_agents(merged, state)

    Logger.info(
      "[Bootstrap] Started #{length(started)}/#{length(merged)} auto-start agents: " <>
        inspect(Enum.map(started, & &1.display_name))
    )

    safe_emit(:bootstrap_completed, %{
      agents: Enum.map(started, &Map.take(&1, [:agent_id, :display_name])),
      total: length(merged)
    })

    {:noreply, %{new_state | status: :ready, agents: started}}
  end

  def handle_info({:retry, config}, state) do
    agent_key = config.display_name
    attempt = Map.get(state.attempts, agent_key, 0) + 1

    if attempt > @max_retries do
      Logger.warning("[Bootstrap] Giving up on #{agent_key} after #{@max_retries} retries")

      {:noreply, state}
    else
      case start_single_agent(config, state) do
        {:ok, result} ->
          Logger.info("[Bootstrap] Retry #{attempt} succeeded for #{agent_key}")

          safe_emit(:agent_auto_started, %{
            agent_id: result.agent_id,
            display_name: agent_key,
            attempt: attempt
          })

          {:noreply, %{state | agents: [result | state.agents]}}

        {:error, reason} when reason in @not_retriable ->
          log_refusal(config, reason)
          {:noreply, state}

        {:error, reason} ->
          Logger.warning(
            "[Bootstrap] Retry #{attempt}/#{@max_retries} failed for #{agent_key}: #{inspect(reason)}"
          )

          schedule_retry(config, attempt, state)
      end
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, Map.take(state, [:status, :agents, :attempts]), state}
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp start_agents(configs, state) do
    Enum.reduce(configs, {[], state}, fn config, {started, acc_state} ->
      case start_single_agent(config, acc_state) do
        {:ok, result} ->
          {[result | started], acc_state}

        {:error, reason} when reason in @not_retriable ->
          log_refusal(config, reason)
          {started, acc_state}

        {:error, reason} ->
          Logger.warning("[Bootstrap] Failed to start #{config.display_name}: #{inspect(reason)}")

          {_, new_state} = schedule_retry(config, 0, acc_state)
          {started, new_state}
      end
    end)
  end

  defp start_single_agent(config, state) do
    with {:ok, agent_id} <- resolve_agent_id(config) do
      case SystemLifecycleAuthority.start_agent(
             agent_id,
             resume_opts(config) ++ state.start_opts,
             state.system_lifecycle_token
           ) do
        {:ok, agent_id, _pid} ->
          {:ok, %{agent_id: agent_id, display_name: config.display_name}}

        {:error, _} = error ->
          error
      end
    end
  rescue
    error ->
      {:error, {:exception, Exception.message(error)}}
  catch
    :exit, reason ->
      {:error, {:exit, reason}}
  end

  # Persisted profiles carry their agent id. A seed only selects an existing
  # profile: the system principal never creates agents.
  defp resolve_agent_id(%{agent_id: agent_id}) when is_binary(agent_id), do: {:ok, agent_id}

  defp resolve_agent_id(config) do
    case Manager.find_existing_profile(config.display_name, config[:template]) do
      {:ok, agent_id} -> {:ok, agent_id}
      :not_found -> {:error, :seed_profile_missing}
    end
  end

  defp resume_opts(config) do
    case config[:model_config] do
      model_config when is_map(model_config) ->
        module = config[:module] || Arbor.Agent.APIAgent
        [model_config: Map.put(model_config, :module, module)]

      _ ->
        []
    end
  end

  defp log_refusal(config, :seed_profile_missing) do
    Logger.warning(
      "[Bootstrap] Skipping seed #{config.display_name}: no existing profile. " <>
        "The system lifecycle principal never creates agents; an operator must " <>
        "create it and enable auto_start."
    )
  end

  defp log_refusal(config, reason) do
    Logger.warning(
      "[Bootstrap] Skipping #{config.display_name}: the system lifecycle principal " <>
        "refused the start (#{inspect(reason)}). A human must enable auto_start " <>
        "with Manager.set_auto_start/3 to delegate it."
    )
  end

  defp schedule_retry(config, attempt, state) do
    delay = Enum.at(@retry_delays, attempt, List.last(@retry_delays))
    Process.send_after(self(), {:retry, config}, delay)
    new_attempts = Map.put(state.attempts, config.display_name, attempt)
    {:noreply, %{state | attempts: new_attempts}}
  end

  defp merge_configs(seeds, persisted_profiles) do
    seed_names = MapSet.new(seeds, & &1.display_name)

    # Convert persisted profiles to config maps, skip those covered by seeds
    persisted_configs =
      persisted_profiles
      |> Enum.reject(fn profile -> MapSet.member?(seed_names, profile.display_name) end)
      |> Enum.map(&profile_to_config/1)

    seeds ++ persisted_configs
  end

  defp profile_to_config(profile) do
    model_config =
      get_in(profile.metadata, [:last_model_config]) ||
        get_in(profile.metadata, ["last_model_config"])

    %{
      agent_id: profile.agent_id,
      display_name: profile.display_name || profile.agent_id,
      module: resolve_module(model_config),
      template: profile.template,
      model_config: model_config
    }
  end

  defp resolve_module(%{module: module}) when is_atom(module), do: module

  defp resolve_module(%{"module" => module}) when is_binary(module) do
    String.to_existing_atom(module)
  rescue
    ArgumentError -> Arbor.Agent.APIAgent
  end

  defp resolve_module(_), do: Arbor.Agent.APIAgent

  defp safe_list_auto_start do
    if ProfileStore.available?() do
      ProfileStore.list_auto_start_profiles()
    else
      []
    end
  rescue
    e ->
      Logger.warning("[Bootstrap] auto-start profile listing failed: #{Exception.message(e)}")
      []
  catch
    :exit, reason ->
      Logger.warning("[Bootstrap] auto-start profile listing exited: #{inspect(reason)}")
      []
  end

  if @test_seams_enabled do
    defp start_opts(opts) do
      case Keyword.get(opts, :start_opts, []) do
        start_opts when is_list(start_opts) -> start_opts
        _ -> []
      end
    end
  else
    defp start_opts(_opts), do: []
  end

  defp safe_emit(type, data) do
    Arbor.Signals.emit(:agent, type, data)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
