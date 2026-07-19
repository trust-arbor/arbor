defmodule Arbor.Shell.PreparedAuthorizedMultiCallSecurityRegressionTest do
  @moduledoc """
  Security regression: execute_prepared_authorized binds command_name to the
  pinned Executable.name, not Path.basename(executable.path).

  On multi-call Linux images (busybox), TrustedPath canonicalizes applet
  symlinks such as /bin/echo → /bin/busybox. Pre-fix required
  Path.basename(path) == command_name and rejected every positive prepared
  agent command with :invalid_prepared_shell_command even when the original
  command re-prepared to an identical map.

  Exact reprepare equality and pinned path identity remain mandatory.
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  setup_all do
    case Process.whereis(Arbor.Shell.ExecutablePolicy) do
      nil ->
        {:ok, _} =
          Supervisor.start_child(
            Arbor.Shell.Supervisor,
            {Arbor.Shell.ExecutablePolicy, startup_path: System.get_env("PATH", "")}
          )

      _pid ->
        :ok
    end

    case Process.whereis(Arbor.Shell.ExecutionRegistry) do
      nil ->
        {:ok, _} =
          Supervisor.start_child(Arbor.Shell.Supervisor, {Arbor.Shell.ExecutionRegistry, []})

      _pid ->
        :ok
    end

    :ok
  end

  test "security regression: pin name binds command_name when path basename differs" do
    command = "echo multi-call-name-binding"

    assert {:ok, prepared} = Arbor.Shell.prepare_agent_command(command, sandbox: :basic)

    assert prepared.command_name == "echo"
    assert prepared.executable_identity.name == "echo"
    assert prepared.executable == prepared.executable_identity.path

    path_basename = Path.basename(prepared.executable)

    # Authoritative identity is the pin name. Path basename may differ after
    # TrustedPath multi-call canonicalization (busybox → basename "busybox").
    assert prepared.command_name == prepared.executable_identity.name

    # Forged pin name that diverges from command_name fails closed without
    # weakening exact reprepare equality on the real prepared map.
    forged = %{
      prepared
      | executable_identity: %{prepared.executable_identity | name: "busybox"}
    }

    assert forged.command_name != forged.executable_identity.name

    assert {:error, :invalid_prepared_shell_command} =
             Arbor.Shell.execute_prepared_authorized(command, forged, sandbox: :basic)

    # Path smuggling via path-like name is rejected by multi_call_safe_argv0?/1.
    path_like = %{
      prepared
      | command_name: "evil/echo",
        executable_identity: %{prepared.executable_identity | name: "evil/echo"}
    }

    assert {:error, :invalid_prepared_shell_command} =
             Arbor.Shell.execute_prepared_authorized(command, path_like, sandbox: :basic)

    # Exact original command + its prepared map succeeds. On multi-call hosts
    # path_basename != "echo"; pre-fix Path.basename(path) == command_name
    # rejected this exact map after a successful first prepare.
    assert {:ok, result} =
             Arbor.Shell.execute_prepared_authorized(command, prepared, sandbox: :basic)

    assert result.exit_code == 0
    assert result.stdout =~ "multi-call-name-binding"

    if path_basename != prepared.command_name do
      # Linux/busybox regression branch: canonical path is the multi-call binary.
      assert path_basename != prepared.executable_identity.name
      assert prepared.executable_identity.name == prepared.command_name
    end
  end

  test "security regression: reprepare equality still rejects inspect-rebuilt argv" do
    # Independent of multi-call: exact reprepare must reject a non-faithful
    # inspect/1 reconstruction of argv (backslash-bearing operand).
    command = "printf %s a\\b"

    assert {:ok, prepared} = Arbor.Shell.prepare_agent_command(command, sandbox: :basic)

    inspect_rebuilt =
      Enum.map_join([prepared.command_name | prepared.args], " ", &inspect/1)

    assert inspect_rebuilt != command

    assert {:error, :invalid_prepared_shell_command} =
             Arbor.Shell.execute_prepared_authorized(
               inspect_rebuilt,
               prepared,
               sandbox: :basic
             )

    assert {:ok, result} =
             Arbor.Shell.execute_prepared_authorized(command, prepared, sandbox: :basic)

    assert result.exit_code == 0
    assert result.stdout == "a\\b"
  end
end
