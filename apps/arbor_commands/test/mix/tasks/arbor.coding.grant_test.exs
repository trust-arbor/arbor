defmodule Mix.Tasks.Arbor.Coding.GrantTest do
  use ExUnit.Case, async: true

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

    assert doc =~ "every round invokes readiness"
    assert doc =~ "emits the full list of"
    assert doc =~ "caller URIs named that round (no dedupe)"
    assert doc =~ "never emits a grant"
    assert doc =~ "halts converged only when a report names nothing"
    assert doc =~ "unconverged at max-rounds"
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
    assert result.remaining == [@uri_a, @uri_b]
    assert result.granted == [@uri_a, @uri_b]

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
    assert result.remaining == [@uri_a, @uri_a, @uri_b]

    rpcs = collect_rpcs([])
    assert Enum.all?(rpcs, fn {_n, _m, fun, _a, _t} -> fun == :coding_dispatch_readiness end)
    assert length(rpcs) == 2

    infos = collect_infos([])
    named = Enum.filter(infos, &String.contains?(&1, @uri_a))
    assert length(named) == 2

    Enum.each(named, fn text ->
      assert text == Enum.join([@uri_a, @uri_a, @uri_b], "\n")
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
    assert result.granted == [@uri_a]

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

  defp runtime_opts(rpc) do
    [
      caller_resolver: fn _cli -> {:ok, @caller} end,
      ensure_distribution: fn -> :ok end,
      server_running?: fn -> true end,
      target_node: fn -> @target end,
      rpc_call: rpc
    ]
  end

  defp missing_report(uris) do
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
end
