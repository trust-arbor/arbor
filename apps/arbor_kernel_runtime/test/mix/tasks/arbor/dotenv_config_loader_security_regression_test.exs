defmodule Mix.Tasks.Arbor.DotenvConfigLoaderSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "KSEC-017"

  @moduletag :fast

  @tag :security_regression
  @tag spec: "KSEC-017"
  test "security regression: every actual config loader rejects process control keys" do
    repo_root = Path.expand("../../../../../../", __DIR__)
    {:ok, system_tmp} = Arbor.Common.SafePath.resolve_real(System.tmp_dir!())
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    tmp = Path.join(system_tmp, "arbor-config-dotenv-#{token}")
    File.mkdir!(tmp)
    File.chmod!(tmp, 0o700)
    on_exit(fn -> File.rm_rf!(tmp) end)

    config_dir = Path.join(tmp, "config")
    File.cp_r!(Path.join(repo_root, "config"), config_dir)
    File.ln_s!(Path.join(repo_root, "apps"), Path.join(tmp, "apps"))

    allowed = ["ARBOR_CONFIG_TIME_PROBE", "OPENAI_API_KEY"]
    blocked = ["MIX_ENV", "ERL_LIBS", "BASH_ENV"]
    support = ["ARBOR_HOME"]
    keys = allowed ++ blocked ++ support
    previous = Map.take(System.get_env(), keys)
    Enum.each(keys, &System.delete_env/1)

    try do
      File.write!(Path.join(tmp, ".env"), """
      ARBOR_CONFIG_TIME_PROBE=allowed
      OPENAI_API_KEY=provider-value
      MIX_ENV=prod
      ERL_LIBS=/attacker
      BASH_ENV=/attacker/bootstrap
      """)

      loaders = [
        {"dev.exs", :dev, false},
        {"test.exs", :test, false},
        {"runtime.exs", :dev, true}
      ]

      Enum.each(loaders, fn {filename, env, from_cwd?} ->
        Enum.each(keys, &System.delete_env/1)
        System.put_env("ARBOR_HOME", Path.join(tmp, "arbor_home"))
        path = Path.join(config_dir, filename)

        config =
          if from_cwd? do
            File.cd!(tmp, fn -> Config.Reader.read!(path, env: env) end)
          else
            Config.Reader.read!(path, env: env)
          end

        assert is_list(config), "#{filename} did not return application config"
        assert System.get_env("ARBOR_CONFIG_TIME_PROBE") == "allowed"
        assert System.get_env("OPENAI_API_KEY") == "provider-value"

        Enum.each(blocked, fn key ->
          refute System.get_env(key), "#{filename} admitted blocked key #{key}"
        end)
      end)
    after
      Enum.each(keys, &System.delete_env/1)
      Enum.each(previous, fn {key, value} -> System.put_env(key, value) end)
    end
  end
end
