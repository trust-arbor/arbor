defmodule Mix.Tasks.Arbor.StartDaemonLaunchTest do
  @moduledoc """
  Focused tests for daemon launcher argv, PID parse, environment inheritance,
  and failure behavior without launching the live Arbor daemon.
  """

  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Common.SafePath
  alias Mix.Tasks.Arbor.Helpers
  alias Mix.Tasks.Arbor.Start

  setup do
    tmp = Path.join(System.tmp_dir!(), "arbor_start_launch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    {:ok, tmp} = SafePath.resolve_real(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    {:ok, tmp: tmp}
  end

  defp argv_spec(overrides \\ %{}) do
    Map.merge(
      %{
        elixir_path: "/opt/elixir/bin/elixir",
        node_string: "arbor_dev@127.0.0.1",
        name_type: "longnames",
        cookie_file: "/home/operator/.arbor/distribution/.erlang.cookie",
        bind_mode: "loopback_v4",
        bootstrap_path: "/repo/bin/arbor-gated-dist-bootstrap.exs",
        mix_path: "/opt/elixir/bin/mix",
        log_file: "/tmp/arbor-dev.log"
      },
      overrides
    )
  end

  test "security regression: daemon launch argv references a cookie file without the cookie" do
    assert {:ok, argv} = Start.daemon_launch_argv(argv_spec())

    assert argv == [
             "/opt/elixir/bin/elixir",
             "arbor_dev@127.0.0.1",
             "longnames",
             "/home/operator/.arbor/distribution/.erlang.cookie",
             "loopback_v4",
             "/repo/bin/arbor-gated-dist-bootstrap.exs",
             "/opt/elixir/bin/mix",
             "/tmp/arbor-dev.log"
           ]

    refute "secret-cookie" in argv
  end

  test "security regression: daemon launch argv rejects values the launcher would word-split" do
    assert {:error, :invalid_node_name} =
             Start.daemon_launch_argv(argv_spec(%{node_string: "-eval@127.0.0.1"}))

    assert {:error, :invalid_node_name} =
             Start.daemon_launch_argv(argv_spec(%{node_string: "a b@127.0.0.1"}))

    assert {:error, :invalid_name_type} =
             Start.daemon_launch_argv(argv_spec(%{name_type: "--name"}))

    assert {:error, :relative_cookie_file} =
             Start.daemon_launch_argv(argv_spec(%{cookie_file: "cookie"}))

    assert {:error, :invalid_distribution_bind_mode} =
             Start.daemon_launch_argv(argv_spec(%{bind_mode: "all"}))
  end

  test "security regression: daemon launch rejects a literal cookie field" do
    assert {:error, :invalid_launch_spec} =
             Start.daemon_launch_argv(%{
               elixir_path: "/opt/elixir/bin/elixir",
               name_type: "longnames",
               node_string: "arbor_dev@127.0.0.1",
               cookie: "secret-cookie-visible-in-argv",
               mix_path: "/opt/elixir/bin/mix",
               log_file: "/tmp/arbor-dev.log"
             })
  end

  test "daemon_launch_argv rejects empty arguments" do
    assert {:error, :empty_launch_argument} =
             Start.daemon_launch_argv(argv_spec(%{cookie_file: ""}))
  end

  test "security regression: daemon environment clears inherited VM flag injection" do
    env =
      Start.daemon_env(
        %{
          "PATH" => "/usr/bin",
          "OPENAI_API_KEY" => "provider-secret",
          "ERL_AFLAGS" => "-setcookie stolen",
          "ERL_FLAGS" => "-eval attacker run",
          "ERL_ZFLAGS" => "-pa /attacker",
          "ELIXIR_ERL_OPTIONS" => "-setcookie stolen-again",
          "ARBOR_COOKIE" => "daemon-reads-the-cookie-file-instead"
        },
        :dev,
        "/trusted/erlang/bin"
      )
      |> Map.new()

    assert env["OPENAI_API_KEY"] == "provider-secret"
    assert env["MIX_ENV"] == "dev"
    assert env["PATH"] == "/trusted/erlang/bin:/usr/bin"

    for key <- Helpers.blocked_vm_flag_env() ++ ["ARBOR_COOKIE"] do
      assert Map.fetch!(env, key) == nil
    end
  end

  test "parse_daemon_pid accepts last-line decimal PID" do
    assert {:ok, 42_424} = Start.parse_daemon_pid("noise\n42424\n")
    assert {:ok, 7} = Start.parse_daemon_pid("7")
    assert {:error, _} = Start.parse_daemon_pid("not-a-pid")
    assert {:error, _} = Start.parse_daemon_pid("")
  end

  test "resolve_daemon_launcher requires pre-existing executable mode (git 100755)" do
    project_dir = Path.expand("../../../../../../", __DIR__)
    launcher_path = Path.join(project_dir, "bin/arbor-dev-daemon-launch")

    assert File.regular?(launcher_path)
    assert Start.launcher_executable?(launcher_path)

    {:ok, %File.Stat{mode: mode_before}} = File.stat(launcher_path)
    assert Bitwise.band(mode_before, 0o111) != 0

    assert {:ok, path} = Start.resolve_daemon_launcher(project_dir)
    assert String.ends_with?(path, "bin/arbor-dev-daemon-launch")

    {:ok, %File.Stat{mode: mode_after}} = File.stat(launcher_path)
    assert mode_after == mode_before
  end

  test "resolve_daemon_launcher fails closed when launcher is not executable", %{tmp: tmp} do
    bin = Path.join(tmp, "bin")
    File.mkdir_p!(bin)
    launcher = Path.join(bin, "arbor-dev-daemon-launch")
    File.write!(launcher, "#!/bin/sh\necho 1\n")
    File.chmod!(launcher, 0o644)
    refute Start.launcher_executable?(launcher)

    assert {:error, {:daemon_launcher_unavailable, ^launcher}} =
             Start.resolve_daemon_launcher(tmp)
  end

  test "spawn_daemon_process uses fake launcher argv, cwd, env, and PID", %{tmp: tmp} do
    record = Path.join(tmp, "launch-record.txt")
    log = Path.join(tmp, "daemon.log")
    fake = Path.join(tmp, "fake-launcher")

    File.write!(fake, """
    #!/bin/sh
    set -eu
    record="$ARBOR_LAUNCH_RECORD"
    {
      printf 'arg1=%s\\n' "$1"
      printf 'arg2=%s\\n' "$2"
      printf 'arg3=%s\\n' "$3"
      printf 'arg4=%s\\n' "$4"
      printf 'arg5=%s\\n' "$5"
      printf 'arg6=%s\\n' "$6"
      printf 'arg7=%s\\n' "$7"
      printf 'arg8=%s\\n' "$8"
      printf 'cwd=%s\\n' "$(pwd)"
      printf 'canary=%s\\n' "${ARBOR_LAUNCH_CANARY:-}"
      printf 'mix_env=%s\\n' "${MIX_ENV:-}"
    } > "$record"
    : > "$8"
    echo 31415
    """)

    File.chmod!(fake, 0o755)

    env =
      System.get_env()
      |> Map.put("MIX_ENV", "dev")
      |> Map.put("ARBOR_LAUNCH_CANARY", "provider-secret-canary")
      |> Map.put("ARBOR_LAUNCH_RECORD", record)
      |> Enum.to_list()

    assert {:ok, 31_415} =
             Start.spawn_daemon_process(%{
               project_dir: tmp,
               launcher: fake,
               elixir_path: "/resolved/elixir",
               node_string: "arbor_dev@10.0.0.1",
               name_type: "longnames",
               cookie_file: "/private/cookie-home/.erlang.cookie",
               bind_mode: "default",
               bootstrap_path: "/repo/bin/arbor-gated-dist-bootstrap.exs",
               mix_path: "/resolved/mix",
               log_file: log,
               env: env
             })

    body = File.read!(record)
    assert body =~ "arg1=/resolved/elixir\n"
    assert body =~ "arg2=arbor_dev@10.0.0.1\n"
    assert body =~ "arg3=longnames\n"
    assert body =~ "arg4=/private/cookie-home/.erlang.cookie\n"
    assert body =~ "arg5=default\n"
    assert body =~ "arg6=/repo/bin/arbor-gated-dist-bootstrap.exs\n"
    assert body =~ "arg7=/resolved/mix\n"
    assert body =~ "arg8=#{log}\n"
    assert body =~ "cwd=#{tmp}\n"
    assert body =~ "canary=provider-secret-canary\n"
    assert body =~ "mix_env=dev\n"
    assert File.exists?(log)
  end

  test "spawn_daemon_process fails closed on non-zero launcher exit", %{tmp: tmp} do
    fake = Path.join(tmp, "fail-launcher")
    File.write!(fake, "#!/bin/sh\necho boom >&2\nexit 9\n")
    File.chmod!(fake, 0o755)

    assert {:error, {:launcher_exit, 9, _}} =
             Start.spawn_daemon_process(launch_spec(tmp, fake))
  end

  test "spawn_daemon_process fails closed on unparseable PID", %{tmp: tmp} do
    fake = Path.join(tmp, "bad-pid-launcher")
    File.write!(fake, "#!/bin/sh\necho not-a-pid\n")
    File.chmod!(fake, 0o755)

    assert {:error, {:invalid_daemon_pid, _}} =
             Start.spawn_daemon_process(launch_spec(tmp, fake))
  end

  test "security regression: launcher keeps HOME, hides cookie, strips VM flags, gates loopback",
       %{tmp: tmp} do
    project_dir = Path.expand("../../../../../../", __DIR__)
    assert {:ok, launcher} = Start.resolve_daemon_launcher(project_dir)

    log = Path.join(tmp, "out.log")
    record = Path.join(tmp, "child-record")
    arbor_home = Path.join(tmp, "arbor-home")
    secret = "cookie-visible-in-old-argv"
    assert {:ok, _cookie_home} = Helpers.prepare_distribution_cookie(secret, arbor_home)
    cookie_file = Helpers.distribution_cookie_file(arbor_home)

    bootstrap = Helpers.runtime_bootstrap_file(project_dir)
    assert File.regular?(bootstrap)

    sleep = System.find_executable("sleep") || "/bin/sleep"
    fake_elixir = Path.join(tmp, "fake-elixir")

    File.write!(fake_elixir, """
    #!/bin/sh
    set -eu
    {
      for arg in "$@"; do printf 'arg=%s\\n' "$arg"; done
      printf 'home=%s\\n' "$HOME"
      printf 'original_home=%s\\n' "${ARBOR_RUNTIME_ORIGINAL_HOME-unset}"
      printf 'arbor_cookie=%s\\n' "${ARBOR_COOKIE-unset}"
      printf 'name_type=%s\\n' "${ARBOR_DIST_NAME_TYPE-unset}"
      printf 'cookie_file=%s\\n' "${ARBOR_DIST_COOKIE_FILE-unset}"
      printf 'erl_aflags=%s\\n' "${ERL_AFLAGS-unset}"
      printf 'erl_flags=%s\\n' "${ERL_FLAGS-unset}"
      printf 'erl_zflags=%s\\n' "${ERL_ZFLAGS-unset}"
      printf 'elixir_erl_options=%s\\n' "${ELIXIR_ERL_OPTIONS-unset}"
    } > "$ARBOR_LAUNCH_RECORD"
    exec #{sleep} 30
    """)

    File.chmod!(fake_elixir, 0o755)

    assert {:ok, pid} =
             Start.spawn_daemon_process(%{
               project_dir: tmp,
               launcher: launcher,
               elixir_path: fake_elixir,
               node_string: "node@127.0.0.1",
               name_type: "longnames",
               cookie_file: cookie_file,
               bind_mode: "loopback_v4",
               bootstrap_path: bootstrap,
               mix_path: "/bin/true",
               log_file: log,
               env: [
                 {"ARBOR_LAUNCH_RECORD", record},
                 {"ARBOR_COOKIE", secret},
                 {"ARBOR_RUNTIME_ORIGINAL_HOME", "/stale"},
                 {"ERL_AFLAGS", "-setcookie #{secret}"},
                 {"ERL_FLAGS", "-eval attacker run"},
                 {"ERL_ZFLAGS", "-pa /attacker"},
                 {"ELIXIR_ERL_OPTIONS", "-setcookie #{secret}"}
               ]
             })

    on_exit(fn ->
      _ = System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)
    end)

    assert :ok = wait_for_file(record)
    body = File.read!(record)
    refute body =~ secret
    refute body =~ "-setcookie"
    refute body =~ "arg=--name\n"
    refute body =~ "arg=--sname\n"
    assert body =~ "arg=--erl\n"

    assert body =~
             "arg=-nocookie -proto_dist arbor_gated_tcp -kernel inet_dist_use_interface {127,0,0,1} " <>
               "inet_dist_listen_min 9100 inet_dist_listen_max 9155 net_ticktime 120 " <>
               "-arbor_dist_node node@127.0.0.1\n"

    assert body =~ "arg=-r\n"
    assert body =~ "arg=#{bootstrap}\n"
    assert body =~ "home=#{System.get_env("HOME")}\n"
    assert body =~ "original_home=unset\n"
    assert body =~ "arbor_cookie=unset\n"
    assert body =~ "name_type=longnames\n"
    assert body =~ "cookie_file=#{cookie_file}\n"
    assert body =~ "erl_aflags=unset\n"
    assert body =~ "erl_flags=unset\n"
    assert body =~ "erl_zflags=unset\n"
    assert body =~ "elixir_erl_options=unset\n"

    assert {:ok, %File.Stat{mode: log_mode}} = File.stat(log)
    assert Bitwise.band(log_mode, 0o777) == 0o600
  end

  test "security regression: launcher selects the IPv6 gated carrier for the IPv6 loopback", %{
    tmp: tmp
  } do
    project_dir = Path.expand("../../../../../../", __DIR__)
    assert {:ok, launcher} = Start.resolve_daemon_launcher(project_dir)
    record = Path.join(tmp, "child-record")
    fake_elixir = Path.join(tmp, "fake-elixir")

    File.write!(fake_elixir, """
    #!/bin/sh
    for arg in "$@"; do printf 'arg=%s\\n' "$arg"; done > "$ARBOR_LAUNCH_RECORD"
    """)

    File.chmod!(fake_elixir, 0o755)

    spec =
      launch_spec(tmp, launcher)
      |> Map.merge(%{elixir_path: fake_elixir, node_string: "n@::1", bind_mode: "loopback_v6"})
      |> Map.put(:env, [{"ARBOR_LAUNCH_RECORD", record}])

    assert {:ok, _pid} = Start.spawn_daemon_process(spec)
    assert :ok = wait_for_file(record)

    assert File.read!(record) =~
             "-proto_dist arbor_gated_tcp6 -kernel inet_dist_use_interface {0,0,0,0,0,0,0,1}"
  end

  test "security regression: launcher rejects a node name that would inject VM flags", %{tmp: tmp} do
    project_dir = Path.expand("../../../../../../", __DIR__)
    assert {:ok, launcher} = Start.resolve_daemon_launcher(project_dir)

    for node <- ["-eval@h", "a b@h", "n@h;x"] do
      argv = ["/e", node, "longnames", "/c", "default", "/b.exs", "/m", Path.join(tmp, "l.log")]
      # Trusted test fixtures only: absolute toolchain or launcher paths.
      # credo:disable-for-next-line
      assert {out, 2} = System.cmd(launcher, argv, stderr_to_stdout: true)
      assert out =~ "invalid node name"
    end
  end

  test "launcher honors a validated distribution listen range", %{tmp: tmp} do
    project_dir = Path.expand("../../../../../../", __DIR__)
    assert {:ok, launcher} = Start.resolve_daemon_launcher(project_dir)
    argv = ["/e", "n@h", "longnames", "/c", "default", "/b.exs", "/m", Path.join(tmp, "l.log")]

    for {min, max} <- [{"80", "90"}, {"9100", "70000"}, {"9200", "9100"}, {"9x", "9100"}] do
      env = [{"ARBOR_DIST_LISTEN_MIN", min}, {"ARBOR_DIST_LISTEN_MAX", max}]
      # Trusted test fixtures only: absolute toolchain or launcher paths.
      # credo:disable-for-next-line
      assert {out, 2} = System.cmd(launcher, argv, env: env, stderr_to_stdout: true)
      assert out =~ "invalid distribution listen"
    end
  end

  defp launch_spec(tmp, launcher) do
    %{
      project_dir: tmp,
      launcher: launcher,
      elixir_path: "/e",
      node_string: "n@h",
      name_type: "longnames",
      cookie_file: "/cookie-home/.erlang.cookie",
      bind_mode: "default",
      bootstrap_path: "/bootstrap.exs",
      mix_path: "/m",
      log_file: Path.join(tmp, "l.log"),
      env: []
    }
  end

  defp wait_for_file(path, attempts \\ 100)
  defp wait_for_file(_path, 0), do: {:error, :timeout}

  defp wait_for_file(path, attempts) do
    if File.regular?(path) do
      :ok
    else
      Process.sleep(10)
      wait_for_file(path, attempts - 1)
    end
  end
end
