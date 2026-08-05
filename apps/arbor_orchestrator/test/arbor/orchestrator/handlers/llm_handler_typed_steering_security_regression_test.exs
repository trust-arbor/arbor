defmodule Arbor.Orchestrator.Handlers.LlmHandlerTypedSteeringSecurityRegressionTest do
  @moduledoc false

  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression
  @moduletag voice_id: "VOICE-17"

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Contracts.Session.SteeringMessage
  alias Arbor.LLM.{Client, ContentPart, Request, Response}
  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Handlers.LlmHandler

  defmodule HandlerAdapter do
    @moduledoc false
    @behaviour Arbor.LLM.ProviderAdapter

    def provider, do: "handler_typed_steering"

    def complete(%Request{} = request, opts) do
      parent = Map.fetch!(request.provider_options, :parent)
      scenario = Map.fetch!(request.provider_options, :scenario)
      tool_count = Enum.count(request.messages, &(&1.role == :tool))

      send(parent, {
        :handler_adapter_attempt,
        scenario,
        request.model,
        tool_count,
        request,
        opts
      })

      response_for(scenario, request.model, tool_count)
    end

    def complete_single_attempt(%Request{} = request, opts), do: complete(request, opts)

    defp response_for(:dynamic_taint, _model, tool_count) when tool_count < 2,
      do: tool_response(tool_count + 1)

    defp response_for(:dynamic_taint, _model, _tool_count), do: final_response()

    defp response_for(:arity_1, _model, _tool_count), do: final_response()

    defp response_for(:post_steer_fallback, "primary-model", 0), do: tool_response(1)
    defp response_for(:post_steer_fallback, "primary-model", _tool_count), do: {:error, :timeout}
    defp response_for(:post_steer_fallback, "fallback-model", _tool_count), do: final_response()

    defp response_for(:pre_steer_fallback, "primary-model", 0), do: tool_response(1)
    defp response_for(:pre_steer_fallback, "primary-model", _tool_count), do: {:error, :timeout}
    defp response_for(:pre_steer_fallback, "fallback-model", 0), do: tool_response(1)
    defp response_for(:pre_steer_fallback, "fallback-model", _tool_count), do: final_response()

    defp tool_response(round) do
      {:ok,
       %Response{
         text: "",
         finish_reason: :tool_calls,
         content_parts: [
           ContentPart.tool_call("handler_call_#{round}", "handler_record_tool", %{
             "round" => round
           })
         ],
         usage: %{},
         raw: %{}
       }}
    end

    defp final_response do
      {:ok,
       %Response{
         text: "handler done",
         finish_reason: :stop,
         content_parts: [ContentPart.text("handler done")],
         usage: %{},
         raw: %{}
       }}
    end
  end

  defmodule HandlerExecutor do
    @moduledoc false

    def execute(name, args, _workdir, opts) do
      send(Arbor.Orchestrator.Handlers.LlmHandlerTypedSteeringSecurityRegressionTest, {
        :handler_tool_attempt,
        name,
        args,
        opts
      })

      {:ok, "recorded"}
    end
  end

  defmodule RecordingRouteDispatcher do
    @moduledoc false
    @behaviour Arbor.LLM.Dispatcher

    @impl true
    def dispatch(%Request{} = request, opts) do
      parent = Map.fetch!(request.provider_options, :parent)

      route = %{
        destination: request.provider,
        provider: request.provider,
        runtime: "arbor",
        model: request.model
      }

      result = Keyword.fetch!(opts, :route_authorizer).(route)
      send(parent, {:direct_route_authorization, route, result, opts})

      case result do
        :allow ->
          {:ok,
           %Response{
             text: "direct done",
             finish_reason: :stop,
             content_parts: [ContentPart.text("direct done")],
             usage: %{},
             raw: %{}
           }}

        denied ->
          {:error, {:route_denied, denied}}
      end
    end
  end

  setup do
    true = Process.register(self(), __MODULE__)
    previous_dispatcher = Application.get_env(:arbor_orchestrator, :llm_dispatcher)

    on_exit(fn ->
      case previous_dispatcher do
        nil -> Application.delete_env(:arbor_orchestrator, :llm_dispatcher)
        module -> Application.put_env(:arbor_orchestrator, :llm_dispatcher, module)
      end
    end)

    :ok
  end

  test "security regression: LlmHandler passes dynamic steering taint to arity-2 turn authorization" do
    # Candidate/base selector: candidate authorizes provider/tool attempts with
    # hostile aggregate taint after steering; base has only request-only wiring.
    parent = self()
    hostile = steering_message(1, :hostile, :restricted)

    steer_check = fn
      {_attempt_ref, 1} -> {:ok, [hostile]}
      {_attempt_ref, 2} -> :none
    end

    turn_authorizer = fn route, %Taint{} = taint ->
      send(parent, {:turn_authorized, route, taint})
      :allow
    end

    outcome =
      execute_tool_node(:dynamic_taint,
        steer_check: steer_check,
        turn_egress_authorizer: turn_authorizer
      )

    assert outcome.status == :success

    authorizations = collect_tag(:turn_authorized)

    assert Enum.map(authorizations, &elem(&1, 2).level) == [
             :untrusted,
             :derived,
             :hostile,
             :hostile
           ]

    assert Enum.map(authorizations, &elem(&1, 2).sensitivity) == [
             :internal,
             :internal,
             :restricted,
             :restricted
           ]

    tool_attempts = collect_tag(:handler_tool_attempt)

    assert Enum.map(tool_attempts, &Keyword.fetch!(elem(&1, 3), :taint).level) == [
             :derived,
             :hostile
           ]

    Enum.each(tool_attempts, fn {:handler_tool_attempt, _name, args, opts} ->
      aggregate = Keyword.fetch!(opts, :taint)
      assert Keyword.fetch!(opts, :param_taint) == Map.new(Map.keys(args), &{&1, aggregate})
    end)

    adapter_attempts = collect_tag(:handler_adapter_attempt)

    Enum.each(adapter_attempts, fn {:handler_adapter_attempt, _, _, _, _request, adapter_opts} ->
      refute Keyword.has_key?(adapter_opts, :turn_egress_authorizer)
      refute Keyword.has_key?(adapter_opts, :steer_check)
      refute Keyword.has_key?(adapter_opts, :on_steer_check)
      refute Keyword.has_key?(adapter_opts, :llm_call_authorizer)
      refute Keyword.has_key?(adapter_opts, :tool_taint)
    end)
  end

  test "arity-1 Session authorizers retain initial and per-provider compatibility" do
    parent = self()

    turn_authorizer = fn route ->
      send(parent, {:legacy_turn_authorized, route})
      :allow
    end

    outcome = execute_tool_node(:arity_1, turn_egress_authorizer: turn_authorizer)

    assert outcome.status == :success
    assert length(collect_tag(:legacy_turn_authorized)) == 2
    assert length(collect_tag(:handler_adapter_attempt)) == 1
  end

  test "security regression: arity-2 initial and direct route admission use exact conservative taint" do
    Application.put_env(:arbor_orchestrator, :llm_dispatcher, RecordingRouteDispatcher)
    parent = self()

    turn_authorizer = fn route, %Taint{} = taint ->
      send(parent, {:direct_turn_authorized, route, taint})
      :allow
    end

    outcome =
      LlmHandler.execute(
        direct_node(),
        context(:direct, []),
        graph(),
        base_opts(turn_authorizer)
      )

    assert outcome.status == :success
    calls = collect_tag(:direct_turn_authorized)
    assert length(calls) == 2

    Enum.each(calls, fn {:direct_turn_authorized, _route, taint} ->
      assert taint == conservative_untrusted_taint()
    end)

    assert_receive {:direct_route_authorization, _route, :allow, dispatch_opts}
    refute Keyword.has_key?(dispatch_opts, :turn_egress_authorizer)
    refute Keyword.has_key?(dispatch_opts, :steer_check)
  end

  test "security regression: post-steer provider failure suppresses fallback replay" do
    # Candidate/base selector: candidate returns a non-eligible ambiguity wrapper
    # after delivery; base returns :timeout and replays the pre-steering request.
    parent = self()
    message = steering_message(2, :untrusted, :internal)

    steer_check = fn descriptor ->
      send(parent, {:post_steer_boundary, descriptor})
      {:ok, [message]}
    end

    outcome =
      execute_tool_node(:post_steer_fallback,
        steer_check: steer_check,
        fallback_chain: [%{model: "fallback-model"}]
      )

    assert outcome.status == :fail
    assert outcome.failure_reason =~ "steering_delivery_ambiguous"

    attempts = collect_tag(:handler_adapter_attempt)
    assert Enum.map(attempts, &elem(&1, 2)) == ["primary-model", "primary-model"]
    assert length(collect_tag(:post_steer_boundary)) == 1
  end

  test "provider failure before accepted steering preserves fallback and creates a fresh attempt ref" do
    parent = self()

    steer_check = fn descriptor ->
      send(parent, {:pre_steer_boundary, descriptor})
      :none
    end

    outcome =
      execute_tool_node(:pre_steer_fallback,
        steer_check: steer_check,
        fallback_chain: [%{model: "fallback-model"}]
      )

    assert outcome.status == :success

    attempts = collect_tag(:handler_adapter_attempt)

    assert Enum.map(attempts, &elem(&1, 2)) == [
             "primary-model",
             "primary-model",
             "fallback-model",
             "fallback-model"
           ]

    assert [
             {:pre_steer_boundary, {primary_ref, 1}},
             {:pre_steer_boundary, {fallback_ref, 1}}
           ] = collect_tag(:pre_steer_boundary)

    assert is_reference(primary_ref)
    assert is_reference(fallback_ref)
    refute primary_ref == fallback_ref
  end

  defp execute_tool_node(scenario, opts) do
    fallback_chain = Keyword.get(opts, :fallback_chain, [])

    turn_authorizer =
      Keyword.get(opts, :turn_egress_authorizer, fn _route, %Taint{} -> :allow end)

    handler_opts =
      base_opts(turn_authorizer)
      |> Keyword.put(:llm_client, client())
      |> Keyword.put(:tool_executor, HandlerExecutor)
      |> maybe_put(:steer_check, Keyword.get(opts, :steer_check))

    LlmHandler.execute(
      tool_node(scenario),
      context(scenario, fallback_chain),
      graph(),
      handler_opts
    )
  end

  defp base_opts(turn_authorizer) do
    [
      frozen_egress_route: frozen_route(),
      turn_egress_authorizer: turn_authorizer
    ]
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp client do
    Client.new(default_provider: HandlerAdapter.provider())
    |> Client.register_adapter(HandlerAdapter)
  end

  defp tool_node(scenario) do
    %{
      id: "typed-steering-tool-node",
      attrs: %{
        "simulate" => "false",
        "prompt" => "run tools",
        "use_tools" => "true",
        "max_turns" => "10",
        "provider_options" => %{parent: self(), scenario: scenario}
      }
    }
  end

  defp direct_node do
    %{
      id: "typed-steering-direct-node",
      attrs: %{
        "simulate" => "false",
        "prompt" => "direct",
        "provider_options" => %{parent: self(), scenario: :direct}
      }
    }
  end

  defp context(_scenario, fallback_chain) do
    Context.new(%{
      "session.agent_id" => "agent_typed_steering_handler",
      "session.llm_provider" => HandlerAdapter.provider(),
      "session.llm_model" => "primary-model",
      "session.llm_runtime" => :arbor,
      "session.llm_fallback_chain" => fallback_chain,
      "session.tools" => tool_definitions()
    })
  end

  defp graph, do: %{attrs: %{"goal" => "typed steering"}}

  defp frozen_route do
    %{
      destination: HandlerAdapter.provider(),
      provider: HandlerAdapter.provider(),
      runtime: "arbor",
      model: "primary-model"
    }
  end

  defp tool_definitions do
    [
      %{
        "type" => "function",
        "function" => %{
          "name" => "handler_record_tool",
          "description" => "record handler tool taint",
          "parameters" => %{
            "type" => "object",
            "properties" => %{"round" => %{"type" => "integer"}}
          }
        }
      }
    ]
  end

  defp steering_message(index, level, sensitivity) do
    encoded = index |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(32, "0")

    {:ok, message} =
      SteeringMessage.new(%{
        message_id: "steer_" <> encoded,
        engagement_id: nil,
        content: "handler steering #{index}",
        taint: %Taint{
          level: level,
          sensitivity: sensitivity,
          sanitizations: 255,
          confidence: :unverified,
          source: "handler-steering-#{index}",
          chain: ["handler-steering-#{index}"]
        }
      })

    message
  end

  defp conservative_untrusted_taint do
    %Taint{
      level: :untrusted,
      sensitivity: :internal,
      sanitizations: 0,
      confidence: :unverified,
      source: nil,
      chain: []
    }
  end

  defp collect_tag(tag), do: collect_tag(tag, [])

  defp collect_tag(tag, acc) do
    receive do
      message when is_tuple(message) and elem(message, 0) == tag ->
        collect_tag(tag, [message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
