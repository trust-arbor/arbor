defmodule Arbor.Actions.Coding.ContractChange.ShellTest do
  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions.Coding.ContractChange.Core
  alias Arbor.Actions.Coding.ContractChange.Shell
  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Contracts.Coding.ValidationCapacityHandoff

  @moduletag :fast

  @kernel_test "apps/arbor_kernel/test/arbor/contracts/admission_test.exs"

  setup do
    previous_runner = Application.get_env(:arbor_actions, :contract_change_mix_runner)
    previous_clock = Application.get_env(:arbor_actions, :contract_change_monotonic_ms)

    previous_resource =
      Application.get_env(:arbor_actions, :contract_change_with_validation_resource)

    on_exit(fn ->
      restore_env(:contract_change_mix_runner, previous_runner)
      restore_env(:contract_change_monotonic_ms, previous_clock)
      restore_env(:contract_change_with_validation_resource, previous_resource)
    end)

    :ok
  end

  test "security regression: passing preflight that consumes the aggregate deadline completes and leaves tests unstarted as runtime capacity" do
    parent = self()
    {:ok, clock_agent} = Agent.start_link(fn -> 0 end)

    on_exit(fn ->
      if Process.alive?(clock_agent), do: Agent.stop(clock_agent)
    end)

    Application.put_env(:arbor_actions, :contract_change_monotonic_ms, fn ->
      Agent.get(clock_agent, & &1)
    end)

    Application.put_env(:arbor_actions, :contract_change_mix_runner, fn _path, args, opts ->
      send(parent, {:mix_invocation, args, opts})
      Agent.update(clock_agent, fn _ -> 5_000 end)
      {:ok, %{exit_code: 0, stdout: "late success", stderr: "", timed_out: false}}
    end)

    assert {:ok, checks} =
             Shell.run_mix_children(
               "/tmp",
               [@kernel_test],
               10_000,
               5_000,
               %{id: "res"}
             )

    assert checks.preflight["passed"] == true
    refute Map.has_key?(checks.preflight, "capacity_handoff")
    assert checks.test["passed"] == false
    assert checks.test["reason"] == "validation_capacity_exceeded"
    handoff = checks.test["capacity_handoff"]
    assert ValidationCapacityHandoff.valid?(handoff)
    assert handoff["schema_version"] == 3
    assert handoff["phase"] == "runtime"
    assert handoff["completed_batch_count"] == 1
    assert handoff["interrupted_batch"] == nil
    assert handoff["per_batch_budget_ms"] == 10_000
    assert Enum.map(handoff["unstarted_batches"], & &1["index"]) == [2]
    assert_receive {:mix_invocation, preflight_args, opts}
    assert preflight_args == Core.preflight_argv()
    assert Keyword.get(opts, :timeout) == 5_000
    refute_received {:mix_invocation, _, _}
  end

  test "security regression: passing final test with no remaining work succeeds after clock exhaustion" do
    parent = self()
    {:ok, clock_agent} = Agent.start_link(fn -> 0 end)

    on_exit(fn ->
      if Process.alive?(clock_agent), do: Agent.stop(clock_agent)
    end)

    Application.put_env(:arbor_actions, :contract_change_monotonic_ms, fn ->
      Agent.get(clock_agent, & &1)
    end)

    Application.put_env(:arbor_actions, :contract_change_mix_runner, fn _path, args, opts ->
      send(parent, {:mix_invocation, args, opts})

      cond do
        args == Core.preflight_argv() ->
          {:ok, %{exit_code: 0, stdout: "preflight ok", stderr: "", timed_out: false}}

        List.starts_with?(args, Core.test_argv_prefix()) ->
          Agent.update(clock_agent, fn _ -> 5_000 end)
          {:ok, %{exit_code: 0, stdout: "late test success", stderr: "", timed_out: false}}

        true ->
          flunk("unexpected mix invocation: #{inspect(args)}")
      end
    end)

    assert {:ok, checks} =
             Shell.run_mix_children(
               "/tmp",
               [@kernel_test],
               10_000,
               5_000,
               %{id: "res"}
             )

    assert checks.preflight["passed"] == true
    assert checks.test["passed"] == true
    refute Map.has_key?(checks.preflight, "capacity_handoff")
    refute Map.has_key?(checks.test, "capacity_handoff")
    assert_receive {:mix_invocation, preflight_args, _}
    assert preflight_args == Core.preflight_argv()
    assert_receive {:mix_invocation, test_args, test_opts}
    assert List.starts_with?(test_args, Core.test_argv_prefix())
    assert Keyword.get(test_opts, :timeout) == 5_000
  end

  test "timed_out child that consumes the deadline keeps interrupted schema-v3 capacity" do
    parent = self()
    {:ok, clock_agent} = Agent.start_link(fn -> 0 end)

    on_exit(fn ->
      if Process.alive?(clock_agent), do: Agent.stop(clock_agent)
    end)

    Application.put_env(:arbor_actions, :contract_change_monotonic_ms, fn ->
      Agent.get(clock_agent, & &1)
    end)

    Application.put_env(:arbor_actions, :contract_change_mix_runner, fn _path, args, opts ->
      send(parent, {:mix_invocation, args, opts})
      Agent.update(clock_agent, fn _ -> 5_000 end)

      {:ok,
       %{
         exit_code: 0,
         stdout: "ok",
         stderr: "",
         timed_out: true,
         killed: false,
         output_limit_exceeded: false,
         cancelled: false
       }}
    end)

    assert {:ok, checks} =
             Shell.run_mix_children(
               "/tmp",
               [@kernel_test],
               10_000,
               5_000,
               %{id: "res"}
             )

    assert checks.preflight["passed"] == false
    assert checks.preflight["reason"] == "validation_capacity_exceeded"
    refute Map.has_key?(checks.preflight, "termination")
    handoff = checks.preflight["capacity_handoff"]
    assert ValidationCapacityHandoff.valid?(handoff)
    assert handoff["phase"] == "runtime"
    interrupted = handoff["interrupted_batch"]
    assert interrupted["index"] == 1
    assert interrupted["total"] == 2

    assert interrupted["label"] ==
             "batch-1-of-2-n#{interrupted["count"]}-#{interrupted["inventory_sha256"]}"

    assert checks.test["status"] == "skipped"
    assert_receive {:mix_invocation, preflight_args, _}
    assert preflight_args == Core.preflight_argv()
    refute_received {:mix_invocation, _, _}
  end

  test "preflight containment does not start the test child" do
    parent = self()

    Application.put_env(:arbor_actions, :contract_change_mix_runner, fn _path, args, opts ->
      send(parent, {:mix_invocation, args, opts})

      {:ok,
       %{
         exit_code: 0,
         stdout: "ok",
         stderr: "",
         timed_out: false,
         killed: true,
         output_limit_exceeded: false,
         cancelled: false,
         containment_failure: true
       }}
    end)

    assert {:ok, checks} =
             Shell.run_mix_children("/tmp", [@kernel_test], 10_000, 60_000, %{id: "res"})

    assert checks.preflight["passed"] == false
    assert checks.preflight["reason"] == "validation_containment_failure"

    assert checks.preflight["termination"] == %{
             "timed_out" => false,
             "killed" => true,
             "output_limit_exceeded" => false,
             "cancelled" => false,
             "containment_failure" => true
           }

    refute Map.has_key?(checks.preflight, "capacity_handoff")
    assert checks.test["status"] == "skipped"
    assert checks.test["reason"] == "validation_containment_failure"
    assert_receive {:mix_invocation, preflight_args, _}
    assert preflight_args == Core.preflight_argv()
    refute_received {:mix_invocation, _, _}
  end

  test "preflight capacity flags skip tests with interrupted schema-v3 handoff" do
    parent = self()

    Application.put_env(:arbor_actions, :contract_change_mix_runner, fn _path, args, opts ->
      send(parent, {:mix_invocation, args, opts})

      {:ok,
       %{
         exit_code: 0,
         stdout: "ok",
         stderr: "",
         timed_out: false,
         killed: true,
         output_limit_exceeded: false,
         cancelled: false
       }}
    end)

    assert {:ok, checks} =
             Shell.run_mix_children("/tmp", [@kernel_test], 10_000, 60_000, %{id: "res"})

    assert checks.preflight["passed"] == false
    assert checks.preflight["reason"] == "validation_capacity_exceeded"
    refute Map.has_key?(checks.preflight, "termination")
    handoff = checks.preflight["capacity_handoff"]
    assert ValidationCapacityHandoff.valid?(handoff)
    interrupted = handoff["interrupted_batch"]
    assert interrupted["index"] == 1
    assert interrupted["total"] == 2

    assert interrupted["label"] ==
             "batch-1-of-2-n#{interrupted["count"]}-#{interrupted["inventory_sha256"]}"

    assert Enum.map(handoff["unstarted_batches"], & &1["index"]) == [2]
    assert checks.test["status"] == "skipped"
    assert_receive {:mix_invocation, preflight_args, _}
    assert preflight_args == Core.preflight_argv()
    refute_received {:mix_invocation, _, _}
  end

  test "security regression: launched-child Shell capacity flags stay interrupted runtime handoffs" do
    parent = self()
    {:ok, clock_agent} = Agent.start_link(fn -> 0 end)

    on_exit(fn ->
      if Process.alive?(clock_agent), do: Agent.stop(clock_agent)
    end)

    Application.put_env(:arbor_actions, :contract_change_monotonic_ms, fn ->
      Agent.get(clock_agent, & &1)
    end)

    Application.put_env(:arbor_actions, :contract_change_mix_runner, fn _path, args, opts ->
      send(parent, {:mix_invocation, args, opts})
      Agent.update(clock_agent, fn _ -> 5_000 end)

      {:ok,
       %{
         exit_code: 1,
         stdout: "failed",
         stderr: "",
         timed_out: false,
         killed: false,
         output_limit_exceeded: false,
         cancelled: false
       }}
    end)

    assert {:ok, checks} =
             Shell.run_mix_children("/tmp", [@kernel_test], 10_000, 5_000, %{id: "res"})

    assert checks.preflight["passed"] == false
    assert checks.preflight["reason"] == "preflight_failed"
    refute Map.has_key?(checks.preflight, "capacity_handoff")
    assert checks.test["status"] == "skipped"
    assert_receive {:mix_invocation, preflight_args, _}
    assert preflight_args == Core.preflight_argv()
    refute_received {:mix_invocation, _, _}
  end

  test "security regression: containment remains dominant when the clock is exhausted after return" do
    parent = self()
    {:ok, clock_agent} = Agent.start_link(fn -> 0 end)

    on_exit(fn ->
      if Process.alive?(clock_agent), do: Agent.stop(clock_agent)
    end)

    Application.put_env(:arbor_actions, :contract_change_monotonic_ms, fn ->
      Agent.get(clock_agent, & &1)
    end)

    Application.put_env(:arbor_actions, :contract_change_mix_runner, fn _path, args, opts ->
      send(parent, {:mix_invocation, args, opts})
      Agent.update(clock_agent, fn _ -> 5_000 end)

      {:ok,
       %{
         exit_code: 0,
         stdout: "ok",
         stderr: "",
         timed_out: false,
         killed: true,
         output_limit_exceeded: false,
         cancelled: false,
         containment_failure: true
       }}
    end)

    assert {:ok, checks} =
             Shell.run_mix_children("/tmp", [@kernel_test], 10_000, 5_000, %{id: "res"})

    assert checks.preflight["reason"] == "validation_containment_failure"
    assert checks.preflight["termination"]["containment_failure"] == true
    refute Map.has_key?(checks.preflight, "capacity_handoff")
    assert checks.test["status"] == "skipped"
    assert_receive {:mix_invocation, preflight_args, _}
    assert preflight_args == Core.preflight_argv()
    refute_received {:mix_invocation, _, _}
  end

  test "security regression: exact prelaunch probe_timeout after residual exhaustion is unstarted capacity" do
    parent = self()

    Enum.each([:probe_timeout, ":probe_timeout"], fn reason ->
      {:ok, clock_agent} = Agent.start_link(fn -> 0 end)

      on_exit(fn ->
        if Process.alive?(clock_agent), do: Agent.stop(clock_agent)
      end)

      Application.put_env(:arbor_actions, :contract_change_monotonic_ms, fn ->
        Agent.get(clock_agent, & &1)
      end)

      Application.put_env(:arbor_actions, :contract_change_mix_runner, fn _path, args, opts ->
        send(parent, {:mix_invocation, args, opts, reason})
        Agent.update(clock_agent, fn _ -> 5_000 end)
        {:error, reason}
      end)

      assert {:ok, checks} =
               Shell.run_mix_children("/tmp", [@kernel_test], 10_000, 5_000, %{id: "res"})

      assert checks.preflight["reason"] == "validation_capacity_exceeded", inspect(reason)
      handoff = checks.preflight["capacity_handoff"]
      assert ValidationCapacityHandoff.valid?(handoff), inspect(reason)
      assert handoff["schema_version"] == 3
      assert handoff["phase"] == "runtime"
      assert handoff["interrupted_batch"] == nil
      assert handoff["per_batch_budget_ms"] == 10_000
      assert Enum.map(handoff["unstarted_batches"], & &1["index"]) == [1, 2]
      assert checks.test["status"] == "skipped"
      assert_receive {:mix_invocation, preflight_args, _, ^reason}
      assert preflight_args == Core.preflight_argv()
      refute_received {:mix_invocation, _, _, _}
      Agent.stop(clock_agent)
    end)
  end

  test "security regression: positive residual and nonexact prelaunch errors remain action errors" do
    parent = self()

    Application.put_env(:arbor_actions, :contract_change_mix_runner, fn _path, args, opts ->
      send(parent, {:mix_invocation, args, opts})
      {:error, :probe_timeout}
    end)

    assert {:error, {:preflight_execution_failed, :probe_timeout}} =
             Shell.run_mix_children("/tmp", [@kernel_test], 10_000, 60_000, %{id: "res"})

    assert_receive {:mix_invocation, preflight_args, _}
    assert preflight_args == Core.preflight_argv()
    refute_received {:mix_invocation, _, _}

    Enum.each(
      [
        :probe_failed,
        :operation_deadline_exceeded,
        "probe_timeout",
        {:probe_timeout, :nested}
      ],
      fn reason ->
        {:ok, clock_agent} = Agent.start_link(fn -> 0 end)

        on_exit(fn ->
          if Process.alive?(clock_agent), do: Agent.stop(clock_agent)
        end)

        Application.put_env(:arbor_actions, :contract_change_monotonic_ms, fn ->
          Agent.get(clock_agent, & &1)
        end)

        Application.put_env(:arbor_actions, :contract_change_mix_runner, fn _path, args, opts ->
          send(parent, {:mix_invocation, args, opts, reason})
          Agent.update(clock_agent, fn _ -> 5_000 end)
          {:error, reason}
        end)

        assert {:error, {:preflight_execution_failed, ^reason}} =
                 Shell.run_mix_children("/tmp", [@kernel_test], 10_000, 5_000, %{id: "res"})

        assert_receive {:mix_invocation, received_args, _, ^reason}
        assert received_args == Core.preflight_argv()
        refute_received {:mix_invocation, _, _, _}
        Agent.stop(clock_agent)
      end
    )
  end

  test "security regression: final-tick launch race retains original handoff budget" do
    parent = self()
    {:ok, clock_agent} = Agent.start_link(fn -> 0 end)

    on_exit(fn ->
      if Process.alive?(clock_agent), do: Agent.stop(clock_agent)
    end)

    Application.put_env(:arbor_actions, :contract_change_monotonic_ms, fn ->
      Agent.get_and_update(clock_agent, fn
        n when n < 2 -> {0, n + 1}
        n -> {5_000, n + 1}
      end)
    end)

    Application.put_env(:arbor_actions, :contract_change_mix_runner, fn _path, args, _opts ->
      send(parent, {:unexpected_mix, args})
      flunk("final-tick race must not launch mix: #{inspect(args)}")
    end)

    assert {:ok, checks} =
             Shell.run_mix_children("/tmp", [@kernel_test], 10_000, 5_000, %{id: "res"})

    assert checks.preflight["reason"] == "validation_capacity_exceeded"
    handoff = checks.preflight["capacity_handoff"]
    assert ValidationCapacityHandoff.valid?(handoff)
    assert handoff["per_batch_budget_ms"] == 10_000
    assert handoff["interrupted_batch"] == nil
    assert Enum.map(handoff["unstarted_batches"], & &1["index"]) == [1, 2]
    refute_received {:unexpected_mix, _}
  end

  test "security regression: configured acquisition injection cannot replace run_mix_children resource" do
    parent = self()
    caller_resource = %{id: "caller-resource"}

    Application.put_env(
      :arbor_actions,
      :contract_change_with_validation_resource,
      fn _workspace_id, _context, fun, _opts ->
        fun.(%{id: "injected-replacement"})
      end
    )

    Application.put_env(:arbor_actions, :contract_change_mix_runner, fn _path, args, opts ->
      send(parent, {:mix_resource, args, Keyword.get(opts, :validation_resource)})
      {:ok, %{exit_code: 0, stdout: "ok", stderr: "", timed_out: false}}
    end)

    assert {:ok, checks} =
             Shell.run_mix_children("/tmp", [@kernel_test], 10_000, 60_000, caller_resource)

    assert checks.preflight["passed"] == true
    assert_receive {:mix_resource, preflight_args, ^caller_resource}
    assert preflight_args == Core.preflight_argv()
    assert_receive {:mix_resource, test_args, ^caller_resource}
    assert List.starts_with?(test_args, Core.test_argv_prefix())
    refute_received {:mix_resource, _, _}
  end

  test "security regression: exact resource-acquisition :operation_deadline_exceeded is structural two-batch capacity",
       %{tmp_dir: tmp_dir} do
    parent = self()

    case Process.whereis(Arbor.Shell.ExecutionRegistry) do
      nil -> {:ok, _} = Application.ensure_all_started(:arbor_shell)
      _pid -> :ok
    end

    fixture = leased_contract_repo(tmp_dir)
    change_kernel_contract!(fixture)

    Application.put_env(:arbor_actions, :contract_change_mix_runner, fn _path, args, _opts ->
      send(parent, {:unexpected_mix, args})
      flunk("resource deadline must not launch mix: #{inspect(args)}")
    end)

    Application.put_env(
      :arbor_actions,
      :contract_change_with_validation_resource,
      fn _workspace_id, _context, _fun, _opts ->
        {:error, :operation_deadline_exceeded}
      end
    )

    {:ok, input} =
      Core.new(%{
        workspace_id: fixture.lease.workspace_id,
        timeout: 10_000,
        stage_timeout: 60_000
      })

    assert {:ok, evidence} = Shell.run(input, fixture.context)
    assert evidence.reason == "validation_capacity_exceeded"
    assert is_list(evidence.changed_files)
    assert is_list(evidence.test_paths)
    decoded = Jason.decode!(evidence.feedback_json)
    refute Map.has_key?(decoded, "changed_files")
    refute Map.has_key?(decoded, "test_paths")
    assert decoded["changed_files_count"] == length(evidence.changed_files)
    assert decoded["test_paths_count"] == length(evidence.test_paths)
    assert decoded["changed_files_sha256"] == Core.inventory_sha256(evidence.changed_files)
    assert decoded["test_paths_sha256"] == Core.inventory_sha256(evidence.test_paths)
    assert is_boolean(decoded["passed"])
    assert is_binary(decoded["reason"])
    assert is_map(decoded["preflight"])
    assert is_map(decoded["test"])
    handoff = evidence.preflight["capacity_handoff"]
    assert ValidationCapacityHandoff.valid?(handoff)
    assert handoff["schema_version"] == 3
    assert handoff["phase"] == "structural"
    assert handoff["per_batch_budget_ms"] == 10_000
    assert handoff["interrupted_batch"] == nil
    assert Enum.map(handoff["unstarted_batches"], & &1["index"]) == [1, 2]
    assert evidence.test["status"] == "skipped"
    refute_received {:unexpected_mix, _}

    Application.put_env(
      :arbor_actions,
      :contract_change_with_validation_resource,
      fn _workspace_id, _context, _fun, _opts ->
        {:error, ":operation_deadline_exceeded"}
      end
    )

    assert {:error, ":operation_deadline_exceeded"} = Shell.run(input, fixture.context)

    Application.put_env(
      :arbor_actions,
      :contract_change_with_validation_resource,
      fn _workspace_id, _context, _fun, _opts ->
        {:error, {:wrapped, :operation_deadline_exceeded}}
      end
    )

    assert {:error, {:wrapped, :operation_deadline_exceeded}} = Shell.run(input, fixture.context)
  end

  test "security regression: malformed successful Mix output returns a typed error instead of raising" do
    for payload <- [:ok, "not-a-map", 1, %{}, %{exit_code: "0"}] do
      Application.put_env(:arbor_actions, :contract_change_mix_runner, fn _path, _args, _opts ->
        {:ok, payload}
      end)

      assert {:error, :invalid_shell_projection} =
               Shell.run_mix_children("/tmp", [@kernel_test], 10_000, 60_000, %{id: "res"})
    end
  end

  test "security regression: successful Mix payloads with non-binary stdout or stderr return a typed error instead of raising" do
    for payload <- [
          %{exit_code: 0, stdout: ["chunk"], stderr: ""},
          %{exit_code: 0, stdout: "", stderr: 1},
          %{"stdout" => %{}, "stderr" => "", exit_code: 0},
          %{exit_code: 0, stdout: :ok, stderr: ""},
          %{exit_code: 0, stdout: false, stderr: ""},
          %{exit_code: 1, stdout: ["x"], stderr: ""},
          %{
            exit_code: 0,
            stdout: ["chunk"],
            stderr: "",
            timed_out: false,
            killed: true,
            output_limit_exceeded: false,
            cancelled: false,
            containment_failure: true
          },
          %{
            exit_code: nil,
            stdout: "ok",
            stderr: 1,
            timed_out: true,
            killed: false,
            output_limit_exceeded: false,
            cancelled: false
          }
        ] do
      Application.put_env(:arbor_actions, :contract_change_mix_runner, fn _path, _args, _opts ->
        {:ok, payload}
      end)

      assert {:error, :invalid_shell_projection} =
               Shell.run_mix_children("/tmp", [@kernel_test], 10_000, 60_000, %{id: "res"})
    end

    empty_sha = :crypto.hash(:sha256, "") |> Base.encode16(case: :lower)
    ok_sha = :crypto.hash(:sha256, "ok") |> Base.encode16(case: :lower)

    for {payload, stdout_sha, stderr_sha} <- [
          {%{exit_code: 0}, empty_sha, empty_sha},
          {%{exit_code: 0, stdout: nil, stderr: nil}, empty_sha, empty_sha},
          {%{"stdout" => nil, "stderr" => nil, exit_code: 0}, empty_sha, empty_sha},
          {%{exit_code: 0, stdout: "ok", stderr: ""}, ok_sha, empty_sha},
          {%{"stdout" => "ok", "stderr" => "", exit_code: 0}, ok_sha, empty_sha},
          {%{exit_code: 0, stdout: "", stderr: ""}, empty_sha, empty_sha},
          {%{exit_code: 0, stdout: "ok"}, ok_sha, empty_sha}
        ] do
      Application.put_env(:arbor_actions, :contract_change_mix_runner, fn _path, _args, _opts ->
        {:ok, payload}
      end)

      assert {:ok, checks} =
               Shell.run_mix_children("/tmp", [@kernel_test], 10_000, 60_000, %{id: "res"})

      assert checks.preflight["passed"] == true
      assert checks.test["passed"] == true
      assert checks.preflight["stdout_sha256"] == stdout_sha
      assert checks.preflight["stderr_sha256"] == stderr_sha
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_actions, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_actions, key, value)

  defp leased_contract_repo(tmp_dir) do
    repo =
      create_contract_repo(Path.join(tmp_dir, "repo-#{System.unique_integer([:positive])}"))

    task_id = "task_contract_#{System.unique_integer([:positive])}"
    principal_id = "agent_contract_#{System.unique_integer([:positive])}"
    context = %{task_id: task_id, agent_id: principal_id}

    {:ok, lease} =
      Workspace.Acquire.run(
        %{
          repo_path: repo,
          branch_name: "test/contract-#{System.unique_integer([:positive])}",
          worktree_base_dir: Path.join(tmp_dir, "worktrees")
        },
        context
      )

    on_exit(fn -> _ = WorkspaceLeaseRegistry.release(lease.workspace_id, :remove, context) end)
    %{repo: repo, lease: lease, context: context}
  end

  defp create_contract_repo(path) do
    create_git_repo(path)

    File.write!(Path.join(path, "mix.exs"), """
    defmodule ContractFixture.MixProject do
      use Mix.Project
      def project, do: [apps_path: "apps", version: "0.1.0", deps: []]
    end
    """)

    File.mkdir_p!(Path.join(path, "config"))
    File.write!(Path.join(path, "config/config.exs"), "import Config\n")
    File.write!(Path.join(path, "mix.lock"), "%{}\n")
    File.mkdir_p!(Path.join(path, "apps/arbor_kernel/lib/arbor/contracts"))
    File.mkdir_p!(Path.join(path, "apps/arbor_kernel/test/arbor/contracts"))

    File.write!(Path.join(path, "apps/arbor_kernel/mix.exs"), """
    defmodule Arbor.Kernel.MixProject do
      use Mix.Project
      def project, do: [app: :arbor_kernel, version: "0.1.0", elixir: "~> 1.14", deps: []]
    end
    """)

    File.write!(Path.join(path, "apps/arbor_kernel/lib/arbor/contracts/foo.ex"), """
    defmodule Arbor.Contracts.Foo do
      def value, do: 1
    end
    """)

    File.write!(
      Path.join(path, "apps/arbor_kernel/test/arbor/contracts/admission_test.exs"),
      """
      defmodule Arbor.Contracts.AdmissionTest do
        use ExUnit.Case
        test "admits", do: assert true
      end
      """
    )

    File.write!(
      Path.join(path, "apps/arbor_kernel/test/arbor/contracts/dependency_hierarchy_test.exs"),
      """
      defmodule Arbor.Contracts.DependencyHierarchyTest do
        use ExUnit.Case
        test "hierarchy", do: assert true
      end
      """
    )

    File.mkdir_p!(Path.join(path, "bin"))
    File.write!(Path.join(path, "bin/mix"), "#!/usr/bin/env bash\nexec mix \"$@\"\n")
    File.chmod!(Path.join(path, "bin/mix"), 0o755)
    git!(path, ["add", "."])
    git!(path, ["commit", "-m", "contract base"])
    path
  end

  defp change_kernel_contract!(fixture) do
    File.write!(
      Path.join(fixture.lease.worktree_path, "apps/arbor_kernel/lib/arbor/contracts/foo.ex"),
      """
      defmodule Arbor.Contracts.Foo do
        def value, do: :contained
      end
      """
    )
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end
end
