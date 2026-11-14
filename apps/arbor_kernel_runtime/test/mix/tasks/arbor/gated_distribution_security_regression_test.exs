defmodule Mix.Tasks.Arbor.GatedDistributionSecurityRegressionTest do
  @moduledoc """
  Security regression tests for the dev daemon's gated distribution, driven
  through the real `bin/arbor-dev-daemon-launch`, the real bootstrap and the
  real gated carrier. A probe script stands in for `mix run`: it reports
  facts from inside the daemon VM and flips the gate on request, so the test
  can hold open the window between `net_kernel:start/2` and `set_cookie/1`
  that the bootstrap normally closes within microseconds.

  Every daemon runs with a scratch HOME, a unique node name and a listen
  range outside 9100-9155, so it never shares a port with a live node.

  Bugs these guard against:

    * 2026-10-07 launcher: the daemon booted with HOME pointed at the cookie
      directory, so `System.user_home/0` and `Path.expand("~")` resolved the
      security master key, revocation ledger and `.env` under
      `~/.arbor/distribution/.arbor`.
    * Starting distribution with `-nocookie` and setting the cookie afterwards
      lets any peer presenting the public cookie `nocookie` connect (root RPC)
      in between, unless inbound handshakes are refused until then.
  """
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :slow
  @moduletag timeout: 180_000

  alias Arbor.Common.SafePath
  alias Mix.Tasks.Arbor.Helpers
  alias Mix.Tasks.Arbor.Start

  @project_dir Path.expand("../../../../../../", __DIR__)

  @probe_source ~S"""
  dir = System.fetch_env!("GD_PROBE_DIR")
  gate = {:arbor_gated_dist, :gate}
  real_cookie = :erlang.get_cookie()

  spawn(fn ->
    Process.sleep(120_000)
    System.halt(3)
  end)

  facts = %{
    user_home: System.user_home(),
    expanded_home: Path.expand("~"),
    home_env: System.get_env("HOME"),
    node: Atom.to_string(node()),
    gate: :persistent_term.get(gate, :missing),
    env_leaks_cookie:
      Enum.any?(System.get_env(), fn {_k, v} -> String.contains?(v, Atom.to_string(real_cookie)) end)
  }

  File.write!(Path.join(dir, "facts.bin"), :erlang.term_to_binary(facts))

  apply_phase = fn
    "window" ->
      :persistent_term.put(gate, :closed)
      :erlang.set_cookie(:nocookie)

    "closed" ->
      :persistent_term.put(gate, :closed)
      :erlang.set_cookie(real_cookie)

    "open" ->
      :persistent_term.put(gate, :open)
      :erlang.set_cookie(real_cookie)
  end

  loop = fn loop, last ->
    phase =
      case File.read(Path.join(dir, "phase")) do
        {:ok, phase} -> String.trim(phase)
        _ -> last
      end

    cond do
      phase == "stop" ->
        System.halt(0)

      phase != last and phase in ["window", "closed", "open"] ->
        apply_phase.(phase)
        File.write!(Path.join(dir, "ack"), phase)
        loop.(loop, phase)

      true ->
        Process.sleep(20)
        loop.(loop, last)
    end
  end

  loop.(loop, nil)
  """

  setup do
    {:ok, system_tmp} = SafePath.resolve_real(System.tmp_dir!())
    token = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    tmp = Path.join(system_tmp, "arbor-gated-dist-#{token}")
    File.mkdir_p!(tmp)
    File.chmod!(tmp, 0o700)
    on_exit(fn -> File.rm_rf!(tmp) end)

    # Stand-in for the operator's real HOME; peers get a different one.
    home = Path.join(tmp, "home")
    peer_home = Path.join(tmp, "peer-home")
    ctl = Path.join(tmp, "ctl")
    Enum.each([home, peer_home, ctl], &File.mkdir_p!/1)

    arbor_home = Path.join(home, ".arbor")
    secret = "gdsecret" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    assert {:ok, cookie_home} = Helpers.prepare_distribution_cookie(secret, arbor_home)

    probe = Path.join(tmp, "probe.exs")
    File.write!(probe, @probe_source)

    ensure_epmd!()

    {:ok,
     tmp: tmp,
     home: home,
     peer_home: peer_home,
     ctl: ctl,
     secret: secret,
     cookie_home: cookie_home,
     cookie_file: Helpers.distribution_cookie_file(arbor_home),
     probe: probe,
     log: Path.join(tmp, "daemon.log"),
     node: "arbor_gdtest_#{token}@127.0.0.1"}
  end

  test "security regression: daemon HOME stays real and the cookie stays out of argv and env",
       ctx do
    pid = launch!(ctx)
    facts = await_facts!(ctx)

    # (a) The cookie is never in the daemon's OS argv.
    argv = os_argv(pid)
    assert argv =~ ctx.node, "expected the node name in the daemon argv: #{argv}"
    refute argv =~ ctx.secret
    refute argv =~ "-setcookie"

    # (d) Inside the daemon `~` is the operator's HOME, not the cookie directory.
    assert facts.user_home == ctx.home
    assert facts.expanded_home == ctx.home
    assert facts.home_env == ctx.home
    assert facts.node == ctx.node

    # (e) Booting created no `.erlang.cookie` anywhere under the real HOME.
    assert Path.wildcard(Path.join(ctx.home, "**/.erlang.cookie"), match_dot: true) ==
             [ctx.cookie_file]

    # The cookie is not readable from the VM's environment either.
    refute facts.env_leaks_cookie
    refute os_environment(pid) =~ ctx.secret
  end

  test "security regression: inbound handshakes are refused until the gate opens", ctx do
    _pid = launch!(ctx)
    facts = await_facts!(ctx)

    # (b) The bootstrap's real window: node alive, cookie still `nocookie`.
    # Without the gate a `nocookie` peer gets `pong` here (full root RPC).
    phase!(ctx, "window")
    assert {nocookie_peer, :pang} = ping(ctx, "nocookie")
    assert {real_peer, :pang} = ping(ctx, ctx.secret)

    # (b) Gate closed after the cookie is set: the real cookie is refused too.
    phase!(ctx, "closed")
    assert {closed_real_peer, :pang} = ping(ctx, ctx.secret)
    assert {closed_nocookie_peer, :pang} = ping(ctx, "nocookie")

    # Refusal happened at the name stage, before any cookie challenge.
    for peer <- [nocookie_peer, real_peer, closed_real_peer, closed_nocookie_peer] do
      assert_log!(ctx, "disallowed node #{peer}")
    end

    # (c) Gate open: the real cookie connects; a wrong cookie and nocookie do not.
    phase!(ctx, "open")
    assert {_peer, :pong} = ping(ctx, ctx.secret)
    assert {wrong_peer, :pang} = ping(ctx, "wrong-cookie-value")
    assert {_peer, :pang} = ping(ctx, "nocookie")
    assert_log!(ctx, ~s(Connection attempt from node :"#{wrong_peer}" rejected))

    # The bootstrap itself left the gate open once the cookie was set.
    assert facts.gate == :open
  end

  test "security regression: the bootstrap fails closed on an unsafe cookie file", ctx do
    File.chmod!(ctx.cookie_file, 0o644)
    pid = launch!(ctx)
    assert await_exit(pid), "daemon kept running with a group-readable cookie file"
    assert File.read!(ctx.log) =~ "cookie file must not be accessible to group or others"

    target = Path.join(ctx.tmp, "elsewhere-cookie")
    File.write!(target, ctx.secret)
    File.chmod!(target, 0o600)
    File.rm!(ctx.cookie_file)
    File.ln_s!(target, ctx.cookie_file)

    pid = launch!(ctx)
    assert await_exit(pid), "daemon kept running with a symlinked cookie file"
    assert File.read!(ctx.log) =~ "cookie file is missing, a symlink, or not a regular file"
    refute File.exists?(Path.join(ctx.ctl, "facts.bin"))
  end

  test "security regression: gated carriers export exactly the inner modules' callbacks" do
    for {source, inner} <- [
          {"bin/arbor_gated_tcp_dist.erl", :inet_tcp_dist},
          {"bin/arbor_gated_tcp6_dist.erl", :inet6_tcp_dist}
        ] do
      path = Path.join(@project_dir, source) |> String.to_charlist()
      assert {:ok, module, binary} = :compile.noenv_file(path, [:binary, :return_errors])
      {:ok, {^module, [exports: exports]}} = :beam_lib.chunks(binary, [:exports])

      # net_kernel probes optional callbacks with `try ... catch error:undef`;
      # any drift here would silently change which path it takes.
      assert Enum.sort(exports) == Enum.sort(inner.module_info(:exports)),
             "#{source} drifted from #{inner}: wrap the new callbacks"
    end
  end

  # --- helpers --------------------------------------------------------------

  defp launch!(ctx) do
    File.rm(Path.join(ctx.ctl, "facts.bin"))
    {:ok, launcher} = Start.resolve_daemon_launcher(@project_dir)
    base = 47_000 + :rand.uniform(1_900)

    env =
      Start.daemon_env(
        %{
          "HOME" => ctx.home,
          "PATH" => System.get_env("PATH", "/usr/bin:/bin"),
          "ARBOR_COOKIE" => ctx.secret,
          "GD_PROBE_DIR" => ctx.ctl,
          "ARBOR_DIST_LISTEN_MIN" => Integer.to_string(base),
          "ARBOR_DIST_LISTEN_MAX" => Integer.to_string(base + 20)
        },
        :test,
        Helpers.erlang_bin_dir()
      )

    # Superset spec: carries the fields of both the gated launcher and the
    # 2026-10-07 HOME-redirect launcher, so the same test can be run against
    # either to show the regression.
    assert {:ok, pid} =
             Start.spawn_daemon_process(%{
               project_dir: ctx.tmp,
               launcher: launcher,
               elixir_path: Helpers.elixir_executable("elixir"),
               node_string: ctx.node,
               name_type: "longnames",
               name_flag: "--name",
               cookie_file: ctx.cookie_file,
               cookie_home: ctx.cookie_home,
               bind_mode: "loopback_v4",
               bootstrap_path: Helpers.runtime_bootstrap_file(@project_dir),
               mix_path: ctx.probe,
               log_file: ctx.log,
               env: env
             })

    on_exit(fn -> stop_daemon(ctx, pid) end)
    pid
  end

  defp stop_daemon(ctx, pid) do
    _ = File.write(Path.join(ctx.ctl, "phase"), "stop")

    unless await_exit(pid, 3_000) do
      if os_argv(pid) =~ ctx.node do
        System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)
      end
    end
  end

  defp await_facts!(ctx) do
    path = Path.join(ctx.ctl, "facts.bin")

    unless wait_until(fn -> File.regular?(path) end, 60_000) do
      flunk("daemon probe never reported facts; log:\n#{File.read!(ctx.log)}")
    end

    # Give the writer a moment to finish the file it just created.
    Process.sleep(50)
    path |> File.read!() |> :erlang.binary_to_term()
  end

  defp phase!(ctx, phase) do
    staging = Path.join(ctx.ctl, "phase.tmp")
    File.write!(staging, phase)
    File.rename!(staging, Path.join(ctx.ctl, "phase"))
    ack = Path.join(ctx.ctl, "ack")

    assert wait_until(fn -> File.read(ack) == {:ok, phase} end, 10_000),
           "probe did not acknowledge phase #{phase}"
  end

  # One short-lived `erl` per attempt, presenting `cookie`. It has no
  # listener of its own and a HOME separate from the daemon's.
  defp ping(ctx, cookie) do
    name = "gdpeer_#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}@127.0.0.1"

    eval =
      "spawn(fun() -> timer:sleep(20000), halt(3) end), " <>
        "io:format(\"~n~p~n\", [net_adm:ping('#{ctx.node}')]), halt()."

    erl = Path.join(Helpers.erlang_bin_dir(), "erl")

    args =
      ~w(-noshell -name #{name} -setcookie #{cookie} -dist_listen false -hidden -eval) ++ [eval]

    env = [{"HOME", ctx.peer_home}, {"ERL_AFLAGS", nil}, {"ERL_FLAGS", nil}, {"ERL_ZFLAGS", nil}]
    # Trusted test fixtures only: absolute toolchain or launcher paths.
    # credo:disable-for-next-line
    {out, _status} = System.cmd(erl, args, env: env, stderr_to_stdout: true)

    result =
      case out |> String.split() |> List.last() do
        "pong" -> :pong
        "pang" -> :pang
        other -> {:unexpected, other, out}
      end

    {name, result}
  end

  defp assert_log!(ctx, needle) do
    assert wait_until(fn -> File.read!(ctx.log) =~ needle end, 5_000),
           "expected #{inspect(needle)} in the daemon log:\n#{File.read!(ctx.log)}"
  end

  defp os_argv(pid) do
    case System.cmd("ps", ["-ww", "-o", "args=", "-p", Integer.to_string(pid)],
           stderr_to_stdout: true
         ) do
      {out, 0} -> out
      _ -> ""
    end
  end

  # The process's initial environment as other processes see it.
  defp os_environment(pid) do
    case :os.type() do
      {:unix, :darwin} ->
        {out, 0} = System.cmd("ps", ["-wwE", "-o", "command=", "-p", Integer.to_string(pid)])
        out

      {:unix, :linux} ->
        File.read!("/proc/#{pid}/environ")
    end
  end

  defp await_exit(pid, timeout \\ 30_000) do
    wait_until(fn -> not Helpers.pid_alive?(pid) end, timeout)
  end

  defp wait_until(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      cond do
        fun.() ->
          :ok

        System.monotonic_time(:millisecond) > deadline ->
          :timeout

        true ->
          Process.sleep(50)
          :retry
      end
    end)
    |> Enum.find(&(&1 != :retry))
    |> Kernel.==(:ok)
  end

  defp ensure_epmd! do
    epmd = Path.join(Helpers.erlang_bin_dir(), "epmd")
    # Trusted test fixtures only: absolute toolchain or launcher paths.
    # credo:disable-for-next-line
    {_, 0} = System.cmd(epmd, ["-daemon"], stderr_to_stdout: true)

    assert wait_until(
             # Trusted test fixtures only: absolute toolchain or launcher paths.
             # credo:disable-for-next-line
             fn -> match?({_, 0}, System.cmd(epmd, ["-names"], stderr_to_stdout: true)) end,
             5_000
           )
  end
end
