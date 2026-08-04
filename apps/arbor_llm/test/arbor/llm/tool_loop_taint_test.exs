defmodule Arbor.LLM.ToolLoopTaintTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.Taint
  alias Arbor.LLM.{Client, ContentPart, Message, Request, Response, ToolLoop}

  @moduletag :fast
  @moduletag :security_regression

  defmodule Adapter do
    @behaviour Arbor.LLM.ProviderAdapter

    def provider, do: "tool_loop_taint_test"

    def complete(%Request{} = request, opts) do
      send(request.provider_options.test_pid, {:adapter_call, request, opts})

      case Enum.count(request.messages, &(&1.role == :tool)) do
        0 -> tool_call("first", %{"path" => "one", "mode" => "read"})
        1 -> tool_call("second", %{"path" => "two"})
        _ -> {:ok, %Response{text: "done", finish_reason: :stop, raw: %{}}}
      end
    end

    defp tool_call(id, args) do
      {:ok,
       %Response{
         text: "",
         finish_reason: :tool_calls,
         content_parts: [ContentPart.tool_call(id, "capture", args)],
         raw: %{}
       }}
    end
  end

  defmodule CapturingExecutor do
    def execute(name, args, workdir, opts) do
      send(self(), {:tool_execution, name, args, workdir, opts})
      {:ok, "captured"}
    end
  end

  defmodule NeverCalledAdapter do
    @behaviour Arbor.LLM.ProviderAdapter

    def provider, do: "tool_loop_taint_never_called"

    def complete(request, opts) do
      send(self(), {:unexpected_adapter_call, request, opts})
      {:ok, %Response{text: "unexpected", finish_reason: :stop, raw: %{}}}
    end
  end

  @tools [
    %{
      "type" => "function",
      "function" => %{
        "name" => "capture",
        "parameters" => %{"type" => "object", "properties" => %{}}
      }
    }
  ]

  test "forwards aggregate and complete per-parameter taint on every tool round" do
    taint = %Taint{
      level: :untrusted,
      sensitivity: :confidential,
      sanitizations: 0,
      confidence: :plausible,
      source: "llm_output",
      chain: ["authenticated_user", "llm_output"]
    }

    assert {:ok, %{content: "done"}} =
             ToolLoop.run(client(Adapter), request(Adapter),
               tools: @tools,
               tool_executor: CapturingExecutor,
               tool_taint: taint
             )

    assert_receive {:tool_execution, "capture", first_args, ".", first_opts}
    assert first_args == %{"path" => "one", "mode" => "read"}
    assert Keyword.fetch!(first_opts, :taint) == taint
    assert Keyword.fetch!(first_opts, :param_taint) == taint_for_all(first_args, taint)

    assert_receive {:tool_execution, "capture", second_args, ".", second_opts}
    assert second_args == %{"path" => "two"}
    assert Keyword.fetch!(second_opts, :taint) == taint
    assert Keyword.fetch!(second_opts, :param_taint) == taint_for_all(second_args, taint)

    for _round <- 1..3 do
      assert_receive {:adapter_call, %Request{} = adapter_request, adapter_opts}
      refute Keyword.has_key?(adapter_opts, :tool_taint)
      refute Map.has_key?(Map.from_struct(adapter_request), :tool_taint)
    end
  end

  test "absent tool_taint preserves executor behavior" do
    assert {:ok, _result} =
             ToolLoop.run(client(Adapter), request(Adapter),
               tools: @tools,
               tool_executor: CapturingExecutor
             )

    assert_receive {:tool_execution, "capture", _args, ".", opts}
    refute Keyword.has_key?(opts, :taint)
    refute Keyword.has_key?(opts, :param_taint)
  end

  test "malformed present tool_taint fails closed before any provider call" do
    malformed = [
      nil,
      :untrusted,
      %{level: :untrusted},
      %{__struct__: Taint},
      %Taint{level: :unknown},
      %Taint{sanitizations: 256},
      %Taint{chain: ["valid", :invalid]},
      Map.put(%Taint{}, :unexpected, true)
    ]

    Enum.each(malformed, fn value ->
      assert {:error, :invalid_tool_taint} =
               ToolLoop.run(client(NeverCalledAdapter), request(NeverCalledAdapter),
                 tools: @tools,
                 tool_executor: CapturingExecutor,
                 tool_taint: value
               )
    end)

    refute_receive {:unexpected_adapter_call, _, _}
  end

  defp client(adapter) do
    Client.new(default_provider: adapter.provider())
    |> Client.register_adapter(adapter)
  end

  defp request(adapter) do
    %Request{
      provider: adapter.provider(),
      model: "test",
      messages: [Message.new(:user, "test")],
      provider_options: %{test_pid: self()}
    }
  end

  defp taint_for_all(args, taint), do: Map.new(Map.keys(args), &{&1, taint})
end
