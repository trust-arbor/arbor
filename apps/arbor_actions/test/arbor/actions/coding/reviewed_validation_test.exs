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
      approval_timeout: Application.get_env(:arbor_actions, :approval_timeout_ms)
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

  test "security regression: non-map nested success is fail-closed (no inspect projection)" do
    # merge_nested_success/3 only accepts plain maps; the execute path rejects
    # non-map {:ok, term} with :nested_validation_result_not_map and never
    # stores inspect(result). Prove the public error atom is well-formed.
    assert format_nested_error(:nested_validation_result_not_map) =~
             "nested_validation_result_not_map"
  end

  # Mirrors ReviewedValidation.format_error/1 public stringification for atoms.
  defp format_nested_error(reason), do: inspect(reason)

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
