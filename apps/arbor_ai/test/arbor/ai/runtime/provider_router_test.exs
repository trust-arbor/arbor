defmodule Arbor.AI.Runtime.ProviderRouterTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.Runtime.ProviderRouter
  alias Arbor.AI.Runtime.Selector
  alias Arbor.Contracts.LLM.{BudgetSnapshot, ModelEntry, ProviderEntry, ProviderObservation}

  @moduletag :fast
  @now ~U[2026-07-22 22:00:00Z]

  test "resolves exact, longest dotted prefix, default, and segment-safe classes" do
    input =
      base_input("code.implement.elixir", %{
        "default" => %{requirements: %{}},
        "code" => %{requirements: %{capabilities: [:tool_use]}},
        "code.implement" => %{requirements: %{min_context: 1}}
      })

    assert {:ok, exact} = ProviderRouter.decide_route(input)
    assert exact["rationale"]["resolved_task_class"] == "code.implement"

    assert {:ok, segment} =
             ProviderRouter.decide_route(%{input | task_class: "code.implement.elixirish"})

    assert segment["rationale"]["resolved_task_class"] == "code.implement"

    assert {:ok, defaulted} = ProviderRouter.decide_route(%{input | task_class: "codegen"})
    assert defaulted["rationale"]["resolved_task_class"] == "default"
    assert "unknown_task_class_defaulted" in defaulted["rationale"]["notes"]
  end

  test "excludes explicit readiness, auth, catalog, quota, spend, concurrency, requirements, and binding failures" do
    candidates = [
      model("bad-unavailable", :unavailable),
      model("bad-auth", :auth_expired),
      model("bad-catalog", :catalog_absent),
      model("bad-quota", :quota_exhausted),
      model("bad-spend", :zero_spend),
      model("bad-concurrency", :full),
      model("bad-requirement", :plain),
      model("good", :good)
    ]

    input = base_input("default", %{"default" => %{requirements: %{capabilities: [:tool_use]}}})

    input = %{
      input
      | catalog: candidates,
        observations: Enum.map(candidates, &observation_for(&1.canonical_id, &1.family)),
        budgets: Enum.map(candidates, &budget_for(&1.canonical_id, &1.family))
    }

    assert {:ok, result} = ProviderRouter.decide_route(input)
    assert result["model"] == "good"
    reasons = result["rationale"]["excluded"] |> Enum.flat_map(& &1["reasons"]) |> MapSet.new()

    for reason <-
          ~w(unavailable auth_expired catalog_absent quota_exhausted zero_remaining_spend full_concurrency requirements_failed) do
      assert MapSet.member?(reasons, reason), reason
    end
  end

  test "strict evidence distinguishes missing evidence from explicit exhaustion" do
    input = base_input("default", %{"default" => %{requirements: %{}}})

    assert {:error, {:no_eligible_routes, [%{"reasons" => reasons} | _]}} =
             ProviderRouter.decide_route(%{
               input
               | observations: [],
                 budgets: [],
                 policy: %{strict_evidence: true}
             })

    assert "missing_evidence:observation" in reasons
    refute "zero_remaining_spend" in reasons
  end

  test "exact model binding excludes a mismatched confirmed model" do
    input = base_input("default", %{"default" => %{requirements: %{exact_model: "model-a"}}})
    observation = observation_for("model-a", :binding)

    assert {:error, {:no_eligible_routes, [%{"reasons" => reasons} | _]}} =
             ProviderRouter.decide_route(%{
               input
               | observations: [observation],
                 budgets: [budget_for("model-a", :good)]
             })

    assert "model_binding_mismatch" in reasons
  end

  test "ranking is lexicographic and independent of input order" do
    input = base_input("default", %{"default" => %{requirements: %{}}})
    catalog = [model("z", :good), model("a", :good), model("b", :good)]

    scoreboard = [
      row("z", 0.9, 0, 0.01, 0.1, 0.01, 10),
      row("a", 0.9, 0, 0.01, 0.1, 0.01, 10),
      row("b", 0.9, 1, 0.0, 0.0, 0.0, 0)
    ]

    input = %{
      input
      | catalog: catalog,
        scoreboard: scoreboard,
        observations: Enum.map(catalog, &observation_for(&1.canonical_id, :good)),
        budgets: Enum.map(catalog, &budget_for(&1.canonical_id, :good))
    }

    assert {:ok, first} = ProviderRouter.decide_route(input)

    assert {:ok, second} =
             ProviderRouter.decide_route(%{
               input
               | catalog: Enum.reverse(catalog),
                 scoreboard: Enum.reverse(scoreboard),
                 observations: Enum.reverse(input.observations),
                 budgets: Enum.reverse(input.budgets)
             })

    assert first == second
    assert first["model"] == "a"

    assert first["fallback_chain"] == [
             %{"model" => "z", "provider" => "provider", "runtime" => "arbor"},
             %{"model" => "b", "provider" => "provider", "runtime" => "arbor"}
           ]
  end

  test "success is JSON-clean and params are passed through" do
    input = base_input("default", %{"default" => %{requirements: %{}}})
    input = %{input | policy: %{params: %{"temperature" => 0.2}, strict_evidence: false}}
    assert {:ok, result} = ProviderRouter.decide_route(input)
    assert Jason.decode!(Jason.encode!(result)) == result
    assert result["params"] == %{"temperature" => 0.2}
  end

  test "rejects malformed and bounded inputs" do
    input = base_input("default", %{"default" => %{requirements: %{}}})

    assert {:error, {:invalid_route_input, _}} =
             ProviderRouter.decide_route(%{input | task_class: "code..implement"})

    assert {:error, {:invalid_route_input, _}} =
             ProviderRouter.decide_route(%{input | policy: %{params: %{bad: :atom}}})

    assert {:error, {:invalid_route_input, _}} =
             ProviderRouter.decide_route(%{
               input
               | catalog: List.duplicate(model("x", :good), 129)
             })
  end

  test "excludes expired observations and invalid or unavailable auth and subscription evidence" do
    for {auth_health, reason} <- [
          {"invalid", "auth_invalid"},
          {"unavailable", "auth_unavailable"}
        ] do
      input = base_input("default", %{"default" => %{requirements: %{}}})
      catalog = [model("model-a", :auth_expired)]

      observation =
        observation_for("model-a", :auth_expired) |> Map.put(:auth_health, auth_health)

      input = %{
        input
        | catalog: catalog,
          observations: [observation],
          budgets: [budget_for("model-a", :auth_expired)]
      }

      assert {:error, {:no_eligible_routes, [%{"reasons" => reasons} | _]}} =
               ProviderRouter.decide_route(input)

      assert reason in reasons
    end

    input = base_input("default", %{"default" => %{requirements: %{}}})
    catalog = [model("model-a", :good)]
    budget = budget_for("model-a", :good) |> Map.put(:subscription_capacity_state, "exhausted")

    input = %{
      input
      | catalog: catalog,
        observations: [observation_for("model-a", :good)],
        budgets: [budget]
    }

    assert {:error, {:no_eligible_routes, [%{"reasons" => reasons} | _]}} =
             ProviderRouter.decide_route(input)

    assert "subscription_exhausted" in reasons

    expired = observation_for("model-a", :good) |> Map.put(:expires_at, "2026-07-22T21:30:00Z")
    input = %{input | observations: [expired], budgets: [budget_for("model-a", :good)]}

    assert {:error, {:no_eligible_routes, [%{"reasons" => reasons} | _]}} =
             ProviderRouter.decide_route(input)

    assert "expired_observation" in reasons

    expired_budget = budget_for("model-a", :good) |> Map.put(:expires_at, "2026-07-22T21:30:00Z")

    input = %{
      input
      | observations: [observation_for("model-a", :good)],
        budgets: [expired_budget]
    }

    assert {:error, {:no_eligible_routes, [%{"reasons" => reasons} | _]}} =
             ProviderRouter.decide_route(input)

    assert "expired_budget" in reasons
  end

  test "rejects duplicate scoreboard and candidate route identities" do
    input = base_input("default", %{"default" => %{requirements: %{}}})

    duplicate_rows = [
      row("model-a", 0.8, 0, 0.1, 0.1, 0.1, 20),
      row("model-a", 0.7, 0, 0.1, 0.1, 0.1, 20)
    ]

    assert {:error, {:invalid_route_input, {:duplicate, :scoreboard_row}}} =
             ProviderRouter.decide_route(%{input | scoreboard: duplicate_rows})

    duplicate_entry = model("model-a", :good)

    assert {:error, {:invalid_route_input, {:duplicate, :candidate_route}}} =
             ProviderRouter.decide_route(%{input | catalog: [duplicate_entry, duplicate_entry]})
  end

  test "normalizes scoreboard aliases and records ranked score provenance" do
    input = base_input("default", %{"default" => %{requirements: %{}}})

    aliased = %{
      "model_id" => "model-a",
      "provider" => "provider",
      "runtime" => "arbor",
      "score" => 0.9,
      "dangerous_miss_count" => 0,
      "format_failures" => 0.1,
      "variance" => 0.1,
      "cost" => 0.1,
      "latency" => 10,
      "throughput" => 100,
      "last_verified" => "2026-07-22T21:00:00Z",
      "eval_run_ref" => "eval-1",
      "quant" => "fp16",
      "hardware" => "local"
    }

    assert {:ok, result} = ProviderRouter.decide_route(%{input | scoreboard: [aliased]})

    assert get_in(hd(result["rationale"]["eligible_ranking"]), [
             "score_provenance",
             "eval_run_ref"
           ]) == "eval-1"
  end

  test "hard metric requirements fail when evidence is missing" do
    input =
      base_input("default", %{
        "default" => %{
          requirements: %{
            max_cost: 1.0,
            max_format_failure_rate: 0.1,
            max_dangerous_misses: 0,
            max_latency_ms: 10
          }
        }
      })

    assert {:error, {:no_eligible_routes, [%{"reasons" => reasons} | _]}} =
             ProviderRouter.decide_route(%{input | scoreboard: []})

    assert "requirements_failed" in reasons
  end

  test "strict mode does not require auth health for auth none routes" do
    input = base_input("default", %{"default" => %{requirements: %{}}})
    observation = observation_for("model-a", :good) |> Map.put(:auth_health, nil)

    input = %{
      input
      | catalog: [model("model-a", :good)],
        observations: [observation],
        budgets: [budget_for("model-a", :good)],
        policy: %{strict_evidence: true}
    }

    assert {:ok, _result} = ProviderRouter.decide_route(input)
  end

  test "ambiguous provider accounts are rejected without merging evidence" do
    input = base_input("default", %{"default" => %{requirements: %{}}})
    first = observation_for("model-a", :good) |> Map.put(:account_id, "acct-a")
    second = observation_for("model-a", :good) |> Map.put(:account_id, "acct-b")

    input = %{
      input
      | catalog: [model("model-a", :good)],
        observations: [first, second],
        budgets: [budget_for("model-a", :good)]
    }

    assert {:error, {:no_eligible_routes, [%{"reasons" => reasons} | _]}} =
             ProviderRouter.decide_route(input)

    assert "ambiguous_account_evidence" in reasons
  end

  test "preserves the existing Selector.choose/2 compatibility API" do
    assert {:ok, %{runtime: :arbor, provider: %ProviderEntry{id: :provider}}} =
             Selector.choose(model("model-a", :good))
  end

  test "task-specific scoreboard rows outrank generic rows" do
    input =
      base_input("code.implement.elixir", %{
        "default" => %{requirements: %{}},
        "code" => %{requirements: %{}}
      })

    generic = row("model-a", 1.0, 0, 0.0, 0.0, 0.0, 1) |> Map.put(:eval_run_ref, "generic")

    specific =
      row("model-a", 0.1, 0, 0.0, 0.0, 0.0, 1)
      |> Map.merge(%{task_class: "code", eval_run_ref: "specific"})

    assert {:ok, result} =
             ProviderRouter.decide_route(%{
               input
               | catalog: [model("model-a", :good)],
                 scoreboard: [generic, specific]
             })

    assert result["rationale"]["selected_score_provenance"]["eval_run_ref"] == "specific"
  end

  test "bounds JSON params depth and rejects duplicate keyword fields" do
    input = base_input("default", %{"default" => %{requirements: %{}}})
    deep = Enum.reduce(1..10, %{"leaf" => true}, fn _, acc -> %{"nested" => acc} end)

    assert {:error, {:invalid_route_input, {:invalid, :params}}} =
             ProviderRouter.decide_route(%{input | policy: %{params: deep}})

    assert {:error, {:invalid_route_input, {:duplicate_field, :task_class}}} =
             ProviderRouter.decide_route(Map.to_list(input) ++ [task_class: "duplicate"])
  end

  defp base_input(task_class, registry) do
    catalog = [model("model-a", :good), model("model-b", :good)]

    %{
      task_class: task_class,
      task_registry: registry,
      catalog: catalog,
      scoreboard: [
        row("model-a", 0.8, 0, 0.1, 0.1, 0.1, 20),
        row("model-b", 0.7, 0, 0.1, 0.1, 0.1, 30)
      ],
      observations: Enum.map(catalog, &observation_for(&1.canonical_id, :good)),
      budgets: Enum.map(catalog, &budget_for(&1.canonical_id, :good)),
      now: @now,
      policy: %{}
    }
  end

  defp model(id, family),
    do: %ModelEntry{
      canonical_id: id,
      providers: [
        %ProviderEntry{
          id: provider_for(family),
          ref: id,
          auth: if(family == :auth_expired, do: :api_key, else: :none),
          runtimes: [:arbor]
        }
      ],
      family: family,
      context_window: 100_000,
      max_output_tokens: 4_000,
      capabilities: if(family == :plain, do: [], else: [:tool_use])
    }

  defp row(model, score, misses, format, variance, cost, latency),
    do: %{
      model: model,
      provider: Atom.to_string(provider_for(:good)),
      runtime: "arbor",
      score: score,
      dangerous_misses: misses,
      format_failure_rate: format,
      variance: variance,
      marginal_cost: cost,
      latency_ms: latency
    }

  defp observation_for(model, family) do
    attrs = %{
      provider: Atom.to_string(provider_for(family)),
      source: "test",
      runtime: "arbor",
      observed_at: "2026-07-22T21:00:00Z",
      expires_at: "2026-07-22T23:00:00Z",
      availability: "available",
      auth_health: "healthy",
      model_catalog_membership: "present",
      quota_state: "available",
      subscription_capacity_state: "not_applicable",
      concurrency_limit: 4,
      concurrency_in_use: 0,
      requested_model_id: model,
      launch_bound_model_id: if(family == :binding, do: "model-b", else: model),
      confirmed_model_id: if(family == :binding, do: "model-b", else: model)
    }

    attrs =
      case family do
        :unavailable -> %{attrs | availability: "unavailable"}
        :auth_expired -> %{attrs | auth_health: "expired"}
        :catalog_absent -> %{attrs | model_catalog_membership: "absent"}
        :quota_exhausted -> %{attrs | quota_state: "exhausted"}
        :full -> %{attrs | concurrency_limit: 1, concurrency_in_use: 1}
        _ -> attrs
      end

    {:ok, observation} = ProviderObservation.new(attrs)
    observation
  end

  defp budget_for(_model, family) do
    attrs = %{
      provider: Atom.to_string(provider_for(family)),
      source: "test",
      observed_at: "2026-07-22T21:00:00Z",
      expires_at: "2026-07-22T23:00:00Z",
      remaining_spend: if(family == :zero_spend, do: 0.0, else: 10.0),
      quota_state: "available",
      quota_remaining_units: 10,
      subscription_capacity_state: "not_applicable",
      concurrency_limit: 4,
      concurrency_in_use: 0
    }

    {:ok, snapshot} = BudgetSnapshot.new(attrs)
    snapshot
  end

  defp provider_for(:good), do: :provider
  defp provider_for(:binding), do: :provider
  defp provider_for(:unavailable), do: :unavailable_provider
  defp provider_for(:auth_expired), do: :auth_expired_provider
  defp provider_for(:catalog_absent), do: :catalog_absent_provider
  defp provider_for(:quota_exhausted), do: :quota_exhausted_provider
  defp provider_for(:zero_spend), do: :zero_spend_provider
  defp provider_for(:full), do: :full_provider
  defp provider_for(:plain), do: :plain_provider
end
