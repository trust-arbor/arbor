defmodule Arbor.Agent.SimpleAgentLLMBoundaryTest do
  use ExUnit.Case, async: false

  alias Arbor.Agent.SimpleAgent
  alias Arbor.LLM.{Client, ContentPart, Message, RequestTimeoutError, Response}

  @moduletag :fast

  # This tool is deliberately absent from the Actions registry. Its proposal
  # exercises the existing error-result continuation without any granted effect.
  defmodule Probe do
    use Jido.Action,
      name: "simple_agent_boundary_probe",
      description: "Test-only tool proposal",
      schema: [value: [type: :string, required: true]]

    def run(_params, _context), do: raise("the facade must not execute this tool")
  end

  defmodule Adapter do
    @behaviour Arbor.LLM.ProviderAdapter

    def provider, do: "simple_agent_boundary"

    def complete(request, opts) do
      # The facade runs inside deadline-owned processes. Use an explicit
      # registered observer rather than assuming process dictionary inheritance.
      send(Arbor.Agent.SimpleAgentLLMBoundaryTest, {:provider_request, request, opts})
      round = Enum.count(request.messages, &(&1.role == :tool))

      case {request.model, round} do
        {"budget", _} ->
          {:ok, %Response{text: String.duplicate("x", 512)}}

        {"invalid-usage", _} ->
          {:ok, %Response{text: "invalid", usage: %{total_tokens: 1.0e308}}}

        {"deadline", _} ->
          receive do
            :release -> final_response()
          end

        {"error", _} ->
          {:error, :provider_failed}

        {"overflow", 1} ->
          {:error, "maximum context length exceeded"}

        {"loop", _} ->
          tool_response(round)

        {model, 0} when model in ["tool", "overflow"] ->
          tool_response(round)

        _ ->
          final_response()
      end
    end

    defp tool_response(round) do
      {:ok,
       %Response{
         text: "Checking",
         finish_reason: :tool_calls,
         content_parts: [
           ContentPart.tool_call("probe_#{round}", "simple_agent_boundary_probe", %{
             "value" => "round #{round}"
           })
         ],
         usage: %{input_tokens: 2, output_tokens: 3, total_tokens: 5}
       }}
    end

    defp final_response do
      {:ok,
       %Response{
         text: "Finished",
         content_parts: [ContentPart.text("Finished")],
         usage: %{input_tokens: 7, output_tokens: 11, total_tokens: 18}
       }}
    end
  end

  setup do
    Process.register(self(), __MODULE__)
    previous_client = Client.default_client()

    client =
      Client.new(
        adapters: %{"simple_agent_boundary" => Adapter},
        default_provider: "simple_agent_boundary",
        model_catalog: %{}
      )

    :ok = Client.set_default_client(client)
    on_exit(fn -> Client.set_default_client(previous_client) end)
    :ok
  end

  test "uses the configured real LLM facade and preserves completion usage" do
    assert {:ok, result} = run("final", system_prompt: "Custom system prompt")

    assert result.text == "Finished"
    assert result.status == :completed
    assert result.turns == 1
    assert result.tool_calls == []
    assert result.model == "final"
    assert result.usage == %{input_tokens: 7, output_tokens: 11, total_tokens: 18}

    assert_received {:provider_request, request, _opts}
    assert request.provider == "simple_agent_boundary"
    assert request.max_tokens == 16_384
    assert request.temperature == 0.3
    assert request.tools == []

    assert [
             %Message{role: :system, content: "Custom system prompt"},
             %Message{role: :user, content: "Test task"}
           ] = request.messages

    refute_received {:provider_request, _, _}
  end

  test "one model step proposes tools and the local loop retains continuation and usage" do
    assert {:ok, result} = run("tool", tools: [Probe], context_management: :heuristic)

    assert result.status == :completed
    assert result.turns == 2
    assert result.usage == %{input_tokens: 9, output_tokens: 14, total_tokens: 23}

    assert [%{turn: 1, name: "simple_agent_boundary_probe", args: args} = entry] =
             result.tool_calls

    assert args == %{"value" => "round 0"}
    assert entry.result =~ "ERROR:"
    assert is_integer(entry.duration_ms)
    assert %DateTime{} = entry.timestamp
    assert result.context_stats.full_transcript_length == 4

    assert_received {:provider_request, first, _opts}
    assert [%{name: "simple_agent_boundary_probe", input_schema: schema}] = first.tools
    assert schema["properties"]["value"]["type"] == "string"

    assert_received {:provider_request, second, _opts}
    assert [_, _, assistant, tool_result] = second.messages
    assert %Message{role: :assistant, content: parts} = assistant

    assert %{kind: :tool_call, id: "probe_0", name: "simple_agent_boundary_probe"} =
             Enum.find(parts, &(&1.kind == :tool_call))

    assert %Message{role: :tool, metadata: %{tool_call_id: "probe_0"}} = tool_result
    assert tool_result.content == entry.result
    refute_received {:provider_request, _, _}
  end

  test "max_turns bounds provider steps even when every response proposes another tool" do
    assert {:ok, result} = run("loop", tools: [Probe], max_turns: 2)

    assert result.status == :max_turns
    assert result.turns == 2
    assert result.text == nil
    assert length(result.tool_calls) == 2
    assert result.usage == %{input_tokens: 4, output_tokens: 6, total_tokens: 10}
    assert_received {:provider_request, _, _}
    assert_received {:provider_request, _, _}
    refute_received {:provider_request, _, _}
  end

  test "zero turns makes no provider request" do
    assert {:ok, result} = run("loop", max_turns: 0)
    assert result.status == :max_turns
    assert result.turns == 0
    assert result.usage == %{}
    refute_received {:provider_request, _, _}
  end

  test "security regression: response byte budget reaches the actual facade with and without tools" do
    for tools <- [[], [Probe]] do
      assert {:error, {:invalid_completion_response, _reason}} =
               run("budget", tools: tools, max_response_bytes: 256)

      assert_received {:provider_request, _request, opts}
      assert Keyword.fetch!(opts, :max_response_bytes) == 256

      assert {:ok, result} = run("budget", tools: tools, max_response_bytes: 2_048)
      assert result.text == String.duplicate("x", 512)
      assert_received {:provider_request, _, _}
      refute_received {:provider_request, _, _}
    end
  end

  test "security regression: invalid provider usage is rejected before host accounting" do
    assert {:error, {:invalid_completion_response, _reason}} = run("invalid-usage")
    assert_received {:provider_request, _, _}
    refute_received {:provider_request, _, _}
  end

  test "per-call deadline bounds a nonresponding adapter" do
    assert {:error, %RequestTimeoutError{}} = run("deadline", timeout: 100)
    assert_received {:provider_request, _, _}
    refute_received {:provider_request, _, _}
  end

  test "provider errors remain errors and context overflow retains completed history" do
    assert {:error, :provider_failed} = run("error")
    assert_received {:provider_request, _, _}

    assert {:ok, result} = run("overflow", tools: [Probe])
    assert result.status == :context_overflow
    assert result.turns == 1
    assert length(result.tool_calls) == 1
    assert result.usage == %{input_tokens: 2, output_tokens: 3, total_tokens: 5}
    assert_received {:provider_request, _, _}
    assert_received {:provider_request, _, _}
    refute_received {:provider_request, _, _}
  end

  defp run(model, opts \\ []) do
    SimpleAgent.run(
      "Test task",
      Keyword.merge(
        [provider: :simple_agent_boundary, model: model, context_management: :none, tools: []],
        opts
      )
    )
  end
end
