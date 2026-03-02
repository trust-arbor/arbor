defmodule Arbor.Agent.Bootstrap do
  @moduledoc """
  Auto-starts agents on application boot.

  Two sources:

  1. **Config seeds** — infrastructure agents defined in application config
     (e.g., diagnostician). Always started.

  2. **Persisted profiles** — agents with `auto_start: true` in their profile.
     Set via `Manager.set_auto_start/2`.

  Seeds override `model_config` for matching agents (by `display_name`).
  Non-matching persisted agents pass through as-is.

  ## Configuration

      config :arbor_agent, :auto_start_agents, [
        %{
          display_name: "diagnostician",
          module: Arbor.Agent.APIAgent,
          template: "diagnostician",
          model_config: %{id: "model-id", provider: :openrouter, backend: :api},
          start_host: true
        }
      ]

      # Disable entirely (e.g., in tests):
      config :arbor_agent, bootstrap_enabled: false
  """

  use GenServer

  require Logger

  alias Arbor.Agent.{Manager, ProfileStore}

  @boot_delay 3_000
  @max_retries 3
  @retry_delays [5_000, 15_000, 45_000]

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

    {:ok, %{agents: [], status: :waiting, attempts: %{}}}
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
      case start_single_agent(config) do
        {:ok, result} ->
          Logger.info("[Bootstrap] Retry #{attempt} succeeded for #{agent_key}")

          safe_emit(:agent_auto_started, %{
            agent_id: result.agent_id,
            display_name: agent_key,
            attempt: attempt
          })

          {:noreply, %{state | agents: [result | state.agents]}}

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
      case start_single_agent(config) do
        {:ok, result} ->
          {[result | started], acc_state}

        {:error, reason} ->
          Logger.warning("[Bootstrap] Failed to start #{config.display_name}: #{inspect(reason)}")

          {_, new_state} = schedule_retry(config, 0, acc_state)
          {started, new_state}
      end
    end)
  end

  defp start_single_agent(config) do
    module = config[:module] || Arbor.Agent.APIAgent
    display_name = config.display_name

    opts =
      [display_name: display_name] ++
        if(config[:template], do: [template: config.template], else: []) ++
        if(config[:model_config], do: [model_config: config.model_config], else: []) ++
        if(config[:start_host], do: [start_host: true], else: [])

    case Manager.start_or_resume(module, display_name, opts) do
      {:ok, agent_id, _pid} ->
        {:ok, %{agent_id: agent_id, display_name: display_name}}

      {:error, _} = error ->
        error
    end
  rescue
    error ->
      {:error, {:exception, Exception.message(error)}}
  catch
    :exit, reason ->
      {:error, {:exit, reason}}
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
    _ -> []
  catch
    :exit, _ -> []
  end

  defp safe_emit(type, data) do
    Arbor.Signals.emit(:agent, type, data)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
