defmodule Arbor.Shell.OciExecutorTest do
  @moduledoc """
  Hermetic tests for the internal OCI/Podman spawn-capable adapter.
  """

  use ExUnit.Case, async: false

  alias Arbor.Shell.ExecutablePolicy.Executable
  alias Arbor.Shell.OciExecutor, as: Executor
  alias Arbor.Shell.OciProbeRuntime
  alias Arbor.Shell.SpawnCapableTimeout

  @moduletag :fast

  @digest String.duplicate("a", 64)
  @image "sha256:#{@digest}"
  @mix_wrapper "/private/tmp/arbor-oci/bin/mix"
  @worktree "/private/tmp/arbor-oci/worktree"
  @validation_runner "/private/tmp/arbor-oci/runner"
  @validation_result "/private/tmp/arbor-oci/result"
  @unit_name_re ~r/\Aarbor-v1-[0-9a-f]{32}\z/

  @valid_admission %{
    "admitted" => true,
    "platform" => %{"os" => "linux", "architecture" => "x86_64"},
    "runtime" => %{"path" => "/usr/bin/podman"},
    "image" => %{
      "execution_reference" => @image,
      "platform" => "linux/amd64"
    }
  }

  setup do
    {:ok, agent} = Agent.start_link(fn -> empty_trace() end)

    on_exit(fn ->
      if Process.alive?(agent), do: Agent.stop(agent)
    end)

    {:ok, agent: agent}
  end

  defp empty_trace do
    %{
      probe_calls: [],
      resolve_calls: 0,
      random_calls: 0,
      register_calls: 0,
      start_calls: [],
      adopt_calls: 0,
      begin_calls: [],
      settle_calls: 0,
      mono: 1_000_000,
      generated_names: [],
      last_spec: nil,
      last_execution_id: nil,
      last_start_ref: nil,
      last_worker: nil,
      registry: %{},
      fail_calls: []
    }
  end

  defp actions_entry(path, mode, purpose) do
    %{
      "path" => path,
      "mode" => Atom.to_string(mode),
      "purpose" => Atom.to_string(purpose)
    }
  end

  defp base_projections do
    %{
      read_only: [
        actions_entry("/opt/erlang", :read_only, :runtime_erlang),
        actions_entry("/opt/elixir", :read_only, :runtime_elixir),
        actions_entry(@mix_wrapper, :read_only, :mix_wrapper),
        actions_entry(@validation_runner, :read_only, :validation_runner)
      ],
      read_write: [
        actions_entry(@worktree, :read_write, :worktree),
        actions_entry("/private/tmp/arbor-oci/home", :read_write, :home),
        actions_entry("/private/tmp/arbor-oci/tmp", :read_write, :tmp),
        actions_entry("/private/tmp/arbor-oci/build", :read_write, :build),
        actions_entry("/private/tmp/arbor-oci/deps", :read_write, :deps),
        actions_entry(@validation_result, :read_write, :validation_result)
      ],
      revision: "candidate"
    }
  end

  defp valid_opts(overrides \\ []) do
    base = [
      cwd: @worktree,
      timeout: 60_000,
      sandbox: :basic,
      env: %{},
      clear_env: true,
      filesystem_projections: base_projections(),
      unit_owner: %{
        validation_resource_id: "validation_res",
        workspace_id: "workspace",
        task_id: "task",
        principal_id: "principal"
      }
    ]

    Keyword.merge(base, overrides)
  end

  defp fake_executable do
    %Executable{
      name: "podman",
      path: "/usr/bin/podman",
      device: 1,
      inode: 2,
      size: 100,
      mtime: 0,
      ctime: 0,
      mode: 0o755,
      sha256: String.duplicate("c", 64)
    }
  end

  defp success_result(overrides \\ %{}) do
    Map.merge(
      %{
        exit_code: 0,
        stdout: "ok",
        stderr: "",
        duration_ms: 12,
        timed_out: false,
        cancelled: false,
        killed: false,
        output_truncated: false,
        output_limit_exceeded: false
      },
      overrides
    )
  end

  defp record(agent, key, value \\ 1) do
    Agent.update(agent, fn state ->
      case Map.get(state, key) do
        list when is_list(list) -> Map.put(state, key, [value | list])
        n when is_integer(n) -> Map.put(state, key, n + value)
        _ -> Map.put(state, key, value)
      end
    end)
  end

  defp put_state(agent, key, value) do
    Agent.update(agent, &Map.put(&1, key, value))
  end

  defp get_state(agent, key) do
    Agent.get(agent, &Map.get(&1, key))
  end

  defp advance_mono(agent, by) do
    Agent.update(agent, fn state ->
      %{state | mono: state.mono + by}
    end)
  end

  defp mono(agent) do
    Agent.get(agent, & &1.mono)
  end

  defp publish_registry(agent, execution_id, status, result, terminal_source) do
    Agent.update(agent, fn state ->
      reg = Map.get(state, :registry, %{})
      entry = Map.get(reg, execution_id, %{status: :running, result: nil, owner: :controller})

      updated = %{
        entry
        | status: status,
          result: result,
          terminal_source: terminal_source
      }

      %{state | registry: Map.put(reg, execution_id, updated)}
    end)
  end

  defp base_deps(agent, overrides \\ %{}) do
    base = %{
      probe: fn remaining ->
        record(agent, :probe_calls, remaining)
        advance_mono(agent, 100)
        {:ok, @valid_admission}
      end,
      resolve_executable: fn ->
        record(agent, :resolve_calls)
        advance_mono(agent, 10)
        {:ok, fake_executable()}
      end,
      generate_unit_name: fn ->
        record(agent, :random_calls)
        name = "arbor-v1-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
        record(agent, :generated_names, name)
        name
      end,
      register: fn _cmd, _opts ->
        record(agent, :register_calls)
        id = "exec_test_" <> Integer.to_string(System.unique_integer([:positive]))
        put_state(agent, :last_execution_id, id)

        put_state(agent, :registry, %{
          id => %{
            status: :pending,
            result: nil,
            owner: :controller,
            terminal_source: nil
          }
        })

        {:ok, id}
      end,
      adopt: fn execution_id, worker ->
        record(agent, :adopt_calls)
        put_state(agent, :last_worker, worker)

        Agent.update(agent, fn state ->
          reg = Map.get(state, :registry, %{})

          entry =
            reg
            |> Map.get(execution_id, %{status: :pending, result: nil, terminal_source: nil})
            |> Map.merge(%{status: :running, owner: worker, terminal_source: nil})

          %{state | registry: Map.put(reg, execution_id, entry)}
        end)

        :ok
      end,
      registry_get: fn execution_id ->
        case Agent.get(agent, fn state -> get_in(state, [:registry, execution_id]) end) do
          nil ->
            {:error, :not_found}

          entry ->
            {:ok,
             %{
               id: execution_id,
               status: Map.get(entry, :status),
               result: Map.get(entry, :result),
               terminal_source: Map.get(entry, :terminal_source)
             }}
        end
      end,
      registry_fail: fn execution_id, reason ->
        record(agent, :fail_calls, {execution_id, reason})
        :ok
      end,
      worker_start: fn spec, exe, execution_id, start_ref ->
        record(agent, :start_calls, %{
          timeout_ms: Map.get(spec, :timeout_ms),
          unit_name: unit_name_from_spec(spec),
          execution_id: execution_id,
          start_ref: start_ref,
          runtime_path: exe.path
        })

        put_state(agent, :last_spec, spec)
        put_state(agent, :last_execution_id, execution_id)
        put_state(agent, :last_start_ref, start_ref)

        parent = self()

        worker =
          spawn(fn ->
            receive do
              {:begin, ^start_ref, _from} ->
                result = success_result()
                publish_registry(agent, execution_id, :completed, result, :owner_published)
                send(parent, {:apple_container_unit_terminal, execution_id, {:ok, result}})
                :ok

              {:cancel_shell_execution, ^execution_id} ->
                :ok
            end
          end)

        put_state(agent, :last_worker, worker)
        {:ok, worker}
      end,
      worker_begin: fn worker, start_ref, timeout ->
        record(agent, :begin_calls, timeout)
        send(worker, {:begin, start_ref, self()})
        :ok
      end,
      await_settled: fn _execution_id ->
        record(agent, :settle_calls)
        :ok
      end,
      monotonic_ms: fn -> mono(agent) end,
      sleep: fn _ms ->
        advance_mono(agent, 1)
        :ok
      end
    }

    Map.merge(base, overrides)
  end

  defp unit_name_from_spec(spec) when is_map(spec) do
    plan = Map.get(spec, :plan)

    cond do
      is_map(plan) and is_binary(Map.get(plan, :unit_name)) -> Map.get(plan, :unit_name)
      is_map(plan) and is_binary(Map.get(plan, "unit_name")) -> Map.get(plan, "unit_name")
      true -> nil
    end
  end

  describe "preflight" do
    test "rejects relative mix without side effects", %{agent: agent} do
      deps = base_deps(agent)

      assert {:error, {:invalid_tool_name, :relative_path}} =
               Executor.execute_for_test("mix", ["compile"], valid_opts(), deps)

      assert get_state(agent, :probe_calls) == []
      assert get_state(agent, :resolve_calls) == 0
      assert get_state(agent, :start_calls) == []
    end
  end

  describe "prelaunch deadline projection" do
    test "trusted probe deadline exhaustion projects canonical operation error", %{agent: agent} do
      timeout = 5_000

      deps =
        base_deps(agent, %{
          probe: fn remaining ->
            record(agent, :probe_calls, remaining)
            advance_mono(agent, timeout)
            {:error, :deadline_exhausted}
          end
        })

      assert {:error, :operation_deadline_exceeded} =
               Executor.execute_for_test(
                 @mix_wrapper,
                 ["compile"],
                 valid_opts(timeout: timeout),
                 deps
               )

      assert get_state(agent, :probe_calls) == [timeout]
      assert get_state(agent, :resolve_calls) == 0
      assert get_state(agent, :random_calls) == 0
      assert get_state(agent, :register_calls) == 0
      assert get_state(agent, :start_calls) == []
      assert get_state(agent, :begin_calls) == []
    end

    test "non-deadline setup errors remain unchanged", %{agent: agent} do
      deps =
        base_deps(agent, %{
          probe: fn _remaining -> {:error, :probe_cancelled} end
        })

      assert {:error, :probe_cancelled} =
               Executor.execute_for_test(@mix_wrapper, ["compile"], valid_opts(), deps)

      assert get_state(agent, :start_calls) == []
      assert get_state(agent, :begin_calls) == []
    end
  end

  describe "happy path" do
    test "execute_for_test uses /usr/bin/podman and arbor-v1 names", %{agent: agent} do
      assert {:ok, result} =
               Executor.execute_for_test(
                 @mix_wrapper,
                 ["compile"],
                 valid_opts(),
                 base_deps(agent)
               )

      assert result.exit_code == 0
      spec = get_state(agent, :last_spec)
      assert spec.plan.runtime_executable == "/usr/bin/podman"
      name = hd(get_state(agent, :generated_names))
      assert Regex.match?(@unit_name_re, name)
      start_meta = hd(get_state(agent, :start_calls))
      assert start_meta.runtime_path == "/usr/bin/podman"
    end
  end

  describe "security regression: CLI identity" do
    @tag :security_regression
    test "security regression: non-root-owned CLI identity is rejected", %{agent: agent} do
      deps =
        base_deps(agent, %{
          resolve_executable: fn ->
            record(agent, :resolve_calls)
            {:error, :untrusted_path}
          end
        })

      assert {:error, :untrusted_path} =
               Executor.execute_for_test(@mix_wrapper, ["compile"], valid_opts(), deps)

      assert get_state(agent, :start_calls) == []
    end
  end

  describe "production path" do
    test "probe runtime only admits /usr/bin/podman" do
      assert {:error, :untrusted_path} =
               OciProbeRuntime.resolve_executable("/home/user/.local/bin/podman")

      assert OciProbeRuntime.runtime_path() == "/usr/bin/podman"
    end

    test "probe deadline is bounded", %{agent: agent} do
      timeout = SpawnCapableTimeout.max_timeout_ms()

      assert {:ok, _} =
               Executor.execute_for_test(
                 @mix_wrapper,
                 ["compile"],
                 valid_opts(timeout: timeout),
                 base_deps(agent)
               )

      assert hd(get_state(agent, :probe_calls)) == SpawnCapableTimeout.max_probe_deadline_ms()
    end
  end
end
