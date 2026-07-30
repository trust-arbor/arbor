defmodule Arbor.AI.Runtime.RouteAssemblyCanaryTest do
  @moduledoc """
  Deterministic no-network canary: assemble → RoutePlan/Dispatch → authorize → fake runtime.
  """
  use ExUnit.Case, async: false

  alias Arbor.AI.RouteConcurrency
  alias Arbor.AI.Runtime.{Dispatch, ProviderRouter, RouteInputAssembler}
  alias Arbor.Contracts.LLM.{BudgetSnapshot, ModelEntry, ProviderEntry, ProviderObservation}
  alias Arbor.LLM.Request

  @moduletag :fast
  @now ~U[2026-07-22 22:00:00Z]

  defmodule CanaryRuntime do
    @moduledoc false
    @behaviour Arbor.AI.Runtime

    alias Arbor.Contracts.AI.RuntimeProfile

    @impl true
    def prepare(request, _opts), do: {:ok, request}

    @impl true
    def execute(request, _callbacks, _opts) do
      case Application.get_env(:arbor_ai, :_canary_fail_model) do
        model when model == request.model ->
          {:error, :timeout}

        _ ->
          {:ok,
           %Arbor.LLM.Response{
             text: "canary ok",
             finish_reason: :stop,
             usage: %{input_tokens: 1, output_tokens: 1},
             raw: %{provider: request.provider, model: request.model, runtime: request.runtime}
           }}
      end
    end

    @impl true
    def profile do
      {:ok, profile} =
        RuntimeProfile.new(%{
          runtime_id: :canary,
          display_name: "canary",
          owns_model_loop: false,
          owns_thread_history: false,
          supports_jido_actions: false,
          supports_action_hooks: false,
          supports_native_tools: false,
          runs_context_engine: false,
          exposes_compaction_data: false,
          unsupported_features: []
        })

      profile
    end
  end

  setup do
    original = Application.get_env(:arbor_ai, :runtime_registry, %{})
    concurrency_name = :"route_assembly_canary_#{System.unique_integer([:positive])}"

    start_supervised!(
      {RouteConcurrency,
       name: concurrency_name, limits: %{provider_a: %{arbor: 1}, provider_b: %{acp: 1}}}
    )

    Application.put_env(:arbor_ai, :runtime_registry, %{
      arbor: CanaryRuntime,
      acp: CanaryRuntime
    })

    on_exit(fn ->
      Application.put_env(:arbor_ai, :runtime_registry, original)
      Application.delete_env(:arbor_ai, :_canary_fail_model)
    end)

    %{route_concurrency_server: concurrency_name}
  end

  test "primary success through assemble → authorize → fake execution", %{
    route_concurrency_server: concurrency_server
  } do
    primary = model("primary", :provider_a, "wire-primary", :arbor)

    assert {:ok, input} = assemble([primary], healthy_evidence([primary]))
    assert input.policy.strict_evidence == true

    assert {:ok, response} =
             Dispatch.dispatch(request(),
               provider_route_input: input,
               route_authorizer: fn route ->
                 assert route.provider.id == :provider_a
                 :allow
               end,
               route_concurrency_server: concurrency_server
             )

    executed = response.usage["arbor.executed_route"]
    assert executed["provider"] == "provider_a"
    assert executed["model"] == "primary"
    assert executed["attempt"] == "primary"
    assert executed["provider_confirmed"] == false
  end

  test "fallback executes after primary failure and records fallback evidence", %{
    route_concurrency_server: concurrency_server
  } do
    primary = model("primary", :provider_a, "wire-primary", :arbor)
    fallback = model("fallback", :provider_b, "wire-fallback", :acp)
    Application.put_env(:arbor_ai, :_canary_fail_model, "wire-primary")

    assert {:ok, input} = assemble([primary, fallback], healthy_evidence([primary, fallback]))

    assert {:ok, response} =
             Dispatch.dispatch(request(),
               provider_route_input: input,
               route_authorizer: fn _ -> :allow end,
               route_concurrency_server: concurrency_server
             )

    executed = response.usage["arbor.executed_route"]
    assert executed["provider"] == "provider_b"
    assert executed["model"] == "fallback"
    assert executed["attempt"] == "fallback"
  end

  test "stale evidence fails closed under strict assembly+selection" do
    primary = model("primary", :provider_a, "wire-primary", :arbor)

    stale_obs =
      observation("provider_a", "primary", "2026-07-22T20:00:00Z", "2026-07-22T21:00:00Z")

    budget = budget("provider_a", "2026-07-22T20:00:00Z", "2026-07-22T23:00:00Z")

    assert {:ok, input} =
             assemble([primary], %{
               observations: [stale_obs],
               budgets: [budget]
             })

    # Timestamps preserved; decision_time is after expires_at.
    assert hd(input.observations).expires_at == "2026-07-22T21:00:00Z"
    assert input.now == @now

    assert {:error, {:selection_failed, {:provider_route, :no_eligible_routes}}} =
             Dispatch.dispatch(request(),
               provider_route_input: input,
               route_authorizer: fn _ -> :allow end
             )
  end

  test "exhausted budget fails closed" do
    primary = model("primary", :provider_a, "wire-primary", :arbor)
    obs = observation("provider_a", "primary", "2026-07-22T21:00:00Z", "2026-07-22T23:00:00Z")

    exhausted =
      budget("provider_a", "2026-07-22T21:00:00Z", "2026-07-22T23:00:00Z")
      |> Map.put(:remaining_spend, 0.0)

    assert {:ok, input} = assemble([primary], %{observations: [obs], budgets: [exhausted]})

    assert {:error, {:selection_failed, {:provider_route, :no_eligible_routes}}} =
             Dispatch.dispatch(request(),
               provider_route_input: input,
               route_authorizer: fn _ -> :allow end
             )
  end

  test "missing evidence fails closed when enabled" do
    primary = model("primary", :provider_a, "wire-primary", :arbor)

    assert {:error, {:route_assembly_failed, :missing_budget}} =
             RouteInputAssembler.assemble(
               profile: profile([primary]),
               clock: fn -> @now end,
               observation_reader: fn _, _ ->
                 {:ok,
                  [
                    observation(
                      "provider_a",
                      "primary",
                      "2026-07-22T21:00:00Z",
                      "2026-07-22T23:00:00Z"
                    )
                  ]}
               end,
               budget_reader: fn _, _ -> {:ok, []} end
             )

    # Even if assembly is bypassed with empty evidence, pure router fails closed.
    input = %{
      task_class: "default",
      task_registry: %{"default" => %{requirements: %{}}},
      catalog: [primary],
      scoreboard: [score_row("primary", "provider_a", "arbor", 1.0)],
      observations: [],
      budgets: [],
      now: @now,
      policy: %{strict_evidence: true}
    }

    assert {:error, {:no_eligible_routes, _}} = ProviderRouter.decide_route(input)
  end

  test "disabled profile preserves legacy Selector dispatch compatibility" do
    assert {:error, :disabled} =
             RouteInputAssembler.assemble(profile: %{enabled: false}, clock: fn -> @now end)

    # Without provider_route_input, Dispatch uses legacy Selector path.
    assert {:ok, response} = Dispatch.dispatch(request("legacy-model"))
    assert response.text == "canary ok"
    refute Map.has_key?(response.usage, "arbor.executed_route")
  end

  defp assemble(catalog, %{observations: observations, budgets: budgets}) do
    RouteInputAssembler.assemble(
      profile: profile(catalog),
      clock: fn -> @now end,
      observation_reader: fn _, _ -> {:ok, observations} end,
      budget_reader: fn _, _ -> {:ok, budgets} end
    )
  end

  defp healthy_evidence(catalog) do
    observations =
      Enum.map(catalog, fn model ->
        provider = hd(model.providers)
        runtime = provider.runtimes |> hd() |> Atom.to_string()

        observation(
          Atom.to_string(provider.id),
          model.canonical_id,
          "2026-07-22T21:00:00Z",
          "2026-07-22T23:00:00Z",
          runtime
        )
      end)

    budgets =
      Enum.map(catalog, fn model ->
        provider = hd(model.providers)
        budget(Atom.to_string(provider.id), "2026-07-22T21:00:00Z", "2026-07-22T23:00:00Z")
      end)

    %{observations: observations, budgets: budgets}
  end

  defp profile(catalog) do
    %{
      enabled: true,
      task_registry: %{"default" => %{requirements: %{}}},
      default_task_class: "default",
      catalog: catalog,
      scoreboard:
        Enum.with_index(catalog, fn model, index ->
          provider = hd(model.providers)
          runtime = provider.runtimes |> hd() |> Atom.to_string()

          score_row(
            model.canonical_id,
            Atom.to_string(provider.id),
            runtime,
            1.0 - index * 0.1
          )
        end),
      providers: Enum.map(catalog, fn m -> Atom.to_string(hd(m.providers).id) end),
      params: %{}
    }
  end

  defp model(id, provider, ref, runtime) do
    %ModelEntry{
      canonical_id: id,
      providers: [%ProviderEntry{id: provider, ref: ref, auth: :none, runtimes: [runtime]}],
      family: :test,
      context_window: 100_000,
      max_output_tokens: 4_000
    }
  end

  defp score_row(model, provider, runtime, score) do
    %{
      model: model,
      provider: provider,
      runtime: runtime,
      score: score,
      dangerous_misses: 0,
      format_failure_rate: 0.0,
      variance: 0.0,
      marginal_cost: 0.01,
      latency_ms: 10
    }
  end

  defp observation(provider, model, observed_at, expires_at, runtime \\ "arbor") do
    {:ok, obs} =
      ProviderObservation.new(%{
        provider: provider,
        source: "test",
        runtime: runtime,
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

  defp request(model \\ "ignored") do
    %Request{
      provider: "ignored",
      model: model,
      runtime: :arbor,
      messages: [Arbor.LLM.Message.new(:user, "hi")],
      max_tokens: 100,
      temperature: 0.7
    }
  end
end
