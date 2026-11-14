defmodule Mix.Tasks.Arbor.DistributionSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "KSEC-003,KSEC-017"

  @moduletag :fast

  alias Arbor.Common.SafePath
  alias Mix.Tasks.Arbor.Attach
  alias Mix.Tasks.Arbor.Helpers

  setup do
    {:ok, system_tmp} = SafePath.resolve_real(System.tmp_dir!())
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    tmp = Path.join(system_tmp, "arbor-distribution-security-#{token}")
    File.mkdir!(tmp)
    File.chmod!(tmp, 0o700)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  @tag spec: "KSEC-003,KSEC-017"
  test "security regression: distribution cookie is stored in a private cookie home", %{tmp: tmp} do
    home = Path.join(tmp, "arbor-home")
    secret = "private-cookie-value"

    assert {:ok, cookie_home} = Helpers.prepare_distribution_cookie(secret, home)
    cookie_file = Helpers.distribution_cookie_file(home)

    assert cookie_home == Path.join(home, "distribution")
    assert File.read!(cookie_file) == secret <> "\n"

    for path <- [home, Path.join(home, "logs"), cookie_home] do
      assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
      assert Bitwise.band(mode, 0o777) == 0o700
    end

    assert {:ok, %File.Stat{mode: cookie_mode}} = File.stat(cookie_file)
    assert Bitwise.band(cookie_mode, 0o777) == 0o600
  end

  test "security regression: loopback hosts select an explicit distribution bind" do
    assert Helpers.distribution_bind_mode("127.0.0.1") == "loopback_v4"
    assert Helpers.distribution_bind_mode("127.20.30.40") == "loopback_v4"
    assert Helpers.distribution_bind_mode("localhost") == "loopback_v4"
    assert Helpers.distribution_bind_mode("::1") == "loopback_v6"
    assert Helpers.distribution_bind_mode("10.42.42.10") == "default"
  end

  test "security regression: dotenv admits only Arbor and supported application keys", %{tmp: tmp} do
    safe_key = "ARBOR_SECURITY_REGRESSION_VALUE"
    allowed = [safe_key, "OPENAI_API_KEY", "DB_USER", "OIDC_CLIENT_ID"]
    blocked = Helpers.blocked_vm_flag_env() ++ ["MIX_ENV", "ERL_LIBS", "BASH_ENV"]
    keys = allowed ++ blocked
    previous = Map.take(System.get_env(), keys)

    Enum.each(keys, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(keys, &System.delete_env/1)
      Enum.each(previous, fn {key, value} -> System.put_env(key, value) end)
    end)

    dotenv = Path.join(tmp, ".env")

    File.write!(dotenv, """
    #{safe_key}=accepted
    OPENAI_API_KEY=provider-value
    DB_USER=database-user
    OIDC_CLIENT_ID=runtime-client
    ERL_AFLAGS=-setcookie exposed
    ERL_FLAGS=-eval attacker run
    ERL_ZFLAGS=-pa /attacker
    ELIXIR_ERL_OPTIONS=-setcookie exposed-again
    MIX_ENV=prod
    ERL_LIBS=/attacker
    BASH_ENV=/attacker/bootstrap
    """)

    Helpers.load_dotenv(dotenv)

    assert System.get_env(safe_key) == "accepted"
    assert System.get_env("OPENAI_API_KEY") == "provider-value"
    assert System.get_env("DB_USER") == "database-user"
    assert System.get_env("OIDC_CLIENT_ID") == "runtime-client"

    Enum.each(blocked, fn key ->
      refute System.get_env(key)
    end)

    refute Helpers.dotenv_key_allowed?("HOME")
    refute Helpers.dotenv_key_allowed?("PATH")
    refute Helpers.dotenv_key_allowed?("MIX_ENV")
    assert Helpers.dotenv_key_allowed?("ARBOR_COOKIE")
    assert Helpers.dotenv_key_allowed?("CONTACT_OWNER_EMAIL")
  end

  test "security regression: attach uses longnames and a cookie file without printing secret", %{
    tmp: tmp
  } do
    secret = "attach-cookie-must-not-be-printed"
    home = Path.join(tmp, "arbor home")
    assert {:ok, cookie_home} = Helpers.prepare_distribution_cookie(secret, home)

    command =
      Attach.attach_command(%{
        attach_name: "arbor_attach_123@127.0.0.1",
        remote_node: "arbor_dev_abcd@127.0.0.1",
        cookie_home: cookie_home,
        iex_path: "/opt/elixir/bin/iex",
        erlang_bin_dir: "/opt/erlang/bin"
      })

    assert command =~ "--name 'arbor_attach_123@127.0.0.1'"
    assert command =~ "--remsh 'arbor_dev_abcd@127.0.0.1'"
    # The remsh client reads the cookie at boot from its private HOME; it
    # runs no Arbor code locally and accepts no inbound connections.
    assert command =~ "HOME='#{cookie_home}'"
    assert command =~ "--erl '-dist_listen false -hidden'"
    refute command =~ "ARBOR_RUNTIME_ORIGINAL_HOME"
    refute command =~ " -r "
    refute command =~ "--sname"
    refute command =~ "--cookie"
    refute command =~ secret
  end

  @tag :slow
  test "security regression: CLI clients start distribution without a listener", %{tmp: tmp} do
    # Node.start/2 used to listen (and register with epmd) under the operator's
    # personal ~/.erlang.cookie until set_cookie/1 ran. Run the real
    # ensure_distribution/0 in a separate VM and check it never listened.
    home = Path.join(tmp, "cli-home")
    File.mkdir_p!(home)
    ebin = :code.which(Helpers) |> to_string() |> Path.dirname()
    epmd = Path.join(Helpers.erlang_bin_dir(), "epmd")
    # Trusted test fixtures only: absolute toolchain or launcher paths.
    # credo:disable-for-next-line
    {_, 0} = System.cmd(epmd, ["-daemon"], stderr_to_stdout: true)

    script = """
    :ok = Mix.Tasks.Arbor.Helpers.ensure_distribution()
    {:ok, names} = :erl_epmd.names()
    [name, _host] = node() |> Atom.to_string() |> String.split("@")
    IO.puts("cookie_set=\#{:erlang.get_cookie() == :cli_regression_cookie}")
    IO.puts("registered=\#{Enum.any?(names, fn {n, _port} -> List.to_string(n) == name end)}")
    """

    elixir = Helpers.elixir_executable("elixir")

    env = [
      {"HOME", home},
      {"PATH", Helpers.erlang_bin_dir() <> ":" <> System.get_env("PATH", "")},
      {"ARBOR_NODE_HOST", "127.0.0.1"},
      {"ARBOR_COOKIE", "cli_regression_cookie"}
    ]

    opts = [cd: tmp, env: env, stderr_to_stdout: true]
    # Trusted test fixtures only: absolute toolchain or launcher paths.
    # credo:disable-for-next-line
    {out, 0} = System.cmd(elixir, ["-pa", ebin, "-e", script], opts)

    assert out =~ "cookie_set=true"
    assert out =~ "registered=false"
  end
end
