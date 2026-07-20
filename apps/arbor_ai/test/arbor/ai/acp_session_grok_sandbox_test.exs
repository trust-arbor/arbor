defmodule Arbor.AI.AcpSession.GrokSandboxTest do
  use ExUnit.Case, async: false
  import Bitwise

  alias Arbor.Common.SafePath
  alias Arbor.AI.AcpSession
  alias Arbor.AI.AcpSession.GrokSandbox

  @expected_grok_command [
    "grok",
    "--sandbox",
    "strict",
    "--no-memory",
    "--no-subagents",
    "--disable-web-search",
    "--deny",
    "MCPTool(*)",
    "--deny",
    "Bash(*)",
    "agent",
    "--no-leader",
    "--model",
    "grok-4.5",
    "stdio"
  ]

  defmodule ProbeAcpClient do
    def start_link(opts) do
      case Keyword.get(opts, :start_mode) do
        :stall ->
          send_signal(test_signal_pid(opts), {:grok_client_started, opts, self()})
          Process.sleep(:infinity)

        _ ->
          with {:ok, pid} <- Agent.start_link(fn -> %{opts: opts} end) do
            send_signal(test_pid(pid), {:grok_client_started, opts, pid})
            {:ok, pid}
          end
      end
    end

    def new_session(client, _cwd, _opts) do
      send_signal(test_pid(client), {:grok_client_new_session, client, test_opts(client).opts})
      {:ok, %{"sessionId" => "probe-session"}}
    end

    def load_session(client, session_id, _cwd, _opts) do
      load_mode = test_opts(client).opts[:load_mode]
      test_pid = test_pid(client)

      send_signal(
        test_pid,
        {:grok_client_load_session, client, session_id, test_opts(client).opts}
      )

      result =
        case {session_id, load_mode} do
          {"probe-session", :fail} ->
            send_signal(test_pid, {:grok_client_disconnected, client})
            Process.exit(client, :kill)
            {:error, :forced_load_failure}

          {_, :fail} ->
            send_signal(test_pid, {:grok_client_disconnected, client})
            Process.exit(client, :kill)
            {:error, :forced_load_failure}

          _ ->
            {:ok, %{"sessionId" => session_id}}
        end

      send_signal(
        test_pid,
        {:grok_client_load_result, client, session_id, load_mode, result}
      )

      result
    end

    def set_config_option(_client, _session_id, _key, _value), do: :ok

    def cancel(_client, _session_id), do: :ok

    def prompt(_client, _session_id, _content, _opts), do: {:ok, %{"text" => "ok"}}

    def disconnect(client) do
      send_signal(test_pid(client), {:grok_client_disconnected, client})
      Agent.stop(client, :normal)
      :ok
    end

    defp test_opts(client), do: Agent.get(client, & &1)

    defp test_pid(client), do: Keyword.get(test_opts(client).opts, :test_pid)

    defp test_signal_pid(opts) when is_list(opts),
      do: Keyword.get(opts, :test_pid)

    defp test_signal_pid(_opts), do: nil

    defp send_signal(nil, _message), do: :ok

    defp send_signal(pid, message) when is_pid(pid),
      do: send(pid, message)

    defp send_signal(_pid, _message), do: :ok
  end

  defp temp_path(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  defp project_profile_path(worktree) do
    Path.join([worktree, ".grok", "sandbox.toml"])
  end

  defp project_backup_path(worktree) do
    Path.join([worktree, ".grok", ".sandbox.toml.arbor-backup"])
  end

  defp canonical_repo_common_dir(repository_root) do
    case SafePath.resolve_real(repository_root) do
      {:ok, canonical_root} ->
        Path.join(canonical_root, ".git")

      {:error, reason} ->
        flunk("failed to canonicalize repository root #{repository_root}: #{inspect(reason)}")
    end
  end

  defp canonical_path(path) do
    case SafePath.resolve_real(path) do
      {:ok, canonical_path} -> canonical_path
      {:error, reason} -> flunk("failed to canonicalize path #{path}: #{inspect(reason)}")
    end
  end

  defp worktree_gitdir(worktree) do
    worktree_gitdir_file = Path.join(worktree, ".git")

    case File.read(worktree_gitdir_file) do
      {:ok, "gitdir: " <> path} -> String.trim(path)
      {:ok, other} -> String.trim(other)
      {:error, _reason} -> flunk("worktree .git pointer missing: #{worktree}")
    end
  end

  defp expected_profile_name(common_dir) do
    "arbor-grok-strict-" <>
      (Base.encode16(:crypto.hash(:sha256, common_dir), case: :lower) |> String.slice(0, 24))
  end

  defp git_cmd(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        flunk("git #{Enum.join(args, " ")} failed in #{cwd} (#{status}): #{output}")
    end
  end

  defp create_git_repo!() do
    repository = temp_path("arbor-ai-grok-repo")
    git_cmd(repository, ["init", "-b", "main"])
    git_cmd(repository, ["config", "user.name", "Acp Test"])
    git_cmd(repository, ["config", "user.email", "acp-test@example.com"])
    File.write!(Path.join(repository, "README.md"), "grok fixture\n")
    git_cmd(repository, ["add", "README.md"])

    case System.cmd("git", ["commit", "-q", "-m", "fixture", "--no-gpg-sign"],
           cd: repository,
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {output, status} ->
        if status == 1 and is_binary(output) and String.contains?(output, "nothing to commit") do
          :ok
        else
          flunk("git commit failed in #{repository} (#{status}): #{String.trim(output)}")
        end
    end

    repository
  end

  defp create_linked_fixture!(worktree_suffix \\ "worktree", branch_suffix \\ nil) do
    repository = create_git_repo!()
    branch = branch_suffix || "grok-test-#{System.unique_integer([:positive])}"

    worktree =
      Path.join(
        System.tmp_dir!(),
        "arbor-ai-grok-worktree-#{worktree_suffix}-#{System.unique_integer([:positive])}"
      )

    git_cmd(repository, ["worktree", "add", "-b", branch, worktree])

    on_exit(fn ->
      File.rm_rf!(repository)
      File.rm_rf!(worktree)
    end)

    {canonical_path(repository), canonical_path(worktree)}
  end

  defp create_standalone_fixture!() do
    worktree = temp_path("arbor-ai-grok-standalone")
    File.mkdir_p!(Path.join(worktree, ".git"))
    worktree
  end

  defp create_temporary_workspace_isolation!() do
    home = temp_path("arbor-ai-grok-home")
    grok_home = Path.join(home, ".grok")
    previous_grok_home = System.get_env("GROK_HOME")

    System.put_env("GROK_HOME", grok_home)

    on_exit(fn ->
      if previous_grok_home do
        System.put_env("GROK_HOME", previous_grok_home)
      else
        System.delete_env("GROK_HOME")
      end

      File.rm_rf!(home)
    end)

    %{home: home, grok_home: grok_home}
  end

  defp install_client_module(module) do
    previous = Application.get_env(:arbor_ai, :acp_client_module)
    Application.put_env(:arbor_ai, :acp_client_module, module)

    on_exit(fn ->
      if previous do
        Application.put_env(:arbor_ai, :acp_client_module, previous)
      else
        Application.delete_env(:arbor_ai, :acp_client_module)
      end
    end)
  end

  defp probe_client_opts(overrides) do
    Keyword.merge([command: @expected_grok_command], overrides)
  end

  defp wait_for_status(session, status, attempts \\ 30, delay_ms \\ 20) do
    if :sys.get_state(session).status == status do
      :ok
    else
      if attempts <= 0 do
        flunk("Timed out waiting for AcpSession status #{inspect(status)}")
      else
        Process.sleep(delay_ms)
        wait_for_status(session, status, attempts - 1, delay_ms)
      end
    end
  end

  defp wait_for_not_alive(pid, attempts \\ 30, delay_ms \\ 25) do
    if Process.alive?(pid) do
      if attempts <= 0 do
        flunk("Timed out waiting for process #{inspect(pid)} to terminate")
      else
        Process.sleep(delay_ms)
        wait_for_not_alive(pid, attempts - 1, delay_ms)
      end
    else
      :ok
    end
  end

  defp probe_client_state(client) when is_pid(client) do
    try do
      {:ok, Agent.get(client, & &1)}
    rescue
      _ -> :not_probe
    end
  end

  defp probe_client_state(_client), do: :not_probe

  defp escape_toml(value) when is_binary(value) do
    value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
  end

  setup do
    create_temporary_workspace_isolation!()
    :ok
  end

  describe "grok sandbox authorization" do
    test "bind succeeds for matching repo/worktree" do
      {repository_root, worktree_root} = create_linked_fixture!()

      assert {:ok, authority} = GrokSandbox.bind(repository_root, worktree_root)
      assert authority.owner == self()
      assert {:ok, canonical_repository_root} = SafePath.resolve_real(repository_root)
      assert authority.repository_root == canonical_repository_root
      assert authority.worktree_root == Path.expand(worktree_root)
      assert authority.common_dir == canonical_repo_common_dir(repository_root)
      assert is_reference(authority.reference)
      assert is_map(authority.snapshot)
    end

    test "bind fails if repository root does not match worktree metadata" do
      {_expected_repository, wrong_worktree} = create_linked_fixture!()
      wrong_repository = create_git_repo!()
      on_exit(fn -> File.rm_rf!(wrong_repository) end)

      assert {:error, :grok_worktree_repository_mismatch} =
               GrokSandbox.bind(wrong_repository, wrong_worktree)
    end

    test "security regression: bind rejects an unproven transient profile backup" do
      {repository_root, worktree_root} = create_linked_fixture!()
      backup_path = project_backup_path(worktree_root)
      File.mkdir_p!(Path.dirname(backup_path))
      File.write!(backup_path, "[profiles.untrusted]\nextends = \"permissive\"\n")

      assert {:error, :ambiguous_grok_profile_recovery} =
               GrokSandbox.bind(repository_root, worktree_root)

      assert File.read!(backup_path) == "[profiles.untrusted]\nextends = \"permissive\"\n"
      refute File.exists?(project_profile_path(worktree_root))
    end

    test "with_launch rejects authority owned by different process" do
      {repository_root, worktree_root} = create_linked_fixture!()
      assert {:ok, authority} = GrokSandbox.bind(repository_root, worktree_root)

      other_owner =
        spawn(fn ->
          receive do
            :owner_stop -> :ok
          end
        end)

      on_exit(fn -> send(other_owner, :owner_stop) end)

      tampered_authority = %{authority | owner: other_owner}

      assert {:error, :grok_linked_worktree_authority_required} =
               GrokSandbox.with_launch(
                 :grok,
                 [command: @expected_grok_command],
                 worktree_root,
                 tampered_authority,
                 self(),
                 fn _ -> flunk("callback should not run") end
               )
    end

    test "grok_sandbox_authority can be adopted by the receiving process" do
      {repository_root, worktree_root} = create_linked_fixture!()
      assert {:ok, authority} = GrokSandbox.bind(repository_root, worktree_root)

      assert {:ok, adopted} = GrokSandbox.adopt_authority(self(), authority)

      assert adopted.owner == self()
      assert adopted.reference != authority.reference
      assert adopted.repository_root == authority.repository_root
      assert adopted.worktree_root == authority.worktree_root
      assert adopted.common_dir == authority.common_dir
      assert adopted.gitdir == authority.gitdir
      assert adopted.snapshot == authority.snapshot
    end

    test "grok_sandbox_authority adoption rejects wrong live owner" do
      {repository_root, worktree_root} = create_linked_fixture!()
      assert {:ok, authority} = GrokSandbox.bind(repository_root, worktree_root)

      other_owner =
        spawn(fn ->
          receive do
            :other_owner_stop -> :ok
          end
        end)

      on_exit(fn -> send(other_owner, :other_owner_stop) end)

      assert {:error, :grok_linked_worktree_authority_required} =
               GrokSandbox.adopt_authority(other_owner, authority)
    end

    test "grok_sandbox_authority adoption rejects dead owner" do
      {repository_root, worktree_root} = create_linked_fixture!()
      parent = self()

      {owner, monitor} =
        spawn_monitor(fn ->
          result = GrokSandbox.bind(repository_root, worktree_root)
          send(parent, {:bound_by_owner, self(), result})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:bound_by_owner, ^owner, {:ok, authority}}
      send(owner, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}

      assert {:error, :grok_worktree_authority_changed} =
               GrokSandbox.adopt_authority(owner, authority)
    end

    test "grok_sandbox_authority adoption rejects malformed authority input" do
      {repository_root, worktree_root} = create_linked_fixture!()
      assert {:ok, _authority} = GrokSandbox.bind(repository_root, worktree_root)

      assert {:error, :invalid_grok_worktree_authority} =
               GrokSandbox.adopt_authority(self(), %{owner: self()})
    end

    test "grok_sandbox_authority adoption rejects metadata mutation after bind" do
      {repository_root, worktree_root} = create_linked_fixture!()
      assert {:ok, authority} = GrokSandbox.bind(repository_root, worktree_root)

      commondir = Path.join(worktree_gitdir(worktree_root), "commondir")
      File.write!(commondir, "/definitely/not/the/original")

      assert {:error, :grok_worktree_authority_changed} =
               GrokSandbox.adopt_authority(self(), authority)
    end

    test "metadata mutation after bind makes launch fail" do
      {repository_root, worktree_root} = create_linked_fixture!()
      assert {:ok, authority} = GrokSandbox.bind(repository_root, worktree_root)

      gitdir = worktree_gitdir(worktree_root)
      commondir = Path.join(gitdir, "commondir")
      File.write!(commondir, "/definitely/not/the/original")

      assert {:error, reason} =
               GrokSandbox.with_launch(
                 :grok,
                 [command: @expected_grok_command],
                 worktree_root,
                 authority,
                 self(),
                 fn _ -> flunk("callback should not run") end
               )

      assert reason in [:grok_worktree_authority_changed, :invalid_grok_directory]
    end

    test "with_launch installs a scoped profile only for callback scope and restores after callback" do
      {repository_root, worktree_root} = create_linked_fixture!()
      assert {:ok, authority} = GrokSandbox.bind(repository_root, worktree_root)

      canonical_repository_root = canonical_repo_common_dir(repository_root)
      expected_profile = expected_profile_name(canonical_repository_root)
      profile_path = project_profile_path(worktree_root)

      assert {:ok, :callback_seen} =
               GrokSandbox.with_launch(
                 :grok,
                 [command: @expected_grok_command],
                 worktree_root,
                 authority,
                 self(),
                 fn prepared ->
                   assert profile_path |> File.exists?()
                   assert Keyword.get(prepared, :command) != @expected_grok_command
                   assert Enum.at(Keyword.get(prepared, :command), 2) == expected_profile
                   :callback_seen
                 end
               )

      refute File.exists?(profile_path)
      refute File.dir?(Path.dirname(profile_path))
    end

    test "TOML escaping for quoted and backslash paths remains parseable" do
      special_name = ~S[quoted"path\with\slash]
      {repository_root, worktree_root} = create_linked_fixture!(special_name, "quoted-path")
      assert {:ok, authority} = GrokSandbox.bind(repository_root, worktree_root)

      canonical_repository_root = canonical_repo_common_dir(repository_root)
      expected_profile = expected_profile_name(canonical_repository_root)
      profile_path = project_profile_path(worktree_root)
      backup_path = project_backup_path(worktree_root)

      denied_paths = [
        profile_path,
        backup_path,
        Path.join([worktree_root, ".grok", "config.toml"]),
        Path.join(worktree_root, ".mcp.json"),
        Path.join([worktree_root, ".cursor", "mcp.json"]),
        Path.join([worktree_root, ".grok", "plugins"]),
        Path.join([worktree_root, ".claude", "plugins"])
      ]

      assert {:ok, :toml_ok} =
               GrokSandbox.with_launch(
                 :grok,
                 [command: @expected_grok_command],
                 worktree_root,
                 authority,
                 self(),
                 fn _ ->
                   assert File.exists?(profile_path)
                   content = File.read!(profile_path)

                   assert content =~
                            "read_only = [\"#{escape_toml(canonical_repo_common_dir(repository_root))}\"]"

                   assert {:ok, decoded} = Toml.decode(content, keys: :strings)
                   profile = get_in(decoded, ["profiles", expected_profile])
                   assert profile["read_only"] == [canonical_repo_common_dir(repository_root)]
                   assert profile["deny"] == denied_paths

                   :toml_ok
                 end
               )
    end

    test "pre-existing project profile bytes and mode restore exactly" do
      {repository_root, worktree_root} = create_linked_fixture!()
      assert {:ok, authority} = GrokSandbox.bind(repository_root, worktree_root)

      profile_path = project_profile_path(worktree_root)
      File.mkdir_p!(Path.dirname(profile_path))
      original = "pre-existing bytes\n"

      File.write!(profile_path, original)
      File.chmod(profile_path, 0o640)
      original_mode = File.lstat!(profile_path).mode &&& 0o777

      assert {:ok, :mutated} =
               GrokSandbox.with_launch(
                 :grok,
                 [command: @expected_grok_command],
                 worktree_root,
                 authority,
                 self(),
                 fn _ ->
                   assert File.read!(profile_path) != original
                   :mutated
                 end
               )

      assert File.read!(profile_path) == original
      assert (File.lstat!(profile_path).mode &&& 0o777) == original_mode
      assert File.exists?(profile_path)
      refute File.exists?(project_backup_path(worktree_root))
    end

    test "global same-name collision is rejected" do
      {repository_root, worktree_root} = create_linked_fixture!()
      assert {:ok, authority} = GrokSandbox.bind(repository_root, worktree_root)

      profile_name = expected_profile_name(canonical_repo_common_dir(repository_root))
      global_sandbox = Path.join(System.get_env("GROK_HOME"), "sandbox.toml")
      File.mkdir_p!(Path.dirname(global_sandbox))

      File.write!(
        global_sandbox,
        [
          "[profiles.#{profile_name}]\n",
          "extends = \"strict\"\n"
        ]
        |> Enum.join()
      )

      assert {:error, :grok_global_profile_conflict} =
               GrokSandbox.with_launch(
                 :grok,
                 [command: @expected_grok_command],
                 worktree_root,
                 authority,
                 self(),
                 fn _ -> flunk("callback should not run") end
               )
    end

    test "standalone worktree receives a transient strict profile and requires no authority" do
      worktree_root = create_standalone_fixture!()
      expected_profile = expected_profile_name(canonical_path(worktree_root))

      assert {:ok, :standalone_done} =
               GrokSandbox.with_launch(
                 :grok,
                 [command: @expected_grok_command],
                 worktree_root,
                 nil,
                 self(),
                 fn prepared ->
                   assert Enum.at(Keyword.get(prepared, :command), 2) == expected_profile
                   assert File.exists?(project_profile_path(worktree_root))
                   :standalone_done
                 end
               )

      refute File.exists?(project_profile_path(worktree_root))

      assert {:error, :unexpected_grok_sandbox_authority} =
               GrokSandbox.with_launch(
                 :grok,
                 [command: @expected_grok_command],
                 worktree_root,
                 :unexpected,
                 self(),
                 fn _ -> flunk("callback should not run") end
               )
    end

    test "security regression: ambient repository MCP sources fail closed before launch" do
      sources = [
        {[".grok", "config.toml"], :file},
        {[".mcp.json"], :file},
        {[".cursor", "mcp.json"], :file},
        {[".grok", "plugins"], :directory},
        {[".claude", "plugins"], :directory}
      ]

      for {relative, kind} <- sources do
        worktree_root = create_standalone_fixture!()
        path = Path.join([worktree_root | relative])
        File.mkdir_p!(Path.dirname(path))

        case kind do
          :file -> File.write!(path, "untrusted MCP source\n")
          :directory -> File.mkdir!(path)
        end

        assert {:error, :grok_ambient_mcp_configuration_forbidden} =
                 GrokSandbox.with_launch(
                   :grok,
                   [command: @expected_grok_command],
                   worktree_root,
                   nil,
                   self(),
                   fn _ -> flunk("callback should not run") end
                 )
      end
    end

    test "security regression: a repository subdirectory cannot bypass root MCP checks" do
      repository_root = create_git_repo!()
      nested_cwd = Path.join([repository_root, "apps", "nested"])
      File.mkdir_p!(nested_cwd)
      on_exit(fn -> File.rm_rf!(repository_root) end)

      assert {:error, :grok_repository_root_required} =
               GrokSandbox.with_launch(
                 :grok,
                 [command: @expected_grok_command],
                 nested_cwd,
                 nil,
                 self(),
                 fn _ -> flunk("callback should not run") end
               )
    end

    test "an explicitly bound ACP MCP server removes only the blanket MCP denial" do
      worktree_root = create_standalone_fixture!()
      bound_server = %{"name" => "arbor-tools", "type" => "http", "url" => "http://local"}

      assert {:ok, :bound_mcp_ready} =
               GrokSandbox.with_launch(
                 :grok,
                 [command: @expected_grok_command],
                 worktree_root,
                 nil,
                 self(),
                 [bound_server],
                 fn prepared ->
                   command = Keyword.fetch!(prepared, :command)
                   assert "Bash(*)" in command
                   # Bash is still hard-denied under bound MCP because it can spawn
                   # uncontrolled process and network capabilities.
                   assert "--no-memory" in command
                   assert "--no-subagents" in command
                   assert "--disable-web-search" in command
                   assert "--no-leader" in command
                   assert "Bash(*)" in command
                   refute "MCPTool(*)" in command
                   assert Enum.at(command, 5) == "--disable-web-search"
                   assert Enum.at(command, 6) == "--deny"
                   assert Enum.at(command, 7) == "Bash(*)"
                   :bound_mcp_ready
                 end
               )
    end

    test "hostile command and explicit :cd are rejected" do
      {repository_root, worktree_root} = create_linked_fixture!()
      assert {:ok, authority} = GrokSandbox.bind(repository_root, worktree_root)
      bound_server = %{"name" => "bound", "type" => "http", "url" => "http://local"}

      missing_bash = [
        "grok",
        "--sandbox",
        "strict",
        "--no-memory",
        "--no-subagents",
        "--disable-web-search",
        "--deny",
        "MCPTool(*)",
        "agent",
        "--no-leader",
        "--model",
        "grok-4.5",
        "stdio"
      ]

      changed_bash_shape = [
        "grok",
        "--sandbox",
        "strict",
        "--no-memory",
        "--no-subagents",
        "--disable-web-search",
        "--deny",
        "MCPTool(*)",
        "--deny",
        "shell",
        "agent",
        "--no-leader",
        "--model",
        "grok-4.5",
        "stdio"
      ]

      reordered_bash_shape = [
        "grok",
        "--sandbox",
        "strict",
        "--no-memory",
        "--no-subagents",
        "--disable-web-search",
        "--deny",
        "Bash(*)",
        "--deny",
        "MCPTool(*)",
        "agent",
        "--no-leader",
        "--model",
        "grok-4.5",
        "stdio"
      ]

      duplicated_bash_shape = [
        "grok",
        "--sandbox",
        "strict",
        "--no-memory",
        "--no-subagents",
        "--disable-web-search",
        "--deny",
        "MCPTool(*)",
        "--deny",
        "Bash(*)",
        "--deny",
        "Bash(*)",
        "agent",
        "--no-leader",
        "--model",
        "grok-4.5",
        "stdio"
      ]

      hostile = [
        "grok",
        "--sandbox",
        "not-strict",
        "--no-memory",
        "agent",
        "--model",
        "grok-4.5",
        "stdio"
      ]

      assert {:error, :grok_sandbox_command_mismatch} =
               GrokSandbox.with_launch(
                 :grok,
                 [command: missing_bash],
                 worktree_root,
                 nil,
                 self(),
                 fn _ -> flunk("callback should not run") end
               )

      assert {:error, :grok_sandbox_command_mismatch} =
               GrokSandbox.with_launch(
                 :grok,
                 [command: reordered_bash_shape],
                 worktree_root,
                 nil,
                 self(),
                 fn _ -> flunk("callback should not run") end
               )

      assert {:error, :grok_sandbox_command_mismatch} =
               GrokSandbox.with_launch(
                 :grok,
                 [command: changed_bash_shape],
                 worktree_root,
                 nil,
                 self(),
                 fn _ -> flunk("callback should not run") end
               )

      assert {:error, :grok_sandbox_command_mismatch} =
               GrokSandbox.with_launch(
                 :grok,
                 [command: duplicated_bash_shape],
                 worktree_root,
                 nil,
                 self(),
                 fn _ -> flunk("callback should not run") end
               )

      assert {:error, :grok_sandbox_command_mismatch} =
               GrokSandbox.with_launch(
                 :grok,
                 [command: hostile],
                 worktree_root,
                 authority,
                 self(),
                 fn _ -> flunk("callback should not run") end
               )

      assert {:error, :grok_sandbox_command_mismatch} =
               GrokSandbox.with_launch(
                 :grok,
                 [command: missing_bash],
                 worktree_root,
                 authority,
                 self(),
                 [bound_server],
                 fn _ -> flunk("callback should not run") end
               )

      assert {:error, :grok_sandbox_command_mismatch} =
               GrokSandbox.with_launch(
                 :grok,
                 [command: reordered_bash_shape],
                 worktree_root,
                 authority,
                 self(),
                 [bound_server],
                 fn _ -> flunk("callback should not run") end
               )

      assert {:error, :grok_sandbox_command_mismatch} =
               GrokSandbox.with_launch(
                 :grok,
                 [command: changed_bash_shape],
                 worktree_root,
                 authority,
                 self(),
                 fn _ -> flunk("callback should not run") end
               )

      assert {:error, :grok_sandbox_command_mismatch} =
               GrokSandbox.with_launch(
                 :grok,
                 [command: duplicated_bash_shape],
                 worktree_root,
                 authority,
                 self(),
                 fn _ -> flunk("callback should not run") end
               )

      assert {:error, :grok_sandbox_cwd_override_forbidden} =
               GrokSandbox.with_launch(
                 :grok,
                 [command: @expected_grok_command, cd: "/tmp/bad"],
                 worktree_root,
                 authority,
                 self(),
                 fn _ -> flunk("callback should not run") end
               )

      assert {:error, :grok_sandbox_native_transport_required} =
               GrokSandbox.with_launch(
                 :grok,
                 [command: @expected_grok_command, adapter: :untrusted_adapter],
                 worktree_root,
                 authority,
                 self(),
                 fn _ -> flunk("callback should not run") end
               )
    end

    test "callback raise still restores transient profile state" do
      {repository_root, worktree_root} = create_linked_fixture!()
      assert {:ok, authority} = GrokSandbox.bind(repository_root, worktree_root)

      assert_raise RuntimeError, "callback exploded", fn ->
        GrokSandbox.with_launch(
          :grok,
          [command: @expected_grok_command],
          worktree_root,
          authority,
          self(),
          fn _ -> raise RuntimeError, "callback exploded" end
        )
      end

      refute File.exists?(project_profile_path(worktree_root))
      refute File.dir?(Path.dirname(project_profile_path(worktree_root)))
    end

    test "concurrent second launch on same worktree is rejected as busy" do
      {repository_root, worktree_root} = create_linked_fixture!()
      assert {:ok, authority} = GrokSandbox.bind(repository_root, worktree_root)
      owner = self()

      callback_task =
        Task.async(fn ->
          GrokSandbox.with_launch(
            :grok,
            [command: @expected_grok_command],
            worktree_root,
            authority,
            owner,
            fn _ ->
              send(owner, {:launch_in_callback, self()})

              receive do
                :release -> :callback_done
              end
            end
          )
        end)

      assert_receive {:launch_in_callback, callback_pid}, 1_000

      assert {:error, :grok_sandbox_profile_busy} =
               GrokSandbox.with_launch(
                 :grok,
                 [command: @expected_grok_command],
                 worktree_root,
                 authority,
                 owner,
                 fn _ -> :unexpected_end end
               )

      send(callback_pid, :release)
      assert Task.await(callback_task) == {:ok, :callback_done}
    end
  end

  describe "AcpSession integration" do
    test "startup sends exact :cd and clears profile before create_session" do
      install_client_module(ProbeAcpClient)
      {repository_root, worktree_root} = create_linked_fixture!()
      assert {:ok, authority} = GrokSandbox.bind(repository_root, worktree_root)

      assert {:ok, session} =
               AcpSession.start_link(
                 provider: :grok,
                 workspace: {:directory, worktree_root},
                 client_opts:
                   probe_client_opts(
                     test_pid: self(),
                     handler_opts: [cwd: "/tmp/untrusted", preserved: :value]
                   ),
                 grok_sandbox_authority: authority,
                 timeout: 2_000
               )

      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      expected_profile = expected_profile_name(authority.common_dir)
      expected_path = Path.expand(worktree_root)

      assert {:ok, %{opts: started_opts}} = probe_client_state(:sys.get_state(session).client)
      assert Keyword.get(started_opts, :cd) == expected_path
      assert get_in(started_opts, [:handler_opts, :cwd]) == expected_path
      assert get_in(started_opts, [:handler_opts, :preserved]) == :value
      assert Enum.at(Keyword.get(started_opts, :command), 2) == expected_profile
      refute File.exists?(project_profile_path(worktree_root))
      assert {:ok, _session_info} = AcpSession.create_session(session)

      assert :ok = AcpSession.close(session)
    end

    test "startup timeout on stalled client restores transient profile" do
      install_client_module(ProbeAcpClient)
      {repository_root, worktree_root} = create_linked_fixture!()
      assert {:ok, authority} = GrokSandbox.bind(repository_root, worktree_root)

      assert {:ok, session} =
               AcpSession.start_link(
                 provider: :grok,
                 workspace: {:directory, worktree_root},
                 client_opts: probe_client_opts(test_pid: self(), start_mode: :stall),
                 grok_sandbox_authority: authority,
                 timeout: 300
               )

      # Let startup advance and fail on the stalled launch while leaving the transient
      # profile in cleanup scope.
      Process.sleep(450)
      assert {:error, :timeout} = AcpSession.await_ready(session, timeout: 1_000)
      refute File.exists?(project_profile_path(worktree_root))

      assert :ok = AcpSession.close(session)
    end

    test "reconnect uses exact :cd and load failure terminates the spawned client" do
      install_client_module(ProbeAcpClient)
      {repository_root, worktree_root} = create_linked_fixture!()
      assert {:ok, authority} = GrokSandbox.bind(repository_root, worktree_root)
      expected_profile = expected_profile_name(authority.common_dir)
      expected_cd = Path.expand(worktree_root)

      assert {:ok, session} =
               AcpSession.start_link(
                 provider: :grok,
                 workspace: {:directory, worktree_root},
                 client_opts: probe_client_opts(test_pid: self(), load_mode: :fail),
                 grok_sandbox_authority: authority,
                 timeout: 2_000
               )

      assert :ok = AcpSession.await_ready(session, timeout: 1_000)
      state = :sys.get_state(session)
      first_client = state.client
      assert {:ok, %{opts: first_opts}} = probe_client_state(first_client)
      assert Enum.at(first_opts[:command], 2) == expected_profile
      assert first_opts[:cd] == expected_cd
      assert_receive {:grok_client_started, started_opts, ^first_client}, 1_000
      assert Enum.at(started_opts[:command], 2) == expected_profile
      assert started_opts[:cd] == expected_cd

      assert {:ok, _session_info} = AcpSession.create_session(session)
      assert_receive {:grok_client_new_session, ^first_client, _}, 1_000

      first_monitor = Process.monitor(first_client)
      Process.exit(first_client, :kill)
      assert_receive {:DOWN, ^first_monitor, :process, ^first_client, :killed}, 1_000

      assert_receive {:grok_client_started, reconnect_opts, reconnect_client}, 1_000
      assert reconnect_opts[:cd] == expected_cd
      assert reconnect_opts[:test_pid] == self()
      assert Enum.at(reconnect_opts[:command], 2) == expected_profile

      assert_receive {:grok_client_load_session, ^reconnect_client, "probe-session",
                      reconnect_load_opts},
                     1_000

      assert reconnect_load_opts[:load_mode] == :fail

      assert_receive {:grok_client_load_result, ^reconnect_client, "probe-session", :fail,
                      load_result},
                     1_000

      assert load_result == {:error, :forced_load_failure}
      wait_for_status(session, :error)
      wait_for_not_alive(reconnect_client)
      assert :sys.get_state(session).client == nil
      assert :ok = AcpSession.close(session)
    end
  end
end
