defmodule Mix.Tasks.Arbor.Coding.RunTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.WorkPacket
  alias Mix.Tasks.Arbor.Coding.Run

  @moduletag :fast

  @caller "agent_operator_run_mix"
  @agent_id "agent_coordinator_run_mix"
  @target :arbor_run@localhost
  @task_id "task_run_mix_1"

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
    :ok
  end

  test "mix help arbor.coding.run documents every flag and the exit codes" do
    doc = Mix.Task.moduledoc(Mix.Tasks.Arbor.Coding.Run)

    assert doc =~ "--agent-id"
    assert doc =~ "--key-file"
    assert doc =~ "--approve-as-dispatcher"
    assert doc =~ "--allow-paths"
    assert doc =~ "--poll-ms"
    assert doc =~ "--max-wait-ms"
    refute doc =~ "--watch"
    assert doc =~ "whole command"
    assert doc =~ "change_committed"
    assert doc =~ "pr_created"
    assert doc =~ "no_changes"
    assert doc =~ "human_review_required"
    assert doc =~ "Exit"
  end

  test "grant non-convergence stops before dispatch" do
    path = write_plan!(bare_plan())
    on_exit(fn -> File.rm(path) end)
    test_pid = self()

    rpc = fn node, module, function, args, timeout ->
      send(test_pid, {:rpc, node, module, function, args, timeout})

      case function do
        :coding_dispatch_readiness -> {:ok, missing_uris_report(["arbor://fs/read/tmp"])}
        :grant -> {:ok, %{id: "cap"}}
        :dispatch_task -> flunk("dispatch must not run after grant non-convergence")
        other -> flunk("unexpected #{inspect(other)}")
      end
    end

    assert {:error, result} =
             Run.execute(
               [path, "--agent-id", @agent_id, "--max-wait-ms", "60000"],
               runtime_opts(rpc)
             )

    assert result.reason == :grant_unconverged
    rpcs = collect_rpcs([])
    refute Enum.any?(rpcs, fn {_n, _m, fun, _a, _t} -> fun == :dispatch_task end)
  end

  test "plan file omitting digest uses the identical stamped envelope for grant, readiness, and dispatch" do
    path = write_plan!(bare_plan())
    on_exit(fn -> File.rm(path) end)
    envelopes = run_and_collect_envelopes(path)

    assert length(envelopes) >= 3
    [grant_env, ready_env, dispatch_env | _] = envelopes
    assert grant_env == ready_env
    assert ready_env == dispatch_env
    assert grant_env["kind"] == "coding_change"
    assert grant_env["plan"]["work_packet_digest"] =~ ~r/^sha256:[0-9a-f]{64}$/
    {:ok, expected} = WorkPacket.digest(bare_plan()["work_packet"])
    assert grant_env["plan"]["work_packet_digest"] == expected
  end

  test "bare plan file dispatches the identical coding_change envelope with stamped digest" do
    path = write_plan!(bare_plan())
    on_exit(fn -> File.rm(path) end)
    [grant_env, ready_env, dispatch_env | _] = run_and_collect_envelopes(path)
    assert grant_env == ready_env
    assert ready_env == dispatch_env
    assert %{"kind" => "coding_change", "plan" => plan} = dispatch_env
    assert is_binary(plan["work_packet_digest"])
  end

  test "injecting only rpc_call plus discovery/caller drives the full sequence" do
    path = write_plan!(wrapped_plan())
    on_exit(fn -> File.rm(path) end)
    test_pid = self()
    readiness = :atomics.new(1, [])
    statuses = :atomics.new(1, [])
    lists = :atomics.new(1, [])

    opts = [
      caller_resolver: fn cli ->
        assert cli.key_file == Path.expand("~/.arbor/identity.key")
        {:ok, @caller}
      end,
      ensure_distribution: fn ->
        send(test_pid, :discovered_dist)
        :ok
      end,
      server_running?: fn ->
        send(test_pid, :discovered_running)
        true
      end,
      target_node: fn ->
        send(test_pid, :discovered_target)
        @target
      end,
      now_ms: fn -> 0 end,
      now_iso: fn -> "2026-08-28T21:00:00Z" end,
      sleep: fn _ms -> :ok end,
      git_status: fn worktree ->
        send(test_pid, {:git, worktree})
        {:ok, " M apps/arbor_commands/lib/foo.ex\0"}
      end,
      rpc_call: fn node, module, function, args, timeout ->
        send(test_pid, {:rpc, node, module, function, args, timeout})

        case function do
          :coding_dispatch_readiness ->
            n = :atomics.add_get(readiness, 1, 1)
            if n == 1, do: {:ok, converged_grant_report()}, else: {:ok, ready_report()}

          :dispatch_task ->
            {:ok, @task_id}

          :task_status ->
            n = :atomics.add_get(statuses, 1, 1)

            cond do
              n == 1 -> {:ok, %{state: :running, current_step: "worker"}}
              n == 2 -> {:ok, %{state: :waiting_approval, current_step: "validate"}}
              n == 3 -> {:ok, %{state: :waiting_approval, current_step: "commit"}}
              true -> {:ok, %{state: :done, current_step: "done"}}
            end

          :list_pending_approvals ->
            n = :atomics.add_get(lists, 1, 1)

            if n == 1 do
              {:ok, [pending("irq_val", "coding_reviewed_validation")]}
            else
              {:ok, [pending("irq_commit", "coding_reviewed_commit")]}
            end

          :answer_approval ->
            :ok

          :task_result ->
            {:ok, terminal("change_committed")}

          :grant ->
            {:ok, %{id: "cap"}}

          other ->
            flunk("unexpected #{inspect(other)} #{inspect(args)}")
        end
      end
    ]

    assert :ok =
             Run.run(
               [
                 path,
                 "--agent-id",
                 @agent_id,
                 "--approve-as-dispatcher",
                 "--allow-paths",
                 "^apps/arbor_commands/"
               ],
               opts
             )

    assert_received :discovered_dist
    assert_received :discovered_running
    assert_received :discovered_target
    refute_received :discovered_dist
    refute_received :discovered_running
    refute_received :discovered_target

    rpcs = collect_rpcs([])
    assert Enum.all?(rpcs, fn {node, _, _, _, _} -> node == @target end)

    functions = Enum.map(rpcs, fn {_n, mod, fun, args, _t} -> {mod, fun, args} end)

    assert Enum.any?(functions, fn
             {Arbor.Agent, :coding_dispatch_readiness, [caller, agent, env, []]} ->
               caller == @caller and agent == @agent_id and env["kind"] == "coding_change"

             _ ->
               false
           end)

    assert Enum.any?(functions, fn
             {Arbor.Agent, :dispatch_task, [@caller, @agent_id, env, []]} ->
               env["kind"] == "coding_change"

             _ ->
               false
           end)

    answers =
      Enum.filter(functions, fn
        {Arbor.Agent.Orchestration, :answer_approval, [id, :approve, [caller_id: @caller]]} ->
          id in ["irq_val", "irq_commit"]

        _ ->
          false
      end)

    assert length(answers) == 2

    assert_received {:git, "/tmp/ws"}
    infos = collect_infos([])
    assert Enum.any?(infos, &String.contains?(&1, @task_id))
    assert Enum.any?(infos, &String.contains?(&1, "change_committed"))
    assert Enum.any?(infos, &String.contains?(&1, "seat=security vote=approve"))
  end

  test "--max-wait-ms shorter than poll_ms and RPC timeout clamps then halts" do
    path = write_plan!(bare_plan())
    on_exit(fn -> File.rm(path) end)
    test_pid = self()
    clock = :atomics.new(1, [])
    readiness = :atomics.new(1, [])
    :atomics.put(clock, 1, 0)

    rpc = fn _node, _mod, function, _args, timeout ->
      send(test_pid, {:rpc_timeout, function, timeout})

      case function do
        :coding_dispatch_readiness ->
          n = :atomics.add_get(readiness, 1, 1)
          if n == 1, do: {:ok, converged_grant_report()}, else: {:ok, ready_report()}

        :dispatch_task ->
          {:ok, @task_id}

        :task_status ->
          {:ok, %{state: :running, current_step: "worker"}}

        other ->
          {:error, {:unused, other}}
      end
    end

    result =
      Run.execute(
        [path, "--agent-id", @agent_id, "--poll-ms", "10000", "--max-wait-ms", "50"],
        runtime_opts(rpc)
        |> Keyword.put(:now_ms, fn -> :atomics.get(clock, 1) end)
        |> Keyword.put(:sleep, fn ms ->
          send(test_pid, {:slept, ms})
          :atomics.put(clock, 1, 50)
        end)
      )

    timeouts =
      for {:rpc_timeout, _fun, timeout} <- collect_tagged(:rpc_timeout, []), do: timeout

    assert timeouts != []
    assert Enum.all?(timeouts, fn t -> is_integer(t) and t <= 50 end)

    assert Enum.any?(collect_tagged(:slept, []), fn {:slept, ms} -> ms <= 50 end)
    assert {:error, %{exit_code: 1, reason: :deadline_exceeded}} = result
  end

  @tag :security_regression
  test "security regression: git-status failures halt with no answer_approval RPC" do
    Enum.each(
      [
        {:error, :timeout},
        {:error, :output_exceeded},
        {:ok, "malformed"},
        {:error, :invalid_worktree}
      ],
      fn git_result ->
        path = write_plan!(bare_plan())
        on_exit(fn -> File.rm(path) end)
        test_pid = self()
        readiness = :atomics.new(1, [])

        opts =
          runtime_opts(fn node, module, function, args, timeout ->
            send(test_pid, {:rpc, node, module, function, args, timeout})

            case function do
              :coding_dispatch_readiness ->
                n = :atomics.add_get(readiness, 1, 1)
                if n == 1, do: {:ok, converged_grant_report()}, else: {:ok, ready_report()}

              :dispatch_task ->
                {:ok, @task_id}

              :task_status ->
                {:ok, %{state: :waiting_approval, current_step: "commit"}}

              :list_pending_approvals ->
                {:ok, [pending("irq_commit", "coding_reviewed_commit")]}

              :answer_approval ->
                flunk("answer_approval must not run on git failure")

              :grant ->
                {:ok, %{}}

              other ->
                {:error, {:unused, other}}
            end
          end)
          |> Keyword.put(:git_status, fn _wt -> git_result end)
          |> Keyword.put(:sleep, fn _ -> :ok end)

        assert {:error, result} =
                 Run.execute(
                   [
                     path,
                     "--agent-id",
                     @agent_id,
                     "--approve-as-dispatcher",
                     "--allow-paths",
                     ".*"
                   ],
                   opts
                 )

        assert result.exit_code == 1
        rpcs = collect_rpcs([])
        refute Enum.any?(rpcs, fn {_n, _m, fun, _a, _t} -> fun == :answer_approval end)
      end
    )
  end

  @tag :security_regression
  test "security regression: foreign or nil task-id approval is never answered" do
    path = write_plan!(bare_plan())
    on_exit(fn -> File.rm(path) end)
    test_pid = self()
    readiness = :atomics.new(1, [])
    statuses = :atomics.new(1, [])

    opts =
      runtime_opts(fn node, module, function, args, timeout ->
        send(test_pid, {:rpc, node, module, function, args, timeout})

        case function do
          :coding_dispatch_readiness ->
            n = :atomics.add_get(readiness, 1, 1)
            if n == 1, do: {:ok, converged_grant_report()}, else: {:ok, ready_report()}

          :dispatch_task ->
            {:ok, @task_id}

          :task_status ->
            n = :atomics.add_get(statuses, 1, 1)

            if n == 1 do
              {:ok, %{state: :waiting_approval, current_step: "validate"}}
            else
              {:ok, %{state: :done, current_step: "done"}}
            end

          :list_pending_approvals ->
            {:ok,
             [
               pending("irq_foreign", "coding_reviewed_validation", "task_other"),
               pending("irq_nil", "coding_reviewed_validation", nil),
               pending("irq_mine", "coding_reviewed_validation", @task_id)
             ]}

          :answer_approval ->
            :ok

          :task_result ->
            {:ok, terminal("change_committed")}

          :grant ->
            {:ok, %{}}

          other ->
            {:error, {:unused, other}}
        end
      end)
      |> Keyword.put(:sleep, fn _ -> :ok end)

    _ = Run.execute([path, "--agent-id", @agent_id, "--approve-as-dispatcher"], opts)
    rpcs = collect_rpcs([])

    answers =
      for {_n, Arbor.Agent.Orchestration, :answer_approval, [id | _], _} <- rpcs, do: id

    assert "irq_mine" in answers
    refute "irq_foreign" in answers
    refute "irq_nil" in answers
  end

  @tag :security_regression
  test "security regression: waiting_approval re-lists on an unchanged fingerprint" do
    path = write_plan!(bare_plan())
    on_exit(fn -> File.rm(path) end)
    test_pid = self()
    readiness = :atomics.new(1, [])
    lists = :atomics.new(1, [])
    statuses = :atomics.new(1, [])

    rpc = fn _node, _mod, function, _args, _timeout ->
      case function do
        :coding_dispatch_readiness ->
          n = :atomics.add_get(readiness, 1, 1)
          if n == 1, do: {:ok, converged_grant_report()}, else: {:ok, ready_report()}

        :dispatch_task ->
          {:ok, @task_id}

        :task_status ->
          n = :atomics.add_get(statuses, 1, 1)

          if n <= 2 do
            {:ok, %{state: :waiting_approval, current_step: "validate"}}
          else
            {:ok, %{state: :done, current_step: "done"}}
          end

        :list_pending_approvals ->
          n = :atomics.add_get(lists, 1, 1)
          send(test_pid, {:listed, n})
          {:ok, []}

        :task_result ->
          {:ok, terminal("no_changes")}

        :grant ->
          {:ok, %{}}

        other ->
          {:error, {:unused, other}}
      end
    end

    assert {:ok, _} =
             Run.execute(
               [path, "--agent-id", @agent_id, "--max-wait-ms", "100000"],
               runtime_opts(rpc) |> Keyword.put(:sleep, fn _ -> :ok end)
             )

    listed = collect_tagged(:listed, [])
    assert length(listed) >= 2
  end

  test "two pending approvals on an unchanged waiting_approval fingerprint are both handled" do
    path = write_plan!(bare_plan())
    on_exit(fn -> File.rm(path) end)
    test_pid = self()
    readiness = :atomics.new(1, [])
    statuses = :atomics.new(1, [])
    answered = :atomics.new(1, [])

    rpc = fn _node, _mod, function, args, _timeout ->
      case function do
        :coding_dispatch_readiness ->
          n = :atomics.add_get(readiness, 1, 1)
          if n == 1, do: {:ok, converged_grant_report()}, else: {:ok, ready_report()}

        :dispatch_task ->
          {:ok, @task_id}

        :task_status ->
          n = :atomics.add_get(statuses, 1, 1)

          if n == 1 do
            {:ok, %{state: :waiting_approval, current_step: "validate"}}
          else
            {:ok, %{state: :done, current_step: "done"}}
          end

        :list_pending_approvals ->
          {:ok,
           [
             pending("irq_a", "coding_reviewed_validation"),
             pending("irq_b", "coding_reviewed_validation")
           ]}

        :answer_approval ->
          [id | _] = args
          send(test_pid, {:answered, id})
          :atomics.add_get(answered, 1, 1)
          :ok

        :task_result ->
          {:ok, terminal("change_committed")}

        :grant ->
          {:ok, %{}}

        other ->
          {:error, {:unused, other}}
      end
    end

    assert {:ok, _} =
             Run.execute(
               [path, "--agent-id", @agent_id, "--approve-as-dispatcher"],
               runtime_opts(rpc) |> Keyword.put(:sleep, fn _ -> :ok end)
             )

    answered_ids = for {:answered, id} <- collect_tagged(:answered, []), do: id
    assert answered_ids == ["irq_a", "irq_b"]
  end

  defp run_and_collect_envelopes(path) do
    test_pid = self()
    readiness = :atomics.new(1, [])

    rpc = fn _node, _mod, function, args, _timeout ->
      case function do
        :coding_dispatch_readiness ->
          send(test_pid, {:envelope, Enum.at(args, 2)})
          n = :atomics.add_get(readiness, 1, 1)
          if n == 1, do: {:ok, converged_grant_report()}, else: {:ok, ready_report()}

        :dispatch_task ->
          send(test_pid, {:envelope, Enum.at(args, 2)})
          {:ok, @task_id}

        :task_status ->
          {:ok, %{state: :done, current_step: "done"}}

        :task_result ->
          {:ok, terminal("no_changes")}

        :grant ->
          {:ok, %{}}

        :list_pending_approvals ->
          {:ok, []}

        other ->
          {:error, {:unused, other}}
      end
    end

    assert {:ok, _} =
             Run.execute(
               [path, "--agent-id", @agent_id],
               runtime_opts(rpc) |> Keyword.put(:sleep, fn _ -> :ok end)
             )

    collect_envelopes([])
  end

  defp collect_envelopes(acc) do
    receive do
      {:envelope, env} -> collect_envelopes(acc ++ [env])
    after
      0 -> acc
    end
  end

  @tag :security_regression
  test "security regression: an approval whose task identity is not in documented provenance is ignored" do
    flat = %{
      id: "irq_flat",
      action: :coding_reviewed_validation,
      metadata: %{"task_id" => @task_id, "worktree" => "/tmp/ws"}
    }

    [view] = Mix.Tasks.Arbor.Coding.Run.__project_approvals_for_test__([flat])
    assert view["task_id"] == nil
    assert view["worktree"] == nil

    [real] =
      Mix.Tasks.Arbor.Coding.Run.__project_approvals_for_test__([
        pending("irq_real", :coding_reviewed_validation)
      ])

    assert real["task_id"] == @task_id
    assert real["worktree"] == "/tmp/ws"
  end

  defp pending(id, action, task_id \\ @task_id) do
    %{
      id: id,
      action: action,
      metadata: %{
        "approval_context" => %{"provenance" => %{"task_id" => task_id}, "path" => "/tmp/ws"},
        "provenance" => %{"task_id" => task_id}
      }
    }
  end

  defp terminal(code) do
    %{
      "outcome" => %{
        "code" => code,
        "disposition" => "succeeded",
        "origin" => "arbor",
        "retry" => "none"
      },
      "evidence" => %{
        "kind" => "executor_result",
        "result" => %{
          "commit" => "deadbeef",
          "branch" => "arbor/coding-agent/x",
          "evaluations" => [
            %{
              "seat" => "security",
              "vote" => "approve",
              "provider" => "anthropic",
              "model" => "claude-opus"
            }
          ]
        }
      }
    }
  end

  defp ready_report do
    %{"planes" => %{"executor" => %{"status" => "ready", "details" => %{}}}}
  end

  defp converged_grant_report do
    %{
      "planes" => %{
        "executor" => %{
          "details" => %{
            "projection" => %{
              "authority_horizon" => %{
                "findings" => [],
                "required_resources" => []
              }
            }
          }
        }
      }
    }
  end

  defp missing_uris_report(uris) do
    %{
      "planes" => %{
        "executor" => %{
          "details" => %{
            "projection" => %{
              "authority_horizon" => %{
                "findings" => [
                  %{
                    "principal_role" => "authenticated_caller",
                    "classification" => "missing",
                    "resource_uris" => uris
                  }
                ],
                "required_resources" => []
              }
            }
          }
        }
      }
    }
  end

  defp runtime_opts(rpc) do
    [
      caller_resolver: fn _cli -> {:ok, @caller} end,
      ensure_distribution: fn -> :ok end,
      server_running?: fn -> true end,
      target_node: fn -> @target end,
      now_ms: fn -> 0 end,
      now_iso: fn -> "2026-08-28T21:00:00Z" end,
      rpc_call: rpc
    ]
  end

  defp bare_plan do
    %{
      "version" => 2,
      "task" => "Run coding packet",
      "repo_root" => "/tmp",
      "worker" => %{"provider" => "grok"},
      "work_packet" => work_packet()
    }
  end

  defp wrapped_plan do
    {:ok, digest} = WorkPacket.digest(work_packet())

    %{
      "kind" => "coding_change",
      "plan" => Map.put(bare_plan(), "work_packet_digest", digest)
    }
  end

  defp work_packet do
    %{
      "version" => 1,
      "success_criteria" => ["coding run command reaches a terminal outcome"],
      "non_goals" => ["Do not merge"],
      "constraints" => ["The worker has no shell."],
      "architecture_refs" => ["apps/arbor_commands/lib/mix/tasks/arbor.coding.run.ex"],
      "required_evidence" => ["Focused mix test"],
      "checkpoint_policy" => "direct"
    }
  end

  defp write_plan!(plan) do
    path = Path.join(System.tmp_dir!(), "coding-run-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(plan))
    path
  end

  defp collect_rpcs(acc) do
    receive do
      {:rpc, node, module, function, args, timeout} ->
        collect_rpcs([{node, module, function, args, timeout} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp collect_infos(acc) do
    receive do
      {:mix_shell, :info, [text]} -> collect_infos([text | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp collect_tagged(tag, acc) do
    receive do
      {^tag, _} = msg -> collect_tagged(tag, [msg | acc])
      {^tag, _, _} = msg -> collect_tagged(tag, [msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
