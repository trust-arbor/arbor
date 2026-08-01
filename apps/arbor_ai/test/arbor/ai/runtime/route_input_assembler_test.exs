defmodule Arbor.AI.Runtime.RouteInputAssemblerTest do
  use ExUnit.Case, async: false

  alias Arbor.AI
  alias Arbor.AI.Runtime.RouteInputAssembler

  alias Arbor.Contracts.LLM.{
    BudgetSnapshot,
    ModelEntry,
    OAuthHealth,
    ProviderEntry,
    ProviderModelCatalog,
    ProviderObservation
  }

  @moduletag :fast
  @decision_time ~U[2026-07-22 22:00:00Z]
  @stale_observed "2026-07-22T20:00:00Z"
  @stale_expires "2026-07-22T21:00:00Z"

  setup do
    Arbor.AI.TestSupport.ProviderRouteEvidence.reset!()
    :ok
  end

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

  test "default catalog reader overlays exact OAuth routes without injected catalog_reader" do
    obs_o = observation("openai_oauth", "gpt-5.6-sol", @stale_observed, "2026-07-22T23:00:00Z")
    obs_x = observation("xai_oauth", "grok-4.5", @stale_observed, "2026-07-22T23:00:00Z")
    budget_o = budget("openai_oauth", @stale_observed, "2026-07-22T23:00:00Z")
    budget_x = budget("xai_oauth", @stale_observed, "2026-07-22T23:00:00Z")

    profile = %{
      enabled: true,
      task_registry: %{"default" => %{requirements: %{}}},
      default_task_class: "default",
      catalog_model_ids: ["gpt-5.6-sol", "grok-4.5"],
      scoreboard: [
        score_row("gpt-5.6-sol", "openai_oauth"),
        score_row("grok-4.5", "xai_oauth")
      ],
      providers: ["openai_oauth", "xai_oauth"],
      params: %{}
    }

    assert {:ok, input} =
             RouteInputAssembler.assemble(
               profile: profile,
               clock: fn -> @decision_time end,
               observation_reader: fn _providers, _dt -> {:ok, [obs_o, obs_x]} end,
               budget_reader: fn _providers, _dt -> {:ok, [budget_o, budget_x]} end
             )

    assert [gpt, grok] = input.catalog
    assert gpt.canonical_id == "gpt-5.6-sol"
    assert grok.canonical_id == "grok-4.5"

    assert [
             %ProviderEntry{
               id: :openai_oauth,
               auth: :oauth,
               ref: "gpt-5.6-sol",
               runtimes: [:arbor],
               pricing: nil
             }
           ] = gpt.providers

    assert [
             %ProviderEntry{
               id: :xai_oauth,
               auth: :oauth,
               ref: "grok-4.5",
               runtimes: [:arbor],
               pricing: nil
             }
           ] = grok.providers
  end

  test "injected catalog_reader is used instead of the exact route catalog default" do
    custom = model_entry("gpt-5.6-sol", :custom_provider)
    obs = observation("custom_provider", "gpt-5.6-sol", @stale_observed, "2026-07-22T23:00:00Z")
    budget = budget("custom_provider", @stale_observed, "2026-07-22T23:00:00Z")
    test_pid = self()

    profile = %{
      enabled: true,
      task_registry: %{"default" => %{requirements: %{}}},
      default_task_class: "default",
      catalog_model_ids: ["gpt-5.6-sol"],
      scoreboard: [score_row("gpt-5.6-sol", "custom_provider")],
      providers: ["custom_provider"],
      params: %{}
    }

    assert {:ok, input} =
             RouteInputAssembler.assemble(
               profile: profile,
               clock: fn -> @decision_time end,
               catalog_reader: fn ids ->
                 send(test_pid, {:catalog_reader_called, ids})
                 {:ok, [custom]}
               end,
               observation_reader: fn _providers, _dt -> {:ok, [obs]} end,
               budget_reader: fn _providers, _dt -> {:ok, [budget]} end
             )

    assert_received {:catalog_reader_called, ["gpt-5.6-sol"]}
    assert [entry] = input.catalog
    assert entry.canonical_id == "gpt-5.6-sol"
    assert [%ProviderEntry{id: :custom_provider}] = entry.providers
    refute Enum.any?(entry.providers, &(&1.id in [:openai_oauth, :xai_oauth]))
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

  describe "default OAuth catalog evidence wiring" do
    @oauth_now ~U[2026-07-29 12:02:00Z]
    @oauth_observed "2026-07-29T12:00:00Z"
    @oauth_gen 3

    test "non-OAuth catalog skips OAuth snapshot reader even when it would be unavailable" do
      # Zero exact OAuth candidates: irrelevant snapshot evidence must not be
      # required or invoked. Assembly succeeds via non-OAuth readiness path.
      model = model_entry("model-a", :grok)
      snap_calls = :counters.new(1, [])

      assert {:ok, input} =
               RouteInputAssembler.assemble(
                 profile: enabled_profile([model], [score_row("model-a", "grok")]),
                 clock: fn -> @oauth_now end,
                 oauth_health_reader: fn _ ->
                   flunk("oauth_health_reader must not run without OAuth candidates")
                 end,
                 oauth_catalog_snapshot_reader: fn ->
                   :counters.add(snap_calls, 1, 1)
                   {:error, :unavailable}
                 end,
                 budget_reader: fn providers, dt ->
                   {:ok, Enum.map(providers, &budget_dt(&1, dt))}
                 end
               )

      assert :counters.get(snap_calls, 1) == 0
      assert [obs] = input.observations
      assert obs.provider == "grok"
      refute obs.source == "arbor_oauth_catalog"
      refute obs.source == "arbor_oauth_health"
    end

    test "present and absent membership from one snapshot and one health read" do
      models = [oauth_model("model-a"), oauth_model("model-b")]
      health_calls = :counters.new(1, [])
      snap_calls = :counters.new(1, [])
      catalog = oauth_catalog!(["model-a"], @oauth_gen)

      assert {:ok, input} =
               RouteInputAssembler.assemble(
                 profile: enabled_profile(models, []),
                 clock: fn -> @oauth_now end,
                 oauth_health_reader: fn route ->
                   :counters.add(health_calls, 1, 1)
                   assert route in ["openai_oauth", :openai_oauth]
                   {:ok, ready_health(@oauth_gen)}
                 end,
                 oauth_catalog_snapshot_reader: fn ->
                   :counters.add(snap_calls, 1, 1)
                   {:ok, %{"openai_oauth" => ProviderModelCatalog.to_map(catalog)}}
                 end,
                 budget_reader: fn providers, dt ->
                   {:ok, Enum.map(providers, &budget_dt(&1, dt))}
                 end
               )

      assert :counters.get(health_calls, 1) == 1
      assert :counters.get(snap_calls, 1) == 1

      by_model = Map.new(input.observations, &{&1.requested_model_id, &1})
      assert by_model["model-a"].model_catalog_membership == "present"
      assert by_model["model-a"].source == "arbor_oauth_catalog"
      assert by_model["model-a"].observed_at == @oauth_observed
      assert by_model["model-b"].model_catalog_membership == "absent"
    end

    test "missing empty snapshot yields unknown membership without assembly failure" do
      model = oauth_model("model-a")

      assert {:ok, input} =
               RouteInputAssembler.assemble(
                 profile: enabled_profile([model], []),
                 clock: fn -> @oauth_now end,
                 oauth_health_reader: fn _ -> {:ok, ready_health(1)} end,
                 oauth_catalog_snapshot_reader: fn -> {:ok, %{}} end,
                 budget_reader: fn providers, dt ->
                   {:ok, Enum.map(providers, &budget_dt(&1, dt))}
                 end
               )

      obs = hd(input.observations)
      assert obs.requested_model_id == "model-a"
      assert obs.model_catalog_membership == "unknown"
      assert obs.source == "arbor_oauth_health"
    end

    test "expired future identity and generation mismatches yield exact unknown" do
      model = oauth_model("model-a")
      health = ready_health(@oauth_gen)

      cases = [
        # expired
        oauth_catalog!(["model-a"], @oauth_gen,
          observed_at: "2026-07-29T11:00:00Z",
          expires_at: "2026-07-29T11:05:00Z"
        ),
        # future observed
        oauth_catalog!(["model-a"], @oauth_gen,
          observed_at: "2026-07-29T12:10:00Z",
          expires_at: "2026-07-29T12:15:00Z"
        ),
        # generation mismatch
        oauth_catalog!(["model-a"], @oauth_gen + 1)
        # identity mismatch (xai catalog under openai route key is shape-malformed —
        # use valid openai route with wrong backend via compose path: xai catalog
        # admitted under its own key while candidate is openai → miss → unknown)
      ]

      for catalog <- cases do
        assert {:ok, input} =
                 RouteInputAssembler.assemble(
                   profile: enabled_profile([model], []),
                   clock: fn -> @oauth_now end,
                   oauth_health_reader: fn _ -> {:ok, health} end,
                   oauth_catalog_snapshot_reader: fn ->
                     {:ok, %{"openai_oauth" => ProviderModelCatalog.to_map(catalog)}}
                   end,
                   budget_reader: fn providers, dt ->
                     {:ok, Enum.map(providers, &budget_dt(&1, dt))}
                   end
                 )

        assert hd(input.observations).model_catalog_membership == "unknown"
        assert hd(input.observations).source == "arbor_oauth_health"
      end

      # Route key present for xai while candidate is openai → miss → unknown
      xai =
        oauth_catalog_route!("xai_oauth", "xai", ["model-a"], @oauth_gen)

      assert {:ok, input} =
               RouteInputAssembler.assemble(
                 profile: enabled_profile([model], []),
                 clock: fn -> @oauth_now end,
                 oauth_health_reader: fn _ -> {:ok, health} end,
                 oauth_catalog_snapshot_reader: fn ->
                   {:ok, %{"xai_oauth" => ProviderModelCatalog.to_map(xai)}}
                 end,
                 budget_reader: fn providers, dt ->
                   {:ok, Enum.map(providers, &budget_dt(&1, dt))}
                 end
               )

      assert hd(input.observations).model_catalog_membership == "unknown"
    end

    test "unavailable and malformed cache states fail closed with distinct reasons" do
      model = oauth_model("model-a")

      assert {:error, {:route_assembly_failed, :oauth_model_catalog_evidence_unavailable}} =
               RouteInputAssembler.assemble(
                 profile: enabled_profile([model], []),
                 clock: fn -> @oauth_now end,
                 oauth_health_reader: fn _ -> {:ok, ready_health(1)} end,
                 oauth_catalog_snapshot_reader: fn -> {:error, :unavailable} end,
                 budget_reader: fn providers, dt ->
                   {:ok, Enum.map(providers, &budget_dt(&1, dt))}
                 end
               )

      assert {:error, {:route_assembly_failed, :oauth_model_catalog_evidence_malformed}} =
               RouteInputAssembler.assemble(
                 profile: enabled_profile([model], []),
                 clock: fn -> @oauth_now end,
                 oauth_health_reader: fn _ -> {:ok, ready_health(1)} end,
                 oauth_catalog_snapshot_reader: fn ->
                   {:ok, %{"openai_oauth" => %{not: "a catalog"}}}
                 end,
                 budget_reader: fn providers, dt ->
                   {:ok, Enum.map(providers, &budget_dt(&1, dt))}
                 end
               )

      assert {:error, {:route_assembly_failed, :oauth_model_catalog_evidence_malformed}} =
               RouteInputAssembler.assemble(
                 profile: enabled_profile([model], []),
                 clock: fn -> @oauth_now end,
                 oauth_health_reader: fn _ -> {:ok, ready_health(1)} end,
                 oauth_catalog_snapshot_reader: fn ->
                   {:ok, %{"not_a_route" => %{"route" => "openai_oauth"}}}
                 end,
                 budget_reader: fn providers, dt ->
                   {:ok, Enum.map(providers, &budget_dt(&1, dt))}
                 end
               )
    end

    test "non-arbor OAuth runtime never borrows catalog evidence or relabels as arbor" do
      model = %ModelEntry{
        canonical_id: "model-a",
        providers: [
          %ProviderEntry{
            id: :openai_oauth,
            ref: "model-a",
            auth: :oauth,
            runtimes: [:acp],
            pricing: nil
          }
        ],
        family: :test,
        context_window: 100_000,
        max_output_tokens: 4_000
      }

      catalog = oauth_catalog!(["model-a"], @oauth_gen)

      assert {:ok, input} =
               RouteInputAssembler.assemble(
                 profile: enabled_profile([model], []),
                 clock: fn -> @oauth_now end,
                 oauth_health_reader: fn _ -> {:ok, ready_health(@oauth_gen)} end,
                 oauth_catalog_snapshot_reader: fn ->
                   {:ok, %{"openai_oauth" => ProviderModelCatalog.to_map(catalog)}}
                 end,
                 budget_reader: fn providers, dt ->
                   {:ok, Enum.map(providers, &budget_dt(&1, dt))}
                 end
               )

      obs = hd(input.observations)
      assert obs.provider == "openai_oauth"
      assert obs.requested_model_id == "model-a"
      assert obs.runtime == "acp"
      refute obs.runtime == "arbor"
      assert obs.model_catalog_membership == "unknown"
      refute obs.source == "arbor_oauth_catalog"
      assert obs.source == "arbor_oauth_health"
    end

    test "one snapshot per assembly and no credential refresh on default path" do
      prior = Application.get_env(:arbor_llm, :oauth_refresh_fun)

      Application.put_env(:arbor_llm, :oauth_refresh_fun, fn _, _, _ ->
        flunk("default assembly must not refresh credentials")
      end)

      on_exit(fn ->
        case prior do
          nil -> Application.delete_env(:arbor_llm, :oauth_refresh_fun)
          fun -> Application.put_env(:arbor_llm, :oauth_refresh_fun, fun)
        end
      end)

      models = [oauth_model("model-a"), oauth_model("model-b")]
      snap_calls = :counters.new(1, [])

      assert {:ok, _input} =
               RouteInputAssembler.assemble(
                 profile: enabled_profile(models, []),
                 clock: fn -> @oauth_now end,
                 oauth_health_reader: fn _ -> {:ok, ready_health(@oauth_gen)} end,
                 oauth_catalog_snapshot_reader: fn ->
                   :counters.add(snap_calls, 1, 1)
                   {:ok, %{}}
                 end,
                 budget_reader: fn providers, dt ->
                   {:ok, Enum.map(providers, &budget_dt(&1, dt))}
                 end
               )

      assert :counters.get(snap_calls, 1) == 1
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

  defp budget_dt(provider, %DateTime{} = dt) do
    budget(
      provider,
      DateTime.to_iso8601(dt),
      DateTime.to_iso8601(DateTime.add(dt, 300, :second))
    )
  end

  defp oauth_model(id) do
    %ModelEntry{
      canonical_id: id,
      providers: [
        %ProviderEntry{
          id: :openai_oauth,
          ref: id,
          auth: :oauth,
          runtimes: [:arbor],
          pricing: nil
        }
      ],
      family: :test,
      context_window: 100_000,
      max_output_tokens: 4_000
    }
  end

  defp ready_health(generation) do
    {:ok, health} =
      OAuthHealth.new(%{
        version: 1,
        route: "openai_oauth",
        backend: "openai",
        status: "ready",
        owner: "arbor_owned",
        origin: "arbor_login",
        source: "arbor_oauth_store",
        generation: generation
      })

    health
  end

  defp oauth_catalog!(model_ids, generation, opts \\ []) do
    oauth_catalog_route!("openai_oauth", "openai", model_ids, generation, opts)
  end

  defp oauth_catalog_route!(route, backend, model_ids, generation, opts \\ []) do
    observed = Keyword.get(opts, :observed_at, "2026-07-29T12:00:00Z")
    expires = Keyword.get(opts, :expires_at, "2026-07-29T12:05:00Z")

    {:ok, catalog} =
      ProviderModelCatalog.new(%{
        route: route,
        backend: backend,
        runtime: "arbor",
        model_ids: model_ids,
        observed_at: observed,
        expires_at: expires,
        credential_generation: generation
      })

    catalog
  end
end
