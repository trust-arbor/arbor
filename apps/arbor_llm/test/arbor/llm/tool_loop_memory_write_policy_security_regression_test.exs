defmodule Arbor.LLM.ToolLoopMemoryWritePolicySecurityRegressionTest do
  @moduledoc false

  # The executor sends to this test-owned registered observer, including when
  # ToolLoop runs in a separate process. No process dictionary is inherited.
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.LLM.{Client, ContentPart, Message, Request, Response, ToolLoop}

  defmodule RecordingAdapter do
    @moduledoc false
    @behaviour Arbor.LLM.ProviderAdapter

    def provider, do: "memory_write_policy_test"

    def complete(request, opts), do: respond(request, opts, :complete)

    def complete_streaming(request, _callback, opts), do: respond(request, opts, :stream)

    defp respond(request, opts, mode) do
      observer = Map.fetch!(request.provider_options, :observer)
      round = Enum.count(request.messages, &(&1.role == :tool))
      send(observer, {:provider_request, mode, round, opts})

      if round < 2 do
        {:ok,
         %Response{
           text: "",
           finish_reason: :tool_calls,
           content_parts: [
             ContentPart.tool_call("call_#{round}", "memory_remember", %{
               "round" => round,
               "content" => "private turn content",
               "memory_write_policy" => "allow"
             })
           ],
           raw: %{}
         }}
      else
        {:ok,
         %Response{
           text: "done",
           finish_reason: :stop,
           content_parts: [ContentPart.text("done")],
           raw: %{}
         }}
      end
    end
  end

  # Harmless stand-in for the registered legacy CLI provider. It only records
  # requests and returns fixture tool calls; no ACP process is started.
  defmodule FakeAcpAdapter do
    @moduledoc false
    @behaviour Arbor.LLM.ProviderAdapter

    def provider, do: "acp"

    def complete(request, opts), do: RecordingAdapter.complete(request, opts)

    def complete_streaming(request, callback, opts),
      do: RecordingAdapter.complete_streaming(request, callback, opts)
  end

  defmodule RecordingExecutor do
    @moduledoc false

    def execute(name, args, _workdir, opts) do
      send(Arbor.LLM.ToolLoopMemoryWritePolicySecurityRegressionTest, {
        :executor_request,
        name,
        args,
        opts
      })

      {:ok, "observed"}
    end
  end

  setup do
    true = Process.register(self(), __MODULE__)
    :ok
  end

  for authorization <- [false, true], mode <- [:complete, :stream] do
    test "security regression: denial survives model arguments with authorization=#{authorization} via #{mode}" do
      authorization = unquote(authorization)
      mode = unquote(mode)

      assert {:ok, result} =
               run_loop(authorization, mode, memory_write_policy: :deny)

      assert result.content == "done"

      for round <- 0..1 do
        assert_receive {:executor_request, "memory_remember", args, opts}
        assert args["round"] == round
        assert args["memory_write_policy"] == "allow"
        assert Keyword.fetch!(opts, :memory_write_policy) == :deny
        assert Keyword.fetch!(opts, :agent_id) == "agent_memory_policy_test"
      end

      for round <- 0..2 do
        assert_receive {:provider_request, ^mode, ^round, opts}
        refute Keyword.has_key?(opts, :memory_write_policy)
      end
    end
  end

  test "ordinary runs without a restriction keep executor and provider policy absent" do
    assert {:ok, result} = run_loop(false, :complete, [])
    assert result.content == "done"

    for round <- 0..1 do
      assert_receive {:executor_request, "memory_remember", args, opts}
      assert args["round"] == round
      assert args["memory_write_policy"] == "allow"
      refute Keyword.has_key?(opts, :memory_write_policy)
    end

    for round <- 0..2 do
      assert_receive {:provider_request, :complete, ^round, opts}
      refute Keyword.has_key?(opts, :memory_write_policy)
    end
  end

  for provider_source <- [:explicit_acp, :default_acp] do
    test "security regression: restricted #{provider_source} is refused before adapter or executor calls" do
      for policy <- [:deny, :allow, false, [], %{}] do
        assert {:error, :memory_write_policy_runtime_unsupported} =
                 run_loop(
                   false,
                   :complete,
                   [memory_write_policy: policy],
                   unquote(provider_source)
                 )

        refute_received {:provider_request, _, _, _}
        refute_received {:executor_request, _, _, _}
      end
    end

    test "#{provider_source} remains callable without a memory restriction" do
      for extra_opts <- [[], [memory_write_policy: nil]] do
        assert {:ok, result} =
                 run_loop(false, :complete, extra_opts, unquote(provider_source))

        assert result.content == "done"

        for _round <- 0..1 do
          assert_receive {:executor_request, "memory_remember", _, opts}
          refute Keyword.has_key?(opts, :memory_write_policy)
        end

        for round <- 0..2 do
          assert_receive {:provider_request, :complete, ^round, opts}
          assert Keyword.get(opts, :memory_write_policy) == nil
        end
      end
    end
  end

  defp run_loop(authorization, mode, extra_opts, provider_source \\ :ordinary) do
    {provider, adapter} =
      case provider_source do
        :ordinary -> {RecordingAdapter.provider(), RecordingAdapter}
        :explicit_acp -> {FakeAcpAdapter.provider(), FakeAcpAdapter}
        :default_acp -> {nil, FakeAcpAdapter}
      end

    client =
      Client.new(default_provider: adapter.provider())
      |> Client.register_adapter(adapter)

    request = %Request{
      provider: provider,
      model: "test",
      messages: [Message.new(:user, "remember this")],
      provider_options: %{observer: self()}
    }

    tools = [
      %{
        "type" => "function",
        "function" => %{
          "name" => "memory_remember",
          "description" => "Test executor boundary",
          "parameters" => %{"type" => "object", "properties" => %{}}
        }
      }
    ]

    opts = [
      authorization: authorization,
      execution_principal: "agent_memory_policy_test",
      agent_id: "agent_memory_policy_test",
      caller_id: "human_memory_policy_test",
      author_id: "agent_memory_policy_test",
      task_id: "task_memory_policy_test",
      session_id: "session_memory_policy_test",
      tool_executor: RecordingExecutor,
      tools: tools,
      max_turns: 3
    ]

    opts =
      if mode == :stream,
        do: Keyword.put(opts, :stream_callback, fn _delta -> :ok end),
        else: opts

    Task.async(fn -> ToolLoop.run(client, request, opts ++ extra_opts) end)
    |> Task.await(5_000)
  end
end
