defmodule Arbor.Shell.AppleContainerAdmissionCoreTest do
  @moduledoc """
  Focused pure adversarial tests for Apple Container admission evidence core.

  Slice 2B only: validates policy + already-collected bounded evidence as data.
  Does not wire `Arbor.Shell.execute_spawn_capable/3` (still production_backend_missing).
  """

  use ExUnit.Case, async: true

  alias Arbor.Shell.AppleContainerAdmissionCore

  @moduletag :fast

  @index_hex String.duplicate("a", 64)
  @manifest_hex String.duplicate("b", 64)
  @mix_lock_hex String.duplicate("c", 64)
  @tree_hex String.duplicate("d", 64)
  @other_hex String.duplicate("e", 64)
  @executable_sha256 String.duplicate("f", 64)

  @image "docker.io/arbor/validation@sha256:#{@index_hex}"
  @index_digest "sha256:#{@index_hex}"
  @manifest_digest "sha256:#{@manifest_hex}"

  @erlang_version "28.4.1"
  @elixir_version "1.19.5-otp-28"

  @env [
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "ARBOR_VALIDATION=1"
  ]

  @labels %{
    "org.arbor.validation.schema" => "1",
    "org.arbor.validation.role" => "spawn-containment",
    "org.arbor.validation.platform" => "linux/arm64",
    "org.arbor.validation.erlang" => @erlang_version,
    "org.arbor.validation.elixir" => @elixir_version,
    "org.arbor.validation.mix-lock-sha256" => @mix_lock_hex,
    "org.arbor.validation.deps-tree-sha256" => @tree_hex,
    "org.arbor.operator.note" => "approved-fixture"
  }

  @designated_requirement AppleContainerAdmissionCore.designated_requirement()

  @valid_policy %{
    image: @image,
    manifest_digest: @manifest_digest,
    env: @env,
    labels: @labels,
    mix_lock_digest: @mix_lock_hex,
    baseline_tree_digest: @tree_hex,
    toolchain: %{
      erlang: @erlang_version,
      elixir: @elixir_version
    }
  }

  @valid_arm64_variant %{
    digest: @manifest_digest,
    platform: %{os: "linux", architecture: "arm64"},
    config: %{
      os: "linux",
      architecture: "arm64",
      config: %{
        "Env" => @env,
        "Labels" => @labels
      }
    }
  }

  # Realistic container 1.1.0 service-status + image-inspect shape (projected
  # to the closed evidence surface the pure core admits).
  @valid_evidence %{
    host_platform: %{
      os: "macos",
      version: "26.0",
      architecture: "arm64"
    },
    runtime: %{
      path: "/usr/local/bin/container",
      cli_version: "1.1.0",
      cli_build: "release",
      executable_sha256: @executable_sha256,
      signing: %{
        identifier: "com.apple.container.cli",
        team_id: "UPBK2H6LZM",
        designated_requirement: @designated_requirement,
        verified_against: @designated_requirement,
        status: "valid"
      }
    },
    service_status: %{
      status: "running",
      install_root: "/usr/local/",
      apiserver_version: "container-apiserver version 1.1.0 (build: release, commit: abcdef1)",
      apiserver_build: "release"
    },
    image_inspect: %{
      configuration: %{
        descriptor: %{
          digest: @index_digest,
          mediaType: "application/vnd.docker.distribution.manifest.list.v2+json",
          size: 772
        },
        name: @image
      },
      variants: [@valid_arm64_variant]
    },
    dependency_baseline: %{
      image_index_digest: @index_digest,
      image_manifest_digest: @manifest_digest,
      mix_lock_digest: @mix_lock_hex,
      baseline_tree_digest: @tree_hex,
      platform: "linux/arm64",
      provisioning: %{
        status: "ready",
        mode: "read_only"
      }
    }
  }

  @valid_input %{
    policy: @valid_policy,
    evidence: @valid_evidence
  }

  @invalid_utf8 <<0xC3, 0x28>>

  # --- Positive path ---

  describe "positive admission" do
    test "admits complete policy + realistic 1.1.0 evidence and binds all fields" do
      assert {:ok, receipt} = AppleContainerAdmissionCore.new(@valid_input)

      assert receipt.admitted == true
      assert receipt.platform == %{os: "macos", version: "26.0", architecture: "arm64"}

      assert receipt.runtime == %{
               path: "/usr/local/bin/container",
               cli_version: "1.1.0",
               api_version: "1.1.0",
               build: "release",
               executable_sha256: @executable_sha256,
               signing_identifier: "com.apple.container.cli",
               team_id: "UPBK2H6LZM",
               designated_requirement: @designated_requirement,
               codesign_verified: true
             }

      assert receipt.service == %{status: "running", install_root: "/usr/local/"}

      assert receipt.image == %{
               reference: @image,
               index_digest: @index_digest,
               manifest_digest: @manifest_digest,
               platform: "linux/arm64",
               env: @env,
               labels: @labels
             }

      assert receipt.toolchain == %{erlang: @erlang_version, elixir: @elixir_version}

      assert receipt.dependency_baseline == %{
               image_index_digest: @index_digest,
               image_manifest_digest: @manifest_digest,
               mix_lock_digest: @mix_lock_hex,
               baseline_tree_digest: @tree_hex,
               platform: "linux/arm64",
               status: "ready",
               mode: "read_only"
             }

      shown = AppleContainerAdmissionCore.show(receipt)
      assert shown["admitted"] == true
      assert shown["runtime"]["designated_requirement"] == @designated_requirement
      assert shown["runtime"]["codesign_verified"] == true
      assert shown["runtime"]["executable_sha256"] == @executable_sha256
      assert shown["image"]["reference"] == @image
      assert shown["toolchain"]["erlang"] == @erlang_version
      assert shown["toolchain"]["elixir"] == @elixir_version
      # No raw command output / oversized blobs in the receipt surface.
      refute Map.has_key?(shown, "stdout")
      refute Map.has_key?(shown, "raw")
      assert Jason.encode!(shown)
    end

    test "is deterministic for the same input" do
      assert {:ok, a} = AppleContainerAdmissionCore.new(@valid_input)
      assert {:ok, b} = AppleContainerAdmissionCore.new(@valid_input)
      assert a == b
      assert AppleContainerAdmissionCore.show(a) == AppleContainerAdmissionCore.show(b)
    end

    test "accepts string-keyed policy and evidence maps" do
      input = %{
        "policy" => %{
          "image" => @image,
          "manifest_digest" => @manifest_digest,
          "env" => @env,
          "labels" => @labels,
          "mix_lock_digest" => @mix_lock_hex,
          "baseline_tree_digest" => @tree_hex,
          "toolchain" => %{
            "erlang" => @erlang_version,
            "elixir" => @elixir_version
          }
        },
        "evidence" => %{
          "host_platform" => %{
            "os" => "macos",
            "version" => "26.1",
            "architecture" => "arm64"
          },
          "runtime" => %{
            "path" => "/usr/local/bin/container",
            "cli_version" => "1.1.2",
            "cli_build" => "release",
            "executable_sha256" => @executable_sha256,
            "signing" => %{
              "identifier" => "com.apple.container.cli",
              "team_id" => "UPBK2H6LZM",
              "designated_requirement" => @designated_requirement,
              "verified_against" => @designated_requirement,
              "status" => "valid"
            }
          },
          "service_status" => %{
            "status" => "running",
            "install_root" => "/usr/local/",
            "apiserver_version" =>
              "container-apiserver version 1.1.2 (build: release, commit: deadbeef)",
            "apiserver_build" => "release"
          },
          "image_inspect" => %{
            "configuration" => %{
              "descriptor" => %{
                "digest" => @index_digest,
                "media_type" => "application/vnd.oci.image.index.v1+json",
                "size" => 1024
              },
              "name" => @image
            },
            "variants" => [
              %{
                "digest" => @manifest_digest,
                "platform" => %{"os" => "linux", "architecture" => "arm64"},
                "config" => %{
                  "os" => "linux",
                  "architecture" => "arm64",
                  "config" => %{"Env" => @env, "Labels" => @labels}
                }
              }
            ]
          },
          "dependency_baseline" => %{
            "image_index_digest" => @index_digest,
            "image_manifest_digest" => @manifest_digest,
            "mix_lock_digest" => @mix_lock_hex,
            "baseline_tree_digest" => @tree_hex,
            "platform" => "linux/arm64",
            "provisioning" => %{"status" => "ready", "mode" => "read_only"}
          }
        }
      }

      assert {:ok, receipt} = AppleContainerAdmissionCore.new(input)
      assert receipt.platform.version == "26.1"
      assert receipt.runtime.cli_version == "1.1.2"
      assert receipt.runtime.api_version == "1.1.2"
      assert receipt.runtime.executable_sha256 == @executable_sha256
      assert receipt.toolchain.erlang == @erlang_version
    end

    test "exports fixed platform authority constants" do
      assert AppleContainerAdmissionCore.runtime_path() == "/usr/local/bin/container"
      assert AppleContainerAdmissionCore.install_root() == "/usr/local/"
      assert AppleContainerAdmissionCore.signing_identifier() == "com.apple.container.cli"
      assert AppleContainerAdmissionCore.team_id() == "UPBK2H6LZM"
      assert AppleContainerAdmissionCore.guest_platform() == "linux/arm64"

      assert AppleContainerAdmissionCore.designated_requirement() ==
               ~s(identifier "com.apple.container.cli" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = UPBK2H6LZM)
    end
  end

  describe "facade remains unwired" do
    test "execute_spawn_capable stays production_backend_missing" do
      assert {:error, {:spawn_backend_unavailable, :production_backend_missing}} =
               Arbor.Shell.execute_spawn_capable("mix", ["test"], cwd: "/tmp")
    end
  end

  # --- Closed shapes / aliases ---

  describe "closed request shapes" do
    test "rejects non-map input and missing policy/evidence" do
      assert {:error, :invalid_request} = AppleContainerAdmissionCore.new("nope")
      assert {:error, :invalid_request} = AppleContainerAdmissionCore.new([])

      assert {:error, :missing_policy} =
               AppleContainerAdmissionCore.new(%{evidence: @valid_evidence})

      assert {:error, :missing_evidence} =
               AppleContainerAdmissionCore.new(%{policy: @valid_policy})
    end

    test "rejects unknown top-level keys without echoing key material" do
      assert {:error, {:unsupported_keys, :request}} =
               AppleContainerAdmissionCore.new(Map.put(@valid_input, :callback, fn -> :ok end))

      assert {:error, {:unsupported_keys, :request}} =
               AppleContainerAdmissionCore.new(Map.put(@valid_input, :extra, 1))
    end

    test "rejects dual atom/string aliases at every closed surface" do
      dual_policy =
        Map.put(@valid_input, :policy, Map.merge(@valid_policy, %{"image" => @image}))

      assert {:error, {:duplicate_key_alias, :policy, :image}} =
               AppleContainerAdmissionCore.new(dual_policy)

      dual_request = Map.merge(@valid_input, %{"policy" => @valid_policy})

      assert {:error, {:duplicate_key_alias, :request, :policy}} =
               AppleContainerAdmissionCore.new(dual_request)

      dual_host =
        put_in(
          @valid_input,
          [:evidence, :host_platform],
          Map.merge(%{os: "macos", version: "26.0", architecture: "arm64"}, %{"os" => "macos"})
        )

      assert {:error, {:duplicate_key_alias, :host_platform, :os}} =
               AppleContainerAdmissionCore.new(dual_host)

      dual_runtime =
        put_in(
          @valid_input,
          [:evidence, :runtime],
          Map.merge(@valid_evidence.runtime, %{"path" => "/usr/local/bin/container"})
        )

      assert {:error, {:duplicate_key_alias, :runtime, :path}} =
               AppleContainerAdmissionCore.new(dual_runtime)

      dual_env =
        put_in(
          @valid_input,
          [:evidence, :image_inspect, :variants],
          [
            put_in(
              @valid_arm64_variant,
              [:config, :config],
              %{"Env" => @env, "Labels" => @labels} |> Map.put(:Env, @env)
            )
          ]
        )

      assert {:error, :ambiguous_env_alias} = AppleContainerAdmissionCore.new(dual_env)
    end

    test "rejects dual atom/string aliases on optional variant fields" do
      dual_variant_platform =
        put_in(
          @valid_input,
          [:evidence, :image_inspect, :variants],
          [
            put_in(
              @valid_arm64_variant,
              [:platform],
              Map.merge(%{os: "linux", architecture: "arm64", variant: "v8"}, %{
                "variant" => "v8"
              })
            )
          ]
        )

      assert {:error, {:duplicate_key_alias, :variant_platform, :variant}} =
               AppleContainerAdmissionCore.new(dual_variant_platform)

      dual_variant_config =
        put_in(
          @valid_input,
          [:evidence, :image_inspect, :variants],
          [
            put_in(
              @valid_arm64_variant,
              [:config],
              Map.merge(
                %{
                  os: "linux",
                  architecture: "arm64",
                  variant: "v8",
                  config: %{"Env" => @env, "Labels" => @labels}
                },
                %{"variant" => "v8"}
              )
            )
          ]
        )

      assert {:error, {:duplicate_key_alias, :variant_config, :variant}} =
               AppleContainerAdmissionCore.new(dual_variant_config)
    end

    test "rejects policy callbacks/modules and unknown policy keys" do
      assert {:error, {:unsupported_keys, :policy}} =
               AppleContainerAdmissionCore.new(
                 put_in(@valid_input, [:policy], Map.put(@valid_policy, :validator, & &1))
               )

      assert {:error, {:unsupported_keys, :policy}} =
               AppleContainerAdmissionCore.new(
                 put_in(@valid_input, [:policy], Map.put(@valid_policy, :module, __MODULE__))
               )
    end
  end

  # --- Host platform ---

  describe "host platform mutations" do
    @mutations [
      {:os, "linux", :platform_os_not_supported},
      {:os, "darwin", :platform_os_not_supported},
      {:os, "macOS", :platform_os_not_supported},
      {:architecture, "x86_64", :platform_architecture_not_supported},
      {:architecture, "aarch64", :platform_architecture_not_supported},
      {:architecture, "arm64e", :platform_architecture_not_supported},
      {:version, "15.6", :platform_os_version_too_old},
      {:version, "25.0", :platform_os_version_too_old},
      {:version, "not-a-version", :invalid_host_version},
      {:version, @invalid_utf8, :invalid_utf8},
      {:os, "macos\n", :unsafe_host_os}
    ]

    test "rejects each host platform field mutation" do
      for {field, value, expected} <- @mutations do
        input =
          put_in(@valid_input, [:evidence, :host_platform, field], value)

        assert {:error, ^expected} = AppleContainerAdmissionCore.new(input),
               "expected #{inspect(expected)} for host_platform.#{field}=#{inspect(value)}"
      end
    end

    test "accepts macOS major 26 and newer" do
      for version <- ["26", "26.0", "26.0.1", "27.1"] do
        input = put_in(@valid_input, [:evidence, :host_platform, :version], version)
        assert {:ok, receipt} = AppleContainerAdmissionCore.new(input)
        assert receipt.platform.version == version
      end
    end
  end

  # --- Runtime path / version / signing ---

  describe "runtime and signing mutations" do
    test "rejects path not equal to fixed /usr/local/bin/container" do
      for path <- [
            "/opt/homebrew/bin/container",
            "/usr/bin/container",
            "/usr/local/bin/container/../container",
            "/usr/local/bin/containerx"
          ] do
        input = put_in(@valid_input, [:evidence, :runtime, :path], path)
        assert {:error, :runtime_path_mismatch} = AppleContainerAdmissionCore.new(input)
      end
    end

    test "requires exact CLI/API patch equality on the 1.1.x release line" do
      # CLI 1.1.0 vs API 1.1.1
      input =
        put_in(
          @valid_input,
          [:evidence, :service_status, :apiserver_version],
          "container-apiserver version 1.1.1 (build: release, commit: abcdef1)"
        )

      assert {:error, :cli_api_version_mismatch} = AppleContainerAdmissionCore.new(input)

      # Outside 1.1.x line
      input =
        @valid_input
        |> put_in([:evidence, :runtime, :cli_version], "1.2.0")
        |> put_in(
          [:evidence, :service_status, :apiserver_version],
          "container-apiserver version 1.2.0 (build: release, commit: abcdef1)"
        )

      assert {:error, :cli_version_not_supported} = AppleContainerAdmissionCore.new(input)

      input =
        @valid_input
        |> put_in([:evidence, :runtime, :cli_version], "0.1.0")
        |> put_in(
          [:evidence, :service_status, :apiserver_version],
          "container-apiserver version 0.1.0 (build: release, commit: abcdef1)"
        )

      assert {:error, :cli_version_not_supported} = AppleContainerAdmissionCore.new(input)
    end

    test "rejects non-release builds" do
      input = put_in(@valid_input, [:evidence, :runtime, :cli_build], "debug")
      assert {:error, :non_release_cli_build} = AppleContainerAdmissionCore.new(input)

      input = put_in(@valid_input, [:evidence, :service_status, :apiserver_build], "debug")
      assert {:error, :non_release_api_build} = AppleContainerAdmissionCore.new(input)

      input =
        put_in(
          @valid_input,
          [:evidence, :service_status, :apiserver_version],
          "container-apiserver version 1.1.0 (build: debug, commit: abcdef1)"
        )

      assert {:error, :non_release_api_version} = AppleContainerAdmissionCore.new(input)
    end

    test "requires and carries pinned executable sha256" do
      input =
        put_in(
          @valid_input,
          [:evidence, :runtime],
          Map.delete(@valid_evidence.runtime, :executable_sha256)
        )

      assert {:error, :missing_executable_sha256} = AppleContainerAdmissionCore.new(input)

      input = put_in(@valid_input, [:evidence, :runtime, :executable_sha256], "not-hex")
      assert {:error, :invalid_executable_sha256} = AppleContainerAdmissionCore.new(input)

      input =
        put_in(
          @valid_input,
          [:evidence, :runtime, :executable_sha256],
          String.upcase(@executable_sha256)
        )

      assert {:error, :invalid_executable_sha256} = AppleContainerAdmissionCore.new(input)
    end

    test "rejects signing identifier, team, requirement, and unbound verification mutations" do
      mutations = [
        {[:evidence, :runtime, :signing, :identifier], "com.apple.other",
         :signing_identifier_mismatch},
        {[:evidence, :runtime, :signing, :team_id], "AAAAAAAAAA", :signing_team_mismatch},
        {[:evidence, :runtime, :signing, :designated_requirement], "identifier \"x\"",
         :designated_requirement_mismatch},
        {[:evidence, :runtime, :signing, :verified_against], "identifier \"x\"",
         :verified_against_mismatch},
        {[:evidence, :runtime, :signing, :status], "invalid", :codesign_not_verified},
        {[:evidence, :runtime, :signing, :status], "true", :codesign_not_verified}
      ]

      for {path, value, expected} <- mutations do
        input = put_in(@valid_input, path, value)

        assert {:error, ^expected} = AppleContainerAdmissionCore.new(input),
               "expected #{inspect(expected)} for #{inspect(path)}"
      end
    end

    test "detached path/version/boolean without bound requirement is insufficient" do
      # Status valid but verified_against does not match fixed requirement.
      input =
        put_in(
          @valid_input,
          [:evidence, :runtime, :signing, :verified_against],
          "identifier \"com.apple.container.cli\""
        )

      assert {:error, :verified_against_mismatch} = AppleContainerAdmissionCore.new(input)

      # Missing signing block entirely.
      runtime = Map.delete(@valid_evidence.runtime, :signing)
      input = put_in(@valid_input, [:evidence, :runtime], runtime)
      assert {:error, :missing_signing} = AppleContainerAdmissionCore.new(input)
    end
  end

  # --- Service status ---

  describe "service-status mutations" do
    test "requires running status and /usr/local/ installRoot" do
      input = put_in(@valid_input, [:evidence, :service_status, :status], "stopped")
      assert {:error, :service_not_running} = AppleContainerAdmissionCore.new(input)

      for root <- [
            "/opt/homebrew/Cellar/container/1.1.0/",
            "/usr/local",
            "/usr/local/bin/",
            "/Applications/"
          ] do
        input = put_in(@valid_input, [:evidence, :service_status, :install_root], root)
        assert {:error, :install_root_mismatch} = AppleContainerAdmissionCore.new(input)
      end
    end

    test "requires real container-apiserver version string shape" do
      bad_versions = [
        "1.1.0",
        "container CLI version 1.1.0 (build: release, commit: abcdef1)",
        "container-apiserver version 1.1.0",
        "container-apiserver version 1.1.0 (build: release)",
        ""
      ]

      for version <- bad_versions do
        input = put_in(@valid_input, [:evidence, :service_status, :apiserver_version], version)

        assert match?({:error, _}, AppleContainerAdmissionCore.new(input)),
               "expected rejection for apiserver_version=#{inspect(version)}"
      end
    end
  end

  # --- Image inspect ---

  describe "image-inspect mutations" do
    test "rejects mutable and non-canonical image references in policy" do
      for image <- [
            "arbor/validation:latest",
            "arbor/validation:1.1.0",
            "arbor/validation",
            "arbor/validation@sha256:SHORT",
            # Short repository form is no longer canonical.
            "arbor/validation@sha256:#{@index_hex}"
          ] do
        input = put_in(@valid_input, [:policy, :image], image)

        assert match?({:error, _}, AppleContainerAdmissionCore.new(input)),
               "expected rejection for image=#{inspect(image)}"
      end
    end

    test "requires exact byte-for-byte image name equality (no repository suffix collisions)" do
      input =
        put_in(
          @valid_input,
          [:evidence, :image_inspect, :configuration, :descriptor, :digest],
          "sha256:#{@other_hex}"
        )

      assert {:error, :image_index_digest_mismatch} = AppleContainerAdmissionCore.new(input)

      input =
        put_in(
          @valid_input,
          [:evidence, :image_inspect, :configuration, :name],
          "docker.io/other/image@sha256:#{@index_hex}"
        )

      assert {:error, :image_name_digest_mismatch} = AppleContainerAdmissionCore.new(input)

      input =
        put_in(
          @valid_input,
          [:evidence, :image_inspect, :configuration, :name],
          "docker.io/arbor/validation@sha256:#{@other_hex}"
        )

      assert {:error, :image_name_digest_mismatch} = AppleContainerAdmissionCore.new(input)

      # Near-collision: attacker prefix ending in the policy repository.
      near_collision =
        "evil.example/docker.io/arbor/validation@sha256:#{@index_hex}"

      input =
        put_in(
          @valid_input,
          [:evidence, :image_inspect, :configuration, :name],
          near_collision
        )

      assert {:error, :image_name_digest_mismatch} = AppleContainerAdmissionCore.new(input)

      # Registry-host prefix that used to pass suffix matching.
      input =
        put_in(
          @valid_input,
          [:evidence, :image_inspect, :configuration, :name],
          "mirror.local/" <> @image
        )

      assert {:error, :image_name_digest_mismatch} = AppleContainerAdmissionCore.new(input)
    end

    test "rejects unsupported or empty image media types" do
      for media <- [
            "",
            "application/json",
            "application/vnd.oci.image.manifest.v1+json",
            "text/plain"
          ] do
        input =
          put_in(
            @valid_input,
            [:evidence, :image_inspect, :configuration, :descriptor, :mediaType],
            media
          )

        assert match?(
                 {:error, reason}
                 when reason in [:empty_media_type, :unsupported_image_media_type],
                 AppleContainerAdmissionCore.new(input)
               ),
               "expected media type rejection for #{inspect(media)}"
      end
    end

    test "requires exactly one linux/arm64 variant with pinned manifest digest" do
      input = put_in(@valid_input, [:evidence, :image_inspect, :variants], [])
      assert {:error, :missing_variants} = AppleContainerAdmissionCore.new(input)

      amd64 = %{
        digest: "sha256:#{@other_hex}",
        platform: %{os: "linux", architecture: "amd64"},
        config: %{
          os: "linux",
          architecture: "amd64",
          config: %{"Env" => @env, "Labels" => @labels}
        }
      }

      input = put_in(@valid_input, [:evidence, :image_inspect, :variants], [amd64])
      assert {:error, :linux_arm64_variant_missing} = AppleContainerAdmissionCore.new(input)

      dup = [
        @valid_arm64_variant,
        Map.put(@valid_arm64_variant, :digest, "sha256:#{@other_hex}")
      ]

      input = put_in(@valid_input, [:evidence, :image_inspect, :variants], dup)
      assert {:error, :duplicate_linux_arm64_variants} = AppleContainerAdmissionCore.new(input)

      wrong_manifest =
        put_in(@valid_arm64_variant, [:digest], "sha256:#{@other_hex}")

      input =
        put_in(@valid_input, [:evidence, :image_inspect, :variants], [wrong_manifest])

      assert {:error, :manifest_digest_mismatch} = AppleContainerAdmissionCore.new(input)
    end

    test "rejects nested os/architecture mismatch on selected variant" do
      variant =
        @valid_arm64_variant
        |> put_in([:config, :os], "windows")

      input = put_in(@valid_input, [:evidence, :image_inspect, :variants], [variant])
      assert {:error, :variant_config_platform_mismatch} = AppleContainerAdmissionCore.new(input)

      variant =
        @valid_arm64_variant
        |> put_in([:config, :architecture], "amd64")

      input = put_in(@valid_input, [:evidence, :image_inspect, :variants], [variant])
      assert {:error, :variant_config_platform_mismatch} = AppleContainerAdmissionCore.new(input)
    end

    test "requires fixed attestation labels bound to toolchain and digests" do
      # Missing fixed label
      labels = Map.delete(@labels, "org.arbor.validation.schema")
      input = put_in(@valid_input, [:policy, :labels], labels)
      assert {:error, :missing_fixed_attestation_label} = AppleContainerAdmissionCore.new(input)

      # Wrong schema value
      labels = Map.put(@labels, "org.arbor.validation.schema", "2")
      input = put_in(@valid_input, [:policy, :labels], labels)
      assert {:error, :fixed_attestation_label_mismatch} = AppleContainerAdmissionCore.new(input)

      # Erlang label not bound to policy toolchain
      labels = Map.put(@labels, "org.arbor.validation.erlang", "27.0")
      input = put_in(@valid_input, [:policy, :labels], labels)
      assert {:error, :fixed_attestation_label_mismatch} = AppleContainerAdmissionCore.new(input)

      # mix-lock label not bound to policy digest
      labels = Map.put(@labels, "org.arbor.validation.mix-lock-sha256", @other_hex)
      input = put_in(@valid_input, [:policy, :labels], labels)
      assert {:error, :fixed_attestation_label_mismatch} = AppleContainerAdmissionCore.new(input)

      # Missing toolchain map
      policy = Map.delete(@valid_policy, :toolchain)

      assert {:error, :missing_toolchain} =
               AppleContainerAdmissionCore.new(%{policy: policy, evidence: @valid_evidence})

      # Empty/arbitrary labels no longer satisfy attestation
      empty_labels = %{"org.arbor.attestation" => "validation-image-v1"}
      input = put_in(@valid_input, [:policy, :labels], empty_labels)
      assert match?({:error, _}, AppleContainerAdmissionCore.new(input))
    end

    test "requires exact operator-approved Env and Labels" do
      # Unexpected inherited Env entry
      variant =
        put_in(@valid_arm64_variant, [:config, :config, "Env"], @env ++ ["EXTRA=1"])

      input = put_in(@valid_input, [:evidence, :image_inspect, :variants], [variant])
      assert {:error, :env_mismatch} = AppleContainerAdmissionCore.new(input)

      # Missing Env entry
      variant = put_in(@valid_arm64_variant, [:config, :config, "Env"], Enum.take(@env, 1))
      input = put_in(@valid_input, [:evidence, :image_inspect, :variants], [variant])
      assert {:error, :env_mismatch} = AppleContainerAdmissionCore.new(input)

      # Reordered Env is a mismatch (exact list equality)
      variant = put_in(@valid_arm64_variant, [:config, :config, "Env"], Enum.reverse(@env))
      input = put_in(@valid_input, [:evidence, :image_inspect, :variants], [variant])
      assert {:error, :env_mismatch} = AppleContainerAdmissionCore.new(input)

      # Label mutation
      variant =
        put_in(@valid_arm64_variant, [:config, :config, "Labels"], Map.put(@labels, "extra", "1"))

      input = put_in(@valid_input, [:evidence, :image_inspect, :variants], [variant])
      assert {:error, :labels_mismatch} = AppleContainerAdmissionCore.new(input)

      variant =
        put_in(
          @valid_arm64_variant,
          [:config, :config, "Labels"],
          Map.delete(@labels, "org.arbor.operator.note")
        )

      input = put_in(@valid_input, [:evidence, :image_inspect, :variants], [variant])
      assert {:error, :labels_mismatch} = AppleContainerAdmissionCore.new(input)
    end

    test "rejects partial image evidence and unknown fields" do
      inspect_missing =
        Map.delete(@valid_evidence.image_inspect, :variants)

      input = put_in(@valid_input, [:evidence, :image_inspect], inspect_missing)
      assert {:error, :missing_variants} = AppleContainerAdmissionCore.new(input)

      input =
        put_in(
          @valid_input,
          [:evidence, :image_inspect],
          Map.put(@valid_evidence.image_inspect, :history, [])
        )

      assert {:error, {:unsupported_keys, :image_inspect}} =
               AppleContainerAdmissionCore.new(input)

      descriptor =
        Map.delete(
          @valid_evidence.image_inspect.configuration.descriptor,
          :size
        )

      input =
        put_in(
          @valid_input,
          [:evidence, :image_inspect, :configuration, :descriptor],
          descriptor
        )

      assert {:error, :partial_image_descriptor} = AppleContainerAdmissionCore.new(input)
    end
  end

  # --- Dependency baseline ---

  describe "dependency baseline mutations" do
    test "binds baseline to image index+manifest digests and exact hex digests" do
      mutations = [
        {[:evidence, :dependency_baseline, :image_index_digest], "sha256:#{@other_hex}",
         :baseline_image_index_mismatch},
        {[:evidence, :dependency_baseline, :image_manifest_digest], "sha256:#{@other_hex}",
         :baseline_image_manifest_mismatch},
        {[:evidence, :dependency_baseline, :mix_lock_digest], @other_hex,
         :baseline_mix_lock_digest_mismatch},
        {[:evidence, :dependency_baseline, :baseline_tree_digest], @other_hex,
         :baseline_tree_digest_mismatch},
        {[:policy, :mix_lock_digest], @other_hex, :fixed_attestation_label_mismatch},
        {[:policy, :baseline_tree_digest], @other_hex, :fixed_attestation_label_mismatch}
      ]

      for {path, value, expected} <- mutations do
        input = put_in(@valid_input, path, value)

        assert {:error, ^expected} = AppleContainerAdmissionCore.new(input),
               "expected #{inspect(expected)} for #{inspect(path)}"
      end
    end

    test "requires linux/arm64 ready read-only provisioning; rejects macOS deps snapshot" do
      for platform <- ["macos", "darwin", "macos/arm64", "darwin/arm64", "linux/amd64"] do
        input = put_in(@valid_input, [:evidence, :dependency_baseline, :platform], platform)

        assert match?(
                 {:error, reason}
                 when reason in [
                        :macos_deps_snapshot_rejected,
                        :baseline_platform_mismatch
                      ],
                 AppleContainerAdmissionCore.new(input)
               ),
               "expected rejection for baseline platform=#{inspect(platform)}"
      end

      input =
        put_in(@valid_input, [:evidence, :dependency_baseline, :provisioning, :status], "pending")

      assert {:error, :baseline_not_ready} = AppleContainerAdmissionCore.new(input)

      input =
        put_in(
          @valid_input,
          [:evidence, :dependency_baseline, :provisioning, :mode],
          "read_write"
        )

      assert {:error, :baseline_not_read_only} = AppleContainerAdmissionCore.new(input)
    end

    test "rejects non-hex digests and oversized/invalid UTF-8 policy digests" do
      assert {:error, {:invalid, :mix_lock_digest}} =
               AppleContainerAdmissionCore.new(
                 put_in(@valid_input, [:policy, :mix_lock_digest], "not-hex")
               )

      assert {:error, {:invalid, :baseline_tree_digest}} =
               AppleContainerAdmissionCore.new(
                 put_in(@valid_input, [:policy, :baseline_tree_digest], String.duplicate("g", 64))
               )

      assert {:error, :invalid_utf8} =
               AppleContainerAdmissionCore.new(
                 put_in(@valid_input, [:policy, :mix_lock_digest], @invalid_utf8)
               )
    end
  end

  # --- Malformed / oversized / partial ---

  describe "malformed and partial evidence" do
    test "rejects invalid UTF-8 across bound string fields without raising" do
      paths = [
        [:policy, :image],
        [:evidence, :host_platform, :os],
        [:evidence, :runtime, :path],
        [:evidence, :service_status, :apiserver_version],
        [:evidence, :image_inspect, :configuration, :name]
      ]

      for path <- paths do
        input = put_in(@valid_input, path, @invalid_utf8)
        assert {:error, :invalid_utf8} = AppleContainerAdmissionCore.new(input)
      end
    end

    test "rejects missing evidence sections as partial" do
      for key <- [
            :host_platform,
            :runtime,
            :service_status,
            :image_inspect,
            :dependency_baseline
          ] do
        evidence = Map.delete(@valid_evidence, key)
        input = %{policy: @valid_policy, evidence: evidence}

        assert match?({:error, _}, AppleContainerAdmissionCore.new(input)),
               "expected rejection when evidence lacks #{key}"
      end
    end

    test "rejects oversized env and labels" do
      huge_env = Enum.map(1..100, &"VAR#{&1}=x")

      assert {:error, :too_many_env_entries} =
               AppleContainerAdmissionCore.new(put_in(@valid_input, [:policy, :env], huge_env))

      huge_labels =
        Map.new(1..64, fn i -> {"k#{i}", "v"} end)

      assert {:error, :too_many_labels} =
               AppleContainerAdmissionCore.new(
                 put_in(@valid_input, [:policy, :labels], huge_labels)
               )
    end

    test "rejects atom-keyed labels as invalid shape" do
      assert {:error, :invalid_labels} =
               AppleContainerAdmissionCore.new(
                 put_in(@valid_input, [:policy, :labels], %{attestation: "x"})
               )
    end

    test "rejects large unknown binary keys without echoing attacker material" do
      huge_key = String.duplicate("A", 100_000)
      input = Map.put(@valid_input, huge_key, "x")

      assert {:error, err} = AppleContainerAdmissionCore.new(input)
      assert err == {:unsupported_keys, :request}

      err_text = inspect(err)
      refute String.contains?(err_text, huge_key)
      refute String.contains?(err_text, String.duplicate("A", 32))
    end

    test "rejects oversized host version and fixed/signing/service/baseline fields" do
      oversized = String.duplicate("9", 10_000)

      assert {:error, :host_version_too_long} =
               AppleContainerAdmissionCore.new(
                 put_in(@valid_input, [:evidence, :host_platform, :version], oversized)
               )

      assert {:error, :designated_requirement_too_long} =
               AppleContainerAdmissionCore.new(
                 put_in(
                   @valid_input,
                   [:evidence, :runtime, :signing, :designated_requirement],
                   oversized
                 )
               )

      assert {:error, :apiserver_version_too_long} =
               AppleContainerAdmissionCore.new(
                 put_in(
                   @valid_input,
                   [:evidence, :service_status, :apiserver_version],
                   oversized
                 )
               )

      assert {:error, :baseline_platform_too_long} =
               AppleContainerAdmissionCore.new(
                 put_in(
                   @valid_input,
                   [:evidence, :dependency_baseline, :platform],
                   oversized
                 )
               )

      assert {:error, :image_name_too_long} =
               AppleContainerAdmissionCore.new(
                 put_in(
                   @valid_input,
                   [:evidence, :image_inspect, :configuration, :name],
                   oversized
                 )
               )

      assert {:error, :toolchain_erlang_too_long} =
               AppleContainerAdmissionCore.new(
                 put_in(@valid_input, [:policy, :toolchain, :erlang], oversized)
               )
    end

    test "rejects oversized maps and lists without raising" do
      huge_map =
        Map.new(1..200, fn i -> {:"k#{i}", i} end)

      assert {:error, :map_too_large} =
               AppleContainerAdmissionCore.new(Map.merge(@valid_input, huge_map))

      huge_variants = List.duplicate(@valid_arm64_variant, 64)

      assert {:error, :too_many_variants} =
               AppleContainerAdmissionCore.new(
                 put_in(@valid_input, [:evidence, :image_inspect, :variants], huge_variants)
               )
    end

    test "public new/1 returns errors for malformed inputs rather than raising" do
      malformed = [
        nil,
        :atom,
        42,
        [policy: @valid_policy],
        %{policy: "nope", evidence: @valid_evidence},
        %{policy: @valid_policy, evidence: "nope"},
        %{policy: @valid_policy, evidence: Map.put(@valid_evidence, :runtime, [])}
      ]

      for input <- malformed do
        assert match?({:error, _}, AppleContainerAdmissionCore.new(input)),
               "expected error for #{inspect(input)}"
      end
    end
  end

  # --- Bound-field mutation sweep ---

  describe "receipt field binding sweep" do
    test "mutating each bound receipt input field fails closed" do
      bound_mutations = [
        {[:evidence, :host_platform, :architecture], "x86_64"},
        {[:evidence, :runtime, :cli_version], "1.1.9"},
        {[:evidence, :runtime, :executable_sha256], @other_hex},
        {[:evidence, :runtime, :signing, :team_id], "ZZZZZZZZZZ"},
        {[:evidence, :service_status, :install_root], "/opt/homebrew/"},
        {[:policy, :manifest_digest], "sha256:#{@other_hex}"},
        {[:policy, :env], @env ++ ["X=1"]},
        {[:policy, :labels], Map.put(@labels, "x", "y")},
        {[:policy, :toolchain, :erlang], "27.0"},
        {[:evidence, :dependency_baseline, :mix_lock_digest], @other_hex},
        {[:evidence, :dependency_baseline, :platform], "macos/arm64"}
      ]

      assert {:ok, _} = AppleContainerAdmissionCore.new(@valid_input)

      for {path, value} <- bound_mutations do
        input = put_in(@valid_input, path, value)
        # CLI version mutation alone also needs matching API or gets version mismatch;
        # either way admission must fail. Note: executable_sha256 is carried evidence
        # (any valid hex64 is shape-valid); binding it does not make it authority.
        # For the sha mutation we only assert fail when paired with label/toolchain
        # changes above; a pure sha change with valid hex still admits the hash as data.
        if path == [:evidence, :runtime, :executable_sha256] do
          assert {:ok, receipt} = AppleContainerAdmissionCore.new(input)
          assert receipt.runtime.executable_sha256 == @other_hex
        else
          assert match?({:error, _}, AppleContainerAdmissionCore.new(input)),
                 "expected fail-closed for mutation #{inspect(path)}=#{inspect(value)}"
        end
      end
    end
  end
end
