defmodule Arbor.LLM.ToolLoopEgressAuthorizationSecurityRegressionTest do
  @moduledoc false
  # async: false — formal selector mutates Application pipeline config for ReqLLM proof.
  use ExUnit.Case, async: false

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
        send(parent, {:adapter_complete, :ordinary})
      end

      counting_response(request)
    end

    def complete_single_attempt(%Request{} = request, opts) do
      parent = Keyword.get(opts, :parent) || Map.get(request.provider_options || %{}, :parent)

      if is_pid(parent) do
        send(parent, {:client_complete, request.model, Keyword.keys(opts)})
        send(parent, {:adapter_complete, :single_attempt})
      end

      counting_response(request)
    end

    defp counting_response(%Request{} = request) do
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

  # Ordinary complete only — no single-attempt attestation.
  defmodule UnsupportedSingleAttemptAdapter do
    @behaviour Arbor.LLM.ProviderAdapter
    def provider, do: "llm_auth_unsupported_single"

    def complete(%Request{} = request, opts) do
      parent = Keyword.get(opts, :parent) || Map.get(request.provider_options || %{}, :parent)
      if is_pid(parent), do: send(parent, {:adapter_complete, :ordinary})

      {:ok,
       %Response{
         text: "should-not-run",
         finish_reason: :stop,
         content_parts: [ContentPart.text("should-not-run")],
         usage: %{},
         raw: %{}
       }}
    end
  end

  # True no/no streaming capability: neither ordinary nor attested streaming exports.
  # Client returns {:stream_not_supported, adapter}; ToolLoop reauthorizes non-stream.
  defmodule NoStreamCapabilityAdapter do
    @behaviour Arbor.LLM.ProviderAdapter
    def provider, do: "llm_auth_no_stream"

    def complete(%Request{} = request, opts) do
      parent = Keyword.get(opts, :parent) || Map.get(request.provider_options || %{}, :parent)

      if is_pid(parent) do
        send(parent, {:client_complete, :fallback, Keyword.keys(opts)})
        send(parent, {:adapter_complete, :ordinary})
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

    def complete_single_attempt(%Request{} = request, opts) do
      parent = Keyword.get(opts, :parent) || Map.get(request.provider_options || %{}, :parent)

      if is_pid(parent) do
        send(parent, {:client_complete, :fallback, Keyword.keys(opts)})
        send(parent, {:adapter_complete, :single_attempt})
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

  # Ordinary streaming exists without attested streaming — fail closed under authorizer.
  defmodule StreamOrdinaryOnlyAdapter do
    @behaviour Arbor.LLM.ProviderAdapter
    def provider, do: "llm_auth_stream_ordinary_only"

    def complete_streaming(%Request{} = request, _callback, opts) do
      parent = Keyword.get(opts, :parent) || Map.get(request.provider_options || %{}, :parent)
      if is_pid(parent), do: send(parent, {:client_complete_streaming, :ordinary})

      {:ok,
       %Response{
         text: "streamed",
         finish_reason: :stop,
         content_parts: [ContentPart.text("streamed")],
         usage: %{},
         raw: %{}
       }}
    end

    def complete(%Request{} = request, opts) do
      parent = Keyword.get(opts, :parent) || Map.get(request.provider_options || %{}, :parent)
      if is_pid(parent), do: send(parent, {:adapter_complete, :ordinary})

      {:ok,
       %Response{
         text: "complete",
         finish_reason: :stop,
         content_parts: [ContentPart.text("complete")],
         usage: %{},
         raw: %{}
       }}
    end

    def complete_single_attempt(%Request{} = request, opts), do: complete(request, opts)
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

    def complete_single_attempt(%Request{} = request, opts), do: complete(request, opts)
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

    def complete_single_attempt(%Request{} = request, opts), do: complete(request, opts)
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

    def complete_single_attempt(%Request{} = request, opts), do: complete(request, opts)
  end

  # Counts single-attempt entries; used with middleware that multi-invokes continuation.
  # Counter lives in Application env so ToolLoop opts need not carry it.
  defmodule GatedSingleAttemptAdapter do
    @behaviour Arbor.LLM.ProviderAdapter
    def provider, do: "llm_auth_gated"

    def complete(%Request{} = _request, _opts) do
      send(self(), {:adapter_complete, :ordinary})

      {:ok,
       %Response{
         text: "ordinary",
         finish_reason: :stop,
         content_parts: [ContentPart.text("ordinary")],
         usage: %{},
         raw: %{}
       }}
    end

    def complete_single_attempt(%Request{} = _request, _opts) do
      counter = Application.fetch_env!(:arbor_llm, :_test_gated_entry_counter)
      parent = Application.fetch_env!(:arbor_llm, :_test_gated_parent)
      n = :atomics.add_get(counter, 1, 1)
      send(parent, {:adapter_complete, :single_attempt, n})

      {:ok,
       %Response{
         text: "single",
         finish_reason: :stop,
         content_parts: [ContentPart.text("single")],
         usage: %{},
         raw: %{}
       }}
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

  test "security regression VOICE-17: no/no stream capability reauthorizes non-stream fallback" do
    counter = :atomics.new(1, [])

    authorizer = fn %Request{} = req ->
      n = :atomics.add_get(counter, 1, 1)
      send(self(), {:authorize, n, req.provider})
      :allow
    end

    # True no/no: adapter exports neither ordinary nor attested streaming.
    # Client returns {:stream_not_supported, adapter}; ToolLoop reauthorizes complete.
    assert {:ok, result} =
             ToolLoop.run(
               client(NoStreamCapabilityAdapter),
               request("llm_auth_no_stream"),
               tools: [],
               tool_executor: EchoTools,
               max_turns: 1,
               parent: self(),
               stream_callback: fn _event -> :ok end,
               llm_call_authorizer: authorizer
             )

    assert result.content == "stream-fallback-ok"
    # First authorize admits the streaming attempt (capability probe); second admits fallback.
    assert_receive {:authorize, 1, "llm_auth_no_stream"}
    assert_receive {:authorize, 2, "llm_auth_no_stream"}
    assert_receive {:client_complete, :fallback, complete_keys}
    refute :llm_call_authorizer in complete_keys
    assert_receive {:adapter_complete, :single_attempt}
    refute_received {:adapter_complete, :ordinary}
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
               client(NoStreamCapabilityAdapter),
               request("llm_auth_no_stream"),
               tools: [],
               max_turns: 1,
               parent: self(),
               stream_callback: fn _ -> :ok end,
               llm_call_authorizer: authorizer
             )

    assert_receive {:authorize, 1}
    # Streaming probe admitted; fallback complete must not run after deny.
    assert_receive {:authorize, 2}
    refute_received {:client_complete, _, _}
    refute_received {:client_complete, _}
    refute_received {:adapter_complete, _}
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

  test "security regression VOICE-17: authorizer present uses single-attempt adapter path" do
    assert {:ok, _} =
             ToolLoop.run(client(CountingAdapter), request("llm_auth_counting"),
               tools: tools(),
               tool_executor: EchoTools,
               max_turns: 3,
               parent: self(),
               llm_call_authorizer: allow_authorizer()
             )

    assert_receive {:adapter_complete, :single_attempt}
    assert_receive {:adapter_complete, :single_attempt}
    refute_received {:adapter_complete, :ordinary}
  end

  test "security regression VOICE-17: unsupported adapter fails before ordinary complete" do
    assert {:error, :single_attempt_not_supported} =
             ToolLoop.run(
               client(UnsupportedSingleAttemptAdapter),
               request("llm_auth_unsupported_single"),
               tools: [],
               max_turns: 1,
               parent: self(),
               llm_call_authorizer: allow_authorizer()
             )

    refute_received {:adapter_complete, :ordinary}
  end

  test "security regression VOICE-17: ToolLoop middleware sequential double-enter yields one adapter invoke" do
    counter = :atomics.new(1, [])
    parent = self()
    Application.put_env(:arbor_llm, :_test_gated_entry_counter, counter)
    Application.put_env(:arbor_llm, :_test_gated_parent, parent)

    on_exit(fn ->
      Application.delete_env(:arbor_llm, :_test_gated_entry_counter)
      Application.delete_env(:arbor_llm, :_test_gated_parent)
    end)

    middleware = fn req, next ->
      first = next.(req)
      second = next.(req)
      send(parent, {:middleware_results, first, second})
      first
    end

    client =
      client(GatedSingleAttemptAdapter)
      |> Map.put(:middleware, [middleware])

    assert {:ok, result} =
             ToolLoop.run(client, request("llm_auth_gated"),
               tools: [],
               max_turns: 1,
               llm_call_authorizer: allow_authorizer()
             )

    assert result.content == "single"
    assert_receive {:middleware_results, first, second}
    assert match?({:ok, %Response{text: "single"}}, first)
    assert second == {:error, :single_attempt_continuation_spent}
    assert :atomics.get(counter, 1) == 1
    assert_receive {:adapter_complete, :single_attempt, 1}
    refute_received {:adapter_complete, :single_attempt, 2}
  end

  test "security regression VOICE-17: ToolLoop middleware concurrent continuation yields one adapter invoke" do
    counter = :atomics.new(1, [])
    parent = self()
    Application.put_env(:arbor_llm, :_test_gated_entry_counter, counter)
    Application.put_env(:arbor_llm, :_test_gated_parent, parent)

    on_exit(fn ->
      Application.delete_env(:arbor_llm, :_test_gated_entry_counter)
      Application.delete_env(:arbor_llm, :_test_gated_parent)
    end)

    middleware = fn req, next ->
      task1 = Task.async(fn -> next.(req) end)
      task2 = Task.async(fn -> next.(req) end)
      r1 = Task.await(task1)
      r2 = Task.await(task2)
      send(parent, {:concurrent_results, r1, r2})

      case {r1, r2} do
        {{:ok, _} = ok, _} -> ok
        {_, {:ok, _} = ok} -> ok
        {other, _} -> other
      end
    end

    client =
      client(GatedSingleAttemptAdapter)
      |> Map.put(:middleware, [middleware])

    assert {:ok, _} =
             ToolLoop.run(client, request("llm_auth_gated"),
               tools: [],
               max_turns: 1,
               llm_call_authorizer: allow_authorizer()
             )

    assert_receive {:concurrent_results, r1, r2}
    results = [r1, r2]
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :single_attempt_continuation_spent})) == 1
    assert :atomics.get(counter, 1) == 1
  end

  test "security regression VOICE-17: ToolLoop late retained continuation cannot invoke adapter" do
    counter = :atomics.new(1, [])
    parent = self()
    Application.put_env(:arbor_llm, :_test_gated_entry_counter, counter)
    Application.put_env(:arbor_llm, :_test_gated_parent, parent)

    on_exit(fn ->
      Application.delete_env(:arbor_llm, :_test_gated_entry_counter)
      Application.delete_env(:arbor_llm, :_test_gated_parent)
    end)

    # Retain continuation via mailbox (not Process.put) for late post-return call.
    middleware = fn req, next ->
      send(parent, {:retained_continuation, next, req})
      next.(req)
    end

    client =
      client(GatedSingleAttemptAdapter)
      |> Map.put(:middleware, [middleware])

    assert {:ok, _} =
             ToolLoop.run(client, request("llm_auth_gated"),
               tools: [],
               max_turns: 1,
               llm_call_authorizer: allow_authorizer()
             )

    assert :atomics.get(counter, 1) == 1
    assert_receive {:retained_continuation, next, req}
    assert is_function(next, 1)
    assert next.(req) == {:error, :single_attempt_continuation_spent}
    assert :atomics.get(counter, 1) == 1
    refute_received {:adapter_complete, :single_attempt, 2}
  end

  test "security regression VOICE-17: ToolLoop timeout-kill retained continuation cannot invoke adapter" do
    counter = :atomics.new(1, [])
    parent = self()
    Application.put_env(:arbor_llm, :_test_gated_entry_counter, counter)
    Application.put_env(:arbor_llm, :_test_gated_parent, parent)

    on_exit(fn ->
      Application.delete_env(:arbor_llm, :_test_gated_entry_counter)
      Application.delete_env(:arbor_llm, :_test_gated_parent)
    end)

    timeout_ms = 50

    # Export continuation via mailbox, then park forever without claiming the gate.
    # Only the Deadline-owned worker may block past the short deadline; :kill ends it.
    middleware = fn req, next ->
      send(parent, {:retained_timeout_continuation, next, req})

      receive do
      after
        :infinity -> :ok
      end

      # Unreachable when Deadline kills the worker on timeout.
      next.(req)
    end

    client =
      client(GatedSingleAttemptAdapter)
      |> Map.put(:middleware, [middleware])

    # Run ToolLoop off the test process so mailbox handoff can be observed before
    # the timeout result returns, keeping the race deterministic under load.
    task =
      Task.async(fn ->
        ToolLoop.run(client, request("llm_auth_gated"),
          tools: [],
          max_turns: 1,
          timeout_ms: timeout_ms,
          receive_timeout: timeout_ms,
          llm_call_authorizer: allow_authorizer(parent)
        )
      end)

    assert_receive {:retained_timeout_continuation, next, req}, 1_000
    assert is_function(next, 1)

    assert {:error, %Arbor.LLM.RequestTimeoutError{}} = Task.await(task, 2_000)

    # After Deadline kills its worker, invoker-owned cleanup must close the gate so a
    # retained continuation cannot invoke the adapter.
    assert next.(req) == {:error, :single_attempt_continuation_spent}
    assert :atomics.get(counter, 1) == 0
    refute_received {:adapter_complete, :single_attempt, 1}
  end

  test "security regression VOICE-17: ordinary stream without attestation fails closed under authorizer" do
    assert {:error, :single_attempt_not_supported} =
             ToolLoop.run(
               client(StreamOrdinaryOnlyAdapter),
               request("llm_auth_stream_ordinary_only"),
               tools: [],
               max_turns: 1,
               parent: self(),
               stream_callback: fn _ -> :ok end,
               llm_call_authorizer: allow_authorizer()
             )

    refute_received {:client_complete_streaming, :ordinary}
    refute_received {:adapter_complete, :ordinary}
  end

  test "security regression VOICE-17: ToolLoop+ReqLLM+Dispatch single-attempt performs one request" do
    # Production path through public ToolLoop + authorizer + real Plugs.Dispatch
    # after real provider prepare. Network-free Req.Test.transport_error.
    # Must not substitute an intercept dispatch plug before provider attach.
    # Deadline performs the transport in its worker, so this non-async test must
    # expose its stub to that child process.
    Req.Test.set_req_test_to_shared()

    bypass_plug = {Req.Test, __MODULE__.ReqLLMSingleAttempt}

    previous_pipeline = Application.get_env(:arbor_llm, :pipeline)

    Application.put_env(:arbor_llm, :pipeline, [
      Arbor.LLM.Plugs.Dispatch,
      Arbor.LLM.Plugs.RateLimitBackoff
    ])

    on_exit(fn ->
      if previous_pipeline do
        Application.put_env(:arbor_llm, :pipeline, previous_pipeline)
      else
        Application.delete_env(:arbor_llm, :pipeline)
      end
    end)

    hits = :atomics.new(1, [])
    parent = self()

    Req.Test.stub(__MODULE__.ReqLLMSingleAttempt, fn conn ->
      :atomics.add_get(hits, 1, 1)
      send(parent, {:req_transport_hit, conn.method})
      Req.Test.transport_error(conn, :econnrefused)
    end)

    client =
      Client.new(
        adapters: %{"openai" => Arbor.LLM.Adapter.ReqLLM},
        default_provider: "openai"
      )

    req = %Request{
      provider: "openai",
      model: "gpt-4o-mini",
      messages: [Message.new(:user, "ping")],
      tools: []
    }

    assert {:error, _} =
             ToolLoop.run(client, req,
               tools: [],
               max_turns: 1,
               llm_call_authorizer: allow_authorizer(),
               api_key: "test-key-not-real",
               # Intentionally request retries; single-attempt post-prepare override must win.
               req_http_options: [plug: bypass_plug, retry: :transient, max_retries: 3]
             )

    assert :atomics.get(hits, 1) == 1
    assert_receive {:req_transport_hit, _}
    refute_received {:req_transport_hit, _}
  end
end
