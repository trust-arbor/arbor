defmodule Arbor.AI.TestSupport.ProviderRouteEvidenceEventLog do
  @moduledoc false
  alias Arbor.Persistence.EventLog.ETS

  def durability_class(_opts), do: :node_restart
  def append(stream, events, opts), do: ETS.append(stream, events, opts)
  def reconcile_append(operation, opts), do: ETS.reconcile_append(operation, opts)
  def stream_version(stream, opts), do: ETS.stream_version(stream, opts)
  def read_stream(stream, opts), do: ETS.read_stream(stream, opts)
end

defmodule Arbor.AI.TestSupport.ProviderRouteEvidence do
  @moduledoc false

  def reset! do
    case Process.whereis(Arbor.AI.ProviderRouteEvidence) do
      pid when is_pid(pid) -> if Process.alive?(pid), do: GenServer.stop(pid)
      _ -> :ok
    end

    old_name = Application.get_env(:arbor_ai, :provider_route_evidence_test_name)

    if is_atom(old_name) do
      case Process.whereis(old_name) do
        pid when is_pid(pid) -> if Process.alive?(pid), do: GenServer.stop(pid)
        _ -> :ok
      end
    end

    name = :provider_route_evidence_test_log

    {:ok, _pid} =
      Arbor.Persistence.EventLog.ETS.start_link(
        name: name,
        max_age_ms: :infinity,
        trim_interval_ms: :disabled
      )

    target = [name: name, backend: Arbor.AI.TestSupport.ProviderRouteEvidenceEventLog, opts: []]
    Application.put_env(:arbor_ai, :provider_route_evidence_target, target)
    Application.put_env(:arbor_ai, :provider_route_evidence_test_name, name)
    {:ok, _pid} = Arbor.AI.ProviderRouteEvidence.start_link(target: target)
    await_ready!()
    :ok
  end

  defp await_ready!(attempts \\ 100)

  defp await_ready!(attempts) when attempts <= 0,
    do: raise("provider route evidence did not become ready")

  defp await_ready!(attempts) do
    case Arbor.AI.ProviderRouteEvidence.status() do
      %{status: :ready} ->
        :ok

      %{status: :replaying} ->
        Process.sleep(1)
        await_ready!(attempts - 1)

      status ->
        raise("provider route evidence unavailable: #{inspect(status)}")
    end
  end
end

# Add children to the empty app supervisor (start_children: false leaves it empty)
children =
  [
    Arbor.AI.QuotaTracker,
    Arbor.AI.RouteFailureStore,
    {Task.Supervisor, name: Arbor.AI.ProviderRouteEvidence.TaskSupervisor},
    # Exact-route OAuth ProviderModelCatalog cache (no network on read).
    Arbor.AI.ProviderModelCatalogStore,
    # Node-local exact-route concurrency authority (not cluster-global).
    Arbor.AI.RouteConcurrency
  ] ++
    if(Application.get_env(:arbor_ai, :enable_budget_tracking, true),
      do: [Arbor.AI.BudgetTracker],
      else: []
    ) ++
    if(Application.get_env(:arbor_ai, :enable_stats_tracking, true),
      do: [Arbor.AI.UsageStats],
      else: []
    )

for child <- children do
  Supervisor.start_child(Arbor.AI.Supervisor, child)
end

Arbor.AI.TestSupport.ProviderRouteEvidence.reset!()

defmodule Arbor.AI.TestSupport.AutoTrustPolicy do
  @moduledoc false

  def confirmation_mode(_agent_id, _resource_uri), do: :auto
end

ExUnit.start(exclude: [:external, :skip, :llm, :llm_local])
