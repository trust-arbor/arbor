defmodule Arbor.Comms.Channels.SignalTest do
  use ExUnit.Case, async: false

  alias Arbor.Comms.Channels.Signal

  describe "channel_info/0" do
    test "returns signal channel metadata" do
      info = Signal.channel_info()
      assert info.name == :signal
      assert info.max_message_length == 2000
      assert info.supports_media == true
      assert info.supports_threads == false
      assert info.latency == :polling
    end
  end

  describe "format_for_channel/1" do
    test "trims whitespace" do
      assert Signal.format_for_channel("  hello  ") == "hello"
    end

    test "truncates long messages" do
      long = String.duplicate("a", 3000)
      result = Signal.format_for_channel(long)
      assert String.length(result) == 2000
      assert String.ends_with?(result, "...")
    end

    test "preserves short messages" do
      assert Signal.format_for_channel("hello") == "hello"
    end

    test "handles empty string" do
      assert Signal.format_for_channel("") == ""
    end
  end

  describe "poll/0" do
    @describetag :external
    test "polls signal-cli for messages" do
      result = Signal.poll()
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "send_message/3" do
    @describetag :external
    test "sends a message via signal-cli" do
      result = Signal.send_message("+1234567890", "Test", [])
      # Will fail without signal-cli, just verify the call works
      assert match?({:error, _}, result) or result == :ok
    end
  end

  # Regression coverage for the signal-cli temp-dir leak: signal-cli (a JVM tool)
  # extracts its ~24 MB native libsignal library to java.io.tmpdir on every
  # invocation and never cleans it up, which leaked tens of GB of stale
  # `libsignal*` directories into $TMPDIR. run_signal_cli/1 now isolates each
  # invocation in its own temp dir and removes it afterward.
  describe "run_signal_cli temp-dir isolation" do
    setup do
      # run_signal_cli/1 goes through Arbor.Shell, whose children aren't started
      # in the arbor_comms test env. Start them idempotently so the fake CLI runs.
      {:ok, _} = Application.ensure_all_started(:arbor_shell)

      for child <- [
            {Arbor.Shell.ExecutionRegistry, []},
            {DynamicSupervisor, name: Arbor.Shell.PortSessionSupervisor, strategy: :one_for_one}
          ] do
        case Supervisor.start_child(Arbor.Shell.Supervisor, child) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          {:error, :already_present} -> :ok
        end
      end

      # A fake signal-cli that records the TMPDIR it was handed and simulates the
      # native-library extraction, so we can assert redirection + cleanup without
      # depending on a real signal-cli install.
      work_dir =
        Path.join(System.tmp_dir!(), "arbor-signal-test-#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(work_dir)
      capture_file = Path.join(work_dir, "captured_tmpdir")
      fake_cli = Path.join(work_dir, "fake-signal-cli")

      File.write!(fake_cli, """
      #!/bin/sh
      printf '%s' "$TMPDIR" > "#{capture_file}"
      mkdir -p "$TMPDIR"
      printf 'dummy' > "$TMPDIR/libsignal_jni_test.dylib"
      exit 0
      """)

      File.chmod!(fake_cli, 0o755)

      prev = Application.get_env(:arbor_comms, :signal)

      Application.put_env(:arbor_comms, :signal,
        account: "+10000000000",
        signal_cli_path: fake_cli
      )

      on_exit(fn ->
        if prev,
          do: Application.put_env(:arbor_comms, :signal, prev),
          else: Application.delete_env(:arbor_comms, :signal)

        File.rm_rf(work_dir)
      end)

      %{capture_file: capture_file}
    end

    test "redirects signal-cli's TMPDIR into a private dir and removes it after the call",
         %{capture_file: capture_file} do
      assert :ok = Signal.send_message("+14432236605", "hello", [])

      captured = capture_file |> File.read!() |> String.trim()

      # signal-cli was pointed at an isolated, arbor-managed temp dir...
      assert String.starts_with?(captured, Path.join(System.tmp_dir!(), "arbor-signal-cli-"))

      # ...and that dir (with its simulated extraction) is gone afterward.
      refute File.exists?(captured)
    end

    test "leaves no arbor-signal-cli-* directories behind across repeated calls" do
      before = isolated_dirs()

      for _ <- 1..5 do
        assert :ok = Signal.send_message("+14432236605", "ping", [])
      end

      assert isolated_dirs() == before
    end
  end

  defp isolated_dirs do
    System.tmp_dir!()
    |> Path.join("arbor-signal-cli-*")
    |> Path.wildcard()
    |> Enum.sort()
  end
end
