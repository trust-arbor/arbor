defmodule Arbor.Scheduler.OwnedDigestRuntimeConfigTest do
  use ExUnit.Case, async: false

  alias Arbor.Common.SafePath
  alias Config.Reader

  @moduletag :fast
  @runtime_path Path.expand("../../../../../config/runtime.exs", __DIR__)
  @env_keys ~w(ARBOR_OWNED_DIGEST_ENABLED ARBOR_OWNED_DIGEST_ROOT ARBOR_HOME ARBOR_ENV_PATH ARBOR_DATA_DIR ARBOR_DB DATABASE_URL SECRET_KEY_BASE ARBOR_VALIDATION_RUNTIME_CONFIG_PATH ARBOR_APPLE_CONTAINER_CONFIG_PATH ARBOR_PRIVATE_MEMORY_ENABLED ARBOR_HYBRID_MEMORY_ENABLED ARBOR_LM_STUDIO_BASE_URL)
  @config_keys [
    {:arbor_scheduler, :pipeline_roots},
    {:arbor_trust, :security_ceilings}
  ]
  @directories ~w(pipelines logs reports/upstream-deps reports/upstream-deps-summary reports/morning-digest)
  @root_error "ARBOR_OWNED_DIGEST_ROOT must be a bounded canonical absolute ASCII directory path"
  @directory_error "ARBOR_OWNED_DIGEST_ROOT requires existing directories without symlink components"
  @file_error "ARBOR_OWNED_DIGEST_ROOT requires regular nonsymlink graph and manifest files"
  @conflict_error "ARBOR_OWNED_DIGEST_ENABLED conflicts with existing roots or ceiling configuration"

  setup do
    previous_env = Map.new(@env_keys, &{&1, System.get_env(&1)})
    Enum.each(@env_keys, &System.delete_env/1)

    previous_config =
      Map.new(@config_keys, fn {app, key} -> {{app, key}, Application.fetch_env(app, key)} end)

    Enum.each(@config_keys, fn {app, key} -> Application.delete_env(app, key) end)

    temporary =
      Path.join(System.tmp_dir!(), "owned-digest-config-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temporary)
    {:ok, root} = SafePath.resolve_real(temporary)
    deployment = Path.join(root, "deployment")
    File.mkdir!(deployment)
    Enum.each(@directories, &File.mkdir_p!(Path.join(deployment, &1)))
    File.write!(Path.join(deployment, "pipelines/morning_digest.dot"), "fixture graph bytes")

    File.write!(
      Path.join(deployment, "pipelines/morning_digest.caps.json"),
      "fixture manifest bytes"
    )

    System.put_env("ARBOR_HOME", root)
    System.put_env("ARBOR_ENV_PATH", Path.join(root, ".env"))
    System.put_env("ARBOR_DATA_DIR", root)

    on_exit(fn ->
      Enum.each(previous_env, fn {key, value} -> put_or_delete(key, value) end)

      Enum.each(previous_config, fn
        {{app, key}, :error} -> Application.delete_env(app, key)
        {{app, key}, {:ok, value}} -> Application.put_env(app, key, value)
      end)

      File.rm_rf!(root)
    end)

    %{root: root, deployment: deployment}
  end

  test "unset and false flags preserve existing configuration without reading the root", ctx do
    existing = [
      arbor_scheduler: [
        {Oban, [plugins: [{Oban.Plugins.Cron, crontab: [{"30 6 * * *", :old_worker}]}]]},
        morning_digest_pipeline: "previous.dot",
        routine_logs_root: "previous-logs",
        pipeline_roots: %{"previous" => "previous-root"}
      ],
      arbor_trust: [security_ceilings: %{"arbor://fs/write" => :ask}]
    ]

    for flag <- [nil, "false"] do
      put_or_delete("ARBOR_OWNED_DIGEST_ENABLED", flag)
      System.put_env("ARBOR_OWNED_DIGEST_ROOT", "not-an-existing-root")
      runtime = read_runtime(ctx.root)
      assert runtime[:arbor_scheduler] == nil
      assert runtime[:arbor_trust] == nil
      merged = Reader.merge(existing, runtime)
      assert merged[:arbor_scheduler] == existing[:arbor_scheduler]
      assert merged[:arbor_trust] == existing[:arbor_trust]
    end
  end

  test "enabled configuration derives only existing scheduler settings and a scoped ceiling",
       ctx do
    enable(ctx.deployment)
    runtime = read_runtime(ctx.root)

    assert runtime[:arbor_scheduler] == [
             morning_digest_pipeline: Path.join(ctx.deployment, "pipelines/morning_digest.dot"),
             routine_logs_root: Path.join(ctx.deployment, "logs"),
             pipeline_roots: %{
               "laptop_digest_verification" => Path.join(ctx.deployment, "pipelines")
             }
           ]

    assert runtime[:arbor_trust][:security_ceilings] == %{write_scope(ctx.deployment) => :allow}

    assert File.read!(Path.join(ctx.deployment, "pipelines/morning_digest.dot")) ==
             "fixture graph bytes"

    assert File.read!(Path.join(ctx.deployment, "pipelines/morning_digest.caps.json")) ==
             "fixture manifest bytes"

    assert File.ls!(Path.join(ctx.deployment, "reports/morning-digest")) == []
    # Config selection does not validate, sign, enroll or execute the fixture manifest.
  end

  test "existing application maps are extended without changing bundled cron or global ceilings",
       ctx do
    roots = %{"scheduler_priv" => "/fixture/bundled", "other" => "/fixture/other"}
    ceilings = %{"arbor://fs/write" => :ask, "arbor://shell" => :ask}
    Application.put_env(:arbor_scheduler, :pipeline_roots, roots)
    Application.put_env(:arbor_trust, :security_ceilings, ceilings)
    enable(ctx.deployment)
    runtime = read_runtime(ctx.root)

    assert runtime[:arbor_scheduler][:pipeline_roots] ==
             Map.put(roots, "laptop_digest_verification", Path.join(ctx.deployment, "pipelines"))

    assert runtime[:arbor_trust][:security_ceilings] ==
             Map.put(ceilings, write_scope(ctx.deployment), :allow)

    cron = [plugins: [{Oban.Plugins.Cron, crontab: [{"30 6 * * *", :bundled_worker}]}]]
    merged = Reader.merge([arbor_scheduler: [{Oban, cron}]], runtime)
    assert merged[:arbor_scheduler][Oban] == cron
  end

  test "configuration already evaluated in this reader takes precedence over application maps",
       ctx do
    Application.put_env(:arbor_scheduler, :pipeline_roots, %{"initial" => "/initial"})
    Application.put_env(:arbor_trust, :security_ceilings, %{"arbor://fs/write" => :ask})
    enable(ctx.deployment)

    prefix = """
    import Config
    config :arbor_scheduler, :pipeline_roots, %{"evaluated" => "/evaluated"}
    config :arbor_trust, :security_ceilings, %{"arbor://shell" => :ask}
    """

    runtime =
      File.cd!(ctx.root, fn ->
        Reader.eval!(@runtime_path, prefix <> File.read!(@runtime_path), env: :dev, target: :host)
      end)

    assert runtime[:arbor_scheduler][:pipeline_roots] == %{
             "evaluated" => "/evaluated",
             "laptop_digest_verification" => Path.join(ctx.deployment, "pipelines")
           }

    assert runtime[:arbor_trust][:security_ceilings] == %{
             "arbor://shell" => :ask,
             write_scope(ctx.deployment) => :allow
           }
  end

  test "dotenv opt-in is available in dev and production without changing the global loader",
       ctx do
    File.write!(Path.join(ctx.root, ".env"), """
    ARBOR_OWNED_DIGEST_ENABLED=true
    ARBOR_OWNED_DIGEST_ROOT=#{ctx.deployment}
    """)

    # Select the already compiled adapter; Config.Reader performs no DB connection.
    adapter = Application.get_env(:arbor_persistence, :repo_adapter, Ecto.Adapters.SQLite3)

    System.put_env(
      "ARBOR_DB",
      if(adapter == Ecto.Adapters.SQLite3, do: "sqlite", else: "postgres")
    )

    System.put_env("DATABASE_URL", "ecto://fixture:fixture@localhost/unused_config_reader")
    System.put_env("SECRET_KEY_BASE", String.duplicate("synthetic-config-fixture-", 4))

    for env <- [:dev, :prod] do
      runtime = read_runtime(ctx.root, env)

      assert runtime[:arbor_scheduler][:morning_digest_pipeline] ==
               Path.join(ctx.deployment, "pipelines/morning_digest.dot")
    end
  end

  test "test environment ignores dotenv and malformed inherited scheduler values", ctx do
    File.write!(Path.join(ctx.root, ".env"), """
    ARBOR_OWNED_DIGEST_ENABLED=malformed-secret-value
    ARBOR_OWNED_DIGEST_ROOT=/missing/secret-root
    """)

    runtime = read_runtime(ctx.root, :test)
    assert System.get_env("ARBOR_OWNED_DIGEST_ENABLED") == "malformed-secret-value"
    assert runtime[:arbor_scheduler] == nil
    assert runtime[:arbor_trust] == nil

    File.rm!(Path.join(ctx.root, ".env"))
    enable(ctx.deployment)
    runtime = read_runtime(ctx.root, :test)
    assert runtime[:arbor_scheduler] == nil
    assert runtime[:arbor_trust] == nil
  end

  test "malformed flags fail closed without disclosing their values", ctx do
    for flag <- ["", "TRUE", "1", " true", "secret-do-not-log"] do
      System.put_env("ARBOR_OWNED_DIGEST_ENABLED", flag)

      assert_raise RuntimeError, "ARBOR_OWNED_DIGEST_ENABLED must be true or false", fn ->
        read_runtime(ctx.root)
      end
    end
  end

  test "enabled roots must be explicit bounded canonical ASCII paths", ctx do
    for root <- [
          nil,
          "",
          "/",
          "relative",
          ctx.deployment <> "/",
          ctx.deployment <> "/../deployment",
          ctx.deployment <> "//pipelines",
          "/secret with spaces",
          "/secret?query",
          "/sëcret",
          "/" <> String.duplicate("s", 2_048)
        ] do
      System.put_env("ARBOR_OWNED_DIGEST_ENABLED", "true")
      put_or_delete("ARBOR_OWNED_DIGEST_ROOT", root)
      assert_raise RuntimeError, @root_error, fn -> read_runtime(ctx.root) end
    end
  end

  test "missing roots and every missing derived directory fail without creating them", ctx do
    missing = Path.join(ctx.root, "never-created")
    enable(missing)
    assert_raise RuntimeError, @directory_error, fn -> read_runtime(ctx.root) end
    refute File.exists?(missing)

    for directory <- @directories do
      original = Path.join(ctx.deployment, directory)
      moved = original <> "-retained"
      File.rename!(original, moved)
      enable(ctx.deployment)
      assert_raise RuntimeError, @directory_error, fn -> read_runtime(ctx.root) end
      refute File.exists?(original)
      File.rename!(moved, original)
    end
  end

  test "symlink root ancestors and derived directories are refused", ctx do
    link = Path.join(ctx.root, "deployment-link")
    File.ln_s!(ctx.deployment, link)
    enable(link)
    assert_raise RuntimeError, @directory_error, fn -> read_runtime(ctx.root) end

    ancestor = Path.join(ctx.root, "ancestor-link")
    File.ln_s!(ctx.root, ancestor)
    enable(Path.join(ancestor, "deployment"))
    assert_raise RuntimeError, @directory_error, fn -> read_runtime(ctx.root) end

    for directory <- ["reports" | @directories] do
      original = Path.join(ctx.deployment, directory)
      moved = original <> "-retained"
      File.rename!(original, moved)
      File.ln_s!(moved, original)
      enable(ctx.deployment)
      assert_raise RuntimeError, @directory_error, fn -> read_runtime(ctx.root) end
      File.rm!(original)
      File.rename!(moved, original)
    end
  end

  test "graph and manifest must each exist as regular nonsymlink files", ctx do
    enable(ctx.deployment)

    for name <- ["morning_digest.dot", "morning_digest.caps.json"] do
      original = Path.join(ctx.deployment, "pipelines/" <> name)
      moved = original <> "-retained"
      File.rename!(original, moved)
      assert_raise RuntimeError, @file_error, fn -> read_runtime(ctx.root) end
      File.mkdir!(original)
      assert_raise RuntimeError, @file_error, fn -> read_runtime(ctx.root) end
      File.rmdir!(original)
      File.ln_s!(moved, original)
      assert_raise RuntimeError, @file_error, fn -> read_runtime(ctx.root) end
      File.rm!(original)
      File.rename!(moved, original)
    end
  end

  test "conflicting or malformed existing maps fail without exposing their values", ctx do
    enable(ctx.deployment)

    for {app, key, values} <- [
          {:arbor_scheduler, :pipeline_roots,
           [nil, [], %{"laptop_digest_verification" => "/secret-other-root"}]},
          {:arbor_trust, :security_ceilings,
           [
             nil,
             [],
             %{write_scope(ctx.deployment) => :ask},
             %{write_scope(ctx.deployment) => :block}
           ]}
        ],
        value <- values do
      Application.put_env(app, key, value)
      assert_raise RuntimeError, @conflict_error, fn -> read_runtime(ctx.root) end
      Application.delete_env(app, key)
    end
  end

  test "identical reserved settings are idempotent", ctx do
    enable(ctx.deployment)
    first = read_runtime(ctx.root)

    Application.put_env(
      :arbor_scheduler,
      :pipeline_roots,
      first[:arbor_scheduler][:pipeline_roots]
    )

    Application.put_env(:arbor_trust, :security_ceilings, first[:arbor_trust][:security_ceilings])
    second = read_runtime(ctx.root)
    assert first[:arbor_scheduler] == second[:arbor_scheduler]
    assert first[:arbor_trust] == second[:arbor_trust]
  end

  defp enable(root) do
    System.put_env("ARBOR_OWNED_DIGEST_ENABLED", "true")
    System.put_env("ARBOR_OWNED_DIGEST_ROOT", root)
  end

  defp write_scope(root), do: "arbor://fs/write" <> Path.join(root, "reports/morning-digest")
  defp put_or_delete(key, nil), do: System.delete_env(key)
  defp put_or_delete(key, value), do: System.put_env(key, value)

  defp read_runtime(root, env \\ :dev) do
    File.cd!(root, fn -> Reader.read!(@runtime_path, env: env, target: :host) end)
  end
end
