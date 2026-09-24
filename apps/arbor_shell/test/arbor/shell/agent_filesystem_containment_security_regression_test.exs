defmodule Arbor.Shell.AgentFilesystemContainmentSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Arbor.Security
  alias Arbor.Shell

  # Only the lower app's test adapter omits Trust; production Actions owns it.
  defmodule Authorizer do
    def authorize_command(agent, _command, opts) do
      Security.authorize(
        agent,
        "arbor://shell/exec/#{opts[:prepared_command].command_name}",
        :execute,
        verify_identity: false
      )
    end

    def authorize_filesystem(agent, uri, operation, capability_id, _opts) do
      Security.authorize_source_owned_exact_ordinary_capability(
        agent,
        uri,
        operation,
        capability_id,
        %{session_id: nil, task_id: nil, principal_scope: nil, expected_egress: nil}
      )
    end
  end

  setup do
    :ok = Security.TestBootstrap.start!()
    old = Application.get_env(:arbor_shell, :agent_authorizer)
    Application.put_env(:arbor_shell, :agent_authorizer, Authorizer)

    root =
      Path.join(
        System.tmp_dir!(),
        "arbor_agent_fs_" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    :ok = File.mkdir(root)
    {:ok, root} = Arbor.Common.SafePath.resolve_real(root)
    cwd = Path.join(root, "work")
    :ok = File.mkdir(cwd)
    File.write!(Path.join(cwd, "input"), "permitted-data")
    File.write!(Path.join(root, "outside"), "outside-data")
    {:ok, identity} = Security.generate_identity(name: "synthetic-shell-containment")
    :ok = Security.register_identity(identity)
    {:ok, _} = Security.grant(principal: identity.agent_id, resource: "arbor://shell/exec/**")

    on_exit(fn ->
      Application.put_env(:arbor_shell, :agent_authorizer, old)
      {:ok, caps} = Security.list_capabilities(identity.agent_id)
      for cap <- caps, do: Security.revoke(cap.id)
      Security.deregister_identity(identity.agent_id)
      File.rm_rf!(root)
    end)

    %{agent: identity.agent_id, root: root, cwd: cwd}
  end

  test "security regression: a command capability alone grants no filesystem access", c do
    result = Shell.authorize_and_execute(c.agent, "cat input", cwd: c.cwd)
    assert {:error, _} = result
  end

  test "security regression: sync async and streaming refuse unqualified platforms or deny outside reads",
       c do
    grant(c, :read)

    for mode <- [:sync, :async, :stream] do
      result = run(mode, c, "cat #{c.root}/outside")

      case :os.type() do
        {:unix, :darwin} ->
          assert {:ok, output, exit_code} = result
          assert exit_code != 0
          refute output =~ "outside-data"

        _ ->
          assert {:error, {:agent_containment_unavailable, :platform_not_qualified}} = result
      end
    end
  end

  test "permitted read and write are real public effects on qualified macOS", c do
    grant(c, :read)
    grant(c, :write)

    if :os.type() == {:unix, :darwin} do
      for mode <- [:sync, :async, :stream] do
        assert {:ok, "permitted-data", 0} = run(mode, c, "cat input")
        assert {:ok, _, 0} = run(mode, c, "touch output_#{mode}")
        assert File.regular?(Path.join(c.cwd, "output_#{mode}"))
      end
    else
      assert {:error, {:agent_containment_unavailable, :platform_not_qualified}} =
               Shell.authorize_and_execute(c.agent, "touch output", cwd: c.cwd)

      refute File.exists?(Path.join(c.cwd, "output"))
    end
  end

  test "security regression: write needs a distinct current filesystem grant", c do
    grant(c, :read)
    assert {:error, _} = Shell.authorize_and_execute(c.agent, "touch output", cwd: c.cwd)
    refute File.exists?(Path.join(c.cwd, "output"))
  end

  test "security regression: revoked read grant cannot be reused", c do
    cap = grant(c, :read)
    assert :ok = Security.revoke(cap.id)
    assert {:error, _} = Shell.authorize_and_execute(c.agent, "cat input", cwd: c.cwd)
  end

  test "security regression: global grants and caller supplied allow paths do not widen scope",
       c do
    {:ok, _} = Security.grant(principal: c.agent, resource: "arbor://fs/**")

    assert {:error, _} =
             Shell.authorize_and_execute(c.agent, "cat input",
               cwd: c.cwd,
               allowed_paths: [c.root],
               agent_containment: %{cwd: c.root, write: true},
               sandbox: :none
             )
  end

  test "security regression: protected credentials and symlink escapes remain unreadable", c do
    grant(c, :read)
    :ok = File.mkdir(Path.join(c.cwd, ".ssh"))
    File.write!(Path.join(c.cwd, ".ssh/id_ed25519"), "synthetic-key")
    :ok = File.ln_s(Path.join(c.root, "outside"), Path.join(c.cwd, "escape"))

    for target <- [".ssh/id_ed25519", "escape"] do
      result = run(:sync, c, "cat #{target}")

      if :os.type() == {:unix, :darwin} do
        assert {:ok, output, code} = result
        assert code != 0
        refute output =~ "synthetic-key"
        refute output =~ "outside-data"
      else
        assert {:error, {:agent_containment_unavailable, :platform_not_qualified}} = result
      end
    end
  end

  test "security regression: anonymous prepared execution cannot bypass containment", c do
    {:ok, prepared} = Shell.prepare_agent_command("cat input", cwd: c.cwd)

    assert {:error, :agent_authority_required} =
             Shell.execute_prepared_authorized("cat input", prepared, cwd: c.cwd)
  end

  test "security regression: another directory grant and unsupported wildcard shapes cannot authorize cwd",
       c do
    for uri <- ["arbor://fs/read#{c.root}/outside/**", "arbor://fs/read#{c.cwd}/*"] do
      {:ok, _} = Security.grant(principal: c.agent, resource: uri)
    end

    assert {:error, _} = Shell.authorize_and_execute(c.agent, "cat input", cwd: c.cwd)
  end

  test "security regression: cwd must be explicit canonical and may not be a protected directory",
       c do
    grant(c, :read)

    for opts <- [[], [cwd: c.cwd <> "/.."], [cwd: "/"]] do
      assert {:error, _} = Shell.authorize_and_execute(c.agent, "cat input", opts)
    end
  end

  test "explicit trusted host execution remains separate", c do
    assert {:ok, %{stdout: "outside-data", exit_code: 0}} =
             Shell.execute_direct("cat", [Path.join(c.root, "outside")],
               cwd: c.cwd,
               sandbox: :none
             )
  end

  defp grant(c, operation) do
    {:ok, cap} =
      Security.grant(
        principal: c.agent,
        resource: "arbor://fs/#{operation}#{c.cwd}/**"
      )

    cap
  end

  defp run(:sync, c, command) do
    case Shell.authorize_and_execute(c.agent, command, cwd: c.cwd, timeout: 5_000) do
      {:ok, r} -> {:ok, r.stdout, r.exit_code}
      other -> other
    end
  end

  defp run(:async, c, command) do
    with {:ok, id} <-
           Shell.authorize_and_execute_async(c.agent, command, cwd: c.cwd, timeout: 5_000),
         {:ok, r} <- Shell.get_result(id, wait: true, timeout: 7_000),
         do: {:ok, r.stdout, r.exit_code}
  end

  defp run(:stream, c, command) do
    case Shell.authorize_and_execute_streaming(c.agent, command,
           cwd: c.cwd,
           timeout: 5_000,
           stream_to: self()
         ) do
      {:ok, id} ->
        assert_receive {:port_exit, ^id, code, output}, 7_000
        {:ok, output, code}

      other ->
        other
    end
  end
end
