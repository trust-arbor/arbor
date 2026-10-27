defmodule Arbor.LLM.ToolResultSensitivitySecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.LLM.{Client, ContentPart, Message, Request, Response, ToolLoop}

  defmodule CapturingAdapter do
    @behaviour Arbor.LLM.ProviderAdapter

    def provider, do: "openai"

    def complete(request, _opts) do
      round = Enum.count(request.messages, &(&1.role == :tool))
      observer = Process.whereis(Arbor.LLM.ToolResultSensitivitySecurityRegressionTest)
      send(observer, {:tool_result_model_effect, round})

      if round == 0 do
        scenario = hd(request.messages).content

        {:ok,
         %Response{
           text: "",
           finish_reason: :tool_calls,
           content_parts: [
             ContentPart.tool_call("source_call", "load_notes", %{"source" => scenario})
           ],
           raw: %{}
         }}
      else
        {:ok,
         %Response{
           text: "Fixture reply",
           finish_reason: :stop,
           content_parts: [ContentPart.text("Fixture reply")],
           raw: %{}
         }}
      end
    end
  end

  defmodule LabeledTools do
    def execute("load_notes", %{"source" => source}, _workdir, _opts) do
      observer = Process.whereis(Arbor.LLM.ToolResultSensitivitySecurityRegressionTest)
      send(observer, {:tool_source_executed, source})

      case source do
        "Read the first source" ->
          {:ok, %{content: "Ordinary project planning notes", sensitivity: :restricted}}

        "Read the second source" ->
          {:error, %{message: "Ordinary project planning notes", sensitivity: :restricted}}

        "Read the third source" ->
          {:ok, %{content: "Ordinary project planning notes", sensitivity: :public}}
      end
    end
  end

  setup do
    Process.register(self(), __MODULE__)
    previous = Application.fetch_env(:arbor_llm, :sensitivity_guarded_adapters)
    Application.put_env(:arbor_llm, :sensitivity_guarded_adapters, [CapturingAdapter])

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_llm, :sensitivity_guarded_adapters, value)
        :error -> Application.delete_env(:arbor_llm, :sensitivity_guarded_adapters)
      end
    end)

    :ok
  end

  test "security regression: labeled successful tool output cannot reach the next cloud attempt" do
    assert {:error, {:sensitivity_blocked, _}} = run("Read the first source")
    assert_receive {:tool_result_model_effect, 0}
    assert_receive {:tool_source_executed, "Read the first source"}
    refute_receive {:tool_result_model_effect, 1}
  end

  test "security regression: labeled error tool output cannot reach the next cloud attempt" do
    assert {:error, {:sensitivity_blocked, _}} = run("Read the second source")
    assert_receive {:tool_result_model_effect, 0}
    assert_receive {:tool_source_executed, "Read the second source"}
    refute_receive {:tool_result_model_effect, 1}
  end

  test "security regression: public tool output still permits the next cloud attempt" do
    assert {:ok, result} = run("Read the third source")
    assert result.content == "Fixture reply"
    assert_receive {:tool_result_model_effect, 0}
    assert_receive {:tool_source_executed, "Read the third source"}
    assert_receive {:tool_result_model_effect, 1}
    refute_receive {:tool_result_model_effect, 2}
  end

  defp run(source) do
    client = Client.new(adapters: %{"openai" => CapturingAdapter})

    request = %Request{
      provider: "openai",
      model: "gpt-4o-mini",
      messages: [Message.new(:user, source)]
    }

    tools = [
      %{
        "type" => "function",
        "function" => %{
          "name" => "load_notes",
          "description" => "Load planning notes",
          "parameters" => %{
            "type" => "object",
            "properties" => %{"source" => %{"type" => "string"}}
          }
        }
      }
    ]

    ToolLoop.run(client, request, tools: tools, tool_executor: LabeledTools, max_turns: 3)
  end
end
