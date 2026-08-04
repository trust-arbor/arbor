defmodule Arbor.AI.Runtime.FreezeProviderRouteTest do
  @moduledoc false
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag voice_id: "VOICE-17"

  alias Arbor.AI
  alias Arbor.AI.RouteConcurrency
  alias Arbor.AI.Runtime.Dispatch
  alias Arbor.Contracts.LLM.{ModelEntry, ProviderEntry}
  alias Arbor.LLM.Message
  alias Arbor.LLM.Request

  defmodule FreezeFailRuntime do
    @moduledoc false
    @behaviour Arbor.AI.Runtime

    alias Arbor.Contracts.AI.RuntimeProfile

    @impl true
    def prepare(req, _opts) do
      send(Application.fetch_env!(:arbor_ai, :_test_freeze_route_pid), {:prepare, req})
      {:ok, req}
    end

    @impl true
    def execute(req, _cb, _opts) do
      send(Application.fetch_env!(:arbor_ai, :_test_freeze_route_pid), {:execute, req})
      {:error, :timeout}
    end

    @impl true
    def profile do
      {:ok, p} =
        RuntimeProfile.new(%{
          runtime_id: :freeze_fail,
          display_name: "freeze fail",
          owns_model_loop: false,
          owns_thread_history: false,
          supports_jido_actions: false,
          supports_action_hooks: false,
          supports_native_tools: false,
          runs_context_engine: false,
          exposes_compaction_data: false,
          unsupported_features: []
        })

      p
    end
  end

  setup do
    original_registry = Application.get_env(:arbor_ai, :runtime_registry, %{})
    original_profile = Application.get_env(:arbor_ai, :provider_route_profile)

    Application.put_env(:arbor_ai, :runtime_registry, %{
      arbor: FreezeFailRuntime,
      acp: FreezeFailRuntime
    })

    Application.put_env(:arbor_ai, :_test_freeze_route_pid, self())

    on_exit(fn ->
      Application.put_env(:arbor_ai, :runtime_registry, original_registry)
      Application.delete_env(:arbor_ai, :_test_freeze_route_pid)

      case original_profile do
        nil -> Application.delete_env(:arbor_ai, :provider_route_profile)
        value -> Application.put_env(:arbor_ai, :provider_route_profile, value)
      end
    end)

    :ok
  end

  test "public freeze_provider_route/1 preserves disabled and invalid task_class compatibility" do
    Application.put_env(:arbor_ai, :provider_route_profile, %{enabled: false})

    assert {:error, :disabled} = AI.freeze_provider_route(nil)
    assert {:error, :disabled} = AI.freeze_provider_route("default")

    for bad <- [%{class: "x"}, 12, :default, ["default"], true, self()] do
      assert {:error, {:route_assembly_failed, :invalid_task_class}} =
               AI.freeze_provider_route(bad)
    end
  end

  test "malformed plans and unavailable ACP mappings collapse to route_freeze_failed" do
    assert {:error, :route_freeze_failed} = Dispatch.prepare_frozen_primary_route(%{})

    no_eligible =
      route_input([model("primary", :provider_a, "wire-primary", :arbor)])
      |> put_in([:task_registry, "default", :requirements], %{providers: ["missing"]})

    assert {:error, :route_freeze_failed} = Dispatch.prepare_frozen_primary_route(no_eligible)

    unsupported =
      route_input([model("primary", :provider_a, "wire-primary", :arbor)])
      |> Map.put(:policy, %{params: %{"temperature" => 0.2}})

    assert {:error, :route_freeze_failed} = Dispatch.prepare_frozen_primary_route(unsupported)

    # Provider with no ACP CLI mapping must fail closed without partial route identity.
    no_cli = route_input([model("primary", :unknown_cli_provider, "wire", :acp)])
    assert {:error, :route_freeze_failed} = Dispatch.prepare_frozen_primary_route(no_cli)
  end

  test "closed projection is exact four-key map of primary only; input is not mutated" do
    primary = model("primary", :provider_a, "wire-primary", :arbor)
    fallback = model("fallback", :xai, "grok-wire", :acp)
    input = route_input([primary, fallback])
    input_before = :erlang.term_to_binary(input)

    assert {:ok, route} = Dispatch.prepare_frozen_primary_route(input)

    assert Map.keys(route) |> Enum.sort() == [:destination, :model, :provider, :runtime]
    assert route.destination == "provider_a"
    assert route.provider == "provider_a"
    assert route.runtime == "arbor"
    assert route.model == "wire-primary"

    # No fallback identity in the scalar route.
    refute route.destination == "acp:grok"
    refute route.provider == "xai"
    refute route.model == "grok-wire"

    assert :erlang.term_to_binary(input) == input_before
  end

  test "VOICE-17: in-BEAM freeze destination equals Dispatch route_authorizer route" do
    primary = model("primary", :provider_a, "wire-primary", :arbor)
    input = route_input([primary])

    assert {:ok, frozen} = Dispatch.prepare_frozen_primary_route(input)

    concurrency_name = :"freeze_rc_arbor_#{System.unique_integer([:positive])}"

    start_supervised!(
      {RouteConcurrency,
       name: concurrency_name,
       limits: %{
         provider_a: %{arbor: 8, acp: 8},
         provider_b: %{arbor: 8, acp: 8}
       }}
    )

    test_pid = self()

    authorizer = fn route ->
      send(
        test_pid,
        {:authorize,
         %{
           destination: route.destination,
           model: route.model,
           provider: Atom.to_string(route.provider.id),
           runtime: Atom.to_string(route.runtime)
         }}
      )

      :allow
    end

    assert {:error, :timeout} =
             Dispatch.dispatch(build_request("primary"),
               provider_route_input: input,
               route_authorizer: authorizer,
               route_concurrency_server: concurrency_name
             )

    assert_receive {:authorize, authorized}
    assert frozen.destination == authorized.destination
    assert frozen.model == authorized.model
    assert frozen.provider == authorized.provider
    assert frozen.runtime == authorized.runtime
    assert frozen.runtime == "arbor"
  end

  test "VOICE-17: xAI ACP freeze destination is acp:grok and matches authorizer" do
    primary = model("primary", :xai, "grok-wire", :acp)
    input = route_input([primary])

    assert {:ok, frozen} = Dispatch.prepare_frozen_primary_route(input)
    assert frozen.destination == "acp:grok"
    assert frozen.provider == "xai"
    assert frozen.runtime == "acp"
    assert frozen.model == "grok-wire"

    concurrency_name = :"freeze_rc_xai_#{System.unique_integer([:positive])}"

    start_supervised!(
      {RouteConcurrency, name: concurrency_name, limits: %{xai: %{acp: 8, arbor: 8}}}
    )

    test_pid = self()

    authorizer = fn route ->
      send(
        test_pid,
        {:authorize_acp, route.destination, route.runtime, route.model, route.provider.id}
      )

      :allow
    end

    assert {:error, :timeout} =
             Dispatch.dispatch(build_request("primary"),
               provider_route_input: input,
               route_authorizer: authorizer,
               route_concurrency_server: concurrency_name
             )

    assert_receive {:authorize_acp, "acp:grok", :acp, "grok-wire", :xai}
    assert frozen.destination == "acp:grok"
    assert frozen.model == "grok-wire"
    assert frozen.provider == "xai"
    assert frozen.runtime == "acp"
  end

  defp build_request(model) do
    %Request{
      provider: "anthropic",
      model: model,
      messages: [Message.new(:user, "hello")],
      tools: [],
      tool_choice: nil,
      max_tokens: 100,
      temperature: 0.7,
      reasoning_effort: nil,
      provider_options: %{}
    }
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
