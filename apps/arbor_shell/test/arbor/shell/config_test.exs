defmodule Arbor.Shell.ConfigTest do
  use ExUnit.Case, async: false

  alias Arbor.Shell.Config

  @app :arbor_shell
  @key :apple_container
  @linux_key :linux_dependency_baseline
  @image_key :apple_container_image_policy

  @index_hex String.duplicate("a", 64)
  @manifest_hex String.duplicate("b", 64)
  @mix_lock_hex String.duplicate("c", 64)
  @tree_hex String.duplicate("d", 64)
  @vminit_index_hex String.duplicate("f0", 32)
  @vminit_manifest_hex String.duplicate("f1", 32)

  @valid_image_policy [
    image: "docker.io/arbor/validation@sha256:#{@index_hex}",
    manifest_digest: "sha256:#{@manifest_hex}",
    vminit_image: "docker.io/arbor/vminit@sha256:#{@vminit_index_hex}",
    vminit_manifest_digest: "sha256:#{@vminit_manifest_hex}",
    env: ["PATH=/usr/bin", "ARBOR_VALIDATION=1"],
    labels: %{
      "org.arbor.validation.schema" => "1",
      "org.arbor.validation.role" => "spawn-containment"
    },
    mix_lock_digest: @mix_lock_hex,
    baseline_tree_digest: @tree_hex,
    toolchain: [erlang: "28.4.1", elixir: "1.19.5-otp-28"]
  ]

  setup do
    previous = Application.get_env(@app, @key)
    previous_linux = Application.get_env(@app, @linux_key)
    previous_image = Application.get_env(@app, @image_key)
    previous_home = System.get_env("HOME")

    on_exit(fn ->
      restore_env(@key, previous)
      restore_env(@linux_key, previous_linux)
      restore_env(@image_key, previous_image)
      restore_system_env("HOME", previous_home)
    end)

    :ok
  end

  describe "apple_container/0" do
    test "absent config is a stable error" do
      Application.delete_env(@app, @key)
      assert {:error, :apple_container_config_absent} = Config.apple_container()
    end

    test "valid strict atom-keyed keyword locators" do
      Application.put_env(@app, @key,
        kernel_path: "/usr/local/share/container/kernels/default.img",
        app_root: "/Users/operator/Library/Application Support/com.apple.container"
      )

      assert {:ok,
              %{
                kernel_path: "/usr/local/share/container/kernels/default.img",
                app_root: "/Users/operator/Library/Application Support/com.apple.container"
              }} = Config.apple_container()
    end

    test "valid strict atom-keyed map locators" do
      Application.put_env(@app, @key, %{
        kernel_path: "/var/db/container/kernel",
        app_root: "/opt/container-app"
      })

      assert {:ok,
              %{
                kernel_path: "/var/db/container/kernel",
                app_root: "/opt/container-app"
              }} = Config.apple_container()
    end

    test "valid closed string keys are accepted when not duplicated" do
      Application.put_env(@app, @key, %{
        "kernel_path" => "/var/db/container/kernel",
        "app_root" => "/opt/container-app"
      })

      assert {:ok,
              %{
                kernel_path: "/var/db/container/kernel",
                app_root: "/opt/container-app"
              }} = Config.apple_container()
    end

    test "rejects unknown keys" do
      Application.put_env(@app, @key,
        kernel_path: "/var/db/container/kernel",
        app_root: "/opt/container-app",
        cli_path: "/evil/container"
      )

      assert {:error, :unknown_apple_container_config_key} = Config.apple_container()
    end

    test "rejects authority-bearing keys" do
      for key <- [
            :bindings,
            :identities,
            :evidence,
            :trusted_path,
            :host_platform,
            :cli_identity,
            :apiserver_path,
            :plugin_path
          ] do
        Application.put_env(
          @app,
          @key,
          Keyword.put(
            [
              kernel_path: "/var/db/container/kernel",
              app_root: "/opt/container-app"
            ],
            key,
            "attacker"
          )
        )

        assert {:error, :unknown_apple_container_config_key} = Config.apple_container()
      end
    end

    test "rejects duplicate logical keys across atom and string forms" do
      Application.put_env(@app, @key, %{
        :kernel_path => "/var/db/container/kernel",
        "kernel_path" => "/var/db/container/other",
        :app_root => "/opt/container-app"
      })

      assert {:error, :duplicate_apple_container_config_key} = Config.apple_container()
    end

    test "rejects missing required keys" do
      Application.put_env(@app, @key, kernel_path: "/var/db/container/kernel")
      assert {:error, :missing_app_root} = Config.apple_container()

      Application.put_env(@app, @key, app_root: "/opt/container-app")
      assert {:error, :missing_kernel_path} = Config.apple_container()
    end

    test "rejects relative paths" do
      Application.put_env(@app, @key,
        kernel_path: "kernels/default.img",
        app_root: "/opt/container-app"
      )

      assert {:error, {:invalid_kernel_path, :relative_path}} = Config.apple_container()
    end

    test "rejects noncanonical paths" do
      Application.put_env(@app, @key,
        kernel_path: "/var/db/../db/container/kernel",
        app_root: "/opt/container-app"
      )

      assert {:error, {:invalid_kernel_path, :dot_segment}} = Config.apple_container()

      Application.put_env(@app, @key,
        kernel_path: "/var//db/container/kernel",
        app_root: "/opt/container-app"
      )

      assert {:error, {:invalid_kernel_path, :non_canonical_path}} = Config.apple_container()

      Application.put_env(@app, @key,
        kernel_path: "/var/db/container/kernel/",
        app_root: "/opt/container-app"
      )

      assert {:error, {:invalid_kernel_path, :trailing_slash}} = Config.apple_container()
    end

    test "rejects oversized, NUL, and invalid UTF-8 paths" do
      oversized = "/" <> String.duplicate("a", 4_096)

      Application.put_env(@app, @key,
        kernel_path: oversized,
        app_root: "/opt/container-app"
      )

      assert {:error, {:invalid_kernel_path, :path_too_long}} = Config.apple_container()

      Application.put_env(@app, @key,
        kernel_path: "/var/db/container/\0kernel",
        app_root: "/opt/container-app"
      )

      assert {:error, {:invalid_kernel_path, :nul_byte}} = Config.apple_container()

      Application.put_env(@app, @key,
        kernel_path: <<"/var/db/container/", 0xFF>>,
        app_root: "/opt/container-app"
      )

      assert {:error, {:invalid_kernel_path, :invalid_utf8}} = Config.apple_container()
    end

    test "rejects malformed config containers" do
      Application.put_env(@app, @key, "not-a-map")
      assert {:error, :apple_container_config_malformed} = Config.apple_container()

      Application.put_env(@app, @key, [{:kernel_path, "/k"}, "not-a-pair"])
      assert {:error, :apple_container_config_malformed} = Config.apple_container()
    end

    test "does not perform filesystem or HOME fallback" do
      Application.delete_env(@app, @key)
      assert {:error, :apple_container_config_absent} = Config.apple_container()

      # Even with HOME set, missing Application env stays absent.
      System.put_env("HOME", "/tmp/should-not-matter")
      assert {:error, :apple_container_config_absent} = Config.apple_container()
    end
  end

  describe "linux_dependency_baseline/0" do
    test "absent config is a stable error" do
      Application.delete_env(@app, @linux_key)

      assert {:error, :linux_dependency_baseline_config_absent} =
               Config.linux_dependency_baseline()
    end

    test "valid strict atom-keyed keyword locators" do
      Application.put_env(@app, @linux_key,
        source_root: "/var/lib/arbor/linux-deps",
        manifest_path: "/var/lib/arbor/linux-deps-manifest.json"
      )

      assert {:ok,
              %{
                source_root: "/var/lib/arbor/linux-deps",
                manifest_path: "/var/lib/arbor/linux-deps-manifest.json"
              }} = Config.linux_dependency_baseline()
    end

    test "valid strict atom-keyed map locators" do
      Application.put_env(@app, @linux_key, %{
        source_root: "/opt/arbor/baseline/source",
        manifest_path: "/opt/arbor/baseline/manifest.json"
      })

      assert {:ok,
              %{
                source_root: "/opt/arbor/baseline/source",
                manifest_path: "/opt/arbor/baseline/manifest.json"
              }} = Config.linux_dependency_baseline()
    end

    test "valid closed string keys are accepted when not duplicated" do
      Application.put_env(@app, @linux_key, %{
        "source_root" => "/opt/arbor/baseline/source",
        "manifest_path" => "/opt/arbor/baseline/manifest.json"
      })

      assert {:ok,
              %{
                source_root: "/opt/arbor/baseline/source",
                manifest_path: "/opt/arbor/baseline/manifest.json"
              }} = Config.linux_dependency_baseline()
    end

    test "rejects unknown keys" do
      Application.put_env(@app, @linux_key,
        source_root: "/opt/arbor/baseline/source",
        manifest_path: "/opt/arbor/baseline/manifest.json",
        destination: "/evil/copy"
      )

      assert {:error, :unknown_linux_dependency_baseline_config_key} =
               Config.linux_dependency_baseline()
    end

    test "rejects authority-bearing fields" do
      for key <- [
            :bindings,
            :binding,
            :identities,
            :evidence,
            :trusted_path,
            :source,
            :ready,
            :destination,
            :inventory,
            :digest,
            :sha256,
            :boot_epoch
          ] do
        Application.put_env(
          @app,
          @linux_key,
          Keyword.put(
            [
              source_root: "/opt/arbor/baseline/source",
              manifest_path: "/opt/arbor/baseline/manifest.json"
            ],
            key,
            "attacker"
          )
        )

        assert {:error, :unknown_linux_dependency_baseline_config_key} =
                 Config.linux_dependency_baseline()
      end
    end

    test "rejects duplicate logical keys across atom and string forms" do
      Application.put_env(@app, @linux_key, %{
        :source_root => "/opt/arbor/baseline/source",
        "source_root" => "/opt/arbor/baseline/other",
        :manifest_path => "/opt/arbor/baseline/manifest.json"
      })

      assert {:error, :duplicate_linux_dependency_baseline_config_key} =
               Config.linux_dependency_baseline()
    end

    test "rejects missing required keys" do
      Application.put_env(@app, @linux_key, source_root: "/opt/arbor/baseline/source")
      assert {:error, :missing_manifest_path} = Config.linux_dependency_baseline()

      Application.put_env(@app, @linux_key, manifest_path: "/opt/arbor/baseline/manifest.json")
      assert {:error, :missing_source_root} = Config.linux_dependency_baseline()
    end

    test "rejects relative paths" do
      Application.put_env(@app, @linux_key,
        source_root: "baseline/source",
        manifest_path: "/opt/arbor/baseline/manifest.json"
      )

      assert {:error, {:invalid_source_root, :relative_path}} = Config.linux_dependency_baseline()
    end

    test "rejects noncanonical paths" do
      Application.put_env(@app, @linux_key,
        source_root: "/opt/arbor/../arbor/baseline/source",
        manifest_path: "/opt/arbor/baseline/manifest.json"
      )

      assert {:error, {:invalid_source_root, :dot_segment}} = Config.linux_dependency_baseline()

      Application.put_env(@app, @linux_key,
        source_root: "/opt//arbor/baseline/source",
        manifest_path: "/opt/arbor/baseline/manifest.json"
      )

      assert {:error, {:invalid_source_root, :non_canonical_path}} =
               Config.linux_dependency_baseline()

      Application.put_env(@app, @linux_key,
        source_root: "/opt/arbor/baseline/source/",
        manifest_path: "/opt/arbor/baseline/manifest.json"
      )

      assert {:error, {:invalid_source_root, :trailing_slash}} =
               Config.linux_dependency_baseline()
    end

    test "rejects oversized, NUL, and invalid UTF-8 paths" do
      oversized = "/" <> String.duplicate("a", 4_096)

      Application.put_env(@app, @linux_key,
        source_root: oversized,
        manifest_path: "/opt/arbor/baseline/manifest.json"
      )

      assert {:error, {:invalid_source_root, :path_too_long}} = Config.linux_dependency_baseline()

      Application.put_env(@app, @linux_key,
        source_root: "/opt/arbor/baseline/\0source",
        manifest_path: "/opt/arbor/baseline/manifest.json"
      )

      assert {:error, {:invalid_source_root, :nul_byte}} = Config.linux_dependency_baseline()

      Application.put_env(@app, @linux_key,
        source_root: <<"/opt/arbor/baseline/", 0xFF>>,
        manifest_path: "/opt/arbor/baseline/manifest.json"
      )

      assert {:error, {:invalid_source_root, :invalid_utf8}} = Config.linux_dependency_baseline()
    end

    test "rejects malformed config containers" do
      Application.put_env(@app, @linux_key, "not-a-map")

      assert {:error, :linux_dependency_baseline_config_malformed} =
               Config.linux_dependency_baseline()

      Application.put_env(@app, @linux_key, [{:source_root, "/s"}, "not-a-pair"])

      assert {:error, :linux_dependency_baseline_config_malformed} =
               Config.linux_dependency_baseline()
    end

    test "does not perform filesystem or HOME fallback" do
      Application.delete_env(@app, @linux_key)

      assert {:error, :linux_dependency_baseline_config_absent} =
               Config.linux_dependency_baseline()

      System.put_env("HOME", "/tmp/should-not-matter")

      assert {:error, :linux_dependency_baseline_config_absent} =
               Config.linux_dependency_baseline()
    end
  end

  describe "apple_container_image_policy/0" do
    test "absent config is a stable error" do
      Application.delete_env(@app, @image_key)

      assert {:error, :apple_container_image_policy_config_absent} =
               Config.apple_container_image_policy()
    end

    test "valid strict atom-keyed keyword policy" do
      Application.put_env(@app, @image_key, @valid_image_policy)

      assert {:ok, policy} = Config.apple_container_image_policy()
      assert policy.image == "docker.io/arbor/validation@sha256:#{@index_hex}"
      assert policy.manifest_digest == "sha256:#{@manifest_hex}"
      assert policy.vminit_image == "docker.io/arbor/vminit@sha256:#{@vminit_index_hex}"
      assert policy.vminit_manifest_digest == "sha256:#{@vminit_manifest_hex}"
      assert policy.env == ["PATH=/usr/bin", "ARBOR_VALIDATION=1"]
      assert policy.labels["org.arbor.validation.schema"] == "1"
      assert policy.mix_lock_digest == @mix_lock_hex
      assert policy.baseline_tree_digest == @tree_hex
      assert policy.toolchain == %{erlang: "28.4.1", elixir: "1.19.5-otp-28"}
    end

    test "valid string-keyed map policy including string toolchain keys" do
      Application.put_env(@app, @image_key, %{
        "image" => "docker.io/arbor/validation@sha256:#{@index_hex}",
        "manifest_digest" => "sha256:#{@manifest_hex}",
        "vminit_image" => "docker.io/arbor/vminit@sha256:#{@vminit_index_hex}",
        "vminit_manifest_digest" => "sha256:#{@vminit_manifest_hex}",
        "env" => ["PATH=/usr/bin"],
        "labels" => %{"org.arbor.validation.schema" => "1"},
        "mix_lock_digest" => @mix_lock_hex,
        "baseline_tree_digest" => @tree_hex,
        "toolchain" => %{"erlang" => "28.4.1", "elixir" => "1.19.5-otp-28"}
      })

      assert {:ok, policy} = Config.apple_container_image_policy()
      assert policy.toolchain.erlang == "28.4.1"
      assert policy.toolchain.elixir == "1.19.5-otp-28"
      assert policy.labels == %{"org.arbor.validation.schema" => "1"}
    end

    test "rejects unknown and authority-bearing keys" do
      Application.put_env(
        @app,
        @image_key,
        Keyword.put(@valid_image_policy, :execution_reference, "evil")
      )

      assert {:error, :unknown_apple_container_image_policy_config_key} =
               Config.apple_container_image_policy()

      for key <- [
            :receipt,
            :baseline_receipt,
            :readiness,
            :ready,
            :module,
            :config_callback,
            :path,
            :source_root
          ] do
        Application.put_env(
          @app,
          @image_key,
          Keyword.put(@valid_image_policy, key, "attacker")
        )

        assert {:error, :unknown_apple_container_image_policy_config_key} =
                 Config.apple_container_image_policy()
      end
    end

    test "rejects duplicate logical keys across atom and string forms" do
      Application.put_env(@app, @image_key, %{
        :image => "docker.io/arbor/validation@sha256:#{@index_hex}",
        "image" => "docker.io/arbor/other@sha256:#{@index_hex}",
        :manifest_digest => "sha256:#{@manifest_hex}",
        :vminit_image => "docker.io/arbor/vminit@sha256:#{@vminit_index_hex}",
        :vminit_manifest_digest => "sha256:#{@vminit_manifest_hex}",
        :env => ["PATH=/usr/bin"],
        :labels => %{"k" => "v"},
        :mix_lock_digest => @mix_lock_hex,
        :baseline_tree_digest => @tree_hex,
        :toolchain => %{erlang: "28.4.1", elixir: "1.19.5-otp-28"}
      })

      assert {:error, :duplicate_apple_container_image_policy_config_key} =
               Config.apple_container_image_policy()
    end

    test "rejects missing required keys" do
      Application.put_env(@app, @image_key, Keyword.delete(@valid_image_policy, :image))
      assert {:error, :missing_image} = Config.apple_container_image_policy()

      Application.put_env(@app, @image_key, Keyword.delete(@valid_image_policy, :toolchain))
      assert {:error, :missing_toolchain} = Config.apple_container_image_policy()
    end

    test "rejects malformed containers, atom label keys, and oversized fields" do
      Application.put_env(@app, @image_key, "not-a-map")

      assert {:error, :apple_container_image_policy_config_malformed} =
               Config.apple_container_image_policy()

      Application.put_env(
        @app,
        @image_key,
        Keyword.put(@valid_image_policy, :labels, %{atom_key: "v"})
      )

      assert {:error, :invalid_labels} = Config.apple_container_image_policy()

      oversized = String.duplicate("a", 5_000)

      Application.put_env(
        @app,
        @image_key,
        Keyword.put(@valid_image_policy, :image, oversized)
      )

      assert {:error, :image_policy_string_too_long} = Config.apple_container_image_policy()

      huge_env = Enum.map(1..100, fn i -> "K#{i}=v" end)

      Application.put_env(
        @app,
        @image_key,
        Keyword.put(@valid_image_policy, :env, huge_env)
      )

      assert {:error, :image_policy_env_too_large} = Config.apple_container_image_policy()
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(@app, key)
  defp restore_env(key, value), do: Application.put_env(@app, key, value)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
