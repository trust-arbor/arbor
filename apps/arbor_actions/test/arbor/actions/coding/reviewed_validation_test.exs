defmodule Arbor.Actions.Coding.ReviewedValidationTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Actions.Coding.ReviewedValidation
  alias Arbor.Actions.Mix, as: MixAction

  defmodule AskNestedValidationPolicy do
    @moduledoc false
    # Outer coding_reviewed_validation is auto so ActionsExecutor cannot
    # intercept approval; exact nested validators remain gated.
    def confirmation_mode(_principal_id, resource_uri, _opts) do
      cond do
        is_binary(resource_uri) and
            (String.contains?(resource_uri, "mix/compile") or
               String.contains?(resource_uri, "cross_app") or
               String.contains?(resource_uri, "security_regression")) ->
          :gated

        true ->
          :auto
      end
    end
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:arbor_comms)
    {:ok, _} = Application.ensure_all_started(:arbor_security)
    {:ok, _} = Application.ensure_all_started(:arbor_trust)
    {:ok, _} = Application.ensure_all_started(:arbor_signals)
    :ok
  end

  setup do
    previous = %{
      approval_guard_enabled: Application.get_env(:arbor_trust, :approval_guard_enabled),
      policy_module: Application.get_env(:arbor_trust, :policy_module),
      interaction_router:
        Application.get_env(:arbor_security, :use_interaction_router_for_approval),
      signing_required: Application.get_env(:arbor_security, :capability_signing_required),
      identity_verification: Application.get_env(:arbor_security, :identity_verification),
      approval_timeout: Application.get_env(:arbor_actions, :approval_timeout_ms),
      orchestrator_approval_timeout:
        Application.get_env(:arbor_orchestrator, :approval_timeout_ms)
    }

    Application.put_env(:arbor_trust, :approval_guard_enabled, true)
    Application.put_env(:arbor_trust, :policy_module, AskNestedValidationPolicy)
    Application.put_env(:arbor_security, :use_interaction_router_for_approval, true)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :identity_verification, false)
    Application.put_env(:arbor_actions, :approval_timeout_ms, 3_000)

    on_exit(fn ->
      restore_env(:arbor_trust, :approval_guard_enabled, previous.approval_guard_enabled)
      restore_env(:arbor_trust, :policy_module, previous.policy_module)

      restore_env(
        :arbor_security,
        :use_interaction_router_for_approval,
        previous.interaction_router
      )

      restore_env(:arbor_security, :capability_signing_required, previous.signing_required)
      restore_env(:arbor_security, :identity_verification, previous.identity_verification)
      restore_env(:arbor_actions, :approval_timeout_ms, previous.approval_timeout)

      restore_env(
        :arbor_orchestrator,
        :approval_timeout_ms,
        previous.orchestrator_approval_timeout
      )
    end)

    :ok
  end

  test "pipeline-internal tool name and tags" do
    assert ReviewedValidation.name() == "coding_reviewed_validation"
    assert "pipeline_internal" in Enum.map(ReviewedValidation.tags(), &to_string/1)
    assert Arbor.Actions.pipeline_internal_action?(ReviewedValidation)
  end

  test "declares every closed nested validator through execution_dependencies" do
    deps = ReviewedValidation.execution_dependencies()

    assert MixAction.Compile in deps
    assert Arbor.Actions.Coding.CrossApp.Validate in deps
    assert Arbor.Actions.Coding.SecurityRegression.Validate in deps
    assert length(deps) == 3
    assert deps == Enum.sort_by(deps, &Atom.to_string/1)

    assert {:ok, names} = Arbor.Actions.execution_dependencies(ReviewedValidation)

    assert Enum.sort(names) ==
             Enum.sort([
               "mix_compile",
               "coding_cross_app_validate",
               "coding_security_regression_validate"
             ])
  end

  test "closed allowlist rejects forged and non-profile pins" do
    # Registered but not an admitted nested validator.
    assert {:error, reason} =
             ReviewedValidation.run(
               %{
                 pinned_action: "coding_reviewed_commit",
                 pinned_profile_id: "default",
                 pinned_params_json: "{}",
                 path: "/tmp"
               },
               %{agent_id: "agent_pin", allow_pipeline_internal: true}
             )

    assert reason =~ "disallowed_pinned_action" or reason =~ "coding_reviewed_commit"

    # Module-looking string.
    assert {:error, _} =
             ReviewedValidation.run(
               %{
                 pinned_action: "Elixir.Arbor.Actions.Mix.Compile",
                 pinned_profile_id: "default",
                 pinned_params_json: "{}",
                 path: "/tmp"
               },
               %{agent_id: "agent_pin", allow_pipeline_internal: true}
             )

    # Profile/action mismatch (forged pin).
    assert {:error, reason2} =
             ReviewedValidation.run(
               %{
                 pinned_action: "mix_compile",
                 pinned_profile_id: "security_regression",
                 pinned_params_json: ~s({"timeout":1000}),
                 path: "/tmp"
               },
               %{agent_id: "agent_pin", allow_pipeline_internal: true}
             )

    assert reason2 =~ "pinned_action_profile_mismatch" or reason2 =~ "security_regression"

    # Unknown profile id.
    assert {:error, reason3} =
             ReviewedValidation.run(
               %{
                 pinned_action: "mix_compile",
                 pinned_profile_id: "not_a_profile",
                 pinned_params_json: ~s({"timeout":1000}),
                 path: "/tmp"
               },
               %{agent_id: "agent_pin", allow_pipeline_internal: true}
             )

    assert reason3 =~ "pinned_action_profile_mismatch" or reason3 =~ "not_a_profile"
  end

  test "allowed_validator_module admits only closed names" do
    assert {:ok, MixAction.Compile} = ReviewedValidation.allowed_validator_module("mix_compile")

    assert {:error, {:disallowed_pinned_action, "shell_execute"}} =
             ReviewedValidation.allowed_validator_module("shell_execute")

    assert ReviewedValidation.allowed_validator_names() ==
             Enum.sort([
               "coding_cross_app_validate",
               "coding_security_regression_validate",
               "mix_compile"
             ])
  end

  test "central exposure excludes pipeline_internal; name resolution still works" do
    refute ReviewedValidation in Arbor.Actions.exposed_actions()
    assert ReviewedValidation in Arbor.Actions.all_actions()

    assert {:ok, ReviewedValidation} =
             Arbor.Actions.name_to_module("coding_reviewed_validation")

    # Without pipeline-internal admission, generic callers cannot run the outer
    # syscall — prevents ActionsExecutor-like paths from intercepting approval
    # without an Engine pin.
    assert {:error, :pipeline_internal_not_exposed} =
             Arbor.Actions.authorize_and_execute(
               "agent_exposure",
               ReviewedValidation,
               %{
                 pinned_action: "mix_compile",
                 pinned_profile_id: "default",
                 pinned_params_json: ~s({"timeout":1000,"warnings_as_errors":true}),
                 path: "/tmp"
               },
               %{}
             )
  end

  test "malformed pinned params json is rejected" do
    assert {:error, reason} =
             ReviewedValidation.run(
               %{
                 pinned_action: "mix_compile",
                 pinned_profile_id: "default",
                 pinned_params_json: "not-json",
                 path: "/tmp"
               },
               %{agent_id: "agent_test", allow_pipeline_internal: true}
             )

    assert is_binary(reason)
    assert reason =~ "invalid_pinned_params_json"
  end

  test "public boundary: approve executes nested once with two fresh signer calls" do
    agent_id = unique_agent("approve")
    grant_mix_compile!(agent_id)
    nested_attempts = :counters.new(1, [])
    attach_nested_attempt_counter!(nested_attempts, "mix_compile")

    signer_calls = :counters.new(1, [])
    context = build_context(agent_id, build_counter_signer(signer_calls, agent_id))

    task =
      Task.async(fn ->
        public_run(agent_id, default_pin_params(timeout: 12_345), context)
      end)

    request = await_pending_request(agent_id)
    assert request_resource(request) =~ "mix/compile"

    assert :ok =
             Arbor.Comms.respond_to_interaction(request.request_id, :approved, %{
               decision: :approve
             })

    # Nested Mix.Compile may fail on a temp path; the attempt is still counted.
    _result = Task.await(task, 10_000)
    # Actions.execute_action/3 and Mix.Compile.run/2 each emit one started
    # signal. Exactly two proves one nested invocation; four would expose a
    # duplicate execution.
    assert_receive {:nested_attempt, "mix_compile"}, 5_000
    assert_receive {:nested_attempt, "mix_compile"}, 5_000
    refute_receive {:nested_attempt, "mix_compile"}, 200
    assert :counters.get(nested_attempts, 1) == 2
    # Authorize + execute each mint one fresh exact-resource signed request.
    assert :counters.get(signer_calls, 1) == 2

    assert Enum.empty?(
             Arbor.Comms.InteractionRouter.pending()
             |> Enum.filter(&(&1.agent_id == agent_id))
           )
  end

  test "public boundary: rework executes nested zero times" do
    agent_id = unique_agent("rework")
    grant_mix_compile!(agent_id)
    nested_attempts = :counters.new(1, [])
    attach_nested_attempt_counter!(nested_attempts, "mix_compile")

    signer_calls = :counters.new(1, [])
    context = build_context(agent_id, build_counter_signer(signer_calls, agent_id))

    task =
      Task.async(fn ->
        public_run(agent_id, default_pin_params(), context)
      end)

    request = await_pending_request(agent_id)

    assert :ok =
             Arbor.Comms.respond_to_interaction(request.request_id, :rejected, %{
               decision: :rework,
               note: "fix the failing test",
               rework: true
             })

    assert {:ok, payload} = Task.await(task, 5_000)
    assert payload["interaction_outcome"] == "rework"
    assert payload["request_id"] == request.request_id
    assert payload["note"] == "fix the failing test"
    refute Map.has_key?(payload, "passed")
    # Give async signal bus a moment; nested must never start.
    refute_receive {:nested_attempt, _}, 200
    assert :counters.get(nested_attempts, 1) == 0
    # Pre-approval authorize signature only — no execute-path re-sign.
    assert :counters.get(signer_calls, 1) == 1
  end

  test "public boundary: deny executes nested zero times" do
    agent_id = unique_agent("deny")
    grant_mix_compile!(agent_id)
    nested_attempts = :counters.new(1, [])
    attach_nested_attempt_counter!(nested_attempts, "mix_compile")

    signer_calls = :counters.new(1, [])
    context = build_context(agent_id, build_counter_signer(signer_calls, agent_id))

    task =
      Task.async(fn ->
        public_run(agent_id, default_pin_params(), context)
      end)

    request = await_pending_request(agent_id)

    assert :ok =
             Arbor.Comms.respond_to_interaction(request.request_id, :rejected, %{
               decision: :deny,
               note: "too risky"
             })

    assert {:ok, payload} = Task.await(task, 5_000)
    assert payload["interaction_outcome"] == "denied"
    assert payload["request_id"] == request.request_id
    assert payload["note"] == "too risky"
    refute Map.has_key?(payload, "passed")
    refute_receive {:nested_attempt, _}, 200
    assert :counters.get(nested_attempts, 1) == 0
    assert :counters.get(signer_calls, 1) == 1
  end

  test "public boundary: unknown decision fails closed with zero nested execution" do
    agent_id = unique_agent("unknown")
    grant_mix_compile!(agent_id)
    nested_attempts = :counters.new(1, [])
    attach_nested_attempt_counter!(nested_attempts, "mix_compile")

    signer_calls = :counters.new(1, [])
    context = build_context(agent_id, build_counter_signer(signer_calls, agent_id))

    task =
      Task.async(fn ->
        public_run(agent_id, default_pin_params(), context)
      end)

    request = await_pending_request(agent_id)

    assert :ok =
             Arbor.Comms.respond_to_interaction(request.request_id, :rejected, %{
               decision: "maybe"
             })

    assert {:error, reason} = Task.await(task, 5_000)
    assert is_binary(reason)
    refute_receive {:nested_attempt, _}, 200
    assert :counters.get(nested_attempts, 1) == 0
    assert :counters.get(signer_calls, 1) == 1
  end

  test "approval wait falls back to the orchestrator-owned timeout" do
    agent_id = unique_agent("orchestrator_timeout")
    grant_mix_compile!(agent_id)

    Application.delete_env(:arbor_actions, :approval_timeout_ms)
    Application.put_env(:arbor_orchestrator, :approval_timeout_ms, 100)

    context =
      agent_id
      |> build_context(build_signer(agent_id))
      |> Map.delete(:approval_timeout_ms)

    task = Task.async(fn -> public_run(agent_id, default_pin_params(), context) end)

    assert {:ok, {:error, reason}} = Task.yield(task, 1_500)
    assert reason =~ "timeout"
  end

  test "public boundary: clamped timeout binding reaches nested default validator" do
    agent_id = unique_agent("timeout_bind")
    grant_mix_compile!(agent_id)
    {:ok, seen} = Agent.start_link(fn -> nil end)
    on_exit(fn -> if Process.alive?(seen), do: Agent.stop(seen) end)

    parent = self()
    nested_attempts = :counters.new(1, [])

    assert {:ok, sub_id} =
             Arbor.Signals.subscribe("action.started", fn signal ->
               name = signal.data[:action] || signal.data["action"]

               if name == "mix_compile" do
                 :counters.add(nested_attempts, 1, 1)

                 if :counters.get(nested_attempts, 1) == 1 do
                   params = signal.data[:params] || signal.data["params"] || %{}
                   timeout = params[:timeout] || params["timeout"]
                   Agent.update(seen, fn _ -> timeout end)
                 end

                 params = signal.data[:params] || signal.data["params"] || %{}
                 send(parent, {:nested_started, params[:timeout] || params["timeout"]})
               end

               :ok
             end)

    on_exit(fn -> Arbor.Signals.unsubscribe(sub_id) end)

    context = build_context(agent_id, build_signer(agent_id))
    params = default_pin_params(timeout: 3_000) |> Map.put(:timeout, 1_111)

    task =
      Task.async(fn ->
        public_run(agent_id, params, context)
      end)

    request = await_pending_request(agent_id)

    assert :ok =
             Arbor.Comms.respond_to_interaction(request.request_id, :approved, %{
               decision: :approve
             })

    _ = Task.await(task, 10_000)
    assert_receive {:nested_started, 1_111}, 5_000
    assert_receive {:nested_started, 1_111}, 5_000
    refute_receive {:nested_started, _}, 200
    assert Agent.get(seen, & &1) == 1_111
    assert :counters.get(nested_attempts, 1) == 2
  end

  test "public boundary: stage_timeout 222222 reaches nested security validator on approve" do
    agent_id = unique_agent("stage_bind")
    grant_reviewed_validation!(agent_id)

    assert {:ok, cap} =
             Arbor.Security.grant(
               principal: agent_id,
               resource: "arbor://action/coding/security_regression/validate",
               constraints: %{}
             )

    on_exit(fn -> Arbor.Security.revoke(cap.id) end)

    nested_attempts = :counters.new(1, [])
    {:ok, seen} = Agent.start_link(fn -> nil end)
    on_exit(fn -> if Process.alive?(seen), do: Agent.stop(seen) end)
    parent = self()

    assert {:ok, sub_id} =
             Arbor.Signals.subscribe("action.started", fn signal ->
               name = signal.data[:action] || signal.data["action"]

               if name == "coding_security_regression_validate" do
                 params = signal.data[:params] || signal.data["params"] || %{}
                 stage = params[:stage_timeout] || params["stage_timeout"]

                 # execute_action emits full nested params (including stage_timeout);
                 # the action's own started signal only carries attestation id.
                 if not is_nil(stage) do
                   :counters.add(nested_attempts, 1, 1)

                   if :counters.get(nested_attempts, 1) == 1 do
                     Agent.update(seen, fn _ -> stage end)
                   end

                   send(parent, {:nested_stage_timeout, stage})
                 end
               end

               :ok
             end)

    on_exit(fn -> Arbor.Signals.unsubscribe(sub_id) end)

    context = build_context(agent_id, build_signer(agent_id))

    pin = %{
      pinned_action: "coding_security_regression_validate",
      pinned_profile_id: "security_regression",
      pinned_params_json: ~s({"timeout":600000,"stage_timeout":900000}),
      review_attestation_id: "attestation-test",
      stage_timeout: 222_222
    }

    task =
      Task.async(fn ->
        public_run(agent_id, pin, context)
      end)

    request = await_pending_request(agent_id)
    assert request_resource(request) =~ "security_regression"

    assert :ok =
             Arbor.Comms.respond_to_interaction(request.request_id, :approved, %{
               decision: :approve
             })

    _ = Task.await(task, 10_000)
    assert_receive {:nested_stage_timeout, 222_222}, 5_000
    refute_receive {:nested_stage_timeout, _}, 200
    assert Agent.get(seen, & &1) == 222_222
    assert :counters.get(nested_attempts, 1) == 1
  end

  defp public_run(agent_id, params, context) do
    Arbor.Actions.authorize_and_execute(
      agent_id,
      ReviewedValidation,
      params,
      Map.put(context, :allow_pipeline_internal, true)
    )
  end

  defp default_pin_params(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 3_000)

    %{
      pinned_action: "mix_compile",
      pinned_profile_id: "default",
      pinned_params_json: Jason.encode!(%{"warnings_as_errors" => true, "timeout" => timeout}),
      path: System.tmp_dir!(),
      workspace_id: "ws_reviewed_validation_test"
    }
  end

  defp build_context(agent_id, signer) do
    %{
      agent_id: agent_id,
      allow_pipeline_internal: true,
      approval_timeout_ms: 3_000,
      signer: signer
    }
  end

  defp build_signer(agent_id) do
    fn resource when is_binary(resource) ->
      {:ok,
       %{
         "principal_id" => agent_id,
         "resource" => resource,
         "nonce" => Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
         "signature" => "test-sig"
       }}
    end
  end

  defp build_counter_signer(counter, agent_id) do
    fn resource when is_binary(resource) ->
      :counters.add(counter, 1, 1)

      {:ok,
       %{
         "principal_id" => agent_id,
         "resource" => resource,
         "nonce" => Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
         "signature" => "test-sig-#{:counters.get(counter, 1)}"
       }}
    end
  end

  defp grant_mix_compile!(agent_id) do
    grant_reviewed_validation!(agent_id)

    assert {:ok, cap} =
             Arbor.Security.grant(
               principal: agent_id,
               resource: "arbor://action/mix/compile",
               constraints: %{}
             )

    on_exit(fn -> Arbor.Security.revoke(cap.id) end)
    cap
  end

  defp grant_reviewed_validation!(agent_id) do
    assert {:ok, cap} =
             Arbor.Security.grant(
               principal: agent_id,
               resource: "arbor://action/coding/reviewed_validation",
               constraints: %{}
             )

    on_exit(fn -> Arbor.Security.revoke(cap.id) end)
    cap
  end

  # Count raw nested started signals. The generic executor and nested action
  # each emit one, so callers assert the exact expected pair per invocation.
  defp attach_nested_attempt_counter!(counter, action_name) do
    parent = self()

    assert {:ok, sub_id} =
             Arbor.Signals.subscribe("action.started", fn signal ->
               name = signal.data[:action] || signal.data["action"]

               if name == action_name do
                 :counters.add(counter, 1, 1)
                 send(parent, {:nested_attempt, name})
               end

               :ok
             end)

    on_exit(fn -> Arbor.Signals.unsubscribe(sub_id) end)
    sub_id
  end

  defp await_pending_request(agent_id, attempts \\ 250)

  defp await_pending_request(agent_id, 0) do
    flunk("timed out waiting for pending approval for #{agent_id}")
  end

  defp await_pending_request(agent_id, attempts) do
    case Enum.find(Arbor.Comms.InteractionRouter.pending(), &(&1.agent_id == agent_id)) do
      nil ->
        Process.sleep(20)
        await_pending_request(agent_id, attempts - 1)

      request ->
        request
    end
  end

  defp request_resource(request) do
    request.resource_uri ||
      get_in(request.metadata, [:resource_uri]) ||
      get_in(request.metadata, ["resource_uri"]) ||
      ""
  end

  defp unique_agent(label) do
    "agent_rv_#{label}_#{System.unique_integer([:positive])}"
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
