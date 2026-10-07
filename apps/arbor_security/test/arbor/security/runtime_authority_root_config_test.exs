defmodule Arbor.Security.RuntimeAuthorityRootConfigTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @runtime_path Path.expand("../../../../../config/runtime.exs", __DIR__)

  test "security regression: dev honors an explicit absolute authority root" do
    root = "/operator-owned/original-checkout/.arbor/security"
    assert {0, {:ok, ^root}, _output} = read_runtime(:dev, root)
  end

  test "absent dev setting leaves the existing authority default untouched" do
    assert {0, :error, _output} = read_runtime(:dev, nil)
  end

  test "empty dev setting does not select a replacement authority root" do
    assert {0, :error, _output} = read_runtime(:dev, "")
  end

  test "test config ignores an absolute ambient authority root" do
    assert {0, :error, _output} = read_runtime(:test, "/operator-owned/security")
  end

  test "test config ignores even an invalid ambient authority root" do
    assert {0, :error, _output} = read_runtime(:test, "relative/security")
  end

  test "prod retains the explicit absolute authority root" do
    root = "/operator-owned/production/security"
    assert {0, {:ok, ^root}, _output} = read_runtime(:prod, root)
  end

  test "security regression: production accepts an explicit independent revocation path" do
    path = "/operator-owned/production-fence/capability-revocations.json"

    assert {0, {:ok, ^path}, _output} =
             read_runtime(:prod, nil, :revocation_ledger_path, path)
  end

  test "test config ignores an ambient revocation path" do
    assert {0, :error, _output} =
             read_runtime(:test, nil, :revocation_ledger_path, "/operator-owned/fence.json")
  end

  test "security regression: production rejects a relative revocation path" do
    {status, :no_result, output} =
      read_runtime(:prod, nil, :revocation_ledger_path, "relative/fence.json")

    assert status != 0
    assert output =~ "ARBOR_SECURITY_REVOCATION_LEDGER_PATH must be an absolute path"
  end

  for env <- [:dev, :prod] do
    test "security regression: #{env} rejects a relative explicit authority root" do
      {status, :no_result, output} = read_runtime(unquote(env), "relative/security")
      assert status != 0
      assert output =~ "ARBOR_SECURITY_STATE_DIR must be an absolute path"
    end
  end

  # Evaluate the complete runtime config in a fresh BEAM without application
  # code, dotenv, inherited credentials, or any live authority/journal owner.
  defp read_runtime(env, root, key \\ :authority_state_root, ledger_path \\ nil) do
    cwd =
      Path.join(System.tmp_dir!(), "arbor-authority-config-#{System.unique_integer([:positive])}")

    File.mkdir!(cwd)
    on_exit(fn -> File.rm_rf!(cwd) end)
    result_path = Path.join(cwd, "result.etf")

    expression = """
    config = Config.Reader.read!(#{inspect(@runtime_path)}, env: #{inspect(env)})
    value = config |> Keyword.get(:arbor_security, []) |> Keyword.fetch(#{inspect(key)})
    File.write!(#{inspect(result_path)}, :erlang.term_to_binary(value), [:exclusive])
    """

    inherited = System.get_env()

    child_env =
      inherited
      |> Map.new(fn {key, _value} -> {key, nil} end)
      |> Map.merge(Map.take(inherited, ["PATH", "HOME", "SYSTEMROOT"]))
      |> Map.merge(%{
        "TMPDIR" => cwd,
        "ARBOR_HOME" => cwd,
        "ARBOR_ENV_PATH" => Path.join(cwd, "absent.env"),
        "ARBOR_DATA_DIR" => Path.join(cwd, "data"),
        "ARBOR_SECURITY_STATE_DIR" => root,
        "ARBOR_SECURITY_REVOCATION_LEDGER_PATH" => ledger_path,
        "SECRET_KEY_BASE" => String.duplicate("configuration-test-only-", 4)
      })
      |> Map.to_list()

    elixir = System.find_executable("elixir") || flunk("pinned elixir executable not found")

    {output, status} =
      System.cmd(elixir, ["-e", expression], cd: cwd, env: child_env, stderr_to_stdout: true)

    result =
      case File.read(result_path) do
        {:ok, bytes} -> :erlang.binary_to_term(bytes, [:safe])
        {:error, :enoent} -> :no_result
      end

    {status, result, output}
  end
end
