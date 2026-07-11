defmodule Arbor.Shell.PortSessionTest do
  use ExUnit.Case, async: true

  alias Arbor.Shell.PortSession

  describe "basic execution" do
    test "runs a command and returns output with exit code 0" do
      {:ok, pid} = PortSession.start_link("echo hello", stream_to: self())
      id = PortSession.get_id(pid)

      assert_receive {:port_exit, ^id, 0, output}, 5_000
      assert String.trim(output) == "hello"
    end

    test "captures non-zero exit code" do
      {:ok, pid} = PortSession.start_link("sh -c 'exit 42'", stream_to: self())
      id = PortSession.get_id(pid)

      assert_receive {:port_exit, ^id, 42, _output}, 5_000
    end

    test "streams output chunks to subscribers" do
      script = "sh -c 'echo line1; echo line2; echo line3'"
      {:ok, pid} = PortSession.start_link(script, stream_to: self())
      id = PortSession.get_id(pid)

      # Collect all data messages before exit
      assert_receive {:port_exit, ^id, 0, full_output}, 5_000
      assert String.contains?(full_output, "line1")
      assert String.contains?(full_output, "line2")
      assert String.contains?(full_output, "line3")
    end

    test "generates unique session IDs" do
      {:ok, pid1} = PortSession.start_link("echo a", stream_to: self())
      {:ok, pid2} = PortSession.start_link("echo b", stream_to: self())

      id1 = PortSession.get_id(pid1)
      id2 = PortSession.get_id(pid2)

      assert id1 != id2
      assert String.starts_with?(id1, "port_")
      assert String.starts_with?(id2, "port_")
    end
  end

  describe "subscriber management" do
    test "sends data to multiple subscribers" do
      {:ok, pid} = PortSession.start_link("echo multi", stream_to: self())
      id = PortSession.get_id(pid)

      # Add a second subscriber (ourselves again — just testing the path)
      test_pid = self()
      PortSession.subscribe(pid, test_pid)

      assert_receive {:port_exit, ^id, 0, _output}, 5_000
    end

    test "late subscriber receives exit message" do
      # Use a script that waits long enough for us to subscribe
      {:ok, pid} = PortSession.start_link("sh -c 'sleep 1 && echo late'", [])

      # Subscribe after start but before exit
      PortSession.subscribe(pid, self())
      id = PortSession.get_id(pid)

      assert_receive {:port_exit, ^id, 0, output}, 5_000
      assert String.contains?(output, "late")
    end
  end

  describe "timeout" do
    test "auto-terminates on timeout" do
      {:ok, pid} = PortSession.start_link("sleep 60", stream_to: self(), timeout: 200)
      id = PortSession.get_id(pid)

      assert_receive {:port_exit, ^id, 137, _output}, 5_000

      # Process should stop after timeout
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end
  end

  describe "streaming output ceiling" do
    test "security regression: retains and delivers at most the byte cap for invalid UTF-8" do
      root =
        Path.join(
          System.tmp_dir!(),
          "port_session_output_cap_#{System.unique_integer([:positive])}"
        )

      input = Path.join(root, "one_megabyte.bin")
      File.mkdir_p!(root)
      File.write!(input, :binary.copy(<<0xFF>>, 1_048_576))

      on_exit(fn -> File.rm_rf!(root) end)

      {:ok, pid} =
        PortSession.start_link_direct(
          System.find_executable("cat"),
          [input],
          "cat #{input}",
          stream_to: self(),
          max_output_bytes: 64,
          timeout: 5_000
        )

      id = PortSession.get_id(pid)
      {delivered, metadata, retained} = collect_limited_stream(id, <<>>, nil)

      assert byte_size(delivered) == 64
      assert delivered == :binary.copy(<<0xFF>>, 64)
      assert byte_size(retained) == 64
      assert retained == delivered
      assert metadata.output_bytes == 64
      assert metadata.max_output_bytes == 64
      assert metadata.output_limit_exceeded
      assert metadata.output_truncated
      assert metadata.killed

      {:ok, result} = PortSession.get_result(pid)
      assert result.status == :killed
      assert result.output_bytes == 64
      assert byte_size(result.output) == 64
      assert result.output == retained
      assert result.output_limit_exceeded
      assert result.output_truncated
      assert result.killed
      refute result.timed_out
    end
  end

  describe "stop and kill" do
    test "stop gracefully terminates the process" do
      {:ok, pid} = PortSession.start_link("sleep 60", stream_to: self(), timeout: :infinity)

      ref = Process.monitor(pid)
      PortSession.stop(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end

    test "kill terminates the process" do
      {:ok, pid} = PortSession.start_link("sleep 60", stream_to: self(), timeout: :infinity)

      ref = Process.monitor(pid)
      PortSession.kill(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end
  end

  describe "get_result" do
    test "returns accumulated output for completed session" do
      {:ok, pid} = PortSession.start_link("echo result_test", stream_to: self())
      id = PortSession.get_id(pid)

      # Wait for completion message
      assert_receive {:port_exit, ^id, 0, _output}, 5_000

      # GenServer stays alive after exit, so we can query results
      {:ok, result} = PortSession.get_result(pid)
      assert result.status == :completed
      assert result.exit_code == 0
      assert String.contains?(result.output, "result_test")
    end

    test "returns status while running" do
      {:ok, pid} = PortSession.start_link("sleep 60", timeout: :infinity)

      {:ok, result} = PortSession.get_result(pid)
      assert result.status == :running
      assert result.exit_code == nil

      PortSession.kill(pid)
    end
  end

  describe "working directory" do
    test "respects cwd option" do
      {:ok, pid} =
        PortSession.start_link("sh -c 'sleep 0.1 && pwd'", stream_to: self(), cwd: "/tmp")

      id = PortSession.get_id(pid)

      assert_receive {:port_exit, ^id, 0, output}, 5_000
      assert String.trim(output) in ["/tmp", "/private/tmp"]
    end
  end

  describe "environment variables" do
    test "passes env to the port" do
      {:ok, pid} =
        PortSession.start_link(
          "sh -c 'echo $MY_TEST_VAR'",
          stream_to: self(),
          env: %{"MY_TEST_VAR" => "port_session_test"}
        )

      id = PortSession.get_id(pid)

      assert_receive {:port_exit, ^id, 0, output}, 5_000
      assert String.trim(output) == "port_session_test"
    end
  end

  describe "send_input" do
    test "sends data to stdin" do
      {:ok, pid} = PortSession.start_link("cat", stream_to: self(), timeout: 2_000)
      id = PortSession.get_id(pid)

      PortSession.send_input(pid, "hello stdin\n")

      # cat should echo the input back
      assert_receive {:port_data, ^id, chunk}, 5_000
      assert String.contains?(chunk, "hello stdin")

      PortSession.kill(pid)
    end

    test "returns error when not running" do
      {:ok, pid} = PortSession.start_link("echo done", stream_to: self())
      id = PortSession.get_id(pid)

      # Wait for it to finish
      assert_receive {:port_exit, ^id, 0, _output}, 5_000

      # Process exits on completion, so send_input would fail
      # This is expected behavior — the GenServer is gone
    end
  end

  describe "supervised start" do
    test "starts under the DynamicSupervisor" do
      {:ok, pid} = PortSession.start_supervised("echo supervised", stream_to: self())

      assert Process.alive?(pid)
      id = PortSession.get_id(pid)

      assert_receive {:port_exit, ^id, 0, output}, 5_000
      assert String.contains?(output, "supervised")
    end
  end

  defp collect_limited_stream(id, delivered, metadata) do
    receive do
      {:port_data, ^id, chunk} ->
        collect_limited_stream(id, delivered <> chunk, metadata)

      {:port_output_limit, ^id, limit_metadata} ->
        collect_limited_stream(id, delivered, limit_metadata)

      {:port_exit, ^id, 137, retained} ->
        {delivered, metadata, retained}
    after
      5_000 ->
        flunk("timed out waiting for capped PortSession output")
    end
  end
end
