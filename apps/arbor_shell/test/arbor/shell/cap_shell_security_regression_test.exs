defmodule Arbor.Shell.CapShellSecurityRegressionTest do
  @moduledoc """
  Security regressions for CapShell fail-closed + authorized-compound residual
  bypasses (intentional API break).

  Agent-authorized boundaries must reject compound commands **before**
  auth/allowlist/session/process/fs work, regardless of
  `compound_shell_enabled` or sandbox level (including `:none`). CapShell and
  `execute_compound_with_capabilities` always return the stable unavailable
  tuple, including for malformed terms (never raise).

  Residual proofs (must fail on the relevant pre-fix parent and pass candidate):
  - bare `authorize/3` for compound (parent authorized leading token only)
  - `authorize_and_execute_async/3` + `authorize_and_execute_streaming/3`
    with `sandbox: :none` (parent lacked unconditional compound rejection)
  - config false + `sandbox: :none` sync compound (parent reached allowlist/auth)
  - malformed CapShell public calls return, not raise
  """
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security.CapabilityStore
  alias Arbor.Shell.CapShell

  @unavailable {:error, {:compound_shell_unavailable, :security_boundary_incomplete}}
  # Outer wait after finite delayed commands (sleep 1) — bounded, not open-ended.
  @side_effect_wait_ms 1_500

  setup do
    ensure_security_started()
    ensure_shell_started()

    prev = %{
      reflex: Application.get_env(:arbor_security, :reflex_checking_enabled),
      signing: Application.get_env(:arbor_security, :capability_signing_required),
      identity: Application.get_env(:arbor_security, :strict_identity_mode),
      approval: Application.get_env(:arbor_security, :approval_guard_enabled),
      receipts: Application.get_env(:arbor_security, :invocation_receipts_enabled),
      compound: Application.get_env(:arbor_shell, :compound_shell_enabled)
    }

    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :approval_guard_enabled, false)
    Application.put_env(:arbor_security, :invocation_receipts_enabled, false)

    agent_id = "agent_capshell_sec_#{:erlang.unique_integer([:positive])}"
    grant_shell_capability(agent_id, "arbor://shell/exec/**")

    on_exit(fn ->
      restore_security(:reflex_checking_enabled, prev.reflex)
      restore_security(:capability_signing_required, prev.signing)
      restore_security(:strict_identity_mode, prev.identity)
      restore_security(:approval_guard_enabled, prev.approval)
      restore_security(:invocation_receipts_enabled, prev.receipts)

      if is_nil(prev.compound),
        do: Application.delete_env(:arbor_shell, :compound_shell_enabled),
        else: Application.put_env(:arbor_shell, :compound_shell_enabled, prev.compound)
    end)

    {:ok, agent_id: agent_id}
  end

  describe "security regression: CapShell always unavailable (any terms)" do
    test "direct facade + CapShell.run return unavailable without side effects",
         %{agent_id: agent_id} do
      command = "echo a && echo b"

      assert @unavailable =
               Arbor.Shell.execute_compound_with_capabilities(agent_id, command)

      assert @unavailable = CapShell.run(agent_id, command)
    end

    test "security regression: malformed public CapShell calls return, not raise" do
      # Parent 9f91f62 guarded CapShell.run/execute_compound with is_binary clauses
      # and raised FunctionClauseError on malformed terms.
      assert @unavailable = CapShell.run(nil, nil, :not_a_keyword)
      assert @unavailable = CapShell.run(123, %{cmd: "x"}, "opts")
      assert @unavailable = CapShell.run()

      assert @unavailable =
               Arbor.Shell.execute_compound_with_capabilities(:bad, 42, %{})

      assert @unavailable = Arbor.Shell.execute_compound_with_capabilities()
    end
  end

  describe "security regression: agent boundaries reject compounds unconditionally" do
    test "security regression: standalone ampersand and all shell list/control operators are compound",
         %{agent_id: agent_id} do
      commands = [
        "sleep 0.1 & touch /tmp/ampersand_must_not_run",
        "echo a && echo b",
        "false || true",
        "echo a; echo b",
        "echo a;; echo b",
        "echo a;& echo b",
        "echo a;;& echo b",
        "echo a | cat",
        "echo a |& cat",
        "(echo grouped)",
        "{ echo grouped; }",
        "echo redirected > /tmp/x",
        "cat < /tmp/x",
        "echo `date`",
        "echo $(date)",
        "! false",
        "echo first\necho second"
      ]

      for command <- commands do
        assert Arbor.Shell.compound_command?(command),
               "expected shared compound gate to reject #{inspect(command)}"

        assert @unavailable = Arbor.Shell.authorize(agent_id, command, sandbox: :none)
      end
    end

    test "security regression: shell interpreters and nested dispatch wrappers reject before authorization",
         %{agent_id: agent_id} do
      commands = [
        "sh -c true",
        "/bin/sh -c true",
        "bash -c true",
        "/bin/zsh -c true",
        "env sh -c true",
        "/usr/bin/env nice sh -c true",
        "command sh -c true",
        "exec sh -c true",
        "nice sh -c true",
        "nohup sh -c true",
        "timeout 1 sh -c true",
        "xargs sh -c true"
      ]

      for command <- commands do
        assert {:error, {:agent_executable_not_allowed, _name}} =
                 Arbor.Shell.authorize(agent_id, command, sandbox: :none)

        assert {:error, {:agent_executable_not_allowed, _name}} =
                 Arbor.Shell.authorize_and_execute(agent_id, command, sandbox: :none)
      end
    end

    test "security regression: every generic executable has a closed argv grammar" do
      accepted = [
        "cat -- /tmp/input",
        "echo -n hello",
        "false",
        "grep needle /tmp/input",
        "head -n 10 /tmp/input",
        "ls -la /tmp",
        "printenv PATH",
        "printf %s value",
        "pwd -P",
        "sleep 0.01",
        "sort -nru /tmp/input",
        "tail -c 10 /tmp/input",
        "touch -- /tmp/output",
        "true",
        "wc -cl /tmp/input"
      ]

      for command <- accepted do
        assert {:ok, %{executable: executable, args: args}} =
                 Arbor.Shell.prepare_agent_command(command),
               "expected closed argv policy to accept #{inspect(command)}"

        assert Path.type(executable) == :absolute
        assert is_list(args)
      end

      rejected = [
        "cat --show-all /tmp/input",
        "echo --help",
        "false --help",
        "grep --color needle /tmp/input",
        "head -f /tmp/input",
        "ls --color /tmp",
        "printenv --null PATH",
        "printf --help",
        "pwd --help",
        "sleep --help",
        "sort -S 64K /tmp/input",
        "sort --compress-program=/bin/sh /tmp/input",
        "tail -f /tmp/input",
        "touch -r /tmp/input /tmp/output",
        "true --help",
        "wc --files0-from=/tmp/input"
      ]

      for command <- rejected do
        assert {:error, {:agent_argv_not_allowed, _executable, _reason}} =
                 Arbor.Shell.prepare_agent_command(command),
               "expected unknown/helper argv to reject #{inspect(command)}"
      end
    end

    test "security regression: env-fed eval cannot restore runtime expansion in sync/async/streaming",
         %{agent_id: agent_id} do
      marker =
        Path.join(
          System.tmp_dir!(),
          "capshell_env_eval_#{:erlang.unique_integer([:positive])}"
        )

      File.rm(marker)
      command = ~S(sh -c 'eval "$PAYLOAD"')
      env = %{"PAYLOAD" => "sleep 0.2 && touch #{marker} &"}

      try do
        results = [
          Arbor.Shell.authorize_and_execute(agent_id, command, sandbox: :none, env: env),
          Arbor.Shell.authorize_and_execute_async(agent_id, command,
            sandbox: :none,
            env: env
          ),
          Arbor.Shell.authorize_and_execute_streaming(agent_id, command,
            sandbox: :none,
            env: env,
            stream_to: self()
          )
        ]

        Process.sleep(700)

        refute File.exists?(marker),
               "env-fed eval launched a delayed background marker side effect"

        assert Enum.all?(results, fn
                 {:error, {:agent_executable_not_allowed, "sh"}} -> true
                 _ -> false
               end)
      after
        File.rm(marker)
      end
    end

    test "security regression: non-empty env and mismatched gate command reject before Security" do
      no_cap_agent = "agent_capshell_no_cap_#{:erlang.unique_integer([:positive])}"

      assert {:error, {:agent_shell_option_not_allowed, :env}} =
               Arbor.Shell.authorize(no_cap_agent, "echo safe",
                 env: %{"LD_PRELOAD" => "/tmp/not-loaded"}
               )

      assert {:error, {:agent_shell_gate_mismatch, "sh", "echo"}} =
               Arbor.Shell.authorize(no_cap_agent, "echo safe", gate_command: "sh")
    end

    test "security regression: absolute executable basename cannot masquerade as an allowed utility",
         %{agent_id: agent_id} do
      root =
        Path.join(
          System.tmp_dir!(),
          "capshell_fake_executable_#{:erlang.unique_integer([:positive])}"
        )

      fake_echo = Path.join(root, "echo")
      marker = Path.join(root, "marker")
      File.mkdir_p!(root)
      File.write!(fake_echo, "#!/bin/sh\nsleep 0.2\ntouch #{marker}\n")
      File.chmod!(fake_echo, 0o755)

      try do
        result =
          Arbor.Shell.authorize_and_execute(agent_id, "#{fake_echo} ignored", sandbox: :none)

        Process.sleep(700)
        refute File.exists?(marker), "a fake executable named echo was launched"
        assert result == {:error, {:agent_executable_path_not_allowed, fake_echo}}
      after
        File.rm_rf!(root)
      end
    end

    test "security regression: sort helper dispatch rejects before sync async or streaming work",
         %{agent_id: agent_id} do
      %{root: root, marker: marker, output: output, command: command} =
        sort_shell_dispatch_fixture("shell_facade")

      execs_before = execution_count()

      try do
        results = [
          Arbor.Shell.authorize_and_execute(agent_id, command,
            sandbox: :none,
            timeout: 100
          ),
          Arbor.Shell.authorize_and_execute_async(agent_id, command,
            sandbox: :none,
            timeout: 100
          ),
          Arbor.Shell.authorize_and_execute_streaming(agent_id, command,
            sandbox: :none,
            timeout: 100,
            stream_to: self()
          )
        ]

        assert Enum.all?(results, fn
                 {:error, {:agent_argv_not_allowed, "sort", {:unsupported_option, _}}} ->
                   true

                 _other ->
                   false
               end)

        Process.sleep(@side_effect_wait_ms)

        refute File.exists?(marker),
               "sort --compress-program executed shell input after boundary rejection"

        refute File.exists?(output), "rejected sort created its requested output file"
        assert execution_count() == execs_before
      after
        File.rm_rf!(root)
      end
    end

    test "security regression: analogous find -exec child-spawning form cannot create a marker",
         %{agent_id: agent_id} do
      root =
        Path.join(
          System.tmp_dir!(),
          "capshell_find_exec_#{System.unique_integer([:positive])}"
        )

      marker = Path.join(root, "marker")
      trigger = Path.join(root, "trigger")
      File.mkdir_p!(root)
      File.write!(trigger, "trigger")
      command = "find #{root} -name trigger -exec touch #{marker} +"

      try do
        assert {:error, {:agent_executable_not_allowed, "find"}} =
                 Arbor.Shell.authorize_and_execute(agent_id, command, sandbox: :none)

        Process.sleep(300)
        refute File.exists?(marker), "generic find -exec launched a child marker process"
      after
        File.rm_rf!(root)
      end
    end

    test "security regression: config true + sandbox:none cannot create delayed marker (sync/async/streaming/bare-authorize)",
         %{agent_id: agent_id} do
      assert_residual_agent_boundaries_closed(agent_id, true)
    end

    test "security regression: config false + sandbox:none cannot create delayed marker (sync/async/streaming/bare-authorize)",
         %{agent_id: agent_id} do
      assert_residual_agent_boundaries_closed(agent_id, false)
    end

    test "security regression: bare authorize rejects plain metacharacter compounds before Security lookup",
         %{agent_id: agent_id} do
      # Parent authorized leading token only (e.g. sleep), letting DOT sandbox:none
      # run /bin/sh -c with full compound semantics after a successful authorize.
      with_compound_shell(false, fn ->
        assert @unavailable =
                 Arbor.Shell.authorize(agent_id, "sleep 1; touch /tmp/should_not_exist")

        assert @unavailable =
                 Arbor.Shell.authorize(agent_id, "echo a && echo b", sandbox: :none)
      end)
    end

    test "security regression: config true still fail-closed for ordinary compounds",
         %{agent_id: agent_id} do
      with_compound_shell(true, fn ->
        assert Arbor.Shell.compound_shell_enabled?()

        marker =
          Path.join(
            System.tmp_dir!(),
            "capshell_sec_touch_#{:erlang.unique_integer([:positive])}"
          )

        File.rm(marker)
        sessions_before = bash_session_count()
        command = "sleep 1; touch #{marker}"

        try do
          assert @unavailable =
                   Arbor.Shell.execute_compound_with_capabilities(agent_id, command)

          assert @unavailable =
                   Arbor.Shell.authorize_and_execute(agent_id, command, sandbox: :basic)

          assert @unavailable =
                   Arbor.Shell.authorize_and_execute(agent_id, command, sandbox: :none)

          assert @unavailable = CapShell.run(agent_id, command)

          Process.sleep(@side_effect_wait_ms)

          refute File.exists?(marker),
                 "delayed compound touch must not execute under fail-closed CapShell"

          assert bash_session_count() <= sessions_before
        after
          File.rm(marker)
        end
      end)
    end

    test "security regression: noisy compound never creates output file or session",
         %{agent_id: agent_id} do
      with_compound_shell(true, fn ->
        out =
          Path.join(
            System.tmp_dir!(),
            "capshell_sec_noise_#{:erlang.unique_integer([:positive])}"
          )

        File.rm(out)
        sessions_before = bash_session_count()
        command = "printf 'noise\\n' | cat > #{out}"

        try do
          assert @unavailable =
                   Arbor.Shell.execute_compound_with_capabilities(agent_id, command)

          assert @unavailable =
                   Arbor.Shell.authorize_and_execute(agent_id, command, sandbox: :none)

          assert @unavailable = CapShell.run(agent_id, command)

          Process.sleep(200)

          refute File.exists?(out),
                 "compound output redirect must not write under fail-closed CapShell"

          assert bash_session_count() <= sessions_before
        after
          File.rm(out)
        end
      end)
    end
  end

  describe "ordinary single-command path preserved" do
    test "authorized non-compound still executes", %{agent_id: agent_id} do
      assert {:ok, %{exit_code: 0, stdout: stdout}} =
               Arbor.Shell.authorize_and_execute(agent_id, "echo single-ok", sandbox: :none)

      assert String.trim(stdout) == "single-ok"
    end
  end

  # ── helpers ──

  defp assert_residual_agent_boundaries_closed(agent_id, config_value) do
    with_compound_shell(config_value, fn ->
      marker =
        Path.join(
          System.tmp_dir!(),
          "capshell_residual_#{:erlang.unique_integer([:positive])}"
        )

      File.rm(marker)
      sessions_before = bash_session_count()
      execs_before = execution_count()

      # Nested interpreter form: parent agent boundaries authorized only the
      # leading `sh` and sandbox:none executed the full compound string.
      command = "sh -c 'sleep 1; touch #{marker}'"

      try do
        assert @unavailable =
                 Arbor.Shell.authorize(agent_id, command, sandbox: :none)

        assert @unavailable =
                 Arbor.Shell.authorize_and_execute(agent_id, command, sandbox: :none)

        assert @unavailable =
                 Arbor.Shell.authorize_and_execute_async(agent_id, command, sandbox: :none)

        assert @unavailable =
                 Arbor.Shell.authorize_and_execute_streaming(
                   agent_id,
                   command,
                   stream_to: self(),
                   sandbox: :none
                 )

        assert @unavailable =
                 Arbor.Shell.execute_compound_with_capabilities(agent_id, command)

        assert @unavailable = CapShell.run(agent_id, command)

        Process.sleep(@side_effect_wait_ms)

        refute File.exists?(marker),
               "delayed compound touch must not execute (config=#{inspect(config_value)}, sandbox:none)"

        assert bash_session_count() <= sessions_before,
               "Bash.Session.list count must not grow from fail-closed compound entry"

        assert execution_count() <= execs_before,
               "ExecutionRegistry must not grow from rejected compound admission"
      after
        File.rm(marker)
      end
    end)
  end

  defp with_compound_shell(value, fun) when is_function(fun, 0) do
    prev = Application.get_env(:arbor_shell, :compound_shell_enabled)

    case value do
      :absent -> Application.delete_env(:arbor_shell, :compound_shell_enabled)
      other -> Application.put_env(:arbor_shell, :compound_shell_enabled, other)
    end

    try do
      fun.()
    after
      if is_nil(prev),
        do: Application.delete_env(:arbor_shell, :compound_shell_enabled),
        else: Application.put_env(:arbor_shell, :compound_shell_enabled, prev)
    end
  end

  defp bash_session_count do
    case Code.ensure_loaded(Bash.Session) do
      {:module, _} ->
        if function_exported?(Bash.Session, :list, 0) or
             function_exported?(Bash.Session, :list, 1) do
          length(Bash.Session.list())
        else
          0
        end

      _ ->
        0
    end
  end

  defp execution_count do
    case Arbor.Shell.list_executions([]) do
      {:ok, list} when is_list(list) -> length(list)
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp sort_shell_dispatch_fixture(tag) do
    root =
      Path.join(
        System.tmp_dir!(),
        "capshell_sort_dispatch_#{tag}_#{System.unique_integer([:positive])}"
      )

    input = Path.join(root, "input")
    output = Path.join(root, "output")
    marker = Path.join(root, "marker")
    File.mkdir_p!(root)

    comments =
      for i <- 1..40_000, into: "" do
        "# #{i} #{String.duplicate("x", 48)}\n"
      end

    # BSD sort pipes sorted runs to --compress-program on stdin. /bin/sh then
    # executes these otherwise inert input lines as a script.
    File.write!(input, comments <> "sleep 1\ntouch #{marker}\n")

    %{
      root: root,
      marker: marker,
      output: output,
      command: "sort -S 64K --compress-program=/bin/sh -o #{output} #{input}"
    }
  end

  defp grant_shell_capability(agent_id, resource_uri) do
    cap = %Capability{
      id: "cap_capshell_sec_#{:erlang.unique_integer([:positive])}",
      resource_uri: resource_uri,
      principal_id: agent_id,
      granted_at: DateTime.utc_now(),
      expires_at: nil,
      constraints: %{},
      delegation_depth: 0,
      delegation_chain: [],
      metadata: %{test: true}
    }

    {:ok, :stored} = CapabilityStore.put(cap)
    cap
  end

  defp ensure_shell_started do
    case Process.whereis(Arbor.Shell.ExecutionRegistry) do
      nil ->
        _ = Application.ensure_all_started(:arbor_shell)

      _pid ->
        :ok
    end
  end

  defp ensure_security_started do
    security_children = [
      {Arbor.Security.Identity.Registry, []},
      {Arbor.Security.Identity.NonceCache, []},
      {Arbor.Security.SystemAuthority, []},
      {Arbor.Security.CapabilityStore, []},
      {Arbor.Security.Reflex.Registry, []}
    ]

    if Process.whereis(Arbor.Security.Supervisor) do
      for child <- security_children do
        try do
          case Supervisor.start_child(Arbor.Security.Supervisor, child) do
            {:ok, _pid} -> :ok
            {:error, {:already_started, _pid}} -> :ok
            {:error, :already_present} -> :ok
            _other -> :ok
          end
        catch
          :exit, _ -> :ok
        end
      end
    end
  end

  defp restore_security(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_security(key, value), do: Application.put_env(:arbor_security, key, value)
end
