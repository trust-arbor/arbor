defmodule Arbor.AI.ProviderRouteReadiness do
  @moduledoc """
  Supervised coordinator for strict provider-route readiness.

  The coordinator starts blocked and performs only local, bounded observation in
  its request path. Catalog refreshes run in a `Task.Supervisor` task and are
  never performed by `ensure_ready/1`. Catalogs are intentionally volatile;
  durable route evidence is owned by `ProviderRouteEvidence` and is observed as
  a separate prerequisite.
  """

  use GenServer

  alias Arbor.AI.ProviderModelCatalogStore
  alias Arbor.AI.ProviderModelCatalogRefresh
  alias Arbor.AI.ProviderRouteEvidence
  alias Arbor.AI.ProviderRouteReadinessCore
  alias Arbor.AI.Runtime.ProviderModelCatalogEvidence
  alias Arbor.AI.Runtime.RouteInputAssembler
  alias Arbor.Contracts.LLM.OAuthHealth

  @name __MODULE__
  @task_supervisor Arbor.AI.ProviderRouteReadiness.TaskSupervisor
  @schema_version 1
  @call_timeout 1_000
  @refresh_timeout_ms 15_000
  @max_backoff_ms 60_000
  @steady_observation_ms 30_000
  @pending_observation_ms 500
  @max_jitter_ms 250
  @catalog_refresh_horizon_ms @steady_observation_ms + @refresh_timeout_ms + @max_jitter_ms
  @max_attempts 8
  @routes ["openai_oauth", "xai_oauth"]
  @max_bindings 256
  @max_model_id_bytes 256

  defstruct requirements: %{enabled: false, required_routes: [], binding: []},
            status: nil,
            task_ref: nil,
            timer_ref: nil,
            failures: 0,
            clock: &DateTime.utc_now/0,
            jitter: &__MODULE__.default_jitter/1,
            requirements_reader: &RouteInputAssembler.production_requirements/0,
            evidence_reader: &ProviderRouteEvidence.status/0,
            catalog_reader: &ProviderModelCatalogStore.snapshot_sync/0,
            health_reader: &Arbor.LLM.oauth_health/1,
            refresh_fun: &ProviderModelCatalogRefresh.refresh/2,
            task_supervisor: @task_supervisor

  @type requirements :: %{
          enabled: boolean(),
          required_routes: [String.t()],
          binding: [map()]
        }

  @doc false
  def child_spec(opts) do
    %{
      id: @name,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc false
  def default_jitter(max) when is_integer(max) and max > 0, do: :rand.uniform(max)
  def default_jitter(_max), do: 0

  @doc "Return the current bounded, JSON-clean readiness status."
  @spec status() :: map()
  def status do
    case Process.whereis(@name) do
      pid when is_pid(pid) ->
        try do
          GenServer.call(pid, :status, @call_timeout)
        catch
          :exit, _ -> unavailable_status()
        end

      _ ->
        unavailable_status()
    end
  end

  @doc false
  @spec ensure_ready(requirements()) :: :ok | {:ok, :disabled} | {:error, atom()}
  def ensure_ready(requirements) do
    with {:ok, requirements} <- normalize_requirements(requirements) do
      case Process.whereis(@name) do
        pid when is_pid(pid) ->
          try do
            GenServer.call(pid, {:ensure_ready, requirements}, @call_timeout)
          catch
            :exit, _ -> {:error, :unavailable}
          end

        _ ->
          {:error, :unavailable}
      end
    else
      {:error, :malformed} -> {:error, :malformed}
    end
  end

  @doc "Ask the coordinator to retry readiness, including permanent auth failures."
  @spec manual_refresh() :: {:ok, :scheduled | :already_running} | {:error, atom()}
  def manual_refresh do
    case Process.whereis(@name) do
      pid when is_pid(pid) ->
        try do
          GenServer.call(pid, :manual_refresh, @call_timeout)
        catch
          :exit, _ -> {:error, :unavailable}
        end

      _ ->
        {:error, :unavailable}
    end
  end

  @impl true
  def init(opts) do
    # This function only stores already-constructed readers and schedules a
    # message. All profile, credential, persistence, and network work occurs in
    # the later supervised observation task.
    state = %__MODULE__{
      clock: option_fun(opts, :clock, &DateTime.utc_now/0, 0),
      jitter: option_fun(opts, :jitter, &__MODULE__.default_jitter/1, 1),
      requirements_reader:
        option_fun(opts, :requirements_reader, &RouteInputAssembler.production_requirements/0, 0),
      evidence_reader: option_fun(opts, :evidence_reader, &ProviderRouteEvidence.status/0, 0),
      catalog_reader:
        option_fun(opts, :catalog_reader, &ProviderModelCatalogStore.snapshot_sync/0, 0),
      health_reader: option_fun(opts, :health_reader, &Arbor.LLM.oauth_health/1, 1),
      refresh_fun: option_fun(opts, :refresh_fun, &ProviderModelCatalogRefresh.refresh/2, 2),
      task_supervisor: Keyword.get(opts, :task_supervisor, @task_supervisor),
      status: startup_status()
    }

    send(self(), :observe)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call({:ensure_ready, requirements}, _from, state) do
    result =
      cond do
        requirements != state.requirements and state.requirements.enabled ->
          {:error, :route_set_changed}

        not requirements.enabled and state.status["state"] == "disabled" ->
          {:ok, :disabled}

        requirements.enabled and requirements != state.requirements ->
          {:error, :not_ready}

        state.status["ready"] == true ->
          :ok

        true ->
          {:error, :not_ready}
      end

    {:reply, result, state}
  end

  def handle_call(:manual_refresh, _from, %{task_ref: ref} = state) when is_reference(ref) do
    {:reply, {:ok, :already_running}, state}
  end

  def handle_call(:manual_refresh, _from, state) do
    send(self(), :observe)
    {:reply, {:ok, :scheduled}, %{state | failures: 0, timer_ref: nil}}
  end

  @impl true
  def handle_info(:observe, %{task_ref: nil} = state) do
    case start_observation(state) do
      {:ok, ref} ->
        {:noreply, %{state | task_ref: ref, timer_ref: nil}}

      {:error, _reason} ->
        {:noreply, schedule_retry(%{state | status: blocked_status(:unavailable)})}
    end
  end

  def handle_info(:observe, state), do: {:noreply, state}

  def handle_info({:observe, ref}, %{timer_ref: ref, task_ref: nil} = state) do
    handle_info(:observe, %{state | timer_ref: nil})
  end

  def handle_info({:observe, _ref}, state), do: {:noreply, state}

  def handle_info({ref, {:ok, observation}}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    next = apply_observation(state, observation)
    {:noreply, %{next | task_ref: nil}}
  end

  def handle_info({ref, {:error, reason}}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    next = schedule_retry(%{state | status: blocked_status(reason), task_ref: nil})
    {:noreply, next}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task_ref: ref} = state) do
    next = schedule_retry(%{state | status: blocked_status(:unavailable), task_ref: nil})
    {:noreply, next}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_observation(state) do
    Task.Supervisor.async_nolink(state.task_supervisor, fn -> observe(state) end)
    |> then(&{:ok, &1.ref})
  rescue
    _ -> {:error, :task_supervisor_unavailable}
  catch
    _, _ -> {:error, :task_supervisor_unavailable}
  end

  defp observe(state) do
    with {:ok, now} <- safe_now(state.clock),
         {:ok, requirements} <- read_requirements(state.requirements_reader),
         {:ok, observation} <- collect_observation(state, requirements, now) do
      {:ok, observation}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp collect_observation(_state, %{enabled: false} = requirements, now) do
    facts =
      base_facts(false, [], %{"status" => "complete"}, %{}, %{}, %{})

    {:ok,
     %{
       requirements: requirements,
       status: ProviderRouteReadinessCore.evaluate(facts, now),
       retry: :steady
     }}
  end

  defp collect_observation(state, requirements, now) do
    durable = durable_fact(state.evidence_reader.())
    {snapshot, snapshot_kind} = catalog_fact(state.catalog_reader.())
    {auth_health, generations} = health_facts(state.health_reader, requirements.required_routes)

    facts =
      base_facts(
        true,
        requirements.required_routes,
        durable,
        auth_health,
        snapshot,
        generations
      )

    {final_facts, refresh_result} =
      maybe_refresh(
        state,
        requirements.required_routes,
        facts,
        snapshot_kind,
        durable,
        now
      )

    result = ProviderRouteReadinessCore.evaluate(final_facts, now)
    retry = retry_kind(result, refresh_result)
    {:ok, %{requirements: requirements, status: result, retry: retry}}
  rescue
    _ -> {:error, :observation_malformed}
  catch
    _, _ -> {:error, :observation_malformed}
  end

  defp maybe_refresh(
         _state,
         _routes,
         facts,
         _snapshot_kind,
         durable,
         _now
       )
       when durable != %{"status" => "complete"} do
    {facts, :none}
  end

  defp maybe_refresh(
         _state,
         [],
         facts,
         _snapshot_kind,
         _durable,
         _now
       ),
       do: {facts, :none}

  defp maybe_refresh(
         _state,
         _routes,
         facts,
         snapshot_kind,
         _durable,
         _now
       )
       when snapshot_kind != :available,
       do: {facts, :none}

  defp maybe_refresh(
         state,
         routes,
         facts,
         _snapshot_kind,
         _durable,
         now
       ) do
    snapshot = facts.catalog_snapshot
    generations = facts.credential_generations
    auth_health = facts.auth_health
    outcomes = facts.refresh_outcomes

    refresh_routes =
      Enum.filter(routes, fn route ->
        refresh_route?(
          Map.get(auth_health, route),
          snapshot,
          route,
          Map.get(generations, route),
          Map.get(outcomes, route),
          now
        )
      end)

    if refresh_routes == [] do
      {facts, :none}
    else
      {next_outcomes, refreshed?} = refresh_each(state.refresh_fun, refresh_routes, outcomes)

      final_facts =
        if refreshed? do
          {next_health, next_generations} = health_facts(state.health_reader, routes)
          {next_snapshot, _kind} = catalog_fact(state.catalog_reader.())

          facts
          |> Map.put(:auth_health, next_health)
          |> Map.put(:credential_generations, next_generations)
          |> Map.put(:catalog_snapshot, next_snapshot)
          |> Map.put(:refresh_outcomes, next_outcomes)
        else
          Map.put(facts, :refresh_outcomes, next_outcomes)
        end

      refresh_result =
        if Enum.any?(refresh_routes, &(Map.get(next_outcomes, &1) == "transient")),
          do: :transient,
          else: :settled

      {final_facts, refresh_result}
    end
  end

  defp refresh_each(refresh_fun, routes, outcomes) do
    Enum.reduce(routes, {outcomes, false}, fn route, {acc, refreshed?} ->
      case refresh_one(refresh_fun, route) do
        "success" -> {Map.delete(acc, route), true}
        "permanent" -> {Map.put(acc, route, "permanent"), refreshed?}
        "transient" -> {Map.put(acc, route, "transient"), refreshed?}
      end
    end)
  end

  defp refresh_one(refresh_fun, route) do
    refresh_fun.(route, timeout_ms: @refresh_timeout_ms)
    |> ProviderRouteReadinessCore.classify_refresh_result()
  rescue
    _ -> "transient"
  catch
    _, _ -> "transient"
  end

  defp catalog_needs_refresh?(snapshot, route, generation, now) do
    case Map.fetch(snapshot["catalogs"], route) do
      :error ->
        true

      {:ok, catalog} ->
        case ProviderModelCatalogEvidence.assess(
               catalog,
               route,
               expected_backend(route),
               "arbor",
               generation,
               now
             ) do
          {:ok, catalog} -> catalog_expires_within_refresh_horizon?(catalog, now)
          {:error, :observed_in_future} -> false
          {:error, _reason} -> true
        end
    end
  end

  defp catalog_expires_within_refresh_horizon?(catalog, now) do
    case DateTime.from_iso8601(catalog.expires_at) do
      {:ok, expires_at, _offset} ->
        DateTime.diff(expires_at, now, :millisecond) <= @catalog_refresh_horizon_ms

      _ ->
        true
    end
  end

  defp refresh_route?(status, snapshot, route, generation, outcome, now) do
    if outcome == "permanent" do
      false
    else
      case ProviderRouteReadinessCore.classify_auth_health(status) do
        :ready -> catalog_needs_refresh?(snapshot, route, generation, now)
        :transient -> true
        :permanent -> false
        :malformed -> false
      end
    end
  end

  defp apply_observation(state, %{requirements: requirements, status: status, retry: retry}) do
    next = %{state | requirements: requirements, status: status}

    case retry do
      :permanent -> %{next | failures: @max_attempts}
      :steady -> schedule_steady(%{next | failures: 0})
      :pending -> schedule_after(%{next | failures: 0}, @pending_observation_ms)
      :transient -> schedule_retry(%{next | failures: min(state.failures + 1, @max_attempts)})
    end
  end

  defp retry_kind(status, refresh_result) do
    cond do
      status["state"] == "disabled" ->
        :steady

      status["state"] in ["catalog_refresh_permanent", "oauth_health_permanent"] ->
        :permanent

      status["state"] in ["durable_replay_pending"] ->
        :pending

      refresh_result == :transient ->
        :transient

      status["ready"] == true ->
        :steady

      status["state"] in ["durable_replay_unavailable", "durable_replay_malformed_or_incomplete"] ->
        :transient

      true ->
        :transient
    end
  end

  defp schedule_retry(%{failures: failures} = state) do
    exponent = max(failures - 1, 0)
    base = min(@max_backoff_ms - @max_jitter_ms, 1_000 * Integer.pow(2, exponent))
    jitter = bounded_jitter(state.jitter)
    schedule_after(state, base + jitter)
  end

  defp schedule_steady(state), do: schedule_after(state, @steady_observation_ms)

  defp schedule_after(state, delay) do
    ref = make_ref()
    _timer = Process.send_after(self(), {:observe, ref}, delay)
    # The message reference, not the timer reference, is the guard against a
    # canceled timer racing a newly scheduled observation.
    %{state | timer_ref: ref}
  rescue
    _ -> %{state | timer_ref: nil}
  end

  defp bounded_jitter(jitter) do
    case jitter.(@max_jitter_ms) do
      value when is_integer(value) and value >= 0 and value <= @max_jitter_ms -> value
      _ -> 0
    end
  rescue
    _ -> 0
  catch
    _, _ -> 0
  end

  defp read_requirements(reader) do
    case reader.() do
      {:ok, requirements} -> normalize_requirements(requirements)
      _ -> {:error, :requirements_unavailable}
    end
  rescue
    _ -> {:error, :requirements_unavailable}
  catch
    _, _ -> {:error, :requirements_unavailable}
  end

  defp normalize_requirements(requirements)
       when is_map(requirements) and not is_struct(requirements) and map_size(requirements) == 3 do
    with [:binding, :enabled, :required_routes] <- Enum.sort(Map.keys(requirements)),
         enabled when is_boolean(enabled) <- Map.get(requirements, :enabled),
         routes when is_list(routes) <- Map.get(requirements, :required_routes),
         binding when is_list(binding) <- Map.get(requirements, :binding),
         {:ok, routes} <- normalize_routes(routes),
         {:ok, binding} <- normalize_binding(binding, routes),
         :ok <- validate_requirement_mode(enabled, routes, binding) do
      {:ok, %{enabled: enabled, required_routes: routes, binding: binding}}
    else
      _ -> {:error, :malformed}
    end
  end

  defp normalize_requirements(_), do: {:error, :malformed}

  defp normalize_routes(routes), do: collect_routes(routes, [], 0)

  defp collect_routes([], routes, _count) do
    {:ok, Enum.filter(@routes, &(&1 in routes))}
  end

  defp collect_routes([route | rest], routes, count)
       when route in @routes and count < length(@routes) do
    if route in routes do
      {:error, :malformed}
    else
      collect_routes(rest, [route | routes], count + 1)
    end
  end

  defp collect_routes(_routes, _seen, _count), do: {:error, :malformed}

  defp normalize_binding(binding, routes), do: collect_binding(binding, routes, [], 0)

  defp collect_binding([], _routes, binding, _count) do
    canonical =
      Enum.sort_by(binding, fn entry ->
        {entry["route"], entry["model_id"], entry["runtime"]}
      end)

    if length(Enum.uniq(canonical)) == length(canonical),
      do: {:ok, canonical},
      else: {:error, :malformed}
  end

  defp collect_binding([entry | rest], routes, binding, count) when count < @max_bindings do
    with {:ok, normalized} <- normalize_binding_entry(entry, routes) do
      collect_binding(rest, routes, [normalized | binding], count + 1)
    end
  end

  defp collect_binding(_binding, _routes, _acc, _count), do: {:error, :malformed}

  defp normalize_binding_entry(entry, routes)
       when is_map(entry) and not is_struct(entry) and map_size(entry) == 3 do
    with ["model_id", "route", "runtime"] <- Enum.sort(Map.keys(entry)),
         route when is_binary(route) <- Map.get(entry, "route"),
         true <- route in routes,
         "arbor" <- Map.get(entry, "runtime"),
         {:ok, model_id} <- normalize_model_id(Map.get(entry, "model_id")) do
      {:ok, %{"route" => route, "model_id" => model_id, "runtime" => "arbor"}}
    else
      _ -> {:error, :malformed}
    end
  end

  defp normalize_binding_entry(_entry, _routes), do: {:error, :malformed}

  defp normalize_model_id(model_id)
       when is_binary(model_id) and byte_size(model_id) > 0 and
              byte_size(model_id) <= @max_model_id_bytes do
    if String.valid?(model_id) and String.trim(model_id) != "" and
         not String.match?(model_id, ~r/[\x00-\x1F\x7F]/) do
      {:ok, model_id}
    else
      {:error, :malformed}
    end
  end

  defp normalize_model_id(_model_id), do: {:error, :malformed}

  defp validate_requirement_mode(false, [], []), do: :ok

  defp validate_requirement_mode(true, routes, binding) do
    binding_routes = binding |> Enum.map(& &1["route"]) |> Enum.uniq() |> Enum.sort()

    if Enum.sort(routes) == binding_routes, do: :ok, else: {:error, :malformed}
  end

  defp validate_requirement_mode(_enabled, _routes, _binding), do: {:error, :malformed}

  defp durable_fact(%{status: :ready}), do: %{"status" => "complete"}
  defp durable_fact(%{status: :replaying}), do: %{"status" => "pending"}
  defp durable_fact(%{status: :malformed}), do: %{"status" => "malformed"}
  defp durable_fact(%{status: :incomplete}), do: %{"status" => "incomplete"}
  defp durable_fact(%{status: _}), do: %{"status" => "unavailable"}
  defp durable_fact(_), do: %{"status" => "unavailable"}

  defp catalog_fact({:ok, catalogs}) when is_map(catalogs),
    do: {%{"status" => "available", "catalogs" => catalogs}, :available}

  defp catalog_fact({:error, :unavailable}),
    do: {%{"status" => "unavailable", "catalogs" => %{}}, :unavailable}

  defp catalog_fact({:error, :malformed}),
    do: {%{"status" => "malformed", "catalogs" => %{}}, :malformed}

  defp catalog_fact(_), do: {%{"status" => "malformed", "catalogs" => %{}}, :malformed}

  defp health_facts(reader, routes) do
    Enum.reduce(routes, {%{}, %{}}, fn route, {health_statuses, generations} ->
      case admit_health(reader.(route)) do
        {:ok, health} when health.route == route ->
          generations =
            if is_integer(health.generation),
              do: Map.put(generations, route, health.generation),
              else: generations

          {Map.put(health_statuses, route, health.status), generations}

        {:ok, _wrong_route} ->
          {Map.put(health_statuses, route, "malformed"), generations}

        {:error, :malformed} ->
          {Map.put(health_statuses, route, "malformed"), generations}

        _ ->
          {Map.put(health_statuses, route, "unavailable"), generations}
      end
    end)
  rescue
    _ -> {Map.new(routes, &{&1, "unavailable"}), %{}}
  catch
    _, _ -> {Map.new(routes, &{&1, "unavailable"}), %{}}
  end

  defp admit_health({:ok, %OAuthHealth{} = health}),
    do: admit_health_map(OAuthHealth.to_map(health))

  defp admit_health({:ok, attrs}) when is_map(attrs), do: admit_health_map(attrs)
  defp admit_health(_), do: {:error, :unavailable}

  defp admit_health_map(attrs) do
    case OAuthHealth.new(attrs) do
      {:ok, health} -> {:ok, health}
      _ -> {:error, :malformed}
    end
  rescue
    _ -> {:error, :malformed}
  catch
    _, _ -> {:error, :malformed}
  end

  defp base_facts(enabled, routes, durable, auth_health, snapshot, generations) do
    %{
      policy_enabled: enabled,
      required_routes: routes,
      durable_replay: durable,
      auth_health: auth_health,
      catalog_snapshot: snapshot,
      credential_generations: generations,
      refresh_outcomes: %{}
    }
  end

  defp expected_backend("openai_oauth"), do: "openai"
  defp expected_backend("xai_oauth"), do: "xai"

  defp safe_now(clock) do
    case clock.() do
      %DateTime{utc_offset: 0, std_offset: 0, calendar: Calendar.ISO} = now -> {:ok, now}
      _ -> {:error, :invalid_clock}
    end
  rescue
    _ -> {:error, :invalid_clock}
  catch
    _, _ -> {:error, :invalid_clock}
  end

  defp option_fun(opts, key, default, arity) do
    case Keyword.get(opts, key, default) do
      fun when is_function(fun, arity) -> fun
      _ -> default
    end
  end

  defp startup_status do
    %{
      "version" => @schema_version,
      "state" => "startup_blocked",
      "ready" => false,
      "required_routes" => [],
      "blocking_routes" => [],
      "checked_at" => nil
    }
  end

  defp blocked_status(reason) do
    %{
      "version" => @schema_version,
      "state" => if(reason == :invalid_clock, do: "malformed_input", else: "unavailable"),
      "ready" => false,
      "required_routes" => [],
      "blocking_routes" => [],
      "checked_at" => nil
    }
  end

  defp unavailable_status do
    %{
      "version" => @schema_version,
      "state" => "unavailable",
      "ready" => false,
      "required_routes" => [],
      "blocking_routes" => [],
      "checked_at" => nil
    }
  end
end
