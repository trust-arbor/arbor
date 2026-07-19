defmodule Arbor.Agent.Orchestration.LegacyCodingTaskExecutorTest do
  @moduledoc """
  Focused tests for the Phase 6 legacy coding TaskExecutor rollback path.
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Actions.Coding.ProduceReviewableChange
  alias Arbor.Agent.Config
  alias Arbor.Agent.Orchestration.LegacyCodingTaskExecutor
  alias Arbor.Contracts.Security.{AuthContext, SignedRequest, SigningAuthority}
  alias Arbor.Shell

  @produce_resource "arbor://action/coding/produce_reviewable_change"

  defmodule CapturingActions do
    @moduledoc false

    def authorize_and_execute(agent_id, action_module, params, context) do
      reply =
        case Application.get_env(:arbor_agent, :legacy_coding_action_reply) do
          fun when is_function(fun, 4) -> fun.(agent_id, action_module, params, context)
          {:ok, _} = ok -> ok
          {:ok, :pending_approval, _} = pending -> pending
          {:error, _} = error -> error
          nil -> default_success()
          other -> other
        end

      case Application.get_env(:arbor_agent, :legacy_coding_action_observer) do
        pid when is_pid(pid) ->
          send(pid, {:authorize_and_execute, agent_id, action_module, params, context})

        _ ->
          :ok
      end

      reply
    end

    defp default_success do
      {:ok,
       %{
         "status" => "change_committed",
         "branch" => "arbor/legacy-test",
         "commit" => "abc123",
         "repo_path" => "/tmp/repo",
         "worktree_path" => "/tmp/ws"
       }}
    end
  end

  defmodule FakeSecurity do
    @moduledoc false

    alias Arbor.Contracts.Security.{SignedRequest, SigningAuthority}

    def load_signing_key(agent_id) do
      case Process.get(:legacy_coding_signing_key) do
        nil ->
          {_public, private} = :crypto.generate_key(:eddsa, :ed25519)
          Process.put({:legacy_coding_fake_key, agent_id}, private)
          {:ok, private}

        :missing ->
          {:error, :no_signing_key}

        {:error, _} = err ->
          err

        key when is_binary(key) ->
          Process.put({:legacy_coding_fake_key, agent_id}, key)
          {:ok, key}
      end
    end

    def build_signing_authority_acquisition_proof(agent_id, private_key, opts)
        when is_binary(agent_id) and is_binary(private_key) and is_list(opts) do
      {:ok, {:legacy_coding_proof, agent_id, Keyword.fetch!(opts, :owner)}}
    end

    def open_signing_authority({:legacy_coding_proof, agent_id, owner}) when owner == self() do
      case Process.get(:legacy_coding_authority_open_reply) do
        nil ->
          token = :crypto.strong_rand_bytes(32)

          {:ok,
           %SigningAuthority{
             token: token,
             principal_id: agent_id,
             purpose: :legacy_coding_task_executor
           }}

        reply ->
          reply
      end
    end

    def open_signing_authority(_proof), do: {:error, :owner_mismatch}

    def sign_with_authority(%SigningAuthority{principal_id: agent_id} = authority, resource)
        when is_binary(resource) do
      case Process.get(:legacy_coding_authority_sign_reply) do
        nil ->
          private =
            Process.get({:legacy_coding_fake_key, agent_id}) ||
              :crypto.strong_rand_bytes(32)

          case SignedRequest.sign(resource, agent_id, private) do
            {:ok, signed} = ok ->
              maybe_observe({:legacy_coding_signed, authority, signed})
              ok

            other ->
              other
          end

        reply ->
          reply
      end
    end

    def verify_request(%SignedRequest{agent_id: agent_id} = signed_request) do
      case Process.get(:legacy_coding_verify_reply) do
        nil ->
          maybe_observe({:legacy_coding_verified, signed_request})
          {:ok, agent_id}

        fun when is_function(fun, 1) ->
          fun.(signed_request)

        reply ->
          reply
      end
    end

    def close_signing_authority(%SigningAuthority{} = authority) do
      closed = Process.get(:legacy_coding_closed_authorities, [])
      Process.put(:legacy_coding_closed_authorities, [authority | closed])
      maybe_observe({:legacy_coding_authority_closed, authority})
      :ok
    end

    def close_signing_authority(_other), do: {:error, :invalid_signing_authority}

    defp maybe_observe(message) do
      case Application.get_env(:arbor_agent, :legacy_coding_action_observer) do
        pid when is_pid(pid) -> send(pid, message)
        _ -> :ok
      end
    end
  end

  defmodule PipelineExecutor do
    @behaviour Arbor.Contracts.Agent.TaskExecutor

    @impl true
    def run(_agent_id, _task, _context), do: {:ok, %{}}
  end

  setup do
    prev_module = Application.get_env(:arbor_agent, :legacy_coding_actions_module)
    prev_security = Application.get_env(:arbor_agent, :legacy_coding_security_module)
    prev_reply = Application.get_env(:arbor_agent, :legacy_coding_action_reply)
    prev_observer = Application.get_env(:arbor_agent, :legacy_coding_action_observer)
    prev_executors = Application.get_env(:arbor_agent, :task_executors)
    prev_mode = Application.get_env(:arbor_agent, :coding_executor_mode)

    Process.delete(:legacy_coding_signing_key)
    Process.delete(:legacy_coding_authority_open_reply)
    Process.delete(:legacy_coding_authority_sign_reply)
    Process.delete(:legacy_coding_verify_reply)
    Process.delete(:legacy_coding_closed_authorities)

    Application.put_env(:arbor_agent, :legacy_coding_actions_module, CapturingActions)
    Application.put_env(:arbor_agent, :legacy_coding_security_module, FakeSecurity)
    Application.put_env(:arbor_agent, :legacy_coding_action_observer, self())
    Application.delete_env(:arbor_agent, :legacy_coding_action_reply)

    on_exit(fn ->
      restore_env(:legacy_coding_actions_module, prev_module)
      restore_env(:legacy_coding_security_module, prev_security)
      restore_env(:legacy_coding_action_reply, prev_reply)
      restore_env(:legacy_coding_action_observer, prev_observer)
      restore_env(:task_executors, prev_executors)
      restore_env(:coding_executor_mode, prev_mode)
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_agent, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_agent, key, value)

  defp valid_task(overrides \\ %{}) do
    Map.merge(
      %{
        "kind" => "coding_change",
        "task" => "add a hello world function",
        "repo_path" => "/tmp/repo",
        "acp_agent" => "codex"
      },
      overrides
    )
  end

  defp valid_context(overrides \\ %{}) do
    Map.merge(
      %{
        "task_id" => "task_legacy_1",
        "caller_id" => "caller_42"
      },
      overrides
    )
  end

  # ---------------------------------------------------------------------------
  # Operator selector (pipeline default / legacy / invalid)
  # ---------------------------------------------------------------------------

  describe "ARBOR_CODING_EXECUTOR / coding_executor_mode" do
    test "pipeline is the default when env is unset" do
      assert {:ok, :pipeline} = Config.coding_executor_mode(nil)
      assert :pipeline = Config.require_coding_executor_mode!(nil)
    end

    test "accepts closed pipeline and legacy values" do
      assert {:ok, :pipeline} = Config.coding_executor_mode("pipeline")
      assert {:ok, :legacy} = Config.coding_executor_mode("legacy")
      assert :legacy = Config.require_coding_executor_mode!("legacy")
    end

    test "invalid values fail closed at agent startup validation" do
      assert {:error, {:invalid_coding_executor, "auto"}} =
               Config.coding_executor_mode("auto")

      assert {:error, {:invalid_coding_executor, ""}} = Config.coding_executor_mode("")

      assert {:error, {:invalid_coding_executor, :pipeline}} =
               Config.coding_executor_mode(:pipeline)

      assert_raise RuntimeError, ~r/ARBOR_CODING_EXECUTOR/, fn ->
        Config.require_coding_executor_mode!("pipeline-v2")
      end
    end

    test "pipeline default wiring keeps orchestrator executor when configured" do
      Application.put_env(:arbor_agent, :coding_executor_mode, :pipeline)

      Application.put_env(:arbor_agent, :task_executors, %{
        "coding_change" => PipelineExecutor
      })

      assert Config.coding_executor_mode() == :pipeline
      assert {:ok, PipelineExecutor} = Config.task_executor("coding_change")
    end

    test "legacy selection installs LegacyCodingTaskExecutor for coding_change" do
      Application.put_env(:arbor_agent, :coding_executor_mode, :legacy)

      Application.put_env(:arbor_agent, :task_executors, %{
        "coding_change" => PipelineExecutor
      })

      assert Config.coding_executor_mode() == :legacy
      assert {:ok, LegacyCodingTaskExecutor} = Config.task_executor("coding_change")
      assert {:ok, LegacyCodingTaskExecutor} = Config.task_executor(:coding_change)
      assert function_exported?(LegacyCodingTaskExecutor, :run, 3)
    end
  end

  # ---------------------------------------------------------------------------
  # Happy path: provenance + TaskArtifacts-normalized JSON-clean output
  # ---------------------------------------------------------------------------

  test "propagates agent, caller, and task provenance to authorize_and_execute" do
    task = valid_task()
    context = valid_context(%{"timeout" => 12_000, "metadata" => %{"source" => "test"}})

    assert {:ok, result} = LegacyCodingTaskExecutor.run("agent_abc", task, context)

    assert_received {:authorize_and_execute, "agent_abc", ProduceReviewableChange, params,
                     action_ctx}

    assert params.task == "add a hello world function"
    assert params.repo_path == "/tmp/repo"
    assert params.acp_agent == "codex"
    assert params.timeout == 12_000
    assert params.open_pr == false
    assert params.submit_review == true
    refute Map.has_key?(params, :validation_timeout)

    assert action_ctx.agent_id == "agent_abc"
    assert action_ctx.task_id == "task_legacy_1"
    assert action_ctx.caller_id == "caller_42"
    assert action_ctx.metadata == %{"source" => "test"}
    assert action_ctx.timeout == 12_000
    refute Map.has_key?(action_ctx, :authorization)
    refute Map.has_key?(action_ctx, :signer)

    assert %SignedRequest{
             agent_id: "agent_abc",
             payload: @produce_resource
           } = action_ctx.signed_request

    assert %AuthContext{
             principal_id: "agent_abc",
             identity_verified: true,
             signed_request: %SignedRequest{payload: @produce_resource}
           } = action_ctx.auth_context

    assert %SigningAuthority{
             principal_id: "agent_abc",
             purpose: :legacy_coding_task_executor
           } = action_ctx.signing_authority

    assert_received {:legacy_coding_authority_closed,
                     %SigningAuthority{principal_id: "agent_abc"}}

    assert result.result_type == :coding_change
    assert result.payload.branch == "arbor/legacy-test"
    assert result.payload.report.status == "change_committed"
    assert {:ok, _} = Jason.encode(result)
  end

  test "returns JSON-clean TaskArtifacts-normalized output" do
    Application.put_env(:arbor_agent, :legacy_coding_action_reply, {
      :ok,
      %{
        status: "change_committed",
        branch: "feat/x",
        commit: "deadbeef",
        worktree_path: "/tmp/ws",
        validation: [%{"command" => "mix test", "passed" => true}]
      }
    })

    assert {:ok, result} =
             LegacyCodingTaskExecutor.run("agent_1", valid_task(), valid_context())

    assert result.result_type == :coding_change
    assert is_map(result.payload)
    assert result.payload.branch == "feat/x"
    assert is_map(result.payload.report)
    assert result.payload.report.status == "change_committed"
    assert {:ok, encoded} = Jason.encode(result)
    assert is_binary(encoded)
  end

  test "adds bounded executor-owned metrics that action output cannot forge" do
    Application.put_env(:arbor_agent, :legacy_coding_action_reply, {
      :ok,
      %{
        status: "change_committed",
        branch: "feat/metrics",
        commit: "deadbeef",
        worktree_path: "/tmp/ws",
        validation: [
          %{"command" => "mix compile", "passed" => true},
          %{"command" => "mix test", "passed" => true}
        ],
        review: %{"status" => "approved", "recommendation" => "keep"},
        metrics: %{
          "action_metric" => %{"value" => 7},
          execution_path: "forged",
          wall_clock_ms: -1,
          validation_attempts: 99,
          validation_command_count: 99,
          review_attempts: 99,
          protocol_retry_count: 99,
          validation_rework_count: 99,
          review_rework_count: 99,
          total_rework_count: 99
        }
      }
    })

    assert {:ok, result} =
             LegacyCodingTaskExecutor.run("agent_1", valid_task(), valid_context())

    metrics = result.payload.metrics

    assert metrics["execution_path"] == "legacy"
    assert is_integer(metrics["wall_clock_ms"])
    assert metrics["wall_clock_ms"] >= 0
    assert metrics["validation_attempts"] == 1
    assert metrics["validation_command_count"] == 2
    assert metrics["review_attempts"] == 1
    assert metrics["protocol_retry_count"] == 0
    assert metrics["validation_rework_count"] == 0
    assert metrics["review_rework_count"] == 0
    assert metrics["total_rework_count"] == 0
    assert metrics["action_metric"] == %{"value" => 7}
    assert result.payload.report.metrics == metrics
    assert result.raw["metrics"] == metrics
    refute Map.has_key?(result.raw, :metrics)
    assert {:ok, _encoded} = Jason.encode(result)
  end

  test "preserves action-returned ACP usage under metrics for benchmark observations" do
    Application.put_env(:arbor_agent, :legacy_coding_action_reply, {
      :ok,
      %{
        status: "change_committed",
        branch: "feat/usage",
        commit: "deadbeef",
        worktree_path: "/tmp/ws",
        validation: [%{"command" => "mix compile", "passed" => true}],
        metrics: %{
          usage: %{
            "input_tokens" => 321,
            "outputTokens" => 45,
            "cost" => 2
          }
        }
      }
    })

    assert {:ok, result} =
             LegacyCodingTaskExecutor.run("agent_1", valid_task(), valid_context())

    metrics = result.payload.metrics
    assert metrics["execution_path"] == "legacy"
    assert metrics["usage"]["input_tokens"] == 321
    assert metrics["usage"]["outputTokens"] == 45
    assert metrics["usage"]["cost"] == 2
    assert result.raw["metrics"]["usage"]["input_tokens"] == 321
  end

  test "reports zero attempts when validation and review evidence are absent" do
    assert {:ok, result} =
             LegacyCodingTaskExecutor.run("agent_1", valid_task(), valid_context())

    metrics = result.payload.metrics

    assert metrics["validation_attempts"] == 0
    assert metrics["validation_command_count"] == 0
    assert metrics["review_attempts"] == 0
    assert metrics["protocol_retry_count"] == 0
    assert metrics["total_rework_count"] == 0
  end

  # ---------------------------------------------------------------------------
  # Malformed / unknown input
  # ---------------------------------------------------------------------------

  test "rejects missing kind and unsupported kinds" do
    assert {:error, :missing_task_kind} =
             LegacyCodingTaskExecutor.run(
               "agent_1",
               Map.delete(valid_task(), "kind"),
               valid_context()
             )

    assert {:error, {:unsupported_task_kind, "chat"}} =
             LegacyCodingTaskExecutor.run(
               "agent_1",
               Map.put(valid_task(), "kind", "chat"),
               valid_context()
             )
  end

  test "rejects missing required fields and bad types" do
    assert {:error, {:missing_field, "repo_path"}} =
             LegacyCodingTaskExecutor.run(
               "agent_1",
               Map.delete(valid_task(), "repo_path"),
               valid_context()
             )

    assert {:error, {:blank_field, "task"}} =
             LegacyCodingTaskExecutor.run(
               "agent_1",
               Map.put(valid_task(), "task", "   "),
               valid_context()
             )

    assert {:error, {:invalid_field_type, "open_pr"}} =
             LegacyCodingTaskExecutor.run(
               "agent_1",
               Map.put(valid_task(), "open_pr", 1),
               valid_context()
             )

    assert {:error, {:invalid_field_type, "acp_agent"}} =
             LegacyCodingTaskExecutor.run(
               "agent_1",
               Map.put(valid_task(), "acp_agent", ["codex"]),
               valid_context()
             )
  end

  test "forwards accepted validation_timeout to ProduceReviewableChange" do
    ceiling = Shell.spawn_capable_max_timeout_ms()
    timeout = min(ceiling, 450_000)

    assert {:ok, _result} =
             LegacyCodingTaskExecutor.run(
               "agent_1",
               valid_task(%{"validation_timeout" => timeout}),
               valid_context()
             )

    assert_received {:authorize_and_execute, "agent_1", ProduceReviewableChange, params, _ctx}
    assert params.validation_timeout == timeout
  end

  test "omits validation_timeout when not supplied so action default remains" do
    assert {:ok, _result} =
             LegacyCodingTaskExecutor.run("agent_1", valid_task(), valid_context())

    assert_received {:authorize_and_execute, "agent_1", ProduceReviewableChange, params, _ctx}
    refute Map.has_key?(params, :validation_timeout)
  end

  test "rejects malformed and over-ceiling validation_timeout fail closed" do
    ceiling = Shell.spawn_capable_max_timeout_ms()

    assert {:error, {:validation_timeout_exceeds_ceiling, over, ^ceiling}} =
             LegacyCodingTaskExecutor.run(
               "agent_1",
               valid_task(%{"validation_timeout" => ceiling + 1}),
               valid_context()
             )

    assert over == ceiling + 1
    refute_received {:authorize_and_execute, _, _, _, _}

    assert {:error, {:invalid_field_type, "validation_timeout"}} =
             LegacyCodingTaskExecutor.run(
               "agent_1",
               valid_task(%{"validation_timeout" => 0}),
               valid_context()
             )

    assert {:error, {:invalid_field_type, "validation_timeout"}} =
             LegacyCodingTaskExecutor.run(
               "agent_1",
               valid_task(%{"validation_timeout" => -1}),
               valid_context()
             )

    assert {:error, {:invalid_field_type, "validation_timeout"}} =
             LegacyCodingTaskExecutor.run(
               "agent_1",
               valid_task(%{"validation_timeout" => 300_000.0}),
               valid_context()
             )

    assert {:error, {:invalid_field_type, "validation_timeout"}} =
             LegacyCodingTaskExecutor.run(
               "agent_1",
               valid_task(%{"validation_timeout" => "600000"}),
               valid_context()
             )

    assert {:error, {:invalid_field_type, "validation_timeout"}} =
             LegacyCodingTaskExecutor.run(
               "agent_1",
               valid_task(%{"validation_timeout" => true}),
               valid_context()
             )

    refute_received {:authorize_and_execute, _, _, _, _}
  end

  test "rejects unknown and non-JSON task fields" do
    assert {:error, {:unknown_task_key, "model"}} =
             LegacyCodingTaskExecutor.run(
               "agent_1",
               Map.put(valid_task(), "model", "gpt"),
               valid_context()
             )

    assert {:error, :invalid_task} =
             LegacyCodingTaskExecutor.run("agent_1", "not a map", valid_context())

    assert {:error, {:non_json_task, :non_string_key}} =
             LegacyCodingTaskExecutor.run(
               "agent_1",
               %{kind: "coding_change", task: "x", repo_path: "/r", acp_agent: "c"},
               valid_context()
             )
  end

  test "rejects direct versioned plan input" do
    task = %{
      "kind" => "coding_change",
      "plan" => %{
        "version" => 1,
        "task" => "do work",
        "repo_root" => "/tmp/repo",
        "worker" => %{"provider" => "codex"},
        "workspace_policy" => %{"mode" => "isolated"},
        "review_profile" => "binding",
        "output" => %{"draft_pr" => false}
      }
    }

    assert {:error, :legacy_executor_rejects_plan} =
             LegacyCodingTaskExecutor.run("agent_1", task, valid_context())

    refute_received {:authorize_and_execute, _, _, _, _}
  end

  test "rejects non-default reviewed profiles rather than pretending support" do
    assert {:error, {:legacy_executor_rejects_review_profile, "security"}} =
             LegacyCodingTaskExecutor.run(
               "agent_1",
               Map.put(valid_task(), "review_profile", "security"),
               valid_context()
             )

    assert {:error, {:legacy_executor_rejects_review_profile, "binding"}} =
             LegacyCodingTaskExecutor.run(
               "agent_1",
               Map.put(valid_task(), "profile", "binding"),
               valid_context()
             )

    refute_received {:authorize_and_execute, _, _, _, _}
  end

  # ---------------------------------------------------------------------------
  # Authorization / pending / error propagation
  # ---------------------------------------------------------------------------

  test "propagates unauthorized and operational errors" do
    Application.put_env(:arbor_agent, :legacy_coding_action_reply, {:error, :unauthorized})

    assert {:error, :unauthorized} =
             LegacyCodingTaskExecutor.run("agent_1", valid_task(), valid_context())

    Application.put_env(
      :arbor_agent,
      :legacy_coding_action_reply,
      {:error, {:action_failed, "boom"}}
    )

    assert {:error, {:action_failed, "boom"}} =
             LegacyCodingTaskExecutor.run("agent_1", valid_task(), valid_context())
  end

  test "propagates pending approval ok and error shapes" do
    Application.put_env(
      :arbor_agent,
      :legacy_coding_action_reply,
      {:ok, :pending_approval, "irq_123"}
    )

    assert {:ok, :pending_approval, "irq_123"} =
             LegacyCodingTaskExecutor.run("agent_1", valid_task(), valid_context())

    Application.put_env(
      :arbor_agent,
      :legacy_coding_action_reply,
      {:error, {:pending_approval, "irq_456"}}
    )

    assert {:error, {:pending_approval, "irq_456"}} =
             LegacyCodingTaskExecutor.run("agent_1", valid_task(), valid_context())
  end

  # ---------------------------------------------------------------------------
  # Task fields cannot override executor selection or authority
  # ---------------------------------------------------------------------------

  test "task fields cannot select executor route or inject authority" do
    for key <- ~w(executor coding_executor agent_id authorization signer capabilities identity) do
      assert {:error, {:forbidden_task_key, ^key}} =
               LegacyCodingTaskExecutor.run(
                 "agent_1",
                 Map.put(valid_task(), key, "attacker"),
                 valid_context()
               )
    end

    refute_received {:authorize_and_execute, _, _, _, _}

    # Route remains operator/config controlled even when task claims otherwise.
    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => LegacyCodingTaskExecutor
    })

    poisoned = Map.put(valid_task(), "executor", "pipeline")

    assert {:error, {:forbidden_task_key, "executor"}} =
             LegacyCodingTaskExecutor.run("agent_1", poisoned, valid_context())

    assert {:ok, LegacyCodingTaskExecutor} = Config.task_executor("coding_change")
  end

  test "context cannot smuggle authority or unknown keys" do
    assert {:error, {:forbidden_context_key, "authorization"}} =
             LegacyCodingTaskExecutor.run(
               "agent_1",
               valid_task(),
               Map.put(valid_context(), "authorization", true)
             )

    assert {:error, {:forbidden_context_key, "signer"}} =
             LegacyCodingTaskExecutor.run(
               "agent_1",
               valid_task(),
               Map.put(valid_context(), "signer", "x")
             )

    assert {:error, {:forbidden_context_key, "engine"}} =
             LegacyCodingTaskExecutor.run(
               "agent_1",
               valid_task(),
               Map.put(valid_context(), "engine", "Engine")
             )

    assert {:error, {:unknown_context_key, "extra_control"}} =
             LegacyCodingTaskExecutor.run(
               "agent_1",
               valid_task(),
               Map.put(valid_context(), "extra_control", "x")
             )

    assert {:error, {:missing_field, "task_id"}} =
             LegacyCodingTaskExecutor.run("agent_1", valid_task(), %{})

    refute_received {:authorize_and_execute, _, _, _, _}
  end

  test "invalid agent id fails closed" do
    assert {:error, :invalid_agent_id} =
             LegacyCodingTaskExecutor.run("", valid_task(), valid_context())

    assert {:error, :invalid_agent_id} =
             LegacyCodingTaskExecutor.run(nil, valid_task(), valid_context())
  end

  test "closes signing authority after action errors" do
    Application.put_env(:arbor_agent, :legacy_coding_action_reply, {:error, :unauthorized})

    assert {:error, :unauthorized} =
             LegacyCodingTaskExecutor.run("agent_abc", valid_task(), valid_context())

    assert_received {:authorize_and_execute, "agent_abc", ProduceReviewableChange, _params,
                     action_ctx}

    assert %SigningAuthority{principal_id: "agent_abc"} = action_ctx.signing_authority

    assert_received {:legacy_coding_authority_closed,
                     %SigningAuthority{principal_id: "agent_abc"}}
  end

  test "fails closed when signing key is missing" do
    Process.put(:legacy_coding_signing_key, :missing)

    assert {:error, :no_signing_key} =
             LegacyCodingTaskExecutor.run("agent_abc", valid_task(), valid_context())

    refute_received {:authorize_and_execute, _, _, _, _}
  end

  test "fails closed when signed request resource binding mismatches" do
    Process.put(:legacy_coding_authority_sign_reply, {
      :ok,
      %SignedRequest{
        payload: "arbor://action/forged",
        agent_id: "agent_abc",
        timestamp: DateTime.utc_now(),
        nonce: :crypto.strong_rand_bytes(16),
        signature: :crypto.strong_rand_bytes(64)
      }
    })

    assert {:error, {:legacy_coding_authority_signing_failed, :signed_request_binding_mismatch}} =
             LegacyCodingTaskExecutor.run("agent_abc", valid_task(), valid_context())

    refute_received {:authorize_and_execute, _, _, _, _}

    assert_received {:legacy_coding_authority_closed,
                     %SigningAuthority{principal_id: "agent_abc"}}
  end

  # ---------------------------------------------------------------------------
  # Real security boundary (resource binding + authority cleanup)
  # ---------------------------------------------------------------------------

  describe "security regression: production signing boundary" do
    @describetag :security_regression

    setup do
      ensure_security_runtime!()
      previous_security = Application.get_env(:arbor_agent, :legacy_coding_security_module)
      Application.put_env(:arbor_agent, :legacy_coding_security_module, Arbor.Security)

      {:ok, identity} = Arbor.Security.generate_identity(name: "legacy-coding-auth")
      :ok = Arbor.Security.register_identity(identity)
      :ok = Arbor.Security.store_signing_key(identity.agent_id, identity.private_key)

      on_exit(fn ->
        restore_env(:legacy_coding_security_module, previous_security)

        if Process.whereis(Arbor.Security.CapabilityStore) do
          Arbor.Security.CapabilityStore.revoke_all(identity.agent_id)
        end

        if Process.whereis(Arbor.Security.Identity.Registry) do
          Arbor.Security.deregister_identity(identity.agent_id)
        end

        _ = Arbor.Security.delete_signing_key(identity.agent_id)
      end)

      {:ok, identity: identity}
    end

    test "security regression: signs exact ProduceReviewableChange resource and closes authority",
         %{identity: identity} do
      agent_id = identity.agent_id

      assert {:ok, _result} =
               LegacyCodingTaskExecutor.run(agent_id, valid_task(), valid_context())

      assert_received {:authorize_and_execute, ^agent_id, ProduceReviewableChange, _params,
                       action_ctx}

      assert %SignedRequest{
               agent_id: ^agent_id,
               payload: @produce_resource
             } = signed = action_ctx.signed_request

      # Resource binding is re-checked through the public verifier (nonce consumed).
      # A second verification of the same request must fail closed as replay.
      assert {:error, :replayed_nonce} = Arbor.Security.verify_request(signed)

      assert %AuthContext{
               principal_id: ^agent_id,
               identity_verified: true,
               signed_request: %SignedRequest{payload: @produce_resource}
             } = action_ctx.auth_context

      assert %SigningAuthority{
               principal_id: ^agent_id,
               purpose: :legacy_coding_task_executor
             } = authority = action_ctx.signing_authority

      # Authority must be closed after the delegated action lifetime.
      assert {:error, _reason} =
               Arbor.Security.sign_with_authority(authority, @produce_resource)
    end

    test "security regression: wrong-principal signing key cannot authorize the action", %{
      identity: identity
    } do
      {:ok, other} = Arbor.Security.generate_identity(name: "legacy-coding-other")
      :ok = Arbor.Security.register_identity(other)
      :ok = Arbor.Security.store_signing_key(other.agent_id, other.private_key)

      on_exit(fn ->
        if Process.whereis(Arbor.Security.Identity.Registry) do
          Arbor.Security.deregister_identity(other.agent_id)
        end

        _ = Arbor.Security.delete_signing_key(other.agent_id)
      end)

      # Run as identity.agent_id but the stored key for that id is still identity's.
      # Forge: overwrite identity key with other's private key so possession proof
      # fails principal binding inside Security.
      :ok = Arbor.Security.store_signing_key(identity.agent_id, other.private_key)

      assert {:error, {:signing_authority_acquisition_failed, _reason}} =
               LegacyCodingTaskExecutor.run(identity.agent_id, valid_task(), valid_context())

      refute_received {:authorize_and_execute, _, _, _, _}
    end
  end

  defp ensure_security_runtime! do
    {:ok, _} = Application.ensure_all_started(:arbor_security)
    {:ok, _} = Application.ensure_all_started(:arbor_contracts)

    security_backend =
      Application.get_env(:arbor_security, :storage_backend, Arbor.Security.Store.JSONFile)

    for {name, collection} <- [
          {:arbor_security_capabilities, "capabilities"},
          {:arbor_security_identities, "identities"},
          {:arbor_security_signing_keys, "signing_keys"}
        ] do
      child =
        Supervisor.child_spec(
          {Arbor.Persistence.BufferedStore,
           name: name, backend: security_backend, write_mode: :sync, collection: collection},
          id: name
        )

      case Supervisor.start_child(Arbor.Security.Supervisor, child) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, {:already_present, _id}} -> :ok
        {:error, reason} -> raise "failed to start #{inspect(name)}: #{inspect(reason)}"
      end
    end

    signing_authority_owner_token = make_ref()

    security_children = [
      {Arbor.Security.Identity.Registry, []},
      {Arbor.Security.Identity.NonceCache, []},
      {Arbor.Security.SystemAuthority, []},
      {Arbor.Security.SigningAuthorityStateOwner, broker_token: signing_authority_owner_token},
      {Arbor.Security.SigningAuthorityBroker, state_owner_token: signing_authority_owner_token},
      {Arbor.Security.CapabilityStore, []}
    ]

    for {module, opts} <- security_children do
      unless Process.whereis(module) do
        case Supervisor.start_child(Arbor.Security.Supervisor, {module, opts}) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> raise "failed to start #{inspect(module)}: #{inspect(reason)}"
        end
      end
    end

    :ok
  end
end
