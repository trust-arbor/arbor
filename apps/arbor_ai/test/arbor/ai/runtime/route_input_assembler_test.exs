defmodule Arbor.AI.Runtime.RouteInputAssemblerTest do
  use ExUnit.Case, async: false

  alias Arbor.AI
  alias Arbor.AI.Runtime.RouteInputAssembler
  alias Arbor.Contracts.LLM.{BudgetSnapshot, ModelEntry, ProviderEntry, ProviderObservation}

  @moduletag :fast
  @decision_time ~U[2026-07-22 22:00:00Z]
  @stale_observed "2026-07-22T20:00:00Z"
  @stale_expires "2026-07-22T21:00:00Z"

  test "absent or disabled profile returns disabled" do
    assert {:error, :disabled} = RouteInputAssembler.assemble(profile: nil)
    assert {:error, :disabled} = RouteInputAssembler.assemble(profile: %{enabled: false})
  end

  test "enabled happy path forces strict_evidence and uses one decision_time" do
    model = model_entry("model-a", :provider)
    obs = observation("provider", "model-a", @stale_observed, "2026-07-22T23:00:00Z")
    budget = budget("provider", @stale_observed, "2026-07-22T23:00:00Z")

    assert {:ok, input} =
             RouteInputAssembler.assemble(
               profile: enabled_profile([model], [score_row("model-a", "provider")]),
               clock: fn -> @decision_time end,
               observation_reader: fn _providers, _dt -> {:ok, [obs]} end,
               budget_reader: fn _providers, _dt -> {:ok, [budget]} end
             )

    assert input.now == @decision_time
    assert input.policy.strict_evidence == true
    assert input.policy.params == %{}
    assert [%ProviderObservation{}] = input.observations
    assert [%BudgetSnapshot{}] = input.budgets
    assert hd(input.observations).observed_at == @stale_observed
    assert Map.has_key?(input.task_registry, "default")
  end

  test "preserves stale observation timestamps exactly and never restamps" do
    model = model_entry("model-a", :provider)
    obs = observation("provider", "model-a", @stale_observed, @stale_expires)

    assert {:ok, input} =
             RouteInputAssembler.assemble(
               profile: enabled_profile([model], [score_row("model-a", "provider")]),
               clock: fn -> @decision_time end,
               observation_reader: fn _providers, _dt -> {:ok, [obs]} end,
               budget_reader: fn _providers, _dt ->
                 {:ok, [budget("provider", @stale_observed, "2026-07-22T23:00:00Z")]}
               end
             )

    observation = hd(input.observations)
    assert observation.observed_at == @stale_observed
    assert observation.expires_at == @stale_expires
  end

  test "missing budget fails closed" do
    model = model_entry("model-a", :provider)

    assert {:error, {:route_assembly_failed, :missing_budget}} =
             RouteInputAssembler.assemble(
               profile: enabled_profile([model], [score_row("model-a", "provider")]),
               clock: fn -> @decision_time end,
               observation_reader: fn _, _ ->
                 {:ok,
                  [
                    observation(
                      "provider",
                      "model-a",
                      @stale_observed,
                      "2026-07-22T23:00:00Z"
                    )
                  ]}
               end,
               budget_reader: fn _, _ -> {:ok, []} end
             )
  end

  test "malformed observation fails closed" do
    model = model_entry("model-a", :provider)

    assert {:error, {:route_assembly_failed, :invalid_observation}} =
             RouteInputAssembler.assemble(
               profile: enabled_profile([model], [score_row("model-a", "provider")]),
               clock: fn -> @decision_time end,
               observation_reader: fn _, _ -> {:ok, [%{not: "an observation"}]} end,
               budget_reader: fn _, _ ->
                 {:ok, [budget("provider", @stale_observed, "2026-07-22T23:00:00Z")]}
               end
             )
  end

  test "malformed budget fails closed" do
    model = model_entry("model-a", :provider)

    assert {:error, {:route_assembly_failed, :invalid_budget}} =
             RouteInputAssembler.assemble(
               profile: enabled_profile([model], [score_row("model-a", "provider")]),
               clock: fn -> @decision_time end,
               observation_reader: fn _, _ ->
                 {:ok,
                  [
                    observation(
                      "provider",
                      "model-a",
                      @stale_observed,
                      "2026-07-22T23:00:00Z"
                    )
                  ]}
               end,
               budget_reader: fn _, _ -> {:ok, [%{bad: true}]} end
             )
  end

  test "passes multi-account observations unmerged" do
    model = model_entry("model-a", :provider)

    first =
      observation("provider", "model-a", @stale_observed, "2026-07-22T23:00:00Z")
      |> Map.put(:account_id, "acct-a")

    second =
      observation("provider", "model-a", @stale_observed, "2026-07-22T23:00:00Z")
      |> Map.put(:account_id, "acct-b")

    assert {:ok, input} =
             RouteInputAssembler.assemble(
               profile: enabled_profile([model], [score_row("model-a", "provider")]),
               clock: fn -> @decision_time end,
               observation_reader: fn _, _ -> {:ok, [first, second]} end,
               budget_reader: fn _, _ ->
                 {:ok, [budget("provider", @stale_observed, "2026-07-22T23:00:00Z")]}
               end
             )

    assert length(input.observations) == 2
    assert Enum.map(input.observations, & &1.account_id) |> Enum.sort() == ["acct-a", "acct-b"]
  end

  test "enabled empty catalog fails closed" do
    assert {:error, {:route_assembly_failed, :invalid_catalog}} =
             RouteInputAssembler.assemble(
               profile: %{
                 enabled: true,
                 task_registry: %{"default" => %{requirements: %{}}},
                 default_task_class: "default",
                 catalog: [],
                 scoreboard: [],
                 providers: ["provider"],
                 params: %{}
               },
               clock: fn -> @decision_time end
             )
  end

  test "enabled profile without task_registry default fails during assembly" do
    model = model_entry("model-a", :provider)

    assert {:error, {:route_assembly_failed, :invalid_profile}} =
             RouteInputAssembler.assemble(
               profile:
                 enabled_profile([model], [score_row("model-a", "provider")])
                 |> Map.put(:task_registry, %{"other" => %{requirements: %{}}}),
               clock: fn -> @decision_time end
             )
  end

  test "enabled profile rejects both catalog sources and production catalog structs" do
    model = model_entry("model-a", :provider)

    both =
      enabled_profile([model], [score_row("model-a", "provider")])
      |> Map.put(:catalog_model_ids, ["model-a"])

    assert {:error, {:route_assembly_failed, :invalid_catalog}} =
             RouteInputAssembler.assemble(profile: both, clock: fn -> @decision_time end)

    prior = Application.get_env(:arbor_ai, :provider_route_profile)

    Application.put_env(
      :arbor_ai,
      :provider_route_profile,
      enabled_profile([model], [score_row("model-a", "provider")])
    )

    on_exit(fn ->
      case prior do
        nil -> Application.delete_env(:arbor_ai, :provider_route_profile)
        value -> Application.put_env(:arbor_ai, :provider_route_profile, value)
      end
    end)

    # Application/production path must use catalog_model_ids, not direct structs.
    assert {:error, {:route_assembly_failed, :invalid_catalog}} =
             RouteInputAssembler.assemble(clock: fn -> @decision_time end)
  end

  test "malformed scoreboard row and invalid explicit provider fail closed" do
    model = model_entry("model-a", :provider)

    bad_score =
      enabled_profile([model], [
        %{model: "model-a", provider: "provider", score: "hot"}
      ])

    assert {:error, {:route_assembly_failed, :invalid_scoreboard}} =
             RouteInputAssembler.assemble(
               profile: bad_score,
               clock: fn -> @decision_time end
             )

    nested_evidence = %{
      nested: %{too: %{deep: %{for: %{bounds: %{still: %{more: true}}}}}}
    }

    nested =
      enabled_profile([model], [
        %{
          model: "model-a",
          provider: "provider",
          runtime: "arbor",
          score: 1.0,
          evidence: nested_evidence
        }
      ])

    assert {:error, {:route_assembly_failed, :invalid_scoreboard}} =
             RouteInputAssembler.assemble(
               profile: nested,
               clock: fn -> @decision_time end
             )

    bad_provider =
      enabled_profile([model], [score_row("model-a", "provider")])
      |> Map.put(:providers, ["ok-provider", 12])

    assert {:error, {:route_assembly_failed, :invalid_profile}} =
             RouteInputAssembler.assemble(
               profile: bad_provider,
               clock: fn -> @decision_time end
             )
  end

  test "enabled profile missing scoreboard key fails; empty scoreboard list is admitted" do
    model = model_entry("model-a", :provider)
    obs = observation("provider", "model-a", @stale_observed, "2026-07-22T23:00:00Z")
    budget = budget("provider", @stale_observed, "2026-07-22T23:00:00Z")

    missing =
      enabled_profile([model], [score_row("model-a", "provider")])
      |> Map.delete(:scoreboard)

    assert {:error, {:route_assembly_failed, :invalid_profile}} =
             RouteInputAssembler.assemble(
               profile: missing,
               clock: fn -> @decision_time end,
               observation_reader: fn _, _ -> {:ok, [obs]} end,
               budget_reader: fn _, _ -> {:ok, [budget]} end
             )

    assert {:ok, input} =
             RouteInputAssembler.assemble(
               profile: enabled_profile([model], []),
               clock: fn -> @decision_time end,
               observation_reader: fn _, _ -> {:ok, [obs]} end,
               budget_reader: fn _, _ -> {:ok, [budget]} end
             )

    assert input.scoreboard == []
  end

  test "direct and reader catalogs admit ModelEntry contracts via ProviderRouter" do
    # Malformed struct: empty providers list fails ProviderRouter.admit_catalog/1
    # before Dispatch. Assembler must not reimplement catalog rules.
    # Do not use enabled_profile/2 here — it derives providers via hd(entry.providers).
    malformed = %ModelEntry{
      canonical_id: "malformed",
      providers: [],
      family: :test,
      context_window: 100_000,
      max_output_tokens: 4_000
    }

    direct_profile = %{
      enabled: true,
      task_registry: %{"default" => %{requirements: %{}}},
      default_task_class: "default",
      catalog: [malformed],
      scoreboard: [],
      providers: ["provider"],
      params: %{}
    }

    assert {:error, {:route_assembly_failed, :invalid_catalog}} =
             RouteInputAssembler.assemble(
               profile: direct_profile,
               clock: fn -> @decision_time end
             )

    # Reader path reuses the same admit_catalog helper.
    assert {:error, {:route_assembly_failed, :invalid_catalog}} =
             RouteInputAssembler.assemble(
               profile: %{
                 enabled: true,
                 task_registry: %{"default" => %{requirements: %{}}},
                 default_task_class: "default",
                 catalog_model_ids: ["malformed"],
                 scoreboard: [],
                 providers: ["provider"],
                 params: %{}
               },
               clock: fn -> @decision_time end,
               catalog_reader: fn _ids -> {:ok, [malformed]} end
             )
  end

  test "reader catalog canonical_ids must match requested model ids exactly and uniquely" do
    model_a = model_entry("model-a", :provider)
    model_b = model_entry("model-b", :provider)
    # Same canonical_id as model-a but a different provider path — duplicate id.
    model_a_dup = model_entry("model-a", :provider_other)

    reader_profile = fn ids ->
      %{
        enabled: true,
        task_registry: %{"default" => %{requirements: %{}}},
        default_task_class: "default",
        catalog_model_ids: ids,
        scoreboard: [],
        providers: ["provider"],
        params: %{}
      }
    end

    # Equal count but wrong canonical_id is not a match.
    assert {:error, {:route_assembly_failed, :invalid_catalog}} =
             RouteInputAssembler.assemble(
               profile: reader_profile.(["model-a"]),
               clock: fn -> @decision_time end,
               catalog_reader: fn _ids -> {:ok, [model_b]} end
             )

    # Equal count with a duplicated canonical_id fails uniqueness.
    assert {:error, {:route_assembly_failed, :invalid_catalog}} =
             RouteInputAssembler.assemble(
               profile: reader_profile.(["model-a", "model-b"]),
               clock: fn -> @decision_time end,
               catalog_reader: fn _ids -> {:ok, [model_a, model_a_dup]} end
             )
  end

  describe "Arbor.AI.assemble_provider_route_input/1 facade" do
    test "rejects every non-nil non-binary task_class without defaulting" do
      prior = Application.get_env(:arbor_ai, :provider_route_profile)
      Application.put_env(:arbor_ai, :provider_route_profile, %{enabled: false})

      on_exit(fn ->
        case prior do
          nil -> Application.delete_env(:arbor_ai, :provider_route_profile)
          value -> Application.put_env(:arbor_ai, :provider_route_profile, value)
        end
      end)

      assert {:error, :disabled} = AI.assemble_provider_route_input(nil)
      assert {:error, :disabled} = AI.assemble_provider_route_input("default")

      for bad <- [%{class: "x"}, 12, :default, ["default"], true, self()] do
        assert {:error, {:route_assembly_failed, :invalid_task_class}} =
                 AI.assemble_provider_route_input(bad)
      end
    end
  end

  defp enabled_profile(catalog, scoreboard) do
    %{
      enabled: true,
      task_registry: %{"default" => %{requirements: %{}}},
      default_task_class: "default",
      catalog: catalog,
      scoreboard: scoreboard,
      providers: Enum.map(catalog, fn m -> Atom.to_string(hd(m.providers).id) end),
      params: %{}
    }
  end

  defp model_entry(id, provider) do
    %ModelEntry{
      canonical_id: id,
      providers: [%ProviderEntry{id: provider, ref: id, auth: :none, runtimes: [:arbor]}],
      family: :test,
      context_window: 100_000,
      max_output_tokens: 4_000
    }
  end

  defp score_row(model, provider) do
    %{
      model: model,
      provider: provider,
      runtime: "arbor",
      score: 1.0,
      dangerous_misses: 0,
      format_failure_rate: 0.0,
      variance: 0.0,
      marginal_cost: 0.01,
      latency_ms: 10
    }
  end

  defp observation(provider, model, observed_at, expires_at) do
    {:ok, obs} =
      ProviderObservation.new(%{
        provider: provider,
        source: "test",
        runtime: "arbor",
        observed_at: observed_at,
        expires_at: expires_at,
        availability: "available",
        auth_health: "healthy",
        model_catalog_membership: "present",
        quota_state: "available",
        subscription_capacity_state: "not_applicable",
        concurrency_limit: 4,
        concurrency_in_use: 0,
        requested_model_id: model,
        launch_bound_model_id: model,
        confirmed_model_id: model
      })

    obs
  end

  defp budget(provider, observed_at, expires_at) do
    {:ok, snap} =
      BudgetSnapshot.new(%{
        provider: provider,
        source: "test",
        observed_at: observed_at,
        expires_at: expires_at,
        remaining_spend: 10.0,
        quota_state: "available",
        quota_remaining_units: 10,
        subscription_capacity_state: "not_applicable",
        concurrency_limit: 4,
        concurrency_in_use: 0
      })

    snap
  end
end
