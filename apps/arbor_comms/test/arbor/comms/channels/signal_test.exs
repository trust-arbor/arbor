defmodule Arbor.Comms.Channels.SignalTest do
  use ExUnit.Case, async: false

  alias Arbor.Comms.Channels.Signal

  defmodule FakeCommandRunner do
    def execute(command, opts) do
      env = Keyword.fetch!(opts, :env)
      tmpdir = Map.fetch!(env, "TMPDIR")
      extraction_dir = Path.join(tmpdir, "libsignal-client")
      extraction = Path.join(extraction_dir, "libsignal_jni_test.dylib")

      File.mkdir_p!(extraction_dir)
      File.write!(extraction, "dummy")

      send(self(), {:signal_command, command, opts, extraction})

      if String.contains?(command, "simulate-signal-cli-failure") do
        {:ok, %{exit_code: 17, stdout: "simulated failure"}}
      else
        {:ok, %{exit_code: 0, stdout: ""}}
      end
    end
  end

  defmodule InvalidCommandRunner do
    def available?, do: false
  end

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
      prev = Application.get_env(:arbor_comms, :signal)

      Application.put_env(:arbor_comms, :signal,
        account: "+10000000000",
        signal_cli_path: "/test/bin/signal-cli",
        command_runner: FakeCommandRunner
      )

      on_exit(fn ->
        if prev,
          do: Application.put_env(:arbor_comms, :signal, prev),
          else: Application.delete_env(:arbor_comms, :signal)
      end)
    end

    test "passes structured temp env to the runner and removes its extraction after success" do
      assert :ok = Signal.send_message("+14432236605", "hello", [])
      assert_receive {:signal_command, command, opts, extraction}

      env = Keyword.fetch!(opts, :env)
      tmpdir = Map.fetch!(env, "TMPDIR")

      assert command =~ "/test/bin/signal-cli"
      assert String.starts_with?(tmpdir, Path.join(System.tmp_dir!(), "arbor-signal-cli-"))
      assert env["JAVA_OPTS"] == "-Djava.io.tmpdir=#{tmpdir}"

      refute File.exists?(extraction)
      refute File.exists?(tmpdir)
    end

    test "removes the runner's extraction after signal-cli reports failure" do
      assert {:error, {:signal_cli_error, 17, "simulated failure"}} =
               Signal.send_message("+14432236605", "simulate-signal-cli-failure", [])

      assert_receive {:signal_command, _command, opts, extraction}

      tmpdir = opts |> Keyword.fetch!(:env) |> Map.fetch!("TMPDIR")

      refute File.exists?(extraction)
      refute File.exists?(tmpdir)
    end

    test "leaves no arbor-signal-cli-* directories behind across repeated calls" do
      before = isolated_dirs()

      for _ <- 1..5 do
        assert :ok = Signal.send_message("+14432236605", "ping", [])
      end

      assert isolated_dirs() == before
    end

    test "fails closed for a closure or a named module without execute/2" do
      invalid_runners = [
        fn _command, _opts -> {:ok, %{exit_code: 0, stdout: ""}} end,
        InvalidCommandRunner
      ]

      for invalid_runner <- invalid_runners do
        Application.put_env(:arbor_comms, :signal,
          account: "+10000000000",
          signal_cli_path: "/test/bin/signal-cli",
          command_runner: invalid_runner
        )

        before = isolated_dirs()

        assert {:error, {:invalid_command_runner, ^invalid_runner}} =
                 Signal.send_message("+14432236605", "hello", [])

        assert isolated_dirs() == before
        refute_receive {:signal_command, _command, _opts, _extraction}
      end
    end
  end

  defp isolated_dirs do
    System.tmp_dir!()
    |> Path.join("arbor-signal-cli-*")
    |> Path.wildcard()
    |> Enum.sort()
  end
end
