defmodule Mix.Tasks.Arbor.Coding.GrantTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.CodingGrantCore
  alias Arbor.Commands.CodingGrantTrustCore
  alias Mix.Tasks.Arbor.Coding.Grant

  @moduletag :fast

  @caller "agent_operator_grant"
  @agent_id "agent_coordinator_grant"
  @target :arbor_grant@localhost
  @uri_a "arbor://fs/read/tmp"
  @uri_b "arbor://agent/dispatch"

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
    :ok
  end

  test "mix help arbor.coding.grant states dry-run semantics exactly" do
    doc = Mix.Task.moduledoc(Mix.Tasks.Arbor.Coding.Grant)

    assert doc =~ "until no role has missing findings"
    assert doc =~ "maximum number of readiness rounds"
    assert doc =~ "every round invokes readiness"
    assert doc =~ "emits the full list of"
    assert doc =~ "missing URIs named that round (no dedupe)"
    assert doc =~ "never emits a grant"
    assert doc =~ "halts converged only when a report names nothing"
    assert doc =~ "unconverged at max-rounds"
    assert doc =~ "--no-trust-rules"
    assert doc =~ "execution-principal"
    assert doc =~ "Arbor.Trust.set_rule/3"
  end

  test "max_rounds 0, negative, and 21 are invalid_max_rounds" do
    path = write_plan!(%{"task" => "grant"})
    on_exit(fn -> File.rm(path) end)

    Enum.each([0, -1, 21], fn max_rounds ->
      assert {:error, result} =
               Grant.execute(
                 [
                   "--plan",
                   path,
                   "--agent-id",
                   @agent_id,
                   "--max-rounds",
                   Integer.to_string(max_rounds)
                 ],
                 runtime_opts(fn _node, _mod, _fun, _args, _timeout ->
                   send(self(), :rpc_called)
                   {:ok, missing_report([@uri_a])}
                 end)
               )

      assert result.status == :invalid_max_rounds
    end)

    refute_received :rpc_called
  end

  test "stable missing report invokes readiness exactly N times and exits non-zero" do
    path = write_plan!(%{"task" => "grant"})
    on_exit(fn -> File.rm(path) end)

    test_pid = self()
    report = missing_report([@uri_a, @uri_b])

    rpc = fn node, module, function, args, timeout ->
      send(test_pid, {:rpc, node, module, function, args, timeout})

      case function do
        :coding_dispatch_readiness -> {:ok, report}
        :grant -> {:ok, %{id: "cap_test"}}
      end
    end

    args = ["--plan", path, "--agent-id", @agent_id, "--max-rounds", "2"]
    opts = runtime_opts(rpc)

    assert {:error, result} = Grant.execute(args, opts)
    assert result.status == :unconverged
    assert result.rounds == 2
    assert result.rounds <= 2
    assert Enum.map(result.remaining, & &1.uri) == [@uri_a, @uri_b]
    assert Enum.map(result.granted, & &1.uri) == [@uri_a, @uri_b]
    assert result.granted == [caller_target(@uri_a), caller_target(@uri_b)]

    rpcs = collect_rpcs([])

    readiness =
      Enum.filter(rpcs, fn {_n, _m, fun, _a, _t} -> fun == :coding_dispatch_readiness end)

    grants = Enum.filter(rpcs, fn {_n, _m, fun, _a, _t} -> fun == :grant end)

    assert length(readiness) == 2
    assert length(grants) == 2

    assert {:shutdown, 1} = catch_exit(Grant.run(args, opts))
    assert_received {:mix_shell, :error, [output]}
    assert output =~ @uri_a
    assert output =~ @uri_b
  end

  test "dry-run emits every round's URIs without dedupe and never grants" do
    path = write_plan!(%{"task" => "grant"})
    on_exit(fn -> File.rm(path) end)

    test_pid = self()
    report = missing_report([@uri_a, @uri_a, @uri_b])

    rpc = fn node, module, function, args, timeout ->
      send(test_pid, {:rpc, node, module, function, args, timeout})

      case function do
        :coding_dispatch_readiness -> {:ok, report}
        :grant -> flunk("dry-run must not grant")
      end
    end

    assert {:error, result} =
             Grant.execute(
               ["--plan", path, "--agent-id", @agent_id, "--max-rounds", "2", "--dry-run"],
               runtime_opts(rpc)
             )

    assert result.status == :unconverged
    assert result.rounds == 2
    assert result.granted == []

    assert result.remaining == [
             caller_target(@uri_a),
             caller_target(@uri_a),
             caller_target(@uri_b)
           ]

    rpcs = collect_rpcs([])
    assert Enum.all?(rpcs, fn {_n, _m, fun, _a, _t} -> fun == :coding_dispatch_readiness end)
    assert length(rpcs) == 2

    infos = collect_infos([])
    named = Enum.filter(infos, &String.contains?(&1, @uri_a))
    assert length(named) == 2

    expected_emit =
      """
      authenticated_caller (#{@caller}):
      #{@uri_a}
      #{@uri_a}
      #{@uri_b}
      """
      |> String.trim_trailing()

    Enum.each(named, fn text ->
      assert text == expected_emit
    end)
  end

  test "injecting only rpc_call proves one discovery and exact facade RPCs" do
    path = write_plan!(%{"kind" => "coding_change", "task" => "grant-loop"})
    on_exit(fn -> File.rm(path) end)

    test_pid = self()
    readiness_n = :atomics.new(1, [])

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
      rpc_call: fn node, module, function, args, timeout ->
        send(test_pid, {:rpc, node, module, function, args, timeout})

        case function do
          :coding_dispatch_readiness ->
            n = :atomics.add_get(readiness_n, 1, 1)

            if n == 1 do
              {:ok, missing_report([@uri_a])}
            else
              {:ok, missing_report([])}
            end

          :grant ->
            {:ok, %{id: "cap_granted"}}
        end
      end
    ]

    assert {:ok, result} =
             Grant.execute(["--plan", path, "--agent-id", @agent_id], opts)

    assert result.status == :converged
    assert Enum.map(result.granted, & &1.uri) == [@uri_a]
    assert result.granted == [caller_target(@uri_a)]

    assert_received :discovered_dist
    assert_received :discovered_running
    assert_received :discovered_target
    refute_received :discovered_dist
    refute_received :discovered_running
    refute_received :discovered_target

    rpcs = collect_rpcs([])

    assert [
             {@target, Arbor.Agent, :coding_dispatch_readiness,
              [@caller, @agent_id, %{"kind" => "coding_change", "task" => "grant-loop"}, []],
              60_000},
             {@target, Arbor.Security, :grant, [[principal: @caller, resource: @uri_a]], 15_000},
             {@target, Arbor.Agent, :coding_dispatch_readiness,
              [@caller, @agent_id, %{"kind" => "coding_change", "task" => "grant-loop"}, []],
              60_000}
           ] = rpcs
  end

  test "later readiness RPC failure preserves granted progress" do
    path = write_plan!(%{"task" => "grant"})
    on_exit(fn -> File.rm(path) end)

    test_pid = self()
    readiness_n = :atomics.new(1, [])

    opts =
      runtime_opts(fn node, module, function, args, timeout ->
        send(test_pid, {:rpc, node, module, function, args, timeout})

        case function do
          :coding_dispatch_readiness ->
            n = :atomics.add_get(readiness_n, 1, 1)

            if n == 1 do
              {:ok, missing_report([@uri_a])}
            else
              {:badrpc, :timeout}
            end

          :grant ->
            {:ok, %{id: "cap_granted"}}
        end
      end)

    assert {:error, result} = Grant.execute(["--plan", path, "--agent-id", @agent_id], opts)
    assert result.status == :malformed_report
    assert result.granted == [caller_target(@uri_a)]
    assert result.rounds == 2
    assert result.failed == []

    rpcs = collect_rpcs([])
    grants = Enum.filter(rpcs, fn {_n, _m, fun, _a, _t} -> fun == :grant end)
    assert length(grants) == 1
  end

  @tag :security_regression
  test "security regression: valid then malformed sibling produces no grant RPC" do
    path = write_plan!(%{"task" => "grant"})
    on_exit(fn -> File.rm(path) end)

    report =
      %{
        "caller_id" => @caller,
        "planes" => %{
          "executor" => %{
            "details" => %{
              "projection" => %{
                "authority_horizon" => %{
                  "findings" => [
                    %{
                      "principal_role" => "authenticated_caller",
                      "classification" => "missing",
                      "resource_uris" => [@uri_a]
                    },
                    "not-a-map"
                  ],
                  "required_resources" => [],
                  "principals" => [
                    %{"role" => "authenticated_caller", "principal_id" => @caller}
                  ]
                }
              }
            }
          }
        }
      }

    opts =
      runtime_opts(fn _node, _mod, function, _args, _timeout ->
        case function do
          :coding_dispatch_readiness -> {:ok, report}
          :grant -> flunk("malformed sibling must not produce a grant RPC")
        end
      end)

    assert {:error, result} = Grant.execute(["--plan", path, "--agent-id", @agent_id], opts)
    assert result.status == :malformed_report
    assert result.granted == []
  end

  test "run exits non-zero on unconverged halt" do
    path = write_plan!(%{"task" => "grant"})
    on_exit(fn -> File.rm(path) end)

    opts =
      runtime_opts(fn _node, _mod, fun, _args, _timeout ->
        case fun do
          :coding_dispatch_readiness -> {:ok, missing_report([@uri_a])}
          :grant -> {:ok, %{}}
        end
      end)

    assert {:shutdown, 1} =
             catch_exit(
               Grant.run(
                 ["--plan", path, "--agent-id", @agent_id, "--max-rounds", "1"],
                 opts
               )
             )
  end

  test "per-role summary grants execution-principal URIs to the coordinator" do
    path = write_plan!(%{"task" => "grant"})
    on_exit(fn -> File.rm(path) end)

    test_pid = self()
    readiness_n = :atomics.new(1, [])
    exec_uri = "arbor://action/coding/design_council_review"

    opts =
      runtime_opts(fn node, module, function, args, timeout ->
        send(test_pid, {:rpc, node, module, function, args, timeout})

        case function do
          :coding_dispatch_readiness ->
            n = :atomics.add_get(readiness_n, 1, 1)

            if n == 1 do
              {:ok, exec_missing_report(exec_uri, @agent_id)}
            else
              {:ok, exec_missing_report_empty(@agent_id)}
            end

          :grant ->
            {:ok, %{id: "cap_exec"}}
        end
      end)

    args = ["--plan", path, "--agent-id", @agent_id]
    assert {:ok, result} = Grant.execute(args, opts)
    assert result.status == :converged
    assert result.granted == [exec_target(exec_uri, @agent_id)]

    rpcs = collect_rpcs([])

    assert Enum.any?(rpcs, fn
             {_n, Arbor.Security, :grant, [[principal: @agent_id, resource: ^exec_uri]], 15_000} ->
               true

             _other ->
               false
           end)

    refute Enum.any?(rpcs, fn
             {_n, Arbor.Security, :grant, [[principal: @caller, resource: ^exec_uri]], _t} ->
               true

             _other ->
               false
           end)

    shown = CodingGrantCore.show(result)
    assert shown =~ "execution_principal"
    assert shown =~ @agent_id
    assert shown =~ exec_uri

    run_n = :atomics.new(1, [])

    run_opts =
      runtime_opts(fn _node, _mod, function, _args, _timeout ->
        case function do
          :coding_dispatch_readiness ->
            n = :atomics.add_get(run_n, 1, 1)

            if n == 1 do
              {:ok, exec_missing_report(exec_uri, @agent_id)}
            else
              {:ok, exec_missing_report_empty(@agent_id)}
            end

          :grant ->
            {:ok, %{id: "cap_exec"}}
        end
      end)

    assert :ok = Grant.run(args, run_opts)
    assert_received {:mix_shell, :info, [output]}
    assert output =~ "execution_principal"
    assert output =~ @agent_id
    assert output =~ exec_uri
  end

  test "refuses to grant a URI to a principal the CLI invocation did not name" do
    path = write_plan!(%{"task" => "grant"})
    on_exit(fn -> File.rm(path) end)

    other = "agent_other_named"
    exec_uri = "arbor://action/coding/design_council_review"

    opts =
      runtime_opts(fn _node, _mod, function, _args, _timeout ->
        case function do
          :coding_dispatch_readiness -> {:ok, exec_missing_report(exec_uri, other)}
          :grant -> flunk("must not grant to an unnamed principal")
        end
      end)

    assert {:error, result} = Grant.execute(["--plan", path, "--agent-id", @agent_id], opts)
    assert result.status == :grant_failed
    assert result.failed == [{exec_target(exec_uri, other), :unnamed_principal}]
    assert result.granted == []
  end

  test "after capability convergence calls Trust facade with exact arguments" do
    path = write_plan!(%{"task" => "grant"})
    on_exit(fn -> File.rm(path) end)

    test_pid = self()
    exec_uri = "arbor://action/coding/design_council_review"

    src =
      Path.expand("../../../lib/mix/tasks/arbor.coding.grant.ex", __DIR__)
      |> File.read!()

    refute src =~ "Arbor.Trust.Store"
    refute src =~ "Arbor.Trust.Authority"
    refute src =~ "reason: :principal_mismatch"

    opts =
      runtime_opts(fn node, module, function, args, timeout ->
        send(test_pid, {:rpc, node, module, function, args, timeout})

        case {module, function} do
          {Arbor.Agent, :coding_dispatch_readiness} ->
            {:ok, converged_coding_report(exec_uri, @agent_id)}

          {Arbor.Trust, :get_trust_profile} ->
            {:ok, %{rules: %{"arbor://action/coding/reviewed_commit" => :auto}}}

          {Arbor.Trust, :explain} ->
            %{effective_mode: :block, user_match: nil}

          {Arbor.Trust, :set_rule} ->
            {:ok, %{}}

          {_mod, :grant} ->
            flunk("already-granted converging report must not grant")
        end
      end)

    assert {:ok, result} = Grant.execute(["--plan", path, "--agent-id", @agent_id], opts)
    assert result.status == :converged
    assert result.granted == []

    rpcs = collect_rpcs([])

    assert [
             {@target, Arbor.Agent, :coding_dispatch_readiness, [_caller, @agent_id, _plan, []],
              60_000},
             {@target, Arbor.Trust, :get_trust_profile, [@agent_id], 15_000},
             {@target, Arbor.Trust, :explain, [@agent_id, ^exec_uri], 15_000},
             {@target, Arbor.Trust, :set_rule, [@agent_id, ^exec_uri, :auto], 15_000}
           ] = rpcs

    refute Enum.any?(rpcs, fn
             {_n, Arbor.Trust, :set_rule, [principal, _uri, _mode], _t} ->
               principal != @agent_id

             _other ->
               false
           end)
  end

  test "--no-trust-rules restores capability-only output and skips Trust RPCs" do
    path = write_plan!(%{"task" => "grant"})
    on_exit(fn -> File.rm(path) end)

    test_pid = self()
    exec_uri = "arbor://action/coding/design_council_review"

    opts =
      runtime_opts(fn node, module, function, args, timeout ->
        send(test_pid, {:rpc, node, module, function, args, timeout})

        case {module, function} do
          {Arbor.Agent, :coding_dispatch_readiness} ->
            {:ok, converged_coding_report(exec_uri, @agent_id)}

          {Arbor.Trust, _fun} ->
            flunk(" --no-trust-rules must not call Arbor.Trust")
        end
      end)

    assert {:ok, result} =
             Grant.execute(
               ["--plan", path, "--agent-id", @agent_id, "--no-trust-rules"],
               opts
             )

    assert result.status == :converged
    refute Map.has_key?(result, :trust)

    assert CodingGrantCore.show(result) ==
             """
             coding grant: converged
             rounds: 1
             granted: (none)
             failed: (none)
             remaining: (none)
             """
             |> String.trim_trailing()

    rpcs = collect_rpcs([])
    assert Enum.all?(rpcs, fn {_n, _m, fun, _a, _t} -> fun == :coding_dispatch_readiness end)
  end

  test "dry-run lists would-install trust rules and never calls set_rule" do
    path = write_plan!(%{"task" => "grant"})
    on_exit(fn -> File.rm(path) end)

    test_pid = self()
    exec_uri = "arbor://action/coding/design_council_review"

    opts =
      runtime_opts(fn node, module, function, args, timeout ->
        send(test_pid, {:rpc, node, module, function, args, timeout})

        case {module, function} do
          {Arbor.Agent, :coding_dispatch_readiness} ->
            {:ok, converged_coding_report(exec_uri, @agent_id)}

          {Arbor.Trust, :get_trust_profile} ->
            {:ok, %{rules: %{"arbor://action/coding/reviewed_commit" => :auto}}}

          {Arbor.Trust, :explain} ->
            %{effective_mode: :block, user_match: nil}

          {Arbor.Trust, :set_rule} ->
            flunk("dry-run must not set_rule")

          {_mod, :grant} ->
            flunk("dry-run must not grant")
        end
      end)

    args = ["--plan", path, "--agent-id", @agent_id, "--dry-run"]
    assert {:ok, result} = Grant.execute(args, opts)
    assert result.status == :converged

    rpcs = collect_rpcs([])
    refute Enum.any?(rpcs, fn {_n, _m, fun, _a, _t} -> fun == :set_rule end)
    refute Enum.any?(rpcs, fn {_n, _m, fun, _a, _t} -> fun == :grant end)

    assert Enum.any?(rpcs, fn
             {_n, Arbor.Trust, :explain, _a, _t} -> true
             _other -> false
           end)

    assert Enum.any?(rpcs, fn
             {_n, Arbor.Trust, :get_trust_profile, _a, _t} -> true
             _other -> false
           end)

    shown = CodingGrantTrustCore.show(result.trust)
    assert shown =~ "would install"
    assert shown =~ exec_uri

    assert :ok = Grant.run(args, opts)
    infos = collect_infos([])
    assert Enum.any?(infos, &String.contains?(&1, "would install"))
    assert Enum.any?(infos, &String.contains?(&1, exec_uri))
  end

  @tag :security_regression
  test "security regression: recorded 2026-08-31 capabilities granted and trust rule absent installs :auto for design_council_review only" do
    path = write_plan!(%{"task" => "grant"})
    on_exit(fn -> File.rm(path) end)

    test_pid = self()
    exec_uri = "arbor://action/coding/design_council_review"

    opts =
      runtime_opts(fn node, module, function, args, timeout ->
        send(test_pid, {:rpc, node, module, function, args, timeout})

        case {module, function} do
          {Arbor.Agent, :coding_dispatch_readiness} ->
            {:ok, converged_coding_report(exec_uri, @agent_id)}

          {Arbor.Trust, :get_trust_profile} ->
            {:ok,
             %{
               rules: %{
                 "arbor://action/coding/reviewed_commit" => :auto,
                 "arbor://action/coding/workspace" => :auto
               }
             }}

          {Arbor.Trust, :explain} ->
            %{effective_mode: :block, user_match: nil}

          {Arbor.Trust, :set_rule} ->
            {:ok, %{}}
        end
      end)

    assert {:ok, result} = Grant.execute(["--plan", path, "--agent-id", @agent_id], opts)
    assert result.status == :converged

    rpcs = collect_rpcs([])
    set_rules = Enum.filter(rpcs, fn {_n, _m, fun, _a, _t} -> fun == :set_rule end)

    assert set_rules == [
             {@target, Arbor.Trust, :set_rule, [@agent_id, exec_uri, :auto], 15_000}
           ]
  end

  test "invalid_input from trust decide prints the reason and exits non-zero" do
    path = write_plan!(%{"task" => "grant"})
    on_exit(fn -> File.rm(path) end)

    exec_uri = "arbor://action/coding/design_council_review"

    opts =
      runtime_opts(fn _node, module, function, _args, _timeout ->
        case {module, function} do
          {Arbor.Agent, :coding_dispatch_readiness} ->
            {:ok, converged_coding_report(exec_uri, @agent_id)}

          {Arbor.Trust, :get_trust_profile} ->
            {:ok, %{rules: :not_a_map}}

          {Arbor.Trust, :explain} ->
            %{effective_mode: :block, user_match: nil}

          {Arbor.Trust, :set_rule} ->
            flunk("invalid_input must not set_rule")

          {_mod, :grant} ->
            flunk("already-granted converging report must not grant")
        end
      end)

    args = ["--plan", path, "--agent-id", @agent_id]

    assert {:error, result} = Grant.execute(args, opts)
    assert result.status == :converged
    assert result.trust == {:error, :invalid_input}

    assert {:shutdown, 1} = catch_exit(Grant.run(args, opts))

    output =
      collect_infos([])
      |> Kernel.++(collect_errors([]))
      |> Enum.join("\n")

    assert output =~ "coding grant: converged"
    assert output =~ "invalid_input"
  end

  defp runtime_opts(rpc) do
    [
      caller_resolver: fn _cli -> {:ok, @caller} end,
      ensure_distribution: fn -> :ok end,
      server_running?: fn -> true end,
      target_node: fn -> @target end,
      rpc_call: rpc
    ]
  end

  defp caller_target(uri, principal_id \\ @caller) do
    %{principal_role: "authenticated_caller", principal_id: principal_id, uri: uri}
  end

  defp exec_target(uri, principal_id) do
    %{principal_role: "execution_principal", principal_id: principal_id, uri: uri}
  end

  defp missing_report(uris) do
    %{
      "caller_id" => @caller,
      "agent_id" => @agent_id,
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
                "required_resources" => [],
                "principals" => [
                  %{"role" => "authenticated_caller", "principal_id" => @caller},
                  %{"role" => "execution_principal", "principal_id" => @agent_id}
                ]
              }
            }
          }
        }
      }
    }
  end

  defp exec_missing_report(uri, coordinator_id) do
    %{
      "caller_id" => @caller,
      "agent_id" => coordinator_id,
      "planes" => %{
        "executor" => %{
          "details" => %{
            "projection" => %{
              "authority_horizon" => %{
                "findings" => [
                  %{
                    "principal_role" => "execution_principal",
                    "classification" => "missing",
                    "total_count" => 1,
                    "resource_uris" => [uri],
                    "resource_uris_digest" => "sha256:" <> String.duplicate("ab", 32)
                  }
                ],
                "required_resources" => %{
                  "total_count" => 1,
                  "resource_uris" => [uri],
                  "resource_uris_digest" => "sha256:" <> String.duplicate("ab", 32)
                },
                "principals" => [
                  %{"role" => "execution_principal", "principal_id" => coordinator_id},
                  %{"role" => "authenticated_caller", "principal_id" => @caller}
                ]
              }
            }
          }
        }
      }
    }
  end

  defp converged_coding_report(uri, coordinator_id) do
    %{
      "caller_id" => @caller,
      "agent_id" => coordinator_id,
      "planes" => %{
        "executor" => %{
          "details" => %{
            "projection" => %{
              "authority_horizon" => %{
                "findings" => [],
                "required_resources" => %{
                  "total_count" => 1,
                  "resource_uris" => [uri],
                  "resource_uris_digest" => "sha256:" <> String.duplicate("ab", 32)
                },
                "principals" => [
                  %{"role" => "execution_principal", "principal_id" => coordinator_id},
                  %{"role" => "authenticated_caller", "principal_id" => @caller}
                ]
              }
            }
          }
        }
      }
    }
  end

  defp exec_missing_report_empty(coordinator_id) do
    %{
      "caller_id" => @caller,
      "agent_id" => coordinator_id,
      "planes" => %{
        "executor" => %{
          "details" => %{
            "projection" => %{
              "authority_horizon" => %{
                "findings" => [],
                "required_resources" => [],
                "principals" => [
                  %{"role" => "execution_principal", "principal_id" => coordinator_id},
                  %{"role" => "authenticated_caller", "principal_id" => @caller}
                ]
              }
            }
          }
        }
      }
    }
  end

  defp write_plan!(plan) do
    path = Path.join(System.tmp_dir!(), "coding-grant-#{System.unique_integer([:positive])}.json")
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

  defp collect_errors(acc) do
    receive do
      {:mix_shell, :error, [text]} -> collect_errors([text | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
