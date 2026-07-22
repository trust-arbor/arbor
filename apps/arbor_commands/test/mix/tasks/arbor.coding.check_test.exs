defmodule Mix.Tasks.Arbor.Coding.CheckTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.Plan
  alias Mix.Tasks.Arbor.Coding.Check

  @moduletag :fast

  @observed_at "2026-07-22T12:00:00Z"

  test "rejects conflicting modes before reading the plan" do
    assert {:error, error} = Check.execute(["--plan", "missing.json", "--static", "--live"])
    assert error == command_error("mode", "conflicting_modes")
  end

  test "reports a missing plan as a bounded command error" do
    assert {:error, error} = Check.execute(["--plan", "missing-coding-plan.json", "--json"])

    assert error == command_error("plan", "not_found")
    refute inspect(error) =~ "missing-coding-plan"
  end

  test "reports malformed JSON without exposing file contents" do
    path =
      Path.join(
        System.tmp_dir!(),
        "coding-check-invalid-#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, ~s({"task": "unterminated))
    on_exit(fn -> File.rm(path) end)

    assert {:error, error} = Check.execute(["--plan", path])
    assert error == command_error("plan", "invalid_json")
  end

  test "invalid contract data is evaluated through the public readiness seam" do
    path = write_plan!(%{"task" => "missing worker", "repo_root" => "/tmp"})
    on_exit(fn -> File.rm(path) end)

    test_pid = self()

    checker = fn raw_plan, opts ->
      send(test_pid, {:readiness_called, raw_plan, opts})
      {:ok, report("blocked", "plan_invalid")}
    end

    assert {:ok, result} =
             Check.execute(
               ["--plan", path, "--static"],
               readiness_checker: checker,
               mode: :live,
               observed_at: @observed_at
             )

    assert_receive {:readiness_called, %{"task" => "missing worker"}, opts}
    assert opts == [mode: :static, observed_at: @observed_at]
    assert result["status"] == "blocked"
    assert Check.exit_code(result["status"]) == 1
  end

  test "canonicalizes a valid plan and returns a JSON-clean report" do
    path = write_plan!(Plan.to_map(valid_plan!()))
    on_exit(fn -> File.rm(path) end)

    checker = fn plan, opts ->
      assert is_map(plan)
      assert plan["version"] == 1
      assert plan["worker"]["provider"] == "grok"
      assert opts == [mode: :static, observed_at: @observed_at]
      {:ok, report("degraded", "acp_health_unavailable")}
    end

    assert {:ok, result} =
             Check.execute(
               ["--plan", path, "--static", "--json"],
               readiness_checker: checker,
               mode: :live,
               observed_at: @observed_at
             )

    assert {:ok, json} = Jason.encode(result)
    assert {:ok, decoded} = Jason.decode(json)
    assert decoded == result
    assert Map.keys(result) == ["diagnostics", "observed_at", "plan_digest", "status", "version"]
    assert Check.exit_code(result["status"]) == 0
  end

  test "live mode reports a bounded error when no target is running" do
    path = write_plan!(Plan.to_map(valid_plan!()))
    on_exit(fn -> File.rm(path) end)

    assert {:error, error} =
             Check.execute(
               ["--plan", path, "--live", "--json"],
               ensure_distribution: fn -> :ok end,
               server_running?: fn -> false end
             )

    assert error == command_error("live", "target_unavailable_start_server_or_use_static")
  end

  test "explicit live mode passes code-owned live mode over RPC" do
    path = write_plan!(Plan.to_map(valid_plan!()))
    on_exit(fn -> File.rm(path) end)

    test_pid = self()

    rpc = fn target, module, function, [plan, opts], timeout ->
      send(test_pid, {:rpc_called, target, module, function, plan, opts, timeout})
      {:ok, report("ready", "live_checks_passed")}
    end

    assert {:ok, result} =
             Check.execute(
               ["--plan", path, "--live"],
               ensure_distribution: fn -> :ok end,
               server_running?: fn -> true end,
               target_node: fn -> :arbor_test@localhost end,
               rpc_call: rpc,
               mode: :static,
               observed_at: @observed_at
             )

    assert_receive {:rpc_called, :arbor_test@localhost, Arbor.Orchestrator,
                    :check_coding_readiness, _plan, [mode: :live, observed_at: @observed_at],
                    5_000}

    assert result["status"] == "ready"
  end

  test "auto mode uses RPC when the established target is running" do
    path = write_plan!(Plan.to_map(valid_plan!()))
    on_exit(fn -> File.rm(path) end)

    test_pid = self()

    rpc = fn target, module, function, [plan, opts], timeout ->
      send(test_pid, {:rpc_called, target, module, function, plan, opts, timeout})
      {:ok, report("ready", "plan_valid")}
    end

    assert {:ok, result} =
             Check.execute(
               ["--plan", path],
               ensure_distribution: fn -> :ok end,
               server_running?: fn -> true end,
               target_node: fn -> :arbor_test@localhost end,
               rpc_call: rpc,
               mode: :static,
               observed_at: @observed_at
             )

    assert_receive {:rpc_called, :arbor_test@localhost, Arbor.Orchestrator,
                    :check_coding_readiness, plan, [mode: :live, observed_at: @observed_at],
                    5_000}

    assert plan["repo_root"] == valid_plan!().repo_root
    assert result["status"] == "ready"
  end

  test "auto mode falls back locally with code-owned static mode" do
    path = write_plan!(Plan.to_map(valid_plan!()))
    on_exit(fn -> File.rm(path) end)

    test_pid = self()

    checker = fn plan, opts ->
      send(test_pid, {:readiness_called, plan, opts})
      {:ok, report("degraded", "acp_health_unavailable")}
    end

    assert {:ok, result} =
             Check.execute(
               ["--plan", path],
               ensure_distribution: fn -> :ok end,
               server_running?: fn -> false end,
               readiness_checker: checker,
               mode: :live,
               observed_at: @observed_at
             )

    assert_receive {:readiness_called, _plan, [mode: :static, observed_at: @observed_at]}
    assert result["status"] == "degraded"
  end

  test "run exits nonzero and emits valid JSON for a blocked report" do
    path = write_plan!(%{"task" => "missing worker", "repo_root" => "/tmp"})
    on_exit(fn -> File.rm(path) end)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert catch_exit(Check.run(["--plan", path, "--static", "--json"])) ==
                 {:shutdown, 1}
      end)

    assert {:ok, report} = Jason.decode(String.trim(output))
    assert report["status"] == "blocked"
    assert length(report["diagnostics"]) == 1
  end

  test "json command errors have canonical deterministic bytes" do
    missing =
      Path.join(
        System.tmp_dir!(),
        "coding-check-missing-#{System.unique_integer([:positive])}.json"
      )

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert catch_exit(Check.run(["--plan", missing, "--json"])) == {:shutdown, 1}
      end)

    assert output ==
             ~s({"error":"invalid_arbor_coding_check_command","field":"plan","reason":"not_found"}\n)
  end

  defp valid_plan! do
    {:ok, plan} =
      Plan.new(%{
        "task" => "Check coding readiness",
        "repo_root" => "/tmp",
        "worker" => %{"provider" => "grok"}
      })

    plan
  end

  defp report(status, code) do
    %{
      "version" => 1,
      "status" => status,
      "plan_digest" => "sha256:diagnostic-test",
      "observed_at" => @observed_at,
      "diagnostics" => [
        %{
          "version" => 1,
          "gate_id" => "plan_schema",
          "phase" => "preflight",
          "decision" => if(status == "blocked", do: "blocked", else: "unavailable"),
          "code" => code,
          "observed_at" => @observed_at,
          "remediation" => "Use the reviewed coding plan and retry."
        }
      ]
    }
  end

  defp write_plan!(plan) do
    path = Path.join(System.tmp_dir!(), "coding-check-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(plan))
    path
  end

  defp command_error(field, reason) do
    %{
      "error" => "invalid_arbor_coding_check_command",
      "field" => field,
      "reason" => reason
    }
  end
end
