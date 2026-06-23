defmodule Arbor.LLM.ToolLoopTest do
  use ExUnit.Case, async: true

  alias Arbor.LLM.Client

  alias Arbor.LLM.ContentPart

  alias Arbor.LLM.Message

  alias Arbor.LLM.Request

  alias Arbor.LLM.Response

  alias Arbor.LLM.ToolLoop
  @moduletag :fast

  # --- Mock tool executor ---

  defmodule MockTools do
    def execute(name, args, workdir, _opts \\ [])

    def execute("read_file", %{"path" => path}, workdir, _opts) do
      full = Path.join(workdir, path)

      case File.read(full) do
        {:ok, content} -> {:ok, content}
        {:error, reason} -> {:error, "Cannot read: #{reason}"}
      end
    end

    def execute("write_file", %{"path" => path, "content" => content}, workdir, _opts) do
      full = Path.join(workdir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
      {:ok, "Wrote #{byte_size(content)} bytes"}
    end

    def execute("shell_exec", %{"command" => cmd}, workdir, _opts) do
      {output, _} = System.cmd("sh", ["-c", cmd], cd: workdir, stderr_to_stdout: true)
      {:ok, output}
    end

    def execute(name, _args, _workdir, _opts), do: {:error, "Unknown: #{name}"}
  end

  # --- Mock adapter ---

  defmodule LoopAdapter do
    @behaviour Arbor.LLM.ProviderAdapter
    def provider, do: "loop_test"

    def complete(%Request{} = request, _opts) do
      # Read the conversation to determine what to return
      last_msg = List.last(request.messages)

      cond do
        # First call: ask to read a file
        last_msg.role == :user ->
          {:ok, tool_call_response("call_1", "read_file", %{"path" => "hello.txt"})}

        # After tool result: produce final answer
        last_msg.role == :tool ->
          {:ok,
           %Response{
             text: "File contains: #{last_msg.content}",
             finish_reason: :stop,
             content_parts: [ContentPart.text("File contains: #{last_msg.content}")],
             usage: %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15},
             raw: %{}
           }}

        true ->
          {:ok, %Response{text: "done", finish_reason: :stop, raw: %{}}}
      end
    end

    defp tool_call_response(id, name, args) do
      %Response{
        text: "",
        finish_reason: :tool_calls,
        content_parts: [ContentPart.tool_call(id, name, args)],
        usage: %{"prompt_tokens" => 5, "completion_tokens" => 3, "total_tokens" => 8},
        raw: %{}
      }
    end
  end

  defmodule MultiToolAdapter do
    @behaviour Arbor.LLM.ProviderAdapter
    def provider, do: "multi_tool_test"

    def complete(%Request{} = request, _opts) do
      tool_msgs = Enum.filter(request.messages, &(&1.role == :tool))

      cond do
        # First call: write a file
        tool_msgs == [] ->
          {:ok,
           tool_call_response("c1", "write_file", %{
             "path" => "output.txt",
             "content" => "hello world"
           })}

        # Second call: read it back
        length(tool_msgs) == 1 ->
          {:ok, tool_call_response("c2", "read_file", %{"path" => "output.txt"})}

        # Third: final answer
        true ->
          content = List.last(request.messages).content

          {:ok,
           %Response{
             text: "Verified: #{content}",
             finish_reason: :stop,
             content_parts: [ContentPart.text("Verified: #{content}")],
             usage: %{"prompt_tokens" => 5, "completion_tokens" => 5, "total_tokens" => 10},
             raw: %{}
           }}
      end
    end

    defp tool_call_response(id, name, args) do
      %Response{
        text: "",
        finish_reason: :tool_calls,
        content_parts: [ContentPart.tool_call(id, name, args)],
        usage: %{"prompt_tokens" => 3, "completion_tokens" => 3, "total_tokens" => 6},
        raw: %{}
      }
    end
  end

  defmodule MaxTurnsAdapter do
    @behaviour Arbor.LLM.ProviderAdapter
    def provider, do: "max_turns_test"

    def complete(_request, _opts) do
      {:ok,
       %Response{
         text: "",
         finish_reason: :tool_calls,
         content_parts: [ContentPart.tool_call("c", "read_file", %{"path" => "x.txt"})],
         usage: %{},
         raw: %{}
       }}
    end
  end

  defmodule NoToolsAdapter do
    @behaviour Arbor.LLM.ProviderAdapter
    def provider, do: "no_tools_test"

    def complete(_request, _opts) do
      {:ok,
       %Response{
         text: "Direct answer",
         finish_reason: :stop,
         content_parts: [ContentPart.text("Direct answer")],
         usage: %{"prompt_tokens" => 5, "completion_tokens" => 5, "total_tokens" => 10},
         raw: %{}
       }}
    end
  end

  # --- Helpers ---

  # Regression: newer ReqLLM usage carries `:cost` as a nested breakdown MAP
  # (not a number). Merging usage across tool rounds used to do `0 + cost_map`,
  # raising :badarith and aborting the loop → empty turns. This adapter returns
  # that shape on both rounds so the test exercises cost-map accumulation.
  defmodule CostMapAdapter do
    @behaviour Arbor.LLM.ProviderAdapter
    def provider, do: "cost_map_test"

    @cost %{total: 2.0e-6, input_cost: 1.0e-6, line_items: [%{count: 13, cost: 2.0e-6}]}

    def complete(%Request{} = request, _opts) do
      case List.last(request.messages).role do
        :user ->
          {:ok,
           %Response{
             text: "",
             finish_reason: :tool_calls,
             content_parts: [ContentPart.tool_call("c1", "read_file", %{"path" => "hello.txt"})],
             usage: %{
               "prompt_tokens" => 5,
               "completion_tokens" => 3,
               "total_tokens" => 8,
               cost: @cost
             },
             raw: %{}
           }}

        :tool ->
          {:ok,
           %Response{
             text: "ok",
             finish_reason: :stop,
             content_parts: [ContentPart.text("ok")],
             usage: %{
               "prompt_tokens" => 10,
               "completion_tokens" => 5,
               "total_tokens" => 15,
               cost: @cost
             },
             raw: %{}
           }}

        _ ->
          {:ok, %Response{text: "done", finish_reason: :stop, raw: %{}}}
      end
    end
  end

  # Regression: some providers finish a tool round with finish_reason=:stop but
  # EMPTY text (no further tool calls), which surfaced as an empty turn. ToolLoop
  # should retry text-only (tools stripped) to force a final answer. This adapter
  # returns empty after the tool round, then answers once tools are gone.
  defmodule EmptyAfterToolAdapter do
    @behaviour Arbor.LLM.ProviderAdapter
    def provider, do: "empty_after_tool_test"

    # Text-only retry (ToolLoop stripped tools) → produce the answer.
    def complete(%Request{tools: tools}, _opts) when tools in [nil, []] do
      {:ok,
       %Response{
         text: "Final answer",
         finish_reason: :stop,
         content_parts: [ContentPart.text("Final answer")],
         usage: %{"prompt_tokens" => 2, "completion_tokens" => 2, "total_tokens" => 4},
         raw: %{}
       }}
    end

    def complete(%Request{} = request, _opts) do
      case List.last(request.messages).role do
        :user ->
          {:ok,
           %Response{
             text: "",
             finish_reason: :tool_calls,
             content_parts: [ContentPart.tool_call("c1", "read_file", %{"path" => "hello.txt"})],
             usage: %{"prompt_tokens" => 5, "completion_tokens" => 3, "total_tokens" => 8},
             raw: %{}
           }}

        :tool ->
          # The bug condition: finished with empty text after the tool round.
          {:ok,
           %Response{
             text: "",
             finish_reason: :stop,
             content_parts: [],
             usage: %{"prompt_tokens" => 4, "completion_tokens" => 0, "total_tokens" => 4},
             raw: %{}
           }}

        _ ->
          {:ok, %Response{text: "done", finish_reason: :stop, raw: %{}}}
      end
    end
  end

  # Exercises the STREAMING tool-loop path (stream_callback set → ToolLoop uses
  # Client.complete_streaming). Regression for: streamed tool calls used to lose
  # their ARGUMENTS (and earlier their name). complete_streaming must fire the
  # delta callback AND return a tool call with full args so the tool executes.
  defmodule StreamAdapter do
    @behaviour Arbor.LLM.ProviderAdapter
    def provider, do: "stream_test"

    def complete(%Request{} = request, _opts) do
      case List.last(request.messages).role do
        :tool ->
          {:ok,
           %Response{
             text: "File contains: #{List.last(request.messages).content}",
             finish_reason: :stop,
             content_parts: [
               ContentPart.text("File contains: #{List.last(request.messages).content}")
             ],
             usage: %{},
             raw: %{}
           }}

        _ ->
          {:ok,
           %Response{
             text: "",
             finish_reason: :tool_calls,
             content_parts: [ContentPart.tool_call("c1", "read_file", %{"path" => "hello.txt"})],
             usage: %{},
             raw: %{}
           }}
      end
    end

    # The real adapter assembles full args here (process_stream); the fake just
    # reuses complete/2 so the returned tool call carries its arguments.
    def complete_streaming(%Request{} = request, callback, _opts) do
      callback.(%Arbor.LLM.StreamEvent{type: :delta, data: %{text: "streaming…"}})
      complete(request, [])
    end
  end

  defp build_client(adapter) do
    Client.new(default_provider: adapter.provider())
    |> Client.register_adapter(adapter)
  end

  defp request(provider) do
    %Request{
      provider: provider,
      model: "test",
      messages: [Message.new(:user, "test prompt")]
    }
  end

  # --- Tests ---

  describe "ToolLoop.run/3" do
    @tag :tmp_dir
    test "single tool call round trip", %{tmp_dir: tmp_dir} do
      # Create the file the mock will try to read
      File.write!(Path.join(tmp_dir, "hello.txt"), "world")

      client = build_client(LoopAdapter)

      {:ok, result} =
        ToolLoop.run(client, request("loop_test"),
          workdir: tmp_dir,
          tool_executor: MockTools
        )

      # Tool results are wrapped in <data_NONCE> tags for prompt injection defense.
      # The mock adapter echoes content verbatim, so tags appear in output.
      assert result.content =~ ~r/File contains: <data_[0-9a-f]{16}>world<\/data_[0-9a-f]{16}>/
      assert result.tool_rounds == 2
      assert result.finish_reason == :stop
    end

    @tag :tmp_dir
    test "multi-turn write then read", %{tmp_dir: tmp_dir} do
      client = build_client(MultiToolAdapter)

      {:ok, result} =
        ToolLoop.run(client, request("multi_tool_test"),
          workdir: tmp_dir,
          tool_executor: MockTools
        )

      # Tool results are wrapped in <data_NONCE> tags for prompt injection defense.
      assert result.content =~ ~r/Verified: <data_[0-9a-f]{16}>hello world<\/data_[0-9a-f]{16}>/
      assert result.tool_rounds == 3

      # Verify file was actually written
      assert File.read!(Path.join(tmp_dir, "output.txt")) == "hello world"
    end

    @tag :tmp_dir
    test "max_turns prevents infinite loops", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "x.txt"), "data")

      client = build_client(MaxTurnsAdapter)

      {:ok, result} =
        ToolLoop.run(client, request("max_turns_test"),
          workdir: tmp_dir,
          max_turns: 3,
          tool_executor: MockTools
        )

      assert result.finish_reason == :max_turns
    end

    test "no tool calls returns immediately" do
      client = build_client(NoToolsAdapter)

      {:ok, result} = ToolLoop.run(client, request("no_tools_test"))

      assert result.content == "Direct answer"
      assert result.tool_rounds == 1
    end

    @tag :tmp_dir
    test "accumulates usage across turns", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "hello.txt"), "data")

      client = build_client(LoopAdapter)

      {:ok, result} =
        ToolLoop.run(client, request("loop_test"),
          workdir: tmp_dir,
          tool_executor: MockTools
        )

      # LoopAdapter returns 8 tokens turn 1, 15 tokens turn 2
      assert result.usage.total_tokens == 23
    end

    @tag :tmp_dir
    test "merges usage when :cost is a nested map (regression: :badarith on 0 + cost_map)",
         %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "hello.txt"), "data")

      client = build_client(CostMapAdapter)

      # Pre-fix, merge_usage_maps did `0 + cost_map` and raised ArithmeticError
      # here, aborting the loop and surfacing as an empty turn. The {:ok, _} match
      # alone is the regression assertion (no crash).
      {:ok, result} =
        ToolLoop.run(client, request("cost_map_test"),
          workdir: tmp_dir,
          tool_executor: MockTools
        )

      assert result.content =~ "ok"
      assert result.tool_rounds == 2
      # Token totals still accumulate (8 + 15) and the cost MAP merged
      # structurally across both rounds rather than crashing.
      assert result.usage.total_tokens == 23
      assert is_map(result.usage.cost)
      assert result.usage.cost.total > 2.0e-6
    end

    @tag :tmp_dir
    test "retries text-only when the model finishes empty after a tool round (regression)",
         %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "hello.txt"), "data")

      client = build_client(EmptyAfterToolAdapter)

      {:ok, result} =
        ToolLoop.run(client, request("empty_after_tool_test"),
          workdir: tmp_dir,
          tool_executor: MockTools
        )

      # Pre-fix: content was "" (empty turn — the model finished with no text
      # after the tool round). The tools-stripped retry now forces a text answer.
      assert result.content == "Final answer"
    end

    @tag :tmp_dir
    test "streaming path (complete_streaming) preserves tool args + fires deltas (regression)",
         %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "hello.txt"), "world")

      client = build_client(StreamAdapter)
      test_pid = self()

      {:ok, result} =
        ToolLoop.run(client, request("stream_test"),
          workdir: tmp_dir,
          tool_executor: MockTools,
          stream_callback: fn ev -> send(test_pid, {:delta, ev}) end
        )

      # The delta callback fired (real-time streaming preserved).
      assert_received {:delta, %Arbor.LLM.StreamEvent{type: :delta}}

      # The tool executed with its "path" argument (read hello.txt → "world").
      # An empty-arg tool call — the bug — would have read nothing.
      assert result.content =~ ~r/File contains: <data_[0-9a-f]+>world<\/data_[0-9a-f]+>/
      assert result.tool_rounds == 2
    end

    @tag :tmp_dir
    test "on_tool_call callback fires", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "hello.txt"), "data")

      test_pid = self()
      client = build_client(LoopAdapter)

      {:ok, _result} =
        ToolLoop.run(client, request("loop_test"),
          workdir: tmp_dir,
          tool_executor: MockTools,
          on_tool_call: fn name, args, result ->
            send(test_pid, {:tool_called, name, args, result})
          end
        )

      assert_received {:tool_called, "read_file", %{"path" => "hello.txt"}, {:ok, "data"}}
    end
  end
end
