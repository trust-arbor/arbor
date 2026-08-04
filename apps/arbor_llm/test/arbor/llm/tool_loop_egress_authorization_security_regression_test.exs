defmodule Arbor.LLM.ToolLoopEgressAuthorizationSecurityRegressionTest do
  @moduledoc false
  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag :security_regression
  @moduletag voice_id: "VOICE-17"

  alias Arbor.LLM.{Client, ContentPart, Message, Request, Response, ToolLoop}

  defmodule CountingAdapter do
    @behaviour Arbor.LLM.ProviderAdapter
    def provider, do: "llm_auth_counting"

    def complete(%Request{} = request, opts) do
      parent = Keyword.get(opts, :parent) || Map.get(request.provider_options || %{}, :parent)

      if is_pid(parent) do
        send(parent, {:client_complete, request.model, Keyword.keys(opts)})
      end

      case Enum.count(request.messages, &(&1.role == :tool)) do
        0 ->
          {:ok,
           %Response{
             text: "",
             finish_reason: :tool_calls,
             content_parts: [ContentPart.tool_call("c1", "echo_tool", %{"v" => "1"})],
             usage: %{},
             raw: %{}
           }}

        _ ->
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
  end

  # Implements complete_streaming so the streaming attempt is observable, then
  # returns stream_not_supported so ToolLoop must reauthorize and complete.
  defmodule StreamUnsupportedAdapter do
    @behaviour Arbor.LLM.ProviderAdapter
    def provider, do: "llm_auth_stream_unsupported"

    def complete_streaming(%Request{} = request, _callback, opts) do
      parent = Keyword.get(opts, :parent) || Map.get(request.provider_options || %{}, :parent)

      if is_pid(parent) do
        send(parent, {:client_complete_streaming, Keyword.keys(opts)})
      end

      {:error, {:stream_not_supported, __MODULE__}}
    end

    def complete(%Request{} = request, opts) do
      parent = Keyword.get(opts, :parent) || Map.get(request.provider_options || %{}, :parent)

      if is_pid(parent) do
        send(parent, {:client_complete, :fallback, Keyword.keys(opts)})
      end

      {:ok,
       %Response{
         text: "stream-fallback-ok",
         finish_reason: :stop,
         content_parts: [ContentPart.text("stream-fallback-ok")],
         usage: %{},
         raw: %{}
       }}
    end
  end

  defmodule MaxTurnsAdapter do
    @behaviour Arbor.LLM.ProviderAdapter
    def provider, do: "llm_auth_max_turns"

    def complete(%Request{tools: tools} = request, opts) when tools in [nil, []] do
      parent = Keyword.get(opts, :parent) || Map.get(request.provider_options || %{}, :parent)
      if is_pid(parent), do: send(parent, {:client_complete, :wrap_up, tools})

      {:ok,
       %Response{
         text: "wrap-up answer",
         finish_reason: :stop,
         content_parts: [ContentPart.text("wrap-up answer")],
         usage: %{},
         raw: %{}
       }}
    end

    def complete(%Request{} = request, opts) do
      parent = Keyword.get(opts, :parent) || Map.get(request.provider_options || %{}, :parent)
      if is_pid(parent), do: send(parent, {:client_complete, :ordinary, request.tools})

      {:ok,
       %Response{
         text: "",
         finish_reason: :tool_calls,
         content_parts: [ContentPart.tool_call("c", "echo_tool", %{"v" => "x"})],
         usage: %{},
         raw: %{}
       }}
    end
  end

  defmodule EmptyFinalAdapter do
    @behaviour Arbor.LLM.ProviderAdapter
    def provider, do: "llm_auth_empty_final"

    def complete(%Request{tools: tools} = request, opts) when tools in [nil, []] do
      parent = Keyword.get(opts, :parent) || Map.get(request.provider_options || %{}, :parent)
      if is_pid(parent), do: send(parent, {:client_complete, :empty_final_retry})

      {:ok,
       %Response{
         text: "forced final",
         finish_reason: :stop,
         content_parts: [ContentPart.text("forced final")],
         usage: %{},
         raw: %{}
       }}
    end

    def complete(%Request{} = request, opts) do
      parent = Keyword.get(opts, :parent) || Map.get(request.provider_options || %{}, :parent)

      case Enum.count(request.messages, &(&1.role == :tool)) do
        0 ->
          if is_pid(parent), do: send(parent, {:client_complete, :tool_round})

          {:ok,
           %Response{
             text: "",
             finish_reason: :tool_calls,
             content_parts: [ContentPart.tool_call("c1", "echo_tool", %{"v" => "1"})],
             usage: %{},
             raw: %{}
           }}

        _ ->
          if is_pid(parent), do: send(parent, {:client_complete, :empty_after_tool})

          {:ok,
           %Response{
             text: "",
             finish_reason: :stop,
             content_parts: [],
             usage: %{},
             raw: %{}
           }}
      end
    end
  end

  defmodule TerminalFreeFormThenSubmitAdapter do
    @behaviour Arbor.LLM.ProviderAdapter
    def provider, do: "llm_auth_terminal_correction"

    def complete(%Request{} = request, opts) do
      parent = Keyword.get(opts, :parent) || Map.get(request.provider_options || %{}, :parent)

      correction? =
        Enum.any?(request.messages, &(&1.role == :user and &1.content =~ "terminal tool"))

      if is_pid(parent) do
        kind = if(correction?, do: :terminal_correction, else: :free_form)
        send(parent, {:client_complete, kind})
      end

      if correction? do
        {:ok,
         %Response{
           text: "",
           finish_reason: :tool_calls,
           content_parts: [
             ContentPart.tool_call("t1", "submit_report", %{
               "vote" => "approve",
               "finding_updates" => [],
               "new_findings" => []
             })
           ],
           usage: %{},
           raw: %{}
         }}
      else
        {:ok,
         %Response{
           text: ~s({"vote":"approve"}),
           finish_reason: :stop,
           content_parts: [ContentPart.text(~s({"vote":"approve"}))],
           usage: %{},
           raw: %{}
         }}
      end
    end
  end

  defmodule EchoTools do
    def execute("echo_tool", args, _workdir, opts) do
      send(self(), {:tool_execution, "echo_tool", args, opts})
      {:ok, "echoed"}
    end

    def execute("submit_report", args, _workdir, _opts), do: {:ok, args}
    def execute(name, _args, _workdir, _opts), do: {:error, "unknown #{name}"}
  end

  defp client(adapter) do
    Client.new(default_provider: adapter.provider())
    |> Client.register_adapter(adapter)
  end

  defp request(provider) do
    %Request{
      provider: provider,
      model: "test",
      messages: [Message.new(:user, "test prompt")],
      provider_options: %{parent: self()}
    }
  end

  defp tools do
    [
      %{
        "type" => "function",
        "function" => %{
          "name" => "echo_tool",
          "description" => "echo",
          "parameters" => %{"type" => "object", "properties" => %{}}
        }
      }
    ]
  end

  defp terminal_tools do
    [
      %{
        "type" => "function",
        "function" => %{
          "name" => "submit_report",
          "description" => "submit",
          "parameters" => %{"type" => "object", "properties" => %{}}
        }
      }
    ]
  end

  defp allow_authorizer(parent \\ self()) do
    fn %Request{} = req ->
      send(parent, {:authorize, req.provider, req.model, length(req.messages), req.tools})
      :allow
    end
  end

  defp collect_authorizes(timeout \\ 50) do
    receive do
      {:authorize, _, _, _, _} = msg ->
        [msg | collect_authorizes(timeout)]
    after
      timeout -> []
    end
  end

  defp collect_client_completes(timeout \\ 50) do
    receive do
      {:client_complete, _, _} = msg ->
        [msg | collect_client_completes(timeout)]

      {:client_complete, _} = msg ->
        [msg | collect_client_completes(timeout)]
    after
      timeout -> []
    end
  end

  test "security regression VOICE-17: absent llm_call_authorizer preserves current behavior" do
    assert {:ok, result} =
             ToolLoop.run(client(CountingAdapter), request("llm_auth_counting"),
               tools: tools(),
               tool_executor: EchoTools,
               max_turns: 3,
               parent: self()
             )

    assert result.content == "done"
    assert_receive {:client_complete, _, _}
    assert_receive {:client_complete, _, _}
    refute_received {:authorize, _, _, _, _}
  end

  test "security regression VOICE-17: one authorization per ordinary external attempt" do
    assert {:ok, result} =
             ToolLoop.run(client(CountingAdapter), request("llm_auth_counting"),
               tools: tools(),
               tool_executor: EchoTools,
               max_turns: 3,
               parent: self(),
               llm_call_authorizer: allow_authorizer()
             )

    assert result.content == "done"
    authorizes = collect_authorizes()
    completes = collect_client_completes()
    assert length(authorizes) == 2
    assert length(completes) == 2
  end

  test "security regression VOICE-17: stream-not-supported fallback reauthorizes separately" do
    counter = :atomics.new(1, [])

    authorizer = fn %Request{} = req ->
      n = :atomics.add_get(counter, 1, 1)
      send(self(), {:authorize, n, req.provider})
      :allow
    end

    assert {:ok, result} =
             ToolLoop.run(
               client(StreamUnsupportedAdapter),
               request("llm_auth_stream_unsupported"),
               tools: [],
               tool_executor: EchoTools,
               max_turns: 1,
               parent: self(),
               stream_callback: fn _event -> :ok end,
               llm_call_authorizer: authorizer
             )

    assert result.content == "stream-fallback-ok"
    # First authorize admits the streaming attempt; second admits fallback complete.
    assert_receive {:authorize, 1, "llm_auth_stream_unsupported"}
    assert_receive {:client_complete_streaming, stream_keys}
    refute :llm_call_authorizer in stream_keys
    assert_receive {:authorize, 2, "llm_auth_stream_unsupported"}
    assert_receive {:client_complete, :fallback, complete_keys}
    refute :llm_call_authorizer in complete_keys
    refute_received {:client_complete, _, _}
    refute_received {:client_complete_streaming, _}
  end

  test "security regression VOICE-17: second stream-fallback authorize deny blocks complete" do
    counter = :atomics.new(1, [])

    authorizer = fn %Request{} ->
      n = :atomics.add_get(counter, 1, 1)
      send(self(), {:authorize, n})
      if n == 1, do: :allow, else: :deny
    end

    assert {:error, {:llm_call_authorization_failed, :denied}} =
             ToolLoop.run(
               client(StreamUnsupportedAdapter),
               request("llm_auth_stream_unsupported"),
               tools: [],
               max_turns: 1,
               parent: self(),
               stream_callback: fn _ -> :ok end,
               llm_call_authorizer: authorizer
             )

    assert_receive {:authorize, 1}
    # Streaming attempt was admitted and observed; fallback complete must not run.
    assert_receive {:client_complete_streaming, stream_keys}
    refute :llm_call_authorizer in stream_keys
    assert_receive {:authorize, 2}
    refute_received {:client_complete, _, _}
    refute_received {:client_complete, _}
  end

  test "security regression VOICE-17: max-turn wrap-up is authorized independently" do
    authorizer = fn %Request{} = req ->
      kind = if req.tools in [nil, []], do: :wrap_up, else: :ordinary
      send(self(), {:authorize, kind})
      :allow
    end

    assert {:ok, result} =
             ToolLoop.run(client(MaxTurnsAdapter), request("llm_auth_max_turns"),
               tools: tools(),
               tool_executor: EchoTools,
               max_turns: 1,
               parent: self(),
               llm_call_authorizer: authorizer
             )

    assert result.finish_reason == :max_turns
    assert result.content =~ "wrap-up"
    assert_receive {:authorize, :ordinary}
    assert_receive {:authorize, :wrap_up}
    assert_receive {:client_complete, :ordinary, _}
    assert_receive {:client_complete, :wrap_up, _}
  end

  test "security regression VOICE-17: empty-final retry is authorized per attempt" do
    authorizer = fn %Request{} = req ->
      kind =
        cond do
          req.tools in [nil, []] -> :empty_final_retry
          Enum.any?(req.messages, &(&1.role == :tool)) -> :empty_after_tool
          true -> :tool_round
        end

      send(self(), {:authorize, kind})
      :allow
    end

    assert {:ok, result} =
             ToolLoop.run(client(EmptyFinalAdapter), request("llm_auth_empty_final"),
               tools: tools(),
               tool_executor: EchoTools,
               max_turns: 5,
               parent: self(),
               llm_call_authorizer: authorizer
             )

    assert result.content == "forced final"
    assert_receive {:authorize, :tool_round}
    assert_receive {:authorize, :empty_after_tool}
    assert_receive {:authorize, :empty_final_retry}
    assert_receive {:client_complete, :tool_round}
    assert_receive {:client_complete, :empty_after_tool}
    assert_receive {:client_complete, :empty_final_retry}
  end

  test "security regression VOICE-17: terminal correction path is authorized per attempt" do
    authorizer = fn %Request{} = req ->
      correction? =
        Enum.any?(req.messages, &(&1.role == :user and &1.content =~ "terminal tool"))

      send(self(), {:authorize, if(correction?, do: :terminal_correction, else: :free_form)})
      :allow
    end

    assert {:ok, result} =
             ToolLoop.run(
               client(TerminalFreeFormThenSubmitAdapter),
               request("llm_auth_terminal_correction"),
               tools: terminal_tools(),
               tool_executor: EchoTools,
               terminal_tools: ["submit_report"],
               max_turns: 3,
               parent: self(),
               llm_call_authorizer: authorizer
             )

    assert result.finish_reason == :stop
    assert_receive {:authorize, :free_form}
    assert_receive {:authorize, :terminal_correction}
    assert_receive {:client_complete, :free_form}
    assert_receive {:client_complete, :terminal_correction}
  end

  test "security regression VOICE-17: present faulting authorizers fail closed with zero client calls" do
    cases = [
      {nil, :invalid_llm_call_authorizer},
      {:not_a_fun, :invalid_llm_call_authorizer},
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
      assert {:error, {:llm_call_authorization_failed, ^reason}} =
               ToolLoop.run(client(CountingAdapter), request("llm_auth_counting"),
                 tools: tools(),
                 tool_executor: EchoTools,
                 max_turns: 2,
                 parent: self(),
                 llm_call_authorizer: authorizer
               )

      refute_received {:client_complete, _, _}
      refute_received {:client_complete_streaming, _}
      refute_received {:tool_execution, _, _, _}
    end)
  end

  test "security regression VOICE-17: authorizer is stripped from client opts" do
    authorizer = fn %Request{} ->
      :allow
    end

    assert {:ok, _} =
             ToolLoop.run(client(CountingAdapter), request("llm_auth_counting"),
               tools: tools(),
               tool_executor: EchoTools,
               max_turns: 3,
               parent: self(),
               llm_call_authorizer: authorizer
             )

    assert_receive {:client_complete, _, keys1}
    assert_receive {:client_complete, _, keys2}
    refute :llm_call_authorizer in keys1
    refute :llm_call_authorizer in keys2
  end
end
