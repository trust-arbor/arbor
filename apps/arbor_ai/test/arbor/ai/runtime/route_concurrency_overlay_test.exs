defmodule Arbor.AI.Runtime.RouteConcurrencyOverlayTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.AI.RouteConcurrency
  alias Arbor.AI.Runtime.RouteEvidenceOverlay
  alias Arbor.AI.Runtime.RouteInputAssembler
  alias Arbor.Contracts.LLM.{BudgetSnapshot, ModelEntry, ProviderEntry, ProviderObservation}

  @now ~U[2026-07-22 22:00:00Z]

  describe "RouteEvidenceOverlay.overlay_concurrency/2" do
    test "sets exact limit and in_use; nil leaves evidence missing" do
      base = %{"provider" => "openai", "runtime" => "arbor", "source" => "test"}

      overlaid =
        RouteEvidenceOverlay.overlay_concurrency(base, %{
          concurrency_limit: 4,
          concurrency_in_use: 1
        })

      assert overlaid["concurrency_limit"] == 4
      assert overlaid["concurrency_in_use"] == 1

      missing = RouteEvidenceOverlay.overlay_concurrency(base, nil)
      refute Map.has_key?(missing, "concurrency_limit")
      refute Map.has_key?(missing, "concurrency_in_use")
    end
  end

  describe "assembler default observation path" do
    test "overlays configured exact route concurrency from one snapshot" do
      ensure_default_authority(%{"openai_oauth" => %{"arbor" => 3}})

      assert {:ok, lease} = RouteConcurrency.acquire("openai_oauth", "arbor")

      model = model_entry("m1", :openai_oauth, :arbor)

      assert {:ok, input} =
               RouteInputAssembler.assemble(
                 profile: enabled_profile([model]),
                 clock: fn -> @now end,
                 budget_reader: fn providers, dt ->
                   {:ok, Enum.map(providers, &budget(&1, dt))}
                 end
               )

      obs = hd(input.observations)
      assert obs.concurrency_limit == 3
      assert obs.concurrency_in_use == 1
      assert ProviderObservation.valid?(obs)

      assert :ok = RouteConcurrency.release(lease)
    end

    test "unconfigured exact route leaves concurrency evidence missing" do
      ensure_default_authority(%{})

      model = model_entry("m1", :openai_oauth, :arbor)

      assert {:ok, input} =
               RouteInputAssembler.assemble(
                 profile: enabled_profile([model]),
                 clock: fn -> @now end,
                 budget_reader: fn providers, dt ->
                   {:ok, Enum.map(providers, &budget(&1, dt))}
                 end
               )

      obs = hd(input.observations)
      assert is_nil(obs.concurrency_limit)
      assert is_nil(obs.concurrency_in_use)
    end

    test "injected observation_reader is left untouched (no concurrency source)" do
      model = model_entry("m1", :openai_oauth, :arbor)

      assert {:ok, input} =
               RouteInputAssembler.assemble(
                 profile: enabled_profile([model]),
                 clock: fn -> @now end,
                 observation_reader: fn providers, dt ->
                   {:ok,
                    Enum.map(providers, fn p ->
                      %{
                        "version" => 1,
                        "provider" => p,
                        "source" => "injected",
                        "runtime" => "arbor",
                        "observed_at" => DateTime.to_iso8601(dt),
                        "availability" => "available"
                      }
                    end)}
                 end,
                 budget_reader: fn providers, dt ->
                   {:ok, Enum.map(providers, &budget(&1, dt))}
                 end
               )

      obs = hd(input.observations)
      assert obs.source == "injected"
      assert is_nil(obs.concurrency_limit)
      assert is_nil(obs.concurrency_in_use)
    end

    test "fails closed when concurrency authority is unavailable" do
      prior = Application.fetch_env(:arbor_ai, :provider_route_concurrency_limits)

      if Process.whereis(RouteConcurrency) do
        _ = Supervisor.terminate_child(Arbor.AI.Supervisor, RouteConcurrency)
      end

      on_exit(fn -> restore_default_authority(prior) end)

      model = model_entry("m1", :openai_oauth, :arbor)

      assert {:error, {:route_assembly_failed, :route_concurrency_evidence_unavailable}} =
               RouteInputAssembler.assemble(
                 profile: enabled_profile([model]),
                 clock: fn -> @now end,
                 budget_reader: fn providers, dt ->
                   {:ok, Enum.map(providers, &budget(&1, dt))}
                 end
               )
    end
  end

  defp ensure_default_authority(limits) when is_map(limits) do
    prior = Application.fetch_env(:arbor_ai, :provider_route_concurrency_limits)

    if Process.whereis(RouteConcurrency) do
      _ = Supervisor.terminate_child(Arbor.AI.Supervisor, RouteConcurrency)
    end

    on_exit(fn -> restore_default_authority(prior) end)

    Application.put_env(:arbor_ai, :provider_route_concurrency_limits, limits)
    restart_default_authority()
  end

  # Restore exact prior Application value, including unset (`:error` from fetch_env).
  defp restore_default_authority(:error) do
    Application.delete_env(:arbor_ai, :provider_route_concurrency_limits)
    restart_default_authority()
  end

  defp restore_default_authority({:ok, prior}) do
    Application.put_env(:arbor_ai, :provider_route_concurrency_limits, prior)
    restart_default_authority()
  end

  defp restart_default_authority do
    case Process.whereis(RouteConcurrency) do
      pid when is_pid(pid) ->
        try do
          GenServer.stop(pid, :normal, 500)
        catch
          :exit, _ -> :ok
        end

      _ ->
        :ok
    end

    case Supervisor.restart_child(Arbor.AI.Supervisor, RouteConcurrency) do
      {:ok, _} ->
        :ok

      {:error, :running} ->
        :ok

      {:error, {:already_started, _}} ->
        :ok

      {:error, :not_found} ->
        _ = Supervisor.start_child(Arbor.AI.Supervisor, RouteConcurrency)
        :ok

      {:error, _} ->
        _ = RouteConcurrency.start_link([])
        :ok
    end
  end

  defp enabled_profile(catalog) do
    providers =
      catalog
      |> Enum.flat_map(fn m -> Enum.map(m.providers, &Atom.to_string(&1.id)) end)
      |> Enum.uniq()

    %{
      enabled: true,
      task_registry: %{"default" => %{requirements: %{}}},
      default_task_class: "default",
      catalog: catalog,
      scoreboard: [],
      providers: providers,
      params: %{}
    }
  end

  defp model_entry(id, provider, runtime) do
    %ModelEntry{
      canonical_id: id,
      providers: [
        %ProviderEntry{id: provider, ref: id, auth: :api_key, runtimes: [runtime]}
      ],
      family: :test,
      context_window: 100_000,
      max_output_tokens: 4_000
    }
  end

  defp budget(provider, %DateTime{} = dt) do
    {:ok, snap} =
      BudgetSnapshot.new(%{
        version: 1,
        provider: provider,
        source: "arbor_ai_trackers",
        observed_at: DateTime.to_iso8601(dt),
        expires_at: DateTime.to_iso8601(DateTime.add(dt, 300, :second)),
        current_spend: 0.0,
        request_count: 0,
        quota_state: "available",
        subscription_capacity_state: "unknown"
      })

    snap
  end
end
