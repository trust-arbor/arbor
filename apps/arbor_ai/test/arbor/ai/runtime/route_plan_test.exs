defmodule Arbor.AI.Runtime.RoutePlanTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.AI.Runtime.RoutePlan
  alias Arbor.Contracts.LLM.{ModelEntry, ProviderEntry}

  defmodule RuntimeSelector do
  end

  test "maps primary and fallback routes to exact catalog structs and provider refs" do
    primary = model("primary", :provider_a, "wire-primary", :arbor)
    fallback = model("fallback", :provider_b, "wire-fallback", :acp)

    assert {:ok, plan} = RoutePlan.build(route_input([fallback, primary]))

    assert plan.primary.model_entry === primary
    assert plan.primary.provider === hd(primary.providers)
    assert plan.primary.provider.ref == "wire-primary"
    assert plan.primary.runtime == :arbor

    assert [fallback_route] = plan.fallbacks
    assert fallback_route.model_entry === fallback
    assert fallback_route.provider === hd(fallback.providers)
    assert fallback_route.provider.ref == "wire-fallback"
    assert fallback_route.runtime == :acp
  end

  test "malformed, unavailable, and stale decisions fail with bounded errors" do
    assert {:error, :invalid_route_input} = RoutePlan.build(%{})

    input =
      route_input([model("primary", :provider_a, "wire-primary", :arbor)])
      |> put_in([:task_registry, "default", :requirements], %{providers: ["missing"]})

    assert {:error, :no_eligible_routes} = RoutePlan.build(input)

    stale = %{
      "model" => "stale-model",
      "provider" => "stale-provider",
      "runtime" => "stale-runtime",
      "params" => %{},
      "fallback_chain" => []
    }

    assert {:error, :route_mapping_mismatch} =
             RoutePlan.map_decision(stale, [model("primary", :provider_a, "wire", :arbor)])
  end

  test "mapping arbitrary identifiers does not intern atoms" do
    unique = "never-intern-#{System.unique_integer([:positive])}"

    decision = %{
      "model" => unique,
      "provider" => unique <> "-provider",
      "runtime" => unique <> "-runtime",
      "params" => %{},
      "fallback_chain" => []
    }

    assert_raise ArgumentError, fn -> String.to_existing_atom(unique) end
    assert {:error, :route_mapping_mismatch} = RoutePlan.map_decision(decision, [])
    assert_raise ArgumentError, fn -> String.to_existing_atom(unique) end
  end

  test "module atoms are never accepted as provider or runtime selectors" do
    module_provider = model("module-provider", RuntimeSelector, "wire", :arbor)
    assert {:error, :route_mapping_mismatch} = RoutePlan.build(route_input([module_provider]))

    module_runtime = model("module-runtime", :provider_a, "wire", RuntimeSelector)
    assert {:error, :route_mapping_mismatch} = RoutePlan.build(route_input([module_runtime]))
  end

  test "nil and boolean atoms are never executable provider or runtime selectors" do
    for sentinel <- [nil, true, false] do
      provider_route = model("primary", sentinel, "wire", :arbor)
      assert {:error, :route_mapping_mismatch} = RoutePlan.build(route_input([provider_route]))

      runtime_route = model("primary", :provider_a, "wire", sentinel)
      assert {:error, :route_mapping_mismatch} = RoutePlan.build(route_input([runtime_route]))
    end
  end

  test "non-empty reviewed params are rejected instead of silently dropped" do
    input =
      route_input([model("primary", :provider_a, "wire", :arbor)])
      |> Map.put(:policy, %{params: %{"temperature" => 0.2}})

    assert {:error, :unsupported_route_params} = RoutePlan.build(input)
  end

  test "directly constructed malformed catalog values fail the mapping boundary" do
    long_ref = String.duplicate("x", 513)
    malformed = model("primary", :provider_a, long_ref, :arbor)

    decision = %{
      "model" => "primary",
      "provider" => "provider_a",
      "runtime" => "arbor",
      "params" => %{},
      "fallback_chain" => []
    }

    assert {:error, :route_mapping_mismatch} = RoutePlan.map_decision(decision, [malformed])

    oversized = %{decision | "model" => String.duplicate("m", 513)}
    assert {:error, :route_mapping_mismatch} = RoutePlan.map_decision(oversized, [malformed])
  end

  defp route_input(catalog) do
    %{
      task_class: "default",
      task_registry: %{"default" => %{requirements: %{}}},
      catalog: catalog,
      scoreboard:
        Enum.map(catalog, fn model ->
          provider = hd(model.providers)

          %{
            model: model.canonical_id,
            provider: Atom.to_string(provider.id),
            runtime: provider.runtimes |> hd() |> Atom.to_string(),
            score: if(model.canonical_id == "primary", do: 1.0, else: 0.5)
          }
        end),
      observations: [],
      budgets: [],
      now: ~U[2026-07-22 22:00:00Z],
      policy: %{}
    }
  end

  defp model(canonical_id, provider, ref, runtime) do
    %ModelEntry{
      canonical_id: canonical_id,
      providers: [%ProviderEntry{id: provider, ref: ref, auth: :none, runtimes: [runtime]}],
      family: :test,
      context_window: 100_000,
      max_output_tokens: 4_000
    }
  end
end
