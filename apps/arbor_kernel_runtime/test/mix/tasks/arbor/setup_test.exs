defmodule Mix.Tasks.Arbor.SetupTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Common.SafePath
  alias Mix.Tasks.Arbor.Setup

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "arbor_setup_#{System.unique_integer([:positive])}")
      |> Path.expand()

    File.mkdir_p!(tmp)
    {:ok, tmp} = SafePath.resolve_real(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    {:ok, tmp: tmp}
  end

  test "ensure_operator_identity generates a 0600 key with a valid agent id", %{tmp: tmp} do
    path = Path.join(tmp, "identity.key")

    assert {:ok, message} = Setup.ensure_operator_identity(path)
    assert message =~ "generated agent_"

    contents = File.read!(path)
    assert [_, agent_id] = Regex.run(~r/^agent_id=(agent_[0-9a-f]{64})$/m, contents)
    assert [_, key_b64] = Regex.run(~r/^private_key_b64=(.+)$/m, contents)
    assert {:ok, raw} = Base.decode64(String.trim(key_b64))
    assert byte_size(raw) in [32, 64]
    assert message =~ agent_id

    # Mode matters: the key is readable by other unix users otherwise.
    assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "ensure_operator_identity NEVER overwrites an existing key", %{tmp: tmp} do
    # The checkpoint HMAC secret is derived from this key. Regenerating it would
    # silently orphan every existing checkpoint, so an existing file must win
    # even when it is not a well-formed key.
    path = Path.join(tmp, "identity.key")
    sentinel = "agent_id=agent_preexisting\nprivate_key_b64=DO_NOT_TOUCH\n"
    File.write!(path, sentinel)

    assert {:skip, message} = Setup.ensure_operator_identity(path)
    assert message =~ "already exists"
    assert File.read!(path) == sentinel
  end

  test "security regression: setup creates .env with mode 0600", %{tmp: tmp} do
    example = Path.join(tmp, ".env.example")
    env = Path.join(tmp, ".env")
    File.write!(example, "ARBOR_DB=sqlite\n")
    File.chmod!(example, 0o644)

    assert {:ok, message} = Setup.setup_env(tmp)
    assert message =~ "mode 600"
    assert File.read!(env) == "ARBOR_DB=sqlite\n"
    assert {:ok, %File.Stat{mode: mode}} = File.stat(env)
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "security regression: generated cookie is saved privately and not returned in output", %{
    tmp: tmp
  } do
    previous = System.get_env("ARBOR_COOKIE")
    System.delete_env("ARBOR_COOKIE")

    on_exit(fn ->
      if previous,
        do: System.put_env("ARBOR_COOKIE", previous),
        else: System.delete_env("ARBOR_COOKIE")
    end)

    assert {:ok, message} = Setup.setup_cookie([], tmp)
    env = Path.join(tmp, ".env")
    assert [_, cookie] = Regex.run(~r/^ARBOR_COOKIE=([0-9a-f]{64})$/m, File.read!(env))
    refute message =~ cookie
    assert {:ok, %File.Stat{mode: mode}} = File.stat(env)
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "security regression: setup generates a private session-token secret", %{tmp: tmp} do
    previous = System.get_env("ARBOR_SESSION_TOKEN_SECRET")
    System.delete_env("ARBOR_SESSION_TOKEN_SECRET")

    on_exit(fn ->
      if previous,
        do: System.put_env("ARBOR_SESSION_TOKEN_SECRET", previous),
        else: System.delete_env("ARBOR_SESSION_TOKEN_SECRET")
    end)

    File.write!(Path.join(tmp, ".env"), "ARBOR_DB=sqlite\n")

    assert {:ok, message} = Setup.setup_session_token_secret(tmp)
    env = Path.join(tmp, ".env")

    assert [_, encoded] =
             Regex.run(~r/^ARBOR_SESSION_TOKEN_SECRET=([A-Za-z0-9_-]{43})$/m, File.read!(env))

    assert {:ok, secret} = Base.url_decode64(encoded, padding: false)
    assert byte_size(secret) == 32
    refute message =~ encoded
    assert {:ok, %File.Stat{mode: mode}} = File.stat(env)
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "security regression: setup makes Arbor runtime and log directories mode 0700", %{
    tmp: tmp
  } do
    arbor_home = Path.join(tmp, ".arbor")
    assert {:ok, _} = Setup.ensure_directories(arbor_home)

    for path <- [arbor_home, Path.join(arbor_home, "logs")] do
      assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
      assert Bitwise.band(mode, 0o777) == 0o700
    end
  end

  test "security regression: SQLite setup makes a custom parent 0700 and database 0600", %{
    tmp: tmp
  } do
    database = Path.join([tmp, "custom", "data", "arbor.db"])
    parent = Path.dirname(database)
    File.mkdir_p!(parent)
    File.chmod!(parent, 0o755)

    assert :created =
             Setup.with_private_sqlite_storage(database, fn ->
               assert_mode(parent, 0o700)
               File.write!(database, "new sqlite bytes")
               File.chmod!(database, 0o644)
               :created
             end)

    assert_mode(parent, 0o700)
    assert_mode(database, 0o600)

    File.chmod!(parent, 0o755)
    File.chmod!(database, 0o644)

    assert :existing =
             Setup.with_private_sqlite_storage(database, fn ->
               assert_mode(parent, 0o700)
               assert_mode(database, 0o600)
               :existing
             end)

    assert_mode(parent, 0o700)
    assert_mode(database, 0o600)
  end

  test "fetch_deps uses the absolute reviewed wrapper with exact argv in a fresh process", %{
    tmp: tmp
  } do
    bin_dir = Path.join(tmp, "bin")
    wrapper = Path.join(bin_dir, "mix")
    invocation = Path.join(tmp, "invocation")
    File.mkdir_p!(bin_dir)

    File.write!(wrapper, """
    #!/bin/sh
    set -eu
    {
      printf 'executable=%s\\n' "$0"
      printf 'argc=%s\\n' "$#"
      printf 'arg1=%s\\n' "$1"
      printf 'cwd=%s\\n' "$(pwd)"
    } > "#{invocation}"
    """)

    File.chmod!(wrapper, 0o755)

    assert {:ok, ^wrapper} = Setup.resolve_mix_wrapper(tmp)
    assert {:ok, "done"} = Setup.fetch_deps(tmp)

    assert File.read!(invocation) ==
             "executable=#{wrapper}\nargc=1\narg1=deps.get\ncwd=#{tmp}\n"
  end

  test "resolve_mix_wrapper fails closed with an actionable error when wrapper is missing", %{
    tmp: tmp
  } do
    expected = Path.join(tmp, "bin/mix")

    assert {:error, message} = Setup.resolve_mix_wrapper(tmp)
    assert message =~ "does not exist at #{expected}"
    assert message =~ "restore bin/mix with executable mode"
  end

  test "resolve_mix_wrapper fails closed when wrapper is not executable", %{tmp: tmp} do
    wrapper = Path.join(tmp, "bin/mix")
    File.mkdir_p!(Path.dirname(wrapper))
    File.write!(wrapper, "#!/bin/sh\nexit 0\n")
    File.chmod!(wrapper, 0o644)

    assert {:error, message} = Setup.resolve_mix_wrapper(tmp)
    assert message =~ "is not executable at #{wrapper}"
    assert message =~ "restore bin/mix with executable mode"
  end

  defp assert_mode(path, expected) do
    assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == expected
  end
end
