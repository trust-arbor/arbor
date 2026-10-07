defmodule Arbor.Common.DotCacheSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "KSEC-020"

  @moduletag :fast

  alias Arbor.Common.SkillLibrary.DotCache

  setup do
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    skill_name = "cache-security-#{token}"
    dir = Path.join([File.cwd!(), ".arbor", "skills", skill_name])
    on_exit(fn -> File.rm_rf(dir) end)
    %{skill_name: skill_name, dir: dir}
  end

  @tag :security_regression
  @tag spec: "KSEC-020"
  test "security regression: cache names cannot escape the fixed skill root" do
    hash = sha256("source")

    assert {:error, :invalid_cache_key} =
             DotCache.put("../cache-escape", hash, "digraph safe {}")
  end

  @tag :security_regression
  test "security regression: a matching source header cannot hide DOT tampering", ctx do
    source_hash = sha256("source")
    assert {:ok, path} = DotCache.put(ctx.skill_name, source_hash, "digraph safe {}")
    assert {:ok, ^path} = DotCache.get(ctx.skill_name, source_hash)

    [header, _body] = File.read!(path) |> String.split("\n", parts: 2)
    File.write!(path, header <> "\ndigraph attacker {}")

    assert {:error, :stale} = DotCache.get(ctx.skill_name, source_hash)
  end

  @tag :security_regression
  test "security regression: a valid skill-name symlink cannot redirect cache writes", ctx do
    outside = tmp_dir("skill-dir-target")
    outside_cache = Path.join(outside, "COMPILED.dot")
    File.mkdir_p!(Path.dirname(ctx.dir))
    File.ln_s!(outside, ctx.dir)

    source_hash = sha256("source")

    assert {:error, :unsafe_cache_path} =
             DotCache.put(ctx.skill_name, source_hash, "digraph attacker {}")

    assert {:error, :unsafe_cache_path} = DotCache.get(ctx.skill_name, source_hash)
    refute File.exists?(outside_cache)
  end

  @tag :security_regression
  test "security regression: a COMPILED.dot symlink is neither read nor followed for writes",
       ctx do
    outside = tmp_dir("compiled-target")
    outside_cache = Path.join(outside, "outside.dot")
    File.mkdir_p!(ctx.dir)
    File.write!(outside_cache, "outside-sentinel")
    File.ln_s!(outside_cache, Path.join(ctx.dir, "COMPILED.dot"))

    source_hash = sha256("source")

    assert {:error, :unsafe_cache_path} = DotCache.get(ctx.skill_name, source_hash)

    assert {:error, :unsafe_cache_path} =
             DotCache.put(ctx.skill_name, source_hash, "digraph attacker {}")

    assert File.read!(outside_cache) == "outside-sentinel"
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp tmp_dir(label) do
    {:ok, system_tmp} = Arbor.Common.SafePath.resolve_real(System.tmp_dir!())
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    path = Path.join(system_tmp, "arbor-dot-cache-#{label}-#{token}")
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
