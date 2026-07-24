defmodule Mix.Tasks.Arbor.Coding.CheckTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.{Plan, WorkPacket}
  alias Mix.Tasks.Arbor.Coding.Check

  @moduletag :fast

  @observed_at "2026-07-22T12:00:00Z"
  @agent_id "agent_operator_readiness_test"
  @task_id "task_operator_verification_test"
  @workspace_id "workspace_operator_verification_test"

  test "rejects conflicting modes before reading the plan" do
    assert {:error, error} = Check.execute(["--plan", "missing.json", "--static", "--live"])
    assert error == command_error("mode", "conflicting_modes")
  end

  test "verification rejects static mode before reading the plan" do
    assert {:error, error} =
             Check.execute(["--verify", "--plan", "missing.json", "--static"])

    assert error == command_error("mode", "verification_is_live")
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
      assert plan["version"] == 2
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
               ["--plan", path, "--live", "--agent-id", @agent_id, "--json"],
               ensure_distribution: fn -> :ok end,
               server_running?: fn -> false end
             )

    assert error == command_error("live", "target_unavailable_start_server_or_use_static")
  end

  test "live mode requires an agent identity before attempting RPC" do
    path = write_plan!(Plan.to_map(valid_plan!()))
    on_exit(fn -> File.rm(path) end)

    rpc = fn _target, _module, _function, _args, _timeout ->
      send(self(), :rpc_called)
      {:ok, report("ready", "live_checks_passed")}
    end

    assert {:error, error} =
             Check.execute(
               ["--plan", path, "--live"],
               server_running?: fn -> true end,
               rpc_call: rpc
             )

    assert error == command_error("agent_id", "required")
    refute_received :rpc_called
  end

  test "invalid agent identities are rejected before attempting RPC" do
    path = write_plan!(Plan.to_map(valid_plan!()))
    on_exit(fn -> File.rm(path) end)

    rpc = fn _target, _module, _function, _args, _timeout ->
      send(self(), :rpc_called)
      {:ok, report("ready", "live_checks_passed")}
    end

    for invalid_agent_id <- [
          "agent_valid\n",
          "agent_valid" <> <<0>>,
          "agent_" <> String.duplicate("x", 251)
        ] do
      assert {:error, error} =
               Check.execute(
                 ["--plan", path, "--live", "--agent-id", invalid_agent_id],
                 server_running?: fn -> true end,
                 rpc_call: rpc
               )

      assert error == command_error("agent_id", "invalid")
    end

    refute_received :rpc_called
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
               ["--plan", path, "--live", "--agent-id", @agent_id],
               ensure_distribution: fn -> :ok end,
               server_running?: fn -> true end,
               target_node: fn -> :arbor_test@localhost end,
               rpc_call: rpc,
               mode: :static,
               observed_at: @observed_at
             )

    assert_receive {:rpc_called, :arbor_test@localhost, Arbor.Orchestrator,
                    :check_coding_readiness, _plan,
                    [mode: :live, agent_id: @agent_id, observed_at: @observed_at], 5_000}

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
               ["--plan", path, "--agent-id", @agent_id],
               ensure_distribution: fn -> :ok end,
               server_running?: fn -> true end,
               target_node: fn -> :arbor_test@localhost end,
               rpc_call: rpc,
               mode: :static,
               observed_at: @observed_at
             )

    assert_receive {:rpc_called, :arbor_test@localhost, Arbor.Orchestrator,
                    :check_coding_readiness, plan,
                    [mode: :live, agent_id: @agent_id, observed_at: @observed_at], 5_000}

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

  test "auto mode requires an agent identity when a live target is available" do
    path = write_plan!(Plan.to_map(valid_plan!()))
    on_exit(fn -> File.rm(path) end)

    rpc = fn _target, _module, _function, _args, _timeout ->
      send(self(), :rpc_called)
      {:ok, report("ready", "live_checks_passed")}
    end

    assert {:error, error} =
             Check.execute(
               ["--plan", path],
               ensure_distribution: fn -> :ok end,
               server_running?: fn -> true end,
               target_node: fn -> :arbor_test@localhost end,
               rpc_call: rpc
             )

    assert error == command_error("agent_id", "required")
    refute_received :rpc_called
  end

  test "static mode accepts and forwards a valid agent identity" do
    path = write_plan!(Plan.to_map(valid_plan!()))
    on_exit(fn -> File.rm(path) end)

    checker = fn _plan, opts ->
      assert opts == [mode: :static, agent_id: @agent_id, observed_at: @observed_at]
      {:ok, report("degraded", "acp_health_unavailable")}
    end

    assert {:ok, result} =
             Check.execute(
               ["--plan", path, "--static", "--agent-id", @agent_id],
               readiness_checker: checker,
               observed_at: @observed_at
             )

    assert result["status"] == "degraded"
  end

  test "verification sends only the closed request and uses a plan-derived RPC timeout" do
    path = write_plan!(Plan.to_map(valid_plan!("default", 12_000)))
    on_exit(fn -> File.rm(path) end)

    test_pid = self()

    rpc = fn target, module, function, [plan, request], timeout ->
      send(test_pid, {:verification_rpc, target, module, function, plan, request, timeout})
      {:ok, verification_report("default")}
    end

    assert {:ok, result} =
             Check.execute(
               [
                 "--verify",
                 "--plan",
                 path,
                 "--agent-id",
                 @agent_id,
                 "--task-id",
                 @task_id,
                 "--workspace-id",
                 @workspace_id
               ],
               ensure_distribution: fn -> :ok end,
               server_running?: fn -> true end,
               target_node: fn -> :arbor_test@localhost end,
               rpc_call: rpc,
               readiness_checker: fn _plan, _opts ->
                 send(test_pid, :readiness_fallback_called)
               end
             )

    assert_receive {:verification_rpc, :arbor_test@localhost, Arbor.Orchestrator,
                    :verify_coding_candidate_for_operator, plan, request, 22_000}

    assert plan["budgets"]["wall_clock_ms"] == 12_000

    assert request == %{
             "agent_id" => @agent_id,
             "task_id" => @task_id,
             "workspace_id" => @workspace_id
           }

    refute Enum.any?(
             ~w[action adapter authority candidate_tree_oid path private_key signing_authority timeout validation_program],
             &Map.has_key?(request, &1)
           )

    refute_received :readiness_fallback_called
    assert result["status"] == "passed"
    assert Check.exit_code(result["status"]) == 0
  end

  test "all verification profiles preserve reports and gate order in JSON and human modes" do
    for profile <- ~w[default cross_app security_regression] do
      path = write_plan!(Plan.to_map(valid_plan!(profile)))
      on_exit(fn -> File.rm(path) end)
      expected = verification_report(profile)
      expected_request = verification_request(profile)

      rpc = fn _target,
               Arbor.Orchestrator,
               :verify_coding_candidate_for_operator,
               [_plan, request],
               _timeout ->
        assert request == expected_request
        {:ok, expected}
      end

      base_args = [
        "--verify",
        "--plan",
        path,
        "--agent-id",
        @agent_id,
        "--task-id",
        @task_id,
        "--workspace-id",
        @workspace_id
      ]

      base_args =
        if profile == "security_regression" do
          base_args ++ ["--review-attestation-id", "review_attestation_command_test"]
        else
          base_args
        end

      runtime_opts = [
        ensure_distribution: fn -> :ok end,
        server_running?: fn -> true end,
        target_node: fn -> :arbor_test@localhost end,
        rpc_call: rpc
      ]

      assert {:ok, human_report} = Check.execute(base_args, runtime_opts)
      assert {:ok, json_report} = Check.execute(base_args ++ ["--json"], runtime_opts)

      assert human_report == expected
      assert json_report == expected

      assert Enum.map(human_report["diagnostics"], & &1["gate_id"]) ==
               expected_gate_ids(profile)

      human_output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok = Check.run(base_args, runtime_opts)
        end)

      assert human_output =~ "Coding verification: PASSED"

      for gate_id <- expected_gate_ids(profile) do
        assert human_output =~ gate_id
      end

      json_output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok = Check.run(base_args ++ ["--json"], runtime_opts)
        end)

      assert Jason.decode!(String.trim(json_output)) == expected
    end
  end

  test "verification never falls back to static readiness" do
    path = write_plan!(Plan.to_map(valid_plan!()))
    on_exit(fn -> File.rm(path) end)
    test_pid = self()

    assert {:error, error} =
             Check.execute(
               [
                 "--verify",
                 "--plan",
                 path,
                 "--agent-id",
                 @agent_id,
                 "--task-id",
                 @task_id,
                 "--workspace-id",
                 @workspace_id
               ],
               ensure_distribution: fn -> :ok end,
               server_running?: fn -> false end,
               readiness_checker: fn _plan, _opts ->
                 send(test_pid, :readiness_fallback_called)
                 {:ok, report("ready", "must_not_run")}
               end
             )

    assert error == command_error("verification", "target_unavailable_start_server")
    refute_received :readiness_fallback_called
  end

  test "default verification transport completes through a cancellable remote process" do
    path = write_plan!(Plan.to_map(valid_plan!()))
    on_exit(fn -> File.rm(path) end)

    assert {:error, error} =
             Check.execute(
               [
                 "--verify",
                 "--plan",
                 path,
                 "--agent-id",
                 "agent_without_a_signing_key",
                 "--task-id",
                 @task_id,
                 "--workspace-id",
                 @workspace_id
               ],
               ensure_distribution: fn -> :ok end,
               server_running?: fn -> true end,
               target_node: fn -> node() end
             )

    assert error == command_error("verification", "check_failed")
  end

  test "security regression: timeout cancels through requester death before remote PID is known" do
    test_pid = self()

    spawn_request = fn _target,
                       Arbor.Orchestrator,
                       :verify_coding_candidate_for_operator_rpc,
                       [requester, reply_to, correlation_id, _plan, _request],
                       [:monitor] ->
      spawn(fn ->
        monitor = Process.monitor(requester)
        send(test_pid, {:unknown_pid_remote_started, requester})

        receive do
          {:DOWN, ^monitor, :process, ^requester, _reason} ->
            send(test_pid, :unknown_pid_requester_down)

            send(
              reply_to,
              {:arbor_operator_candidate_verification_rpc_cancelled, correlation_id, :ok}
            )
        end
      end)

      make_ref()
    end

    assert {:badrpc, :timeout} =
             Check.cancellable_verification_rpc(
               node(),
               Arbor.Orchestrator,
               :verify_coding_candidate_for_operator,
               [%{}, %{}],
               50,
               spawn_request
             )

    assert_receive {:unknown_pid_remote_started, requester}
    assert_receive :unknown_pid_requester_down
    refute Process.alive?(requester)
  end

  test "verification requires task, workspace, and agent identities" do
    path = write_plan!(Plan.to_map(valid_plan!()))
    on_exit(fn -> File.rm(path) end)

    required = [
      {"--agent-id", @agent_id, "agent_id"},
      {"--task-id", @task_id, "task_id"},
      {"--workspace-id", @workspace_id, "workspace_id"}
    ]

    for missing <- required do
      {_flag, _value, missing_field} = missing

      args =
        ["--verify", "--plan", path] ++
          (required
           |> List.delete(missing)
           |> Enum.flat_map(fn {flag, value, _field} -> [flag, value] end))

      assert {:error, error} = Check.execute(args)
      assert error == command_error(missing_field, "required")
    end
  end

  test "verification rejects reports carrying authority fields" do
    path = write_plan!(Plan.to_map(valid_plan!()))
    on_exit(fn -> File.rm(path) end)

    rpc = fn _target, _module, _function, _args, _timeout ->
      {:ok, Map.put(verification_report("default"), "signing_authority", "forbidden")}
    end

    assert {:error, error} =
             Check.execute(
               [
                 "--verify",
                 "--plan",
                 path,
                 "--agent-id",
                 @agent_id,
                 "--task-id",
                 @task_id,
                 "--workspace-id",
                 @workspace_id
               ],
               ensure_distribution: fn -> :ok end,
               server_running?: fn -> true end,
               target_node: fn -> :arbor_test@localhost end,
               rpc_call: rpc
             )

    assert error == command_error("verification", "invalid_report")
  end

  test "verification failed and blocked reports exit nonzero" do
    for status <- ~w[failed blocked] do
      path = write_plan!(Plan.to_map(valid_plan!()))
      on_exit(fn -> File.rm(path) end)

      rpc = fn _target, _module, _function, _args, _timeout ->
        {:ok, Map.put(verification_report("default"), "status", status)}
      end

      args = [
        "--verify",
        "--plan",
        path,
        "--agent-id",
        @agent_id,
        "--task-id",
        @task_id,
        "--workspace-id",
        @workspace_id
      ]

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert catch_exit(
                   Check.run(
                     args,
                     ensure_distribution: fn -> :ok end,
                     server_running?: fn -> true end,
                     target_node: fn -> :arbor_test@localhost end,
                     rpc_call: rpc
                   )
                 ) == {:shutdown, 1}
        end)

      assert output =~ "Coding verification: #{String.upcase(status)}"
      assert Check.exit_code(status) == 1
    end
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

  test "missing live identity has canonical JSON error bytes" do
    path = write_plan!(Plan.to_map(valid_plan!()))
    on_exit(fn -> File.rm(path) end)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert catch_exit(Check.run(["--plan", path, "--live", "--json"])) ==
                 {:shutdown, 1}
      end)

    assert output ==
             ~s({"error":"invalid_arbor_coding_check_command","field":"agent_id","reason":"required"}\n)
  end

  defp valid_plan!(profile \\ "default", wall_clock_ms \\ 900_000) do
    work_packet = %{
      "version" => 1,
      "success_criteria" => ["verification command reports canonical status"],
      "non_goals" => ["execute coding work"],
      "constraints" => ["send only closed operator request fields"],
      "architecture_refs" => [
        "apps/arbor_commands/lib/mix/tasks/arbor.coding.check.ex"
      ],
      "required_evidence" => ["verification report"],
      "checkpoint_policy" => "direct"
    }

    {:ok, work_packet_digest} = WorkPacket.digest(work_packet)

    attrs = %{
      "version" => 2,
      "task" => "Check coding readiness",
      "repo_root" => "/tmp",
      "worker" => %{"provider" => "grok"},
      "validation_profile" => profile,
      "budgets" => %{"wall_clock_ms" => wall_clock_ms},
      "work_packet" => work_packet,
      "work_packet_digest" => work_packet_digest
    }

    attrs =
      if profile == "security_regression" do
        Map.put(attrs, "requested_paths", [
          "apps/arbor_commands/test/operator_candidate_security_regression_test.exs"
        ])
      else
        attrs
      end

    {:ok, plan} = Plan.new(attrs)

    plan
  end

  defp verification_request(profile) do
    %{
      "agent_id" => @agent_id,
      "task_id" => @task_id,
      "workspace_id" => @workspace_id
    }
    |> maybe_put(
      "review_attestation_id",
      if(profile == "security_regression", do: "review_attestation_command_test")
    )
  end

  defp verification_report(profile) do
    %{
      "version" => 1,
      "status" => "passed",
      "profile" => profile,
      "candidate_ref" => "git-tree:" <> String.duplicate("a", 40),
      "observed_at" => @observed_at,
      "diagnostics" =>
        Enum.map(expected_gate_ids(profile), fn gate_id ->
          %{
            "version" => 1,
            "gate_id" => gate_id,
            "phase" => "validation",
            "decision" => "passed",
            "code" => "validation_passed",
            "observed_at" => @observed_at
          }
        end),
      "provenance" => verification_provenance(profile)
    }
  end

  defp verification_provenance(profile) do
    %{
      "version" => 1,
      "task_id" => @task_id,
      "workspace_id" => @workspace_id,
      "principal_id" => @agent_id,
      "plan_fingerprint" => String.duplicate("a", 64),
      "plan_version" => 2,
      "validation_profile" => profile,
      "review_profile" => "binding",
      "work_packet_digest" => "sha256:" <> String.duplicate("b", 64),
      "compile_manifest_sha256" => String.duplicate("c", 64),
      "workspace_provenance_sha256" => String.duplicate("d", 64),
      "workspace_lifecycle" => "active"
    }
  end

  defp expected_gate_ids("default"), do: ["coding.validation.default.compile"]

  defp expected_gate_ids("cross_app") do
    [
      "coding.validation.cross_app.compile",
      "coding.validation.cross_app.xref",
      "coding.validation.cross_app.test_compile",
      "coding.validation.cross_app.tests"
    ]
  end

  defp expected_gate_ids("security_regression") do
    [
      "coding.validation.security_regression.attestation",
      "coding.validation.security_regression.candidate",
      "coding.validation.security_regression.base"
    ]
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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
