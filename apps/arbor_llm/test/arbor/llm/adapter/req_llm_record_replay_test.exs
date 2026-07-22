defmodule Arbor.LLM.Adapter.ReqLLMRecordReplayTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.LLM.Adapter.ReqLLM, as: Adapter
  alias Arbor.LLM.Plugs.Record
  alias Arbor.LLM.Plugs.Replay
  alias Arbor.LLM.Plugs.Usage
  alias Arbor.LLM.Request

  defmodule FakeReqLLMDispatch do
    use Arbor.LLM.Plug

    alias Arbor.LLM.Call

    def call(%Call{halted: true} = call), do: call

    def call(%Call{result: nil} = call) do
      if parent = Application.get_env(:arbor_llm, :req_llm_record_replay_test_pid),
        do: send(parent, :fake_dispatch_called)

      %{call | result: {:ok, response()}}
    end

    def call(%Call{} = call), do: call

    defp response do
      %ReqLLM.Response{
        id: "live-response",
        model: "gpt-4",
        context: ReqLLM.Context.new([]),
        message: %ReqLLM.Message{
          role: :assistant,
          content: [
            ReqLLM.Message.ContentPart.thinking("reasoning text"),
            ReqLLM.Message.ContentPart.text("answer")
          ],
          tool_calls: [ReqLLM.ToolCall.new("call-1", "lookup", ~s({"q":"x"}))],
          reasoning_details: [
            %ReqLLM.Message.ReasoningDetails{
              text: "reasoning text",
              signature: "must-not-be-recorded",
              encrypted?: true,
              provider: :openai,
              provider_data: %{"header" => "provider-internal"}
            }
          ]
        },
        stream?: false,
        stream: nil,
        usage: %{input_tokens: 7, output_tokens: 3, total_tokens: 10, total_cost: 0.25},
        finish_reason: :tool_calls,
        provider_meta: %{"secret" => "must-not-be-recorded"},
        error: nil
      }
    end
  end

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "arbor_llm_adapter_record_replay_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    original_recorder = Application.get_env(:arbor_llm, :recorder)
    original_pipeline = Application.get_env(:arbor_llm, :pipeline)
    Application.put_env(:arbor_llm, :recorder, fixtures_path: tmp_dir)
    Application.put_env(:arbor_llm, :pipeline, [Replay, FakeReqLLMDispatch, Record, Usage])
    Application.put_env(:arbor_llm, :req_llm_record_replay_test_pid, self())
    test_pid = self()

    handler_id = "adapter-record-replay-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:arbor, :llm, :usage],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:usage_event, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)
      Application.delete_env(:arbor_llm, :req_llm_record_replay_test_pid)
      File.rm_rf!(tmp_dir)
      restore_env(:recorder, original_recorder)
      restore_env(:pipeline, original_pipeline)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "adapter record then replay reconstructs ReqLLM and skips fake transport", %{
    tmp_dir: tmp_dir
  } do
    request = %Request{provider: "openai", model: "gpt-4", messages: []}

    assert {:ok, live} = Adapter.complete(request)
    assert live.text == "answer"
    assert live.reasoning_content == "reasoning text"
    assert live.finish_reason == :tool_calls
    assert live.usage[:input_tokens] == 7
    assert live.usage[:total_cost] == 0.25
    assert Enum.any?(live.content_parts, &(&1.kind == :thinking and &1.text == "reasoning text"))
    assert Enum.any?(live.content_parts, &(&1.kind == :tool_call and &1.name == "lookup"))
    assert_receive :fake_dispatch_called
    assert_receive {:usage_event, [:arbor, :llm, :usage], %{input: 7, output: 3, total: 10}, _}

    [fixture_name] = File.ls!(tmp_dir)
    fixture_path = Path.join(tmp_dir, fixture_name)
    assert String.ends_with?(fixture_path, ".json")
    fixture = fixture_path |> File.read!() |> Jason.decode!()
    assert fixture["schema_version"] == 2
    assert fixture["response"]["value"]["response_kind"] == "req_llm"
    refute File.read!(fixture_path) =~ "must-not-be-recorded"
    refute File.read!(fixture_path) =~ "provider-internal"

    assert {:ok, replayed} = Adapter.complete(request)
    assert replayed.text == "answer"
    assert replayed.reasoning_content == "reasoning text"
    assert replayed.finish_reason == :tool_calls
    assert replayed.usage[:input_tokens] == 7
    assert replayed.usage[:total_cost] == 0.25

    assert Enum.any?(
             replayed.content_parts,
             &(&1.kind == :thinking and &1.text == "reasoning text")
           )

    assert Enum.any?(replayed.content_parts, &(&1.kind == :tool_call and &1.name == "lookup"))
    refute_receive :fake_dispatch_called
    refute_receive {:usage_event, [:arbor, :llm, :usage], _, _}, 100
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_llm, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_llm, key, value)
end
