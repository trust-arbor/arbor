defmodule Mix.Tasks.Arbor.StartDaemonLaunchTest do
  @moduledoc """
  Focused tests for daemon launcher argv, PID parse, environment inheritance,
  and failure behavior without launching the live Arbor daemon.
  """

  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Common.SafePath
  alias Mix.Tasks.Arbor.Start

  setup do
    tmp = Path.join(System.tmp_dir!(), "arbor_start_launch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    {:ok, tmp} = SafePath.resolve_real(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    {:ok, tmp: tmp}
  end

  test "daemon_launch_argv builds exact six-element positional argv" do
    assert {:ok, argv} =
             Start.daemon_launch_argv(%{
               elixir_path: "/opt/elixir/bin/elixir",
               name_flag: "--name",
               node_string: "arbor_dev@127.0.0.1",
               cookie: "secret-cookie",
               mix_path: "/opt/elixir/bin/mix",
               log_file: "/tmp/arbor-dev.log"
             })

    assert argv == [
             "/opt/elixir/bin/elixir",
             "--name",
             "arbor_dev@127.0.0.1",
             "secret-cookie",
             "/opt/elixir/bin/mix",
             "/tmp/arbor-dev.log"
           ]
  end

  test "daemon_launch_argv rejects empty arguments" do
    assert {:error, :empty_launch_argument} =
             Start.daemon_launch_argv(%{
               elixir_path: "/opt/elixir/bin/elixir",
               name_flag: "--name",
               node_string: "arbor_dev@127.0.0.1",
               cookie: "",
               mix_path: "/opt/elixir/bin/mix",
               log_file: "/tmp/arbor-dev.log"
             })
  end

  test "parse_daemon_pid accepts last-line decimal PID" do
    assert {:ok, 42_424} = Start.parse_daemon_pid("noise\n42424\n")
    assert {:ok, 7} = Start.parse_daemon_pid("7")
    assert {:error, _} = Start.parse_daemon_pid("not-a-pid")
    assert {:error, _} = Start.parse_daemon_pid("")
  end

  test "resolve_daemon_launcher requires pre-existing executable mode (git 100755)" do
    # __DIR__ = apps/arbor_common/test/mix/tasks/arbor
    project_dir = Path.expand("../../../../../../", __DIR__)
    launcher_path = Path.join(project_dir, "bin/arbor-dev-daemon-launch")

    # Assert executable mode before resolve; the resolver must not chmod-mutate.
    assert File.regular?(launcher_path)
    assert Start.launcher_executable?(launcher_path)

    {:ok, %File.Stat{mode: mode_before}} = File.stat(launcher_path)
    assert Bitwise.band(mode_before, 0o111) != 0

    assert {:ok, path} = Start.resolve_daemon_launcher(project_dir)
    assert String.ends_with?(path, "bin/arbor-dev-daemon-launch")

    {:ok, %File.Stat{mode: mode_after}} = File.stat(launcher_path)
    # Resolver must not change mode.
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
      printf 'cwd=%s\\n' "$(pwd)"
      printf 'canary=%s\\n' "${ARBOR_LAUNCH_CANARY:-}"
      printf 'mix_env=%s\\n' "${MIX_ENV:-}"
    } > "$record"
    : > "$6"
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
               name_flag: "--name",
               node_string: "arbor_dev@10.0.0.1",
               cookie: "cookie-value",
               mix_path: "/resolved/mix",
               log_file: log,
               env: env
             })

    {:ok, body} = File.read(record)

    assert body =~ "arg1=/resolved/elixir\n"
    assert body =~ "arg2=--name\n"
    assert body =~ "arg3=arbor_dev@10.0.0.1\n"
    assert body =~ "arg4=cookie-value\n"
    assert body =~ "arg5=/resolved/mix\n"
    assert body =~ "arg6=#{log}\n"
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
             Start.spawn_daemon_process(%{
               project_dir: tmp,
               launcher: fake,
               elixir_path: "/e",
               name_flag: "--name",
               node_string: "n@h",
               cookie: "c",
               mix_path: "/m",
               log_file: Path.join(tmp, "l.log"),
               env: []
             })
  end

  test "spawn_daemon_process fails closed on unparseable PID", %{tmp: tmp} do
    fake = Path.join(tmp, "bad-pid-launcher")
    File.write!(fake, "#!/bin/sh\necho not-a-pid\n")
    File.chmod!(fake, 0o755)

    assert {:error, {:invalid_daemon_pid, _}} =
             Start.spawn_daemon_process(%{
               project_dir: tmp,
               launcher: fake,
               elixir_path: "/e",
               name_flag: "--name",
               node_string: "n@h",
               cookie: "c",
               mix_path: "/m",
               log_file: Path.join(tmp, "l.log"),
               env: []
             })
  end

  test "trusted static launcher backgrounds and prints PID without sh -c", %{tmp: tmp} do
    project_dir = Path.expand("../../../../../../", __DIR__)
    launcher_path = Path.join(project_dir, "bin/arbor-dev-daemon-launch")
    assert Start.launcher_executable?(launcher_path)
    assert {:ok, launcher} = Start.resolve_daemon_launcher(project_dir)

    log = Path.join(tmp, "out.log")
    # Use /bin/sleep as a stand-in for elixir so we never start Arbor.
    # The launcher still applies the fixed argv shape around it.
    sleep = System.find_executable("sleep") || "/bin/sleep"

    # Cookie/name/node/mix args are still passed positionally; sleep ignores them
    # after its duration arg — we only need the launcher to background *something*
    # and echo $!. Use a tiny helper as "elixir" that ignores argv and sleeps.
    fake_elixir = Path.join(tmp, "fake-elixir")
    File.write!(fake_elixir, "#!/bin/sh\nexec #{sleep} 30\n")
    File.chmod!(fake_elixir, 0o755)

    # The trusted static launcher receives inert argv; no shell command string.
    # credo:disable-for-lines:6
    {output, 0} =
      System.cmd(
        launcher,
        [fake_elixir, "--name", "node@host", "cookie", "/bin/true", log],
        cd: tmp
      )

    assert {:ok, pid} = Start.parse_daemon_pid(output)
    assert is_integer(pid) and pid > 0

    # Child should still be alive briefly; clean up.
    _ = System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)
  end
end
