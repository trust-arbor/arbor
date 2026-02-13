defmodule Arbor.Orchestrator.UnifiedLLM.ToolLoopTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.UnifiedLLM.{
    Client,
    CodingTools,
    ContentPart,
    Message,
    Request,
    Response,
    ToolLoop
  }

  @moduletag :fast

  # --- Mock tool executor ---

  defmodule MockTools do
    def execute("read_file", %{"path" => path}, workdir) do
      full = Path.join(workdir, path)

      case File.read(full) do
        {:ok, content} -> {:ok, content}
        {:error, reason} -> {:error, "Cannot read: #{reason}"}
      end
    end

    def execute("write_file", %{"path" => path, "content" => content}, workdir) do
      full = Path.join(workdir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
      {:ok, "Wrote #{byte_size(content)} bytes"}
    end

    def execute("shell_exec", %{"command" => cmd}, workdir) do
      {output, _} = System.cmd("sh", ["-c", cmd], cd: workdir, stderr_to_stdout: true)
      {:ok, output}
    end

    def execute(name, _args, _workdir), do: {:error, "Unknown: #{name}"}
  end

  # --- Mock adapter ---

  defmodule LoopAdapter do
    @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter
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
    @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter
    def provider, do: "multi_tool_test"

    def complete(%Request{} = request, _opts) do
      tool_msgs = Enum.filter(request.messages, &(&1.role == :tool))

      cond do
        # First call: write a file
        length(tool_msgs) == 0 ->
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
    @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter
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
    @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter
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

      assert result.text == "File contains: world"
      assert result.turns == 2
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

      assert result.text == "Verified: hello world"
      assert result.turns == 3

      # Verify file was actually written
      assert File.read!(Path.join(tmp_dir, "output.txt")) == "hello world"
    end

    @tag :tmp_dir
    test "max_turns prevents infinite loops", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "x.txt"), "data")

      client = build_client(MaxTurnsAdapter)

      {:error, {:max_turns_reached, 3, _usage}} =
        ToolLoop.run(client, request("max_turns_test"),
          workdir: tmp_dir,
          max_turns: 3,
          tool_executor: MockTools
        )
    end

    test "no tool calls returns immediately" do
      client = build_client(NoToolsAdapter)

      {:ok, result} = ToolLoop.run(client, request("no_tools_test"))

      assert result.text == "Direct answer"
      assert result.turns == 1
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

  describe "CodingTools.definitions/0" do
    test "returns 5 tool definitions" do
      defs = CodingTools.definitions()
      assert length(defs) == 5
      names = Enum.map(defs, & &1["function"]["name"])
      assert "read_file" in names
      assert "write_file" in names
      assert "list_files" in names
      assert "search_content" in names
      assert "shell_exec" in names
    end

    test "all definitions have required OpenAI schema fields" do
      for tool <- CodingTools.definitions() do
        assert tool["type"] == "function"
        assert is_map(tool["function"])
        assert is_binary(tool["function"]["name"])
        assert is_binary(tool["function"]["description"])
        assert is_map(tool["function"]["parameters"])
      end
    end
  end

  describe "CodingTools.execute/3" do
    @tag :tmp_dir
    test "read_file reads a file", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test.txt"), "content here")

      assert {:ok, "content here"} =
               CodingTools.execute("read_file", %{"path" => "test.txt"}, tmp_dir)
    end

    @tag :tmp_dir
    test "read_file returns error for missing file", %{tmp_dir: tmp_dir} do
      assert {:error, msg} = CodingTools.execute("read_file", %{"path" => "nope.txt"}, tmp_dir)
      assert msg =~ "Cannot read"
    end

    @tag :tmp_dir
    test "write_file creates file and dirs", %{tmp_dir: tmp_dir} do
      assert {:ok, msg} =
               CodingTools.execute(
                 "write_file",
                 %{
                   "path" => "sub/dir/file.ex",
                   "content" => "defmodule Test, do: nil"
                 },
                 tmp_dir
               )

      assert msg =~ "Wrote"
      assert File.read!(Path.join(tmp_dir, "sub/dir/file.ex")) == "defmodule Test, do: nil"
    end

    @tag :tmp_dir
    test "list_files matches glob patterns", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      File.write!(Path.join(tmp_dir, "lib/a.ex"), "")
      File.write!(Path.join(tmp_dir, "lib/b.ex"), "")
      File.write!(Path.join(tmp_dir, "mix.exs"), "")

      {:ok, result} = CodingTools.execute("list_files", %{"pattern" => "lib/*.ex"}, tmp_dir)
      assert result =~ "lib/a.ex"
      assert result =~ "lib/b.ex"
      refute result =~ "mix.exs"
    end

    @tag :tmp_dir
    test "search_content finds matching lines", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "code.ex"), "defmodule Foo do\n  def bar, do: :ok\nend\n")

      {:ok, result} =
        CodingTools.execute(
          "search_content",
          %{
            "pattern" => "defmodule"
          },
          tmp_dir
        )

      assert result =~ "code.ex:1:"
      assert result =~ "defmodule Foo"
    end

    @tag :tmp_dir
    test "shell_exec runs commands", %{tmp_dir: tmp_dir} do
      {:ok, result} = CodingTools.execute("shell_exec", %{"command" => "echo hello"}, tmp_dir)
      assert String.trim(result) == "hello"
    end

    test "unknown tool returns error" do
      assert {:error, "Unknown tool: nope"} = CodingTools.execute("nope", %{}, ".")
    end
  end
end
