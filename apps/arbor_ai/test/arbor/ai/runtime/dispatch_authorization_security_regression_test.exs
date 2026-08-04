defmodule Arbor.AI.Runtime.DispatchAuthorizationSecurityRegressionTest do
  @moduledoc false
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression
  @moduletag voice_id: "VOICE-17"

  alias Arbor.AI.Runtime.Dispatch
  alias Arbor.LLM.Message
  alias Arbor.LLM.Request

  defmodule LegacyAuthFailingRuntime do
    @moduledoc false
    @behaviour Arbor.AI.Runtime

    alias Arbor.Contracts.AI.RuntimeProfile

    @impl true
    def prepare(req, _opts) do
      send(Application.fetch_env!(:arbor_ai, :_test_legacy_auth_pid), {:prepare, req})
      {:ok, req}
    end

    @impl true
    def execute(req, _cb, _opts) do
      send(Application.fetch_env!(:arbor_ai, :_test_legacy_auth_pid), {:execute, req})
      {:error, :timeout}
    end

    @impl true
    def profile do
      {:ok, p} =
        RuntimeProfile.new(%{
          runtime_id: :legacy_auth_fail,
          display_name: "legacy auth fail",
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

  defmodule LegacyAuthSuccessRuntime do
    @moduledoc false
    @behaviour Arbor.AI.Runtime

    alias Arbor.Contracts.AI.RuntimeProfile
    alias Arbor.LLM.Response

    @impl true
    def prepare(req, _opts) do
      send(Application.fetch_env!(:arbor_ai, :_test_legacy_auth_pid), {:prepare, req})
      {:ok, req}
    end

    @impl true
    def execute(req, _cb, _opts) do
      send(Application.fetch_env!(:arbor_ai, :_test_legacy_auth_pid), {:execute, req})

      {:ok,
       %Response{
         text: "legacy ok",
         finish_reason: :stop,
         usage: %{input_tokens: 0, output_tokens: 0},
         raw: %{model: req.model, runtime: req.runtime}
       }}
    end

    @impl true
    def profile do
      {:ok, p} =
        RuntimeProfile.new(%{
          runtime_id: :legacy_auth_ok,
          display_name: "legacy auth ok",
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

  defp build_request(model, opts \\ []) do
    %Request{
      provider: Keyword.get(opts, :provider, "anthropic"),
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

  setup do
    original = Application.get_env(:arbor_ai, :runtime_registry, %{})

    Application.put_env(:arbor_ai, :runtime_registry, %{
      arbor: LegacyAuthFailingRuntime,
      acp: LegacyAuthSuccessRuntime
    })

    Application.put_env(:arbor_ai, :_test_legacy_auth_pid, self())

    on_exit(fn ->
      Application.put_env(:arbor_ai, :runtime_registry, original)
      Application.delete_env(:arbor_ai, :_test_legacy_auth_pid)
    end)

    :ok
  end

  test "security regression VOICE-17: legacy absent route_authorizer still prepares and executes" do
    request = build_request("totally-unknown-legacy-auth-model")

    assert {:error, :timeout} = Dispatch.dispatch(request)
    assert_receive {:prepare, %Request{model: "totally-unknown-legacy-auth-model"}}
    assert_receive {:execute, %Request{model: "totally-unknown-legacy-auth-model"}}
  end

  test "security regression VOICE-17: legacy primary and fallback each get exact source-owned routes" do
    test_pid = self()

    authorizer = fn route ->
      send(
        test_pid,
        {:authorize,
         %{
           canonical_model: route.model_entry.canonical_id,
           selected_provider: route.provider.id,
           runtime: route.runtime,
           ref: route.provider.ref,
           destination: route.destination,
           model: route.model
         }}
      )

      :allow
    end

    assert {:ok, response} =
             Dispatch.dispatch(build_request("claude-opus-4-6"),
               policy: %{runtime: :arbor, fallback_chain: [%{runtime: :acp}]},
               route_authorizer: authorizer
             )

    assert response.text == "legacy ok"
    assert_receive {:authorize, primary}
    assert primary.runtime == :arbor
    assert primary.canonical_model == "claude-opus-4-6"
    assert is_atom(primary.selected_provider)
    assert is_binary(primary.ref)

    assert_receive {:prepare, %Request{} = primary_request}
    assert primary_request.runtime == :arbor
    assert primary.destination == primary_request.provider
    assert primary.model == primary_request.model
    assert_receive {:execute, %Request{runtime: :arbor}}

    assert_receive {:authorize, fallback}
    assert fallback.runtime == :acp
    assert fallback.canonical_model == "claude-opus-4-6"
    # Distinct exact routes — fallback must not inherit primary's approval token.
    assert fallback.runtime != primary.runtime

    assert_receive {:prepare, %Request{} = fallback_request}
    assert fallback_request.runtime == :acp
    # ACP destination is the exact CLI used by checkout (shared resolver), not bare provider.
    assert {:ok, expected_acp_dest} =
             Arbor.AI.Runtime.Acp.authorization_destination(:acp, fallback_request.provider)

    assert fallback.destination == expected_acp_dest
    assert String.starts_with?(fallback.destination, "acp:")
    assert fallback.model == fallback_request.model
    assert_receive {:execute, %Request{runtime: :acp}}
  end

  test "security regression VOICE-17: synthesized legacy entries bind the exact outbound provider" do
    test_pid = self()

    authorizer = fn route ->
      send(test_pid, {:authorize_exact, route.destination, route.model, route.provider.id})
      :allow
    end

    Enum.each(["openai", "xai"], fn provider ->
      request = build_request("uncatalogued-shared-model", provider: provider)

      assert {:error, :timeout} =
               Dispatch.dispatch(request, route_authorizer: authorizer)

      assert_receive {:authorize_exact, ^provider, "uncatalogued-shared-model", :legacy}

      assert_receive {:prepare,
                      %Request{
                        provider: ^provider,
                        model: "uncatalogued-shared-model",
                        runtime: :arbor
                      }}

      assert_receive {:execute, %Request{provider: ^provider}}
    end)
  end

  test "security regression VOICE-17: unresolved outbound identity fails before callback or runtime" do
    test_pid = self()

    assert {:error, {:authorization_failed, :invalid_route}} =
             Dispatch.dispatch(build_request("uncatalogued-no-provider", provider: nil),
               route_authorizer: fn route ->
                 send(test_pid, {:unexpected_authorization, route})
                 :allow
               end
             )

    refute_received {:unexpected_authorization, _}
    refute_received {:prepare, _}
    refute_received {:execute, _}
  end

  test "security regression VOICE-17: fallback cannot inherit a prior primary approval" do
    counter = :atomics.new(1, [])

    authorizer = fn route ->
      n = :atomics.add_get(counter, 1, 1)
      send(self(), {:authorize, n, route.runtime})
      if n == 1, do: :allow, else: :deny
    end

    assert {:error, {:authorization_failed, :denied}} =
             Dispatch.dispatch(build_request("claude-opus-4-6"),
               policy: %{runtime: :arbor, fallback_chain: [%{runtime: :acp}]},
               route_authorizer: authorizer
             )

    assert_receive {:authorize, 1, :arbor}
    assert_receive {:prepare, %Request{runtime: :arbor}}
    assert_receive {:execute, %Request{runtime: :arbor}}
    assert_receive {:authorize, 2, :acp}
    refute_received {:prepare, %Request{runtime: :acp}}
    refute_received {:execute, %Request{runtime: :acp}}
  end

  test "security regression VOICE-17: legacy present faulting authorizers stop before prepare/execute" do
    cases = [
      {nil, :invalid_route_authorizer},
      {:not_a_callback, :invalid_route_authorizer},
      {fn _ -> :deny end, :denied},
      {fn _ -> :ok end, :denied},
      {fn _ -> true end, :denied},
      {fn _ -> {:error, :denied} end, :denied},
      {fn _ -> {:requires_approval, :egress} end, :pending},
      {fn _ -> raise "boom" end, :raised},
      {fn _ -> throw(:nope) end, :raised},
      {fn _ -> exit(:boom) end, :raised}
    ]

    Enum.each(cases, fn {authorizer, reason} ->
      assert {:error, {:authorization_failed, ^reason}} =
               Dispatch.dispatch(build_request("totally-unknown-legacy-auth-model"),
                 route_authorizer: authorizer
               )

      refute_received {:prepare, _}
      refute_received {:execute, _}
    end)
  end

  test "security regression VOICE-17: ProviderRouter ACP destinations are exact acp:<agent>" do
    alias Arbor.Contracts.LLM.{ModelEntry, ProviderEntry}

    primary =
      %ModelEntry{
        canonical_id: "primary",
        providers: [
          %ProviderEntry{id: :anthropic, ref: "claude-wire", auth: :none, runtimes: [:acp]}
        ],
        family: :test,
        context_window: 100_000,
        max_output_tokens: 4_000
      }

    fallback =
      %ModelEntry{
        canonical_id: "fallback",
        providers: [
          %ProviderEntry{id: :openai, ref: "codex-wire", auth: :none, runtimes: [:acp]}
        ],
        family: :test,
        context_window: 100_000,
        max_output_tokens: 4_000
      }

    # Primary ACP attempt fails so fallback is considered; authorizer records destinations.
    Application.put_env(:arbor_ai, :runtime_registry, %{
      acp: LegacyAuthFailingRuntime
    })

    concurrency_name = :"auth_rc_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Arbor.AI.RouteConcurrency,
       name: concurrency_name,
       limits: %{
         anthropic: %{acp: 8, arbor: 8},
         openai: %{acp: 8, arbor: 8}
       }}
    )

    test_pid = self()

    authorizer = fn route ->
      send(
        test_pid,
        {:authorize_acp, route.destination, route.runtime, route.model, route.provider.id}
      )

      :allow
    end

    route_input = %{
      task_class: "default",
      task_registry: %{"default" => %{requirements: %{}}},
      catalog: [primary, fallback],
      scoreboard: [
        %{model: "primary", provider: "anthropic", runtime: "acp", score: 1.0},
        %{model: "fallback", provider: "openai", runtime: "acp", score: 0.5}
      ],
      observations: [],
      budgets: [],
      now: ~U[2026-07-22 22:00:00Z],
      policy: %{}
    }

    assert {:error, :timeout} =
             Dispatch.dispatch(build_request("primary"),
               provider_route_input: route_input,
               route_authorizer: authorizer,
               route_concurrency_server: concurrency_name
             )

    assert_receive {:authorize_acp, "acp:claude", :acp, "claude-wire", :anthropic}
    assert_receive {:prepare, %Request{provider: "anthropic", runtime: :acp, model: "claude-wire"}}
    assert_receive {:execute, %Request{provider: "anthropic", runtime: :acp}}

    assert_receive {:authorize_acp, "acp:codex", :acp, "codex-wire", :openai}
    assert_receive {:prepare, %Request{provider: "openai", runtime: :acp, model: "codex-wire"}}
    assert_receive {:execute, %Request{provider: "openai", runtime: :acp}}
  end

  test "security regression VOICE-17: ProviderRouter approval for one ACP agent cannot authorize another" do
    alias Arbor.Contracts.LLM.{ModelEntry, ProviderEntry}

    primary =
      %ModelEntry{
        canonical_id: "primary",
        providers: [
          %ProviderEntry{id: :anthropic, ref: "claude-wire", auth: :none, runtimes: [:acp]}
        ],
        family: :test,
        context_window: 100_000,
        max_output_tokens: 4_000
      }

    fallback =
      %ModelEntry{
        canonical_id: "fallback",
        providers: [
          %ProviderEntry{id: :openai, ref: "codex-wire", auth: :none, runtimes: [:acp]}
        ],
        family: :test,
        context_window: 100_000,
        max_output_tokens: 4_000
      }

    Application.put_env(:arbor_ai, :runtime_registry, %{
      acp: LegacyAuthFailingRuntime
    })

    concurrency_name = :"auth_rc_deny_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Arbor.AI.RouteConcurrency,
       name: concurrency_name,
       limits: %{
         anthropic: %{acp: 8, arbor: 8},
         openai: %{acp: 8, arbor: 8}
       }}
    )

    authorizer = fn route ->
      send(self(), {:authorize_dest, route.destination})
      # Allow only claude CLI destination — codex must be denied separately.
      if route.destination == "acp:claude", do: :allow, else: :deny
    end

    route_input = %{
      task_class: "default",
      task_registry: %{"default" => %{requirements: %{}}},
      catalog: [primary, fallback],
      scoreboard: [
        %{model: "primary", provider: "anthropic", runtime: "acp", score: 1.0},
        %{model: "fallback", provider: "openai", runtime: "acp", score: 0.5}
      ],
      observations: [],
      budgets: [],
      now: ~U[2026-07-22 22:00:00Z],
      policy: %{}
    }

    assert {:error, {:authorization_failed, :denied}} =
             Dispatch.dispatch(build_request("primary"),
               provider_route_input: route_input,
               route_authorizer: authorizer,
               route_concurrency_server: concurrency_name
             )

    assert_receive {:authorize_dest, "acp:claude"}
    assert_receive {:prepare, %Request{provider: "anthropic", runtime: :acp}}
    assert_receive {:execute, %Request{provider: "anthropic", runtime: :acp}}
    assert_receive {:authorize_dest, "acp:codex"}
    refute_received {:prepare, %Request{provider: "openai"}}
    refute_received {:execute, %Request{provider: "openai"}}
  end
end
