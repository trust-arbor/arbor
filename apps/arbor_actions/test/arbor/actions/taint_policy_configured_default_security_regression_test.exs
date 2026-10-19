defmodule Arbor.Actions.TaintPolicyConfiguredDefaultSecurityRegressionTest do
  @moduledoc """
  Security regression: a missing `:taint_policy` must resolve to the configured
  default, never a hard-coded `:permissive`. With no config at all in prod it
  must resolve to `:strict`. arXiv 2610.23362 (Monitor-Validity Failures) —
  a detector fire stranded behind a permissive fallback never becomes a deny.

  These tests fail when `TaintEnforcement.check/3` and
  `Application.get_env/3` fall back to `:permissive`.
  """
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Actions.File, as: FileActions
  alias Arbor.Actions.TaintEnforcement
  alias Arbor.Contracts.Security.Taint

  setup do
    previous_policy = Application.get_env(:arbor_actions, :default_taint_policy)
    previous_runtime = Application.get_env(:arbor_actions, :taint_policy_runtime_env)

    unique = System.unique_integer([:positive])
    principal = "agent_taint_policy_default_#{unique}"

    workspace =
      Path.join(System.user_home!(), "arbor-taint-policy-ws/ws-#{unique}")

    File.mkdir_p!(workspace)

    {:ok, capability} =
      Arbor.Security.grant_fixture(
        principal: principal,
        resource: "arbor://fs/write#{workspace}/**"
      )

    on_exit(fn ->
      Arbor.Security.revoke_fixture(capability.id)
      File.rm_rf!(workspace)
      restore_env(:default_taint_policy, previous_policy)
      restore_env(:taint_policy_runtime_env, previous_runtime)
    end)

    {:ok, principal: principal, workspace: workspace}
  end

  test "security regression: authorize without :taint_policy uses configured :strict, not :permissive",
       %{principal: principal, workspace: workspace} do
    Application.put_env(:arbor_actions, :default_taint_policy, :strict)

    target = Path.join(workspace, "strict-default.txt")
    path_sanitization = Map.fetch!(Taint.sanitization_bits(), :path_traversal)
    derived = %Taint{level: :derived, sanitizations: path_sanitization}

    context = %{
      workspace: workspace,
      taint: derived,
      param_taint: %{path: derived, content: :trusted, mode: derived}
    }

    params = %{path: target, content: "should not land", mode: :write}

    assert {:error, {:taint_blocked, blocked, :derived, :control}} =
             TaintEnforcement.check(FileActions.Write, params, context)

    assert blocked in [:path, :mode]

    assert {:error, {:taint_blocked, auth_blocked, :derived, :control}} =
             Arbor.Actions.authorize_and_execute(
               principal,
               FileActions.Write,
               params,
               context
             )

    assert auth_blocked in [:path, :mode]
    refute File.exists?(target)
  end

  test "security regression: authorize without :taint_policy uses configured :audit_only, not :permissive",
       %{workspace: workspace} do
    Application.put_env(:arbor_actions, :default_taint_policy, :audit_only)

    params = %{
      path: Path.join(workspace, "audit-default.txt"),
      content: "audit only",
      mode: :write
    }

    context = %{taint: :untrusted, param_taint: %{mode: :untrusted}}

    assert :ok = TaintEnforcement.check(FileActions.Write, params, context)
  end

  test "security regression: with no config at all in prod, policy resolves to :strict",
       %{principal: principal, workspace: workspace} do
    Application.delete_env(:arbor_actions, :default_taint_policy)
    Application.put_env(:arbor_actions, :taint_policy_runtime_env, :prod)

    assert TaintEnforcement.configured_policy() == :strict
    assert TaintEnforcement.configured_policy(env: :prod) == :strict

    target = Path.join(workspace, "prod-default.txt")
    path_sanitization = Map.fetch!(Taint.sanitization_bits(), :path_traversal)
    derived = %Taint{level: :derived, sanitizations: path_sanitization}

    context = %{
      workspace: workspace,
      taint: derived,
      param_taint: %{path: derived, content: :trusted, mode: derived}
    }

    params = %{path: target, content: "prod must deny", mode: :write}

    assert {:error, {:taint_blocked, blocked, :derived, :control}} =
             TaintEnforcement.check(FileActions.Write, params, context)

    assert blocked in [:path, :mode]

    assert {:error, {:taint_blocked, auth_blocked, :derived, :control}} =
             Arbor.Actions.authorize_and_execute(
               principal,
               FileActions.Write,
               params,
               context
             )

    assert auth_blocked in [:path, :mode]
    refute File.exists?(target)
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_actions, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_actions, key, value)
end
