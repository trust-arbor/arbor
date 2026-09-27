defmodule Mix.Tasks.Arbor.ChatFallbackCounterwitnessSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :tmp_dir
  @source Path.expand("../../../../lib/mix/tasks/arbor/agent.ex", __DIR__)
  @copy Mix.Tasks.Arbor.ChatFallbackCounterwitnessTask

  # Preserve the public task's exact parser and branches on either revision.
  # Only two outbound dependencies are replaced in this isolated module copy:
  # distribution/RPC records inert effects, and the default key path points at
  # disposable fixture storage. No real node, HOME, or operator.key is accessed.
  defmodule Transport do
    def ensure_distribution, do: record(:distribution_attempt)
    def server_running?, do: true
    def full_node_name, do: :conversation_cli_fixture@invalid
    def log_file, do: Path.join(Process.get(:cli_counterwitness_root), "inert.log")

    def rpc!(_node, Arbor.Agent.Registry, :list, []) do
      record(:registry_lookup)
      {:ok, [%{agent_id: "agent_inert", metadata: %{display_name: "inert"}}]}
    end

    def rpc!(_node, Arbor.Agent.Manager, :chat, [envelope, "CLI", _opts]) do
      record({:compatibility_chat_attempt, envelope.content})
      {:ok, "inert compatibility dispatch"}
    end

    def rpc!(_node, module, function, _args),
      do: raise("unexpected RPC #{inspect(module)}.#{function}")

    defp record(event) do
      send(self(), {:counterwitness_effect, event})
      :ok
    end
  end

  defmodule KeyPaths do
    def default_key_path,
      do: Path.join(Process.get(:cli_counterwitness_root), "absent-default.key")

    def key_file_path(opts) do
      true = is_binary(Keyword.fetch!(opts, :key_file))
      Arbor.Agent.IdentityAliasProof.key_file_path(opts)
    end
  end

  setup_all do
    source = File.read!(@source) |> Code.string_to_quoted!()

    sandboxed =
      Macro.prewalk(source, fn
        {:__aliases__, meta, [:Mix, :Tasks, :Arbor, :Agent]} ->
          {:__aliases__, meta, [:Mix, :Tasks, :Arbor, :ChatFallbackCounterwitnessTask]}

        {:__aliases__, meta, [:Mix, :Tasks, :Arbor, :Helpers]} ->
          {:__aliases__, meta,
           [:Mix, :Tasks, :Arbor, :ChatFallbackCounterwitnessSecurityRegressionTest, :Transport]}

        {:__aliases__, meta, [:Arbor, :Agent, :IdentityAliasProof]} ->
          {:__aliases__, meta,
           [:Mix, :Tasks, :Arbor, :ChatFallbackCounterwitnessSecurityRegressionTest, :KeyPaths]}

        node ->
          node
      end)

    Code.compile_quoted(sandboxed, @source)
    :ok
  end

  setup %{tmp_dir: dir} do
    Process.put(:cli_counterwitness_root, dir)
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
    :ok
  end

  test "security regression: missing key cannot attempt compatibility Manager.chat", %{
    tmp_dir: dir
  } do
    rejects_before_transport!(Path.join(dir, "missing.key"))
  end

  test "security regression: malformed explicit key cannot be ignored for compatibility Manager.chat",
       %{tmp_dir: dir} do
    path = Path.join(dir, "malformed.key")
    File.write!(path, "not signing material")
    File.chmod!(path, 0o600)
    rejects_before_transport!(path)
  end

  defp rejects_before_transport!(key_path) do
    outcome =
      try do
        {:returned,
         apply(@copy, :run, [
           ["chat", "agent_inert", "fixture private draft", "--key-file", key_path]
         ])}
      catch
        :exit, reason -> {:exited, reason}
      end

    effects = drain([])

    assert outcome == {:exited, {:shutdown, 1}},
           "CLI must reject the key before transport; outcome=#{inspect(outcome)}, recorded=#{inspect(effects)}"

    refute Enum.any?(effects, &match?({:counterwitness_effect, _}, &1)),
           "CLI contacted transport before authenticating: #{inspect(effects)}"

    assert Enum.any?(effects, fn
             {:mix_shell, :error, [message]} ->
               message =~ "Chat requires a valid private operator key"

             _ ->
               false
           end)
  end

  defp drain(events) do
    receive do
      {:counterwitness_effect, _} = event -> drain([event | events])
      {:mix_shell, _, _} = event -> drain([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end
end
