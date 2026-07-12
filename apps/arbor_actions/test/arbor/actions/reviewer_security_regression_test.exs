defmodule Arbor.Actions.ReviewerSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions.Git
  alias Arbor.Actions.Mix.Format, as: MixFormat
  alias Arbor.Actions.Shell.Execute

  @moduletag :fast
  @moduletag :security_regression

  test "security regression: Shell Execute rejects absent principal authority" do
    root = fixture_root("missing-principal")
    marker = Path.join(root, "executed")
    File.mkdir_p!(root)

    try do
      assert {:error, message} =
               Execute.run(%{command: "touch -- #{marker}", sandbox: :none}, %{})

      assert message =~ "requires one authenticated principal"
      refute File.exists?(marker)
    after
      File.rm_rf!(root)
    end
  end

  test "security regression: outer authorization rejects a caller-controlled inner principal" do
    assert {:error, {:principal_context_mismatch, "agent_outer", ["agent_inner"]}} =
             Arbor.Actions.authorize_and_execute(
               "agent_outer",
               Execute,
               %{command: "echo denied", sandbox: :none},
               %{agent_id: "agent_inner"}
             )
  end

  test "security regression: outer authorization rejects duplicate principal namespaces" do
    assert {:error, {:principal_context_mismatch, "agent_outer", ["agent_outer", "agent_outer"]}} =
             Arbor.Actions.authorize_and_execute(
               "agent_outer",
               Execute,
               %{command: "echo denied", sandbox: :none},
               %{"agent_id" => "agent_outer", agent_id: "agent_outer"}
             )
  end

  test "security regression: Trust block cannot be bypassed through direct Shell facade" do
    ensure_trust_started()
    previous_authorizer = Application.get_env(:arbor_shell, :agent_authorizer)
    previous = security_config()
    configure_minimal_security()
    Application.delete_env(:arbor_shell, :agent_authorizer)

    agent_id = "agent_trust_block_#{System.unique_integer([:positive])}"
    resource = "arbor://shell/exec/touch"
    root = fixture_root("trust-block")
    marker = Path.join(root, "executed")
    File.mkdir_p!(root)

    {:ok, profile} = Arbor.Contracts.Trust.Profile.new(agent_id)

    :ok =
      Arbor.Trust.Store.store_profile(%{
        profile
        | rules: Map.put(profile.rules, resource, :block)
      })

    {:ok, _capability} = Arbor.Security.grant(principal: agent_id, resource: resource)

    try do
      assert {:error, :unauthorized} =
               Arbor.Actions.Shell.authorize_command(agent_id, "touch -- #{marker}")

      assert {:error, :agent_authorizer_unavailable} =
               Arbor.Shell.authorize_and_execute(
                 agent_id,
                 "touch -- #{marker}",
                 sandbox: :none
               )

      refute File.exists?(marker)
    after
      restore_security_config(previous)
      restore(:arbor_shell, :agent_authorizer, previous_authorizer)
      File.rm_rf!(root)
    end
  end

  test "security regression: Git rejects core.worktree outside authorized repository" do
    root = fixture_root("git-worktree")
    repo = Path.join(root, "repo")
    outside = Path.join(root, "outside")
    File.mkdir_p!(repo)
    File.mkdir_p!(outside)

    assert {_output, 0} = System.cmd("git", ["init", "-q"], cd: repo)
    assert {_output, 0} = System.cmd("git", ["config", "core.worktree", outside], cd: repo)
    File.write!(Path.join(outside, "outside.txt"), "must not be adopted")

    try do
      assert {:error, message} = Git.Status.run(%{path: repo}, %{})
      assert message =~ "git_worktree_outside_authorized_root"
    after
      File.rm_rf!(root)
    end
  end

  test "security regression: Mix Format rejects --no-exit file option injection" do
    root = format_fixture("option-injection")
    source = Path.join(root, "bad.ex")
    before = File.read!(source)

    try do
      assert {:error, message} =
               MixFormat.run(
                 %{path: root, check_only: true, files: ["--no-exit", "bad.ex"]},
                 %{}
               )

      assert message =~ "invalid_format_file"
      assert File.read!(source) == before
    after
      File.rm_rf!(root)
    end
  end

  test "security regression: Mix Format rejects unknown option keys" do
    root = format_fixture("unknown-option")

    try do
      assert {:error, message} =
               MixFormat.run(%{path: root, files: ["bad.ex"], no_exit: true}, %{})

      assert message =~ "unsupported_format_option"
    after
      File.rm_rf!(root)
    end
  end

  test "security regression: Mix Format rejects non-boolean check mode" do
    root = format_fixture("check-mode")

    try do
      assert {:error, message} =
               MixFormat.run(%{path: root, check_only: "false", files: ["bad.ex"]}, %{})

      assert message =~ "invalid_check_only"
    after
      File.rm_rf!(root)
    end
  end

  test "security regression: Mix Format rejects glob expansion" do
    root = format_fixture("glob")

    try do
      assert {:error, message} = MixFormat.run(%{path: root, files: ["*.ex"]}, %{})
      assert message =~ "invalid_format_file"
    after
      File.rm_rf!(root)
    end
  end

  test "security regression: Mix Format cannot rewrite a path outside its root" do
    root = format_fixture("path-escape")
    outside = Path.join(Path.dirname(root), "outside_#{System.unique_integer([:positive])}.ex")
    File.write!(outside, "defmodule Outside do\n def value,do: 1\nend\n")
    before = File.read!(outside)

    try do
      assert {:error, message} =
               MixFormat.run(%{path: root, files: ["../#{Path.basename(outside)}"]}, %{})

      assert message =~ "invalid_format_file"
      assert File.read!(outside) == before
    after
      File.rm_rf!(root)
      File.rm(outside)
    end
  end

  defp format_fixture(tag) do
    root = fixture_root(tag)
    File.mkdir_p!(root)
    File.write!(Path.join(root, ".formatter.exs"), "[inputs: [\"*.ex\"]]\n")
    File.write!(Path.join(root, "bad.ex"), "defmodule Bad do\n def value,do: 1\nend\n")
    root
  end

  defp fixture_root(tag) do
    Path.join(
      System.tmp_dir!(),
      "arbor_actions_reviewer_#{tag}_#{System.unique_integer([:positive])}"
    )
  end

  defp ensure_trust_started do
    {:ok, _} = Application.ensure_all_started(:arbor_security)
    {:ok, _} = Application.ensure_all_started(:arbor_trust)

    if Process.whereis(Arbor.Trust.Store) == nil do
      start_supervised!(Arbor.Trust.Store)
    end
  end

  defp security_config do
    %{
      reflex: Application.get_env(:arbor_security, :reflex_checking_enabled),
      signing: Application.get_env(:arbor_security, :capability_signing_required),
      identity: Application.get_env(:arbor_security, :strict_identity_mode),
      uri_registry: Application.get_env(:arbor_security, :uri_registry_enforcement),
      escalation: Application.get_env(:arbor_security, :consensus_escalation_enabled),
      security_approval: Application.get_env(:arbor_security, :approval_guard_enabled),
      receipts: Application.get_env(:arbor_security, :invocation_receipts_enabled),
      trust_guard: Application.get_env(:arbor_trust, :approval_guard_enabled),
      trust_enforcer: Application.get_env(:arbor_trust, :policy_enforcer_enabled)
    }
  end

  defp configure_minimal_security do
    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :uri_registry_enforcement, false)
    Application.put_env(:arbor_security, :consensus_escalation_enabled, false)
    Application.put_env(:arbor_security, :approval_guard_enabled, false)
    Application.put_env(:arbor_security, :invocation_receipts_enabled, false)
    Application.put_env(:arbor_trust, :approval_guard_enabled, true)
    Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)
  end

  defp restore_security_config(previous) do
    restore(:arbor_security, :reflex_checking_enabled, previous.reflex)
    restore(:arbor_security, :capability_signing_required, previous.signing)
    restore(:arbor_security, :strict_identity_mode, previous.identity)
    restore(:arbor_security, :uri_registry_enforcement, previous.uri_registry)
    restore(:arbor_security, :consensus_escalation_enabled, previous.escalation)
    restore(:arbor_security, :approval_guard_enabled, previous.security_approval)
    restore(:arbor_security, :invocation_receipts_enabled, previous.receipts)
    restore(:arbor_trust, :approval_guard_enabled, previous.trust_guard)
    restore(:arbor_trust, :policy_enforcer_enabled, previous.trust_enforcer)
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
