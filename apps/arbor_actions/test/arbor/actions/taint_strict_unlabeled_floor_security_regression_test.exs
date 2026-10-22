defmodule Arbor.Actions.TaintStrictUnlabeledFloorSecurityRegressionTest do
  @moduledoc """
  Security regression: group N residuals after PR #26.

  Under `:strict`, an unlabeled `:control` param (nil, missing, or no
  metadata) must count as `:untrusted` and be denied. An empty
  `:param_taint` map must not ignore an untrusted aggregate. A context
  `:permissive` cannot go below a configured `:strict` in prod, and
  `Capability.taint_policy/1` is a floor over a weaker context policy.
  """
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Actions.File, as: FileActions
  alias Arbor.Actions.TaintEnforcement
  alias Arbor.Contracts.Security.Capability
  alias Arbor.Contracts.Security.Taint

  defmodule MockControlAction do
    def name, do: "taint_strict_unlabeled_floor_control"

    def taint_roles do
      %{
        command: :control,
        sandbox: :control,
        content: :data
      }
    end

    def run(_params, _context), do: {:ok, %{success: true}}
  end

  setup do
    previous_policy = Application.get_env(:arbor_actions, :default_taint_policy)
    previous_runtime = Application.get_env(:arbor_actions, :taint_policy_runtime_env)

    unique = System.unique_integer([:positive])
    principal = "agent_taint_unlabeled_floor_#{unique}"

    workspace =
      Path.join(System.user_home!(), "arbor-taint-unlabeled-floor-ws/ws-#{unique}")

    File.mkdir_p!(workspace)

    {:ok, capability} =
      Arbor.Security.grant_fixture(
        principal: principal,
        resource: "arbor://fs/write#{workspace}/**"
      )

    {:ok, strict_capability} =
      Arbor.Security.grant_fixture(
        principal: principal,
        resource: "arbor://fs/write#{workspace}/strict-cap/**",
        constraints: %{taint_policy: :strict}
      )

    on_exit(fn ->
      Arbor.Security.revoke_fixture(capability.id)
      Arbor.Security.revoke_fixture(strict_capability.id)
      File.rm_rf!(workspace)
      restore_env(:default_taint_policy, previous_policy)
      restore_env(:taint_policy_runtime_env, previous_runtime)
    end)

    {:ok,
     principal: principal,
     workspace: workspace,
     capability: capability,
     strict_capability: strict_capability}
  end

  test "security regression: under strict, an unlabeled :control param is denied", %{
    principal: principal,
    workspace: workspace
  } do
    target = Path.join(workspace, "unlabeled-control.txt")
    trusted_path = sanitized_path_taint()

    missing_label = %{
      workspace: workspace,
      taint_policy: :strict,
      taint: trusted_path,
      param_taint: %{path: trusted_path, content: :trusted}
    }

    nil_label = %{
      workspace: workspace,
      taint_policy: :strict,
      taint: trusted_path,
      param_taint: %{path: trusted_path, content: :trusted, mode: nil}
    }

    no_metadata = %{workspace: workspace, taint_policy: :strict}

    params = %{path: target, content: "must not land", mode: :write}

    assert {:error, {:taint_blocked, :mode, :untrusted, :control}} =
             TaintEnforcement.check(FileActions.Write, params, missing_label)

    assert {:error, {:taint_blocked, :mode, :untrusted, :control}} =
             TaintEnforcement.check(FileActions.Write, params, nil_label)

    assert {:error, {:taint_blocked, unlabeled, :untrusted, :control}} =
             TaintEnforcement.check(FileActions.Write, params, no_metadata)

    assert unlabeled in [:path, :mode]

    assert {:error, {:taint_blocked, :command, :untrusted, :control}} =
             TaintEnforcement.check(
               MockControlAction,
               %{command: "echo unlabeled"},
               %{taint_policy: :strict, param_taint: %{content: :trusted}}
             )

    assert {:error, {:taint_blocked, blocked, :untrusted, :control}} =
             Arbor.Actions.authorize_and_execute(
               principal,
               FileActions.Write,
               params,
               missing_label
             )

    assert blocked == :mode
    refute File.exists?(target)
  end

  test "security regression: an empty param_taint map with an untrusted overall label is denied" do
    context = %{
      taint: :untrusted,
      param_taint: %{},
      taint_policy: :permissive
    }

    assert {:error, {:taint_blocked, :sandbox, :untrusted, :control}} =
             TaintEnforcement.check(MockControlAction, %{sandbox: "basic"}, context)

    nested = %{
      taint: :untrusted,
      taint_context: %{param_taint: %{}},
      taint_policy: :permissive
    }

    assert {:error, {:taint_blocked, :command, :untrusted, :control}} =
             TaintEnforcement.check(MockControlAction, %{command: "echo empty"}, nested)
  end

  test "security regression: context :permissive against configured :strict resolves to strict",
       %{principal: principal, workspace: workspace} do
    Application.put_env(:arbor_actions, :default_taint_policy, :strict)
    Application.put_env(:arbor_actions, :taint_policy_runtime_env, :prod)

    target = Path.join(workspace, "context-permissive-prod.txt")
    derived = derived_path_taint()

    context = %{
      workspace: workspace,
      taint: derived,
      param_taint: %{path: derived, content: :trusted, mode: derived},
      taint_policy: :permissive
    }

    params = %{path: target, content: "must not land", mode: :write}

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

  test "security regression: a :strict capability beats a :permissive context", %{
    principal: principal,
    workspace: workspace,
    strict_capability: strict_capability
  } do
    target = Path.join([workspace, "strict-cap", "cap-floor.txt"])
    File.mkdir_p!(Path.dirname(target))
    derived = derived_path_taint()

    context = %{
      workspace: workspace,
      taint: derived,
      param_taint: %{path: derived, content: :trusted, mode: derived},
      taint_policy: :permissive,
      capability: strict_capability
    }

    params = %{path: target, content: "must not land", mode: :write}

    assert Capability.taint_policy(strict_capability) == :strict

    assert {:error, {:taint_blocked, blocked, :derived, :control}} =
             TaintEnforcement.check(FileActions.Write, params, context)

    assert blocked in [:path, :mode]

    assert {:error, {:taint_blocked, auth_blocked, :derived, :control}} =
             Arbor.Actions.authorize_and_execute(
               principal,
               FileActions.Write,
               params,
               Map.delete(context, :capability)
             )

    assert auth_blocked in [:path, :mode]
    refute File.exists?(target)
  end

  defp sanitized_path_taint do
    bits = Map.fetch!(Taint.sanitization_bits(), :path_traversal)
    %Taint{level: :trusted, sanitizations: bits}
  end

  defp derived_path_taint do
    bits = Map.fetch!(Taint.sanitization_bits(), :path_traversal)
    %Taint{level: :derived, sanitizations: bits}
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_actions, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_actions, key, value)
end
