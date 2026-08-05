defmodule Arbor.LLM.ToolLoopTypedSteeringSecurityRegressionTest do
  @moduledoc false

  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression
  @moduletag voice_id: "VOICE-17"

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Contracts.Session.SteeringMessage
  alias Arbor.LLM.{Client, ContentPart, Message, Request, Response, ToolLoop}
  alias Arbor.Signals.Signal

  defmodule AdapterSupport do
    @moduledoc false

    alias Arbor.LLM.{ContentPart, Response}

    def complete(mode, request, opts) do
      parent = Map.fetch!(request.provider_options, :parent)
      send(parent, {:adapter_attempt, mode, request, opts})
      tool_count = Enum.count(request.messages, &(&1.role == :tool))

      case mode do
        :immediate ->
          final_response()

        :one_round when tool_count == 0 ->
          tool_response(tool_count + 1)

        :one_round ->
          final_response()

        :three_rounds when tool_count < 3 ->
          tool_response(tool_count + 1)

        :three_rounds ->
          final_response()

        :two_then_fail when tool_count < 2 ->
          tool_response(tool_count + 1)

        :two_then_fail ->
          {:error, :timeout}

        :always ->
          tool_response(tool_count + 1)
      end
    end

    defp tool_response(round) do
      {:ok,
       %Response{
         text: "",
         finish_reason: :tool_calls,
         content_parts: [
           ContentPart.tool_call("call_#{round}", "record_tool", %{"round" => round})
         ],
         usage: %{},
         raw: %{}
       }}
    end

    defp final_response do
      {:ok,
       %Response{
         text: "done",
         finish_reason: :stop,
         content_parts: [ContentPart.text("done")],
         usage: %{},
         raw: %{}
       }}
    end
  end

  for {module, provider, mode} <- [
        {ImmediateAdapter, "typed_steering_immediate", :immediate},
        {OneRoundAdapter, "typed_steering_one", :one_round},
        {ThreeRoundAdapter, "typed_steering_three", :three_rounds},
        {TwoThenFailAdapter, "typed_steering_fail", :two_then_fail},
        {AlwaysToolAdapter, "typed_steering_always", :always}
      ] do
    defmodule module do
      @moduledoc false
      @behaviour Arbor.LLM.ProviderAdapter

      @provider provider
      @mode mode

      def provider, do: @provider

      def complete(request, opts),
        do:
          Arbor.LLM.ToolLoopTypedSteeringSecurityRegressionTest.AdapterSupport.complete(
            @mode,
            request,
            opts
          )

      def complete_single_attempt(request, opts), do: complete(request, opts)
    end
  end

  defmodule RecordingExecutor do
    @moduledoc false

    def execute(name, args, _workdir, opts) do
      send(Arbor.LLM.ToolLoopTypedSteeringSecurityRegressionTest, {
        :tool_attempt,
        name,
        args,
        opts
      })

      {:ok, "recorded"}
    end
  end

  setup do
    ensure_signal_children()
    true = Process.register(self(), __MODULE__)
    :ok
  end

  test "security regression: typed steering appends in order once per boundary without control leakage" do
    # Candidate/base selector: candidate accepts exact typed envelopes and emits
    # two content-free audits; the base only understands an arity-0 bare string.
    first = steering_message(1, "first steering", engagement_id: engagement_id(1))
    second = steering_message(2, "second steering", engagement_id: engagement_id(1))
    parent = self()

    {:ok, subscription_id} =
      Arbor.Signals.subscribe(
        "agent.steering_message_accepted",
        fn signal ->
          send(parent, {:steering_audit, signal})
          :ok
        end,
        async: false
      )

    on_exit(fn -> Arbor.Signals.unsubscribe(subscription_id) end)

    steer_check = fn descriptor ->
      send(parent, {:steering_boundary, descriptor})
      {:ok, [first, second]}
    end

    assert {:ok, %{content: "done"}} =
             run(OneRoundAdapter, on_steer_check: steer_check, tool_taint: trusted_taint())

    assert_receive {:adapter_attempt, :one_round, first_request, first_opts}
    assert_receive {:tool_attempt, "record_tool", %{"round" => 1}, _tool_opts}
    assert_receive {:steering_boundary, {attempt_ref, 1}}
    assert is_reference(attempt_ref)

    assert_receive {:adapter_attempt, :one_round, second_request, second_opts}

    user_contents =
      second_request.messages
      |> Enum.filter(&(&1.role == :user))
      |> Enum.map(& &1.content)

    assert Enum.take(user_contents, -2) == ["first steering", "second steering"]
    assert collect_tag(:steering_boundary) == []

    for controls <- [first_opts, second_opts] do
      refute Keyword.has_key?(controls, :on_steer_check)
      refute Keyword.has_key?(controls, :llm_call_authorizer)
      refute Keyword.has_key?(controls, :tool_taint)
      refute inspect(controls) =~ inspect(attempt_ref)
      refute inspect(controls) =~ "SteeringMessage"
    end

    forwarded = inspect({first_request, second_request, first_opts, second_opts})
    refute forwarded =~ first.message_id
    refute forwarded =~ first.engagement_id
    refute forwarded =~ inspect(attempt_ref)
    refute forwarded =~ "SteeringMessage"

    audits =
      for expected <- [first, second] do
        assert_receive {:steering_audit, %Signal{type: :steering_message_accepted, data: data}}

        assert data == %{
                 message_id: expected.message_id,
                 turn: 0,
                 boundary_sequence: 1,
                 content_bytes: byte_size(expected.content),
                 taint: %{
                   level: expected.taint.level,
                   sensitivity: expected.taint.sensitivity,
                   sanitizations: expected.taint.sanitizations,
                   confidence: expected.taint.confidence
                 }
               }

        data
      end

    audit_text = inspect(audits)
    refute audit_text =~ first.content
    refute audit_text =~ second.content
    refute audit_text =~ first.engagement_id
    refute audit_text =~ "principal"
    refute audit_text =~ "callback"
    refute audit_text =~ inspect(attempt_ref)
    refute_receive {:steering_audit, _}
  end

  test "security regression: malformed steering callback fails before provider or tool I/O" do
    assert {:error, {:invalid_steering_callback, :expected_arity_1}} =
             run(OneRoundAdapter, on_steer_check: fn -> :none end)

    refute_receive {:adapter_attempt, _, _, _}
    refute_receive {:tool_attempt, _, _, _}
  end

  test "security regression: malformed callback results and envelopes fail closed at the boundary" do
    valid = steering_message(10, "valid")

    cases = [
      {fn _ -> nil end,
       {:invalid_steering_callback_result, :expected_none_or_nonempty_message_list}},
      {fn _ -> {:ok, []} end,
       {:invalid_steering_callback_result, :expected_none_or_nonempty_message_list}},
      {fn _ -> {:ok, [Map.from_struct(valid)]} end,
       {:invalid_steering_envelope, :expected_exact_struct}},
      {fn _ -> {:ok, [%{valid | content: ""}]} end,
       {:invalid_steering_envelope, :invalid_content}},
      {fn _ -> {:error, :other_read_failure} end,
       {:invalid_steering_callback_result, :expected_none_or_nonempty_message_list}},
      {fn _ -> raise "fault" end, {:steering_callback_failed, :raised}}
    ]

    Enum.each(cases, fn {check, expected_reason} ->
      assert {:error, ^expected_reason} = run(OneRoundAdapter, on_steer_check: check)
      assert length(collect_tag(:adapter_attempt)) == 1
      assert length(collect_tag(:tool_attempt)) == 1
    end)
  end

  test "security regression: per-boundary steering count and byte limits fail closed atomically" do
    five = Enum.map(1..5, &steering_message(&1, "m#{&1}"))

    assert {:error, {:steering_limit_exceeded, :messages_per_boundary, 4}} =
             run(OneRoundAdapter, on_steer_check: fn _ -> {:ok, five} end)

    assert length(collect_tag(:adapter_attempt)) == 1
    assert length(collect_tag(:tool_attempt)) == 1

    oversized_batch = [
      steering_message(20, String.duplicate("a", 32_768)),
      steering_message(21, "b")
    ]

    assert {:error, {:steering_limit_exceeded, :bytes_per_boundary, 32_768}} =
             run(OneRoundAdapter, on_steer_check: fn _ -> {:ok, oversized_batch} end)

    assert length(collect_tag(:adapter_attempt)) == 1
    assert length(collect_tag(:tool_attempt)) == 1
  end

  test "security regression: cumulative steering message and byte counters span boundaries" do
    count_check = fn {_attempt_ref, boundary} ->
      start = (boundary - 1) * 4 + 1
      count = if boundary <= 4, do: 4, else: 1
      {:ok, Enum.map(start..(start + count - 1), &steering_message(&1, "x"))}
    end

    assert {:error,
            {:steering_delivery_ambiguous, {:steering_limit_exceeded, :messages_per_turn, 16}}} =
             run(AlwaysToolAdapter, on_steer_check: count_check, max_turns: 20)

    assert length(collect_tag(:adapter_attempt)) == 5
    assert length(collect_tag(:tool_attempt)) == 5

    bytes_check = fn {_attempt_ref, boundary} ->
      content = if boundary <= 4, do: String.duplicate("z", 32_768), else: "z"
      {:ok, [steering_message(100 + boundary, content)]}
    end

    assert {:error,
            {:steering_delivery_ambiguous, {:steering_limit_exceeded, :bytes_per_turn, 131_072}}} =
             run(AlwaysToolAdapter, on_steer_check: bytes_check, max_turns: 20)

    assert length(collect_tag(:adapter_attempt)) == 5
    assert length(collect_tag(:tool_attempt)) == 5
  end

  test "security regression: steering observes at most 128 boundaries per turn" do
    parent = self()

    check = fn {attempt_ref, boundary} ->
      send(parent, {:observed_boundary, attempt_ref, boundary})
      :none
    end

    assert {:error, {:steering_limit_exceeded, :boundaries_per_turn, 128}} =
             run(AlwaysToolAdapter, on_steer_check: check, max_turns: 200)

    observed = collect_tag(:observed_boundary)
    assert length(observed) == 128
    assert Enum.map(observed, &elem(&1, 2)) == Enum.to_list(1..128)
    assert observed |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 1
    assert length(collect_tag(:adapter_attempt)) == 129
    assert length(collect_tag(:tool_attempt)) == 129
  end

  test "security regression: accepted taint rises monotonically for provider authorizers and tools" do
    # Candidate/base selector: the candidate reaches untrusted then hostile with
    # sanitizations wiped; the base drops steering provenance entirely.
    parent = self()

    initial = %Taint{
      level: :trusted,
      sensitivity: :public,
      sanitizations: 255,
      confidence: :verified,
      source: "initial",
      chain: Enum.map(1..16, &"initial-#{&1}")
    }

    untrusted =
      steering_message(200, "untrusted steering",
        taint: %Taint{
          level: :untrusted,
          sensitivity: :internal,
          sanitizations: 255,
          confidence: :verified,
          source: "untrusted-source",
          chain: ["untrusted-chain"]
        }
      )

    hostile =
      steering_message(201, "hostile steering",
        taint: %Taint{
          level: :hostile,
          sensitivity: :restricted,
          sanitizations: 255,
          confidence: :unverified,
          source: "hostile-source",
          chain: ["hostile-chain"]
        }
      )

    steer_check = fn
      {_attempt_ref, 1} -> {:ok, [untrusted]}
      {_attempt_ref, 2} -> {:ok, [hostile]}
      {_attempt_ref, 3} -> :none
    end

    authorizer = fn %Request{} = request, %Taint{} = taint ->
      tool_count = Enum.count(request.messages, &(&1.role == :tool))
      send(parent, {:provider_taint, tool_count, taint})
      :allow
    end

    assert {:ok, %{content: "done", taint: %Taint{} = final_taint}} =
             run(ThreeRoundAdapter,
               on_steer_check: steer_check,
               llm_call_authorizer: authorizer,
               tool_taint: initial
             )

    assert final_taint.level == :hostile
    assert final_taint.sensitivity == :restricted
    assert final_taint.sanitizations == 0

    provider_taints = collect_tag(:provider_taint)

    assert Enum.map(provider_taints, &elem(&1, 2).level) == [
             :trusted,
             :untrusted,
             :hostile,
             :hostile
           ]

    assert Enum.map(provider_taints, &elem(&1, 2).sensitivity) == [
             :public,
             :internal,
             :restricted,
             :restricted
           ]

    assert Enum.map(provider_taints, &elem(&1, 2).sanitizations) == [255, 0, 0, 0]

    tool_attempts = collect_tag(:tool_attempt)
    tool_taints = Enum.map(tool_attempts, &Keyword.fetch!(elem(&1, 3), :taint))
    assert Enum.map(tool_taints, & &1.level) == [:trusted, :untrusted, :hostile]
    assert Enum.map(tool_taints, & &1.sanitizations) == [255, 0, 0]

    Enum.each(tool_attempts, fn {:tool_attempt, _name, args, opts} ->
      aggregate = Keyword.fetch!(opts, :taint)
      assert Keyword.fetch!(opts, :param_taint) == Map.new(Map.keys(args), &{&1, aggregate})
    end)

    hostile_provider_taint = provider_taints |> Enum.at(2) |> elem(2)
    assert length(hostile_provider_taint.chain) == SteeringMessage.max_taint_chain_entries()
    assert List.last(hostile_provider_taint.chain) == "hostile-source"
  end

  test "arity-2 provider authorizer receives exact conservative taint when tool_taint is absent" do
    parent = self()

    authorizer = fn %Request{}, %Taint{} = taint ->
      send(parent, {:default_authorizer_taint, taint})
      :allow
    end

    assert {:ok, %{content: "done", taint: nil}} =
             run(ImmediateAdapter, tools: [], llm_call_authorizer: authorizer)

    assert_receive {:default_authorizer_taint,
                    %Taint{
                      level: :untrusted,
                      sensitivity: :internal,
                      sanitizations: 0,
                      confidence: :unverified,
                      source: nil,
                      chain: []
                    }}
  end

  test "security regression: repeated accepted boundaries keep one post-steer ambiguity wrapper" do
    check = fn {_attempt_ref, boundary} ->
      {:ok, [steering_message(300 + boundary, "steering #{boundary}")]}
    end

    assert {:error, {:steering_delivery_ambiguous, :timeout}} =
             run(TwoThenFailAdapter,
               on_steer_check: check,
               llm_call_authorizer: fn _request -> :allow end
             )

    assert length(collect_tag(:adapter_attempt)) == 3
    assert length(collect_tag(:tool_attempt)) == 2
  end

  test "security regression: Session read ambiguity maps once after accepted steering" do
    check = fn
      {_attempt_ref, 1} -> {:ok, [steering_message(400, "accepted steering")]}
      {_attempt_ref, 2} -> {:error, :steering_read_ambiguous}
    end

    assert {:error, {:steering_delivery_ambiguous, :session_read}} =
             run(ThreeRoundAdapter, on_steer_check: check)

    assert length(collect_tag(:adapter_attempt)) == 2
    assert length(collect_tag(:tool_attempt)) == 2
  end

  defp run(adapter, opts) do
    defaults = [
      tools: tool_definitions(),
      tool_executor: RecordingExecutor,
      max_turns: 10
    ]

    ToolLoop.run(client(adapter), request(adapter.provider()), Keyword.merge(defaults, opts))
  end

  defp client(adapter) do
    Client.new(default_provider: adapter.provider())
    |> Client.register_adapter(adapter)
  end

  defp request(provider) do
    %Request{
      provider: provider,
      model: "test-model",
      messages: [Message.new(:user, "initial prompt")],
      provider_options: %{parent: self()}
    }
  end

  defp tool_definitions do
    [
      %{
        "type" => "function",
        "function" => %{
          "name" => "record_tool",
          "description" => "record one round",
          "parameters" => %{
            "type" => "object",
            "properties" => %{"round" => %{"type" => "integer"}}
          }
        }
      }
    ]
  end

  defp steering_message(index, content, opts \\ []) do
    taint =
      Keyword.get(opts, :taint, %Taint{
        level: :untrusted,
        sensitivity: :internal,
        sanitizations: 0,
        confidence: :unverified,
        source: "steering-source-#{index}",
        chain: ["steering-chain-#{index}"]
      })

    {:ok, message} =
      SteeringMessage.new(%{
        message_id: message_id(index),
        engagement_id: Keyword.get(opts, :engagement_id),
        content: content,
        taint: taint
      })

    message
  end

  defp message_id(index) do
    encoded = index |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(32, "0")
    "steer_" <> encoded
  end

  defp engagement_id(index) do
    encoded = index |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(32, "0")
    "eng_" <> encoded
  end

  defp trusted_taint do
    %Taint{
      level: :trusted,
      sensitivity: :public,
      sanitizations: 255,
      confidence: :verified,
      source: "initial",
      chain: ["initial"]
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

  defp ensure_signal_children do
    {:ok, _started} = Application.ensure_all_started(:arbor_signals)

    for child <- [
          {Arbor.Signals.Store, []},
          {Arbor.Signals.TopicKeys, []},
          {Arbor.Signals.Channels, []},
          {Arbor.Signals.Bus, []},
          {Arbor.Signals.Relay, []}
        ] do
      case Supervisor.start_child(Arbor.Signals.Supervisor, child) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, :already_present} -> :ok
      end
    end
  end
end
