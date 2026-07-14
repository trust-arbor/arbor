defmodule Arbor.Shell.AppleContainerAdmissionCoreTest do
  @moduledoc """
  Focused pure adversarial tests for Apple Container admission evidence core.

  Composes nested control-plane admission via startup-owner bindings +
  `evidence.control_plane`. Does not wire `Arbor.Shell.execute_spawn_capable/3`
  (still production_backend_missing).
  """

  use ExUnit.Case, async: true

  alias Arbor.Shell.AppleContainerAdmissionCore
  alias Arbor.Shell.AppleContainerControlPlaneAdmissionCore, as: ControlPlane
  alias Arbor.Shell.TrustedPath.Identity

  @moduletag :fast

  @index_hex String.duplicate("a", 64)
  @manifest_hex String.duplicate("b", 64)
  @mix_lock_hex String.duplicate("c", 64)
  @tree_hex String.duplicate("d", 64)
  @other_hex String.duplicate("e", 64)
  @vminit_index_hex String.duplicate("f0", 32)
  @vminit_manifest_hex String.duplicate("f1", 32)

  # CLI identity SHA is the aggregate executable authority; must match bindings.
  # Use letter-containing hex so String.upcase/1 is a distinct invalid form.
  @cli_sha String.duplicate("ab", 32)
  @api_sha String.duplicate("cd", 32)
  @plugin_sha String.duplicate("ef", 32)
  @config_sha String.duplicate("a1", 32)
  @kernel_sha String.duplicate("b2", 32)
  @executable_sha256 @cli_sha

  @image "docker.io/arbor/validation@sha256:#{@index_hex}"
  @index_digest "sha256:#{@index_hex}"
  @manifest_digest "sha256:#{@manifest_hex}"
  @workload_execution_ref "127.0.0.1:0/arbor/workload@sha256:#{@index_hex}"

  @vminit_image "docker.io/arbor/vminit@sha256:#{@vminit_index_hex}"
  @vminit_index_digest "sha256:#{@vminit_index_hex}"
  @vminit_manifest_digest "sha256:#{@vminit_manifest_hex}"
  @vminit_execution_ref "127.0.0.1:0/arbor/vminit@sha256:#{@vminit_index_hex}"

  @erlang_version "28.4.1"
  @elixir_version "1.19.5-otp-28"
  @version "1.1.0"
  @app_root "/Users/arbor/Library/Application Support/com.apple.container"
  @kernel_path "/usr/local/share/container/kernels/default.kernel"
  @exec_mode 0o100755
  @file_mode 0o100644

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
  @cli_requirement ControlPlane.cli_designated_requirement()
  @apiserver_requirement ControlPlane.apiserver_designated_requirement()
  @plugin_requirement ControlPlane.plugin_designated_requirement()

  @cli_identity %Identity{
    path: "/usr/local/bin/container",
    type: :regular,
    device: 1,
    inode: 101,
    size: 4_096,
    mtime: 1_700_000_000,
    ctime: 1_700_000_000,
    mode: @exec_mode,
    uid: 0,
    gid: 0,
    sha256: @cli_sha,
    executable_required: true
  }

  @apiserver_identity %Identity{
    path: "/usr/local/bin/container-apiserver",
    type: :regular,
    device: 1,
    inode: 102,
    size: 4_096,
    mtime: 1_700_000_000,
    ctime: 1_700_000_000,
    mode: @exec_mode,
    uid: 0,
    gid: 0,
    sha256: @api_sha,
    executable_required: true
  }

  @plugin_identity %Identity{
    path:
      "/usr/local/libexec/container/plugins/container-runtime-linux/bin/container-runtime-linux",
    type: :regular,
    device: 1,
    inode: 103,
    size: 4_096,
    mtime: 1_700_000_000,
    ctime: 1_700_000_000,
    mode: @exec_mode,
    uid: 0,
    gid: 0,
    sha256: @plugin_sha,
    executable_required: true
  }

  @plugin_config_identity %Identity{
    path: "/usr/local/libexec/container/plugins/container-runtime-linux/config.toml",
    type: :regular,
    device: 1,
    inode: 104,
    size: 512,
    mtime: 1_700_000_000,
    ctime: 1_700_000_000,
    mode: @file_mode,
    uid: 0,
    gid: 0,
    sha256: @config_sha,
    executable_required: false
  }

  @kernel_identity %Identity{
    path: @kernel_path,
    type: :regular,
    device: 1,
    inode: 105,
    size: 8_192,
    mtime: 1_700_000_000,
    ctime: 1_700_000_000,
    mode: @file_mode,
    uid: 0,
    gid: 0,
    sha256: @kernel_sha,
    executable_required: false
  }

  @control_plane_bindings %{
    cli_identity: @cli_identity,
    apiserver_identity: @apiserver_identity,
    runtime_plugin_identity: @plugin_identity,
    runtime_plugin_config_identity: @plugin_config_identity,
    kernel_identity: @kernel_identity,
    app_root: @app_root
  }

  @control_plane_evidence %{
    cli: %{
      identity: @cli_identity,
      version: @version,
      build: "release",
      signing: %{
        identifier: "com.apple.container.cli",
        team_id: "UPBK2H6LZM",
        designated_requirement: @cli_requirement,
        verified_against: @cli_requirement,
        status: "valid"
      }
    },
    apiserver: %{
      identity: @apiserver_identity,
      version: @version,
      build: "release",
      signing: %{
        identifier: "com.apple.container.apiserver",
        team_id: "UPBK2H6LZM",
        designated_requirement: @apiserver_requirement,
        verified_against: @apiserver_requirement,
        status: "valid"
      },
      launchd: %{
        label: "com.apple.container.apiserver",
        program: "/usr/local/bin/container-apiserver",
        argv: ["/usr/local/bin/container-apiserver", "start"],
        environment: %{
          "CONTAINER_APP_ROOT" => @app_root,
          "CONTAINER_INSTALL_ROOT" => "/usr/local"
        }
      }
    },
    service_status: %{
      status: "running",
      install_root: "/usr/local/",
      apiserver_version: @version,
      apiserver_build: "release"
    },
    runtime_plugin: %{
      identity: @plugin_identity,
      config_identity: @plugin_config_identity,
      signing: %{
        identifier: "com.apple.container.container-runtime-linux",
        team_id: "UPBK2H6LZM",
        designated_requirement: @plugin_requirement,
        verified_against: @plugin_requirement,
        status: "valid"
      },
      config: %{
        abstract: "Linux container runtime plugin",
        author: "Apple",
        version: "0.1",
        services_config: %{
          load_at_boot: false,
          run_at_load: false,
          default_arguments: [],
          services: [%{type: "runtime"}]
        }
      }
    },
    user_plugin_root: %{
      path: "/usr/local/libexec/container-plugins",
      status: "absent"
    },
    kernel_identity: @kernel_identity
  }

  @valid_policy %{
    image: @image,
    manifest_digest: @manifest_digest,
    vminit_image: @vminit_image,
    vminit_manifest_digest: @vminit_manifest_digest,
    env: @env,
    labels: @labels,
    mix_lock_digest: @mix_lock_hex,
    baseline_tree_digest: @tree_hex,
    toolchain: %{
      erlang: @erlang_version,
      elixir: @elixir_version
    }
  }

  # Realistic container 1.1.0 linux/arm64 projection includes OCI variant "v8"
  # on both selected platform and selected config maps.
  @valid_arm64_variant %{
    digest: @manifest_digest,
    platform: %{os: "linux", architecture: "arm64", variant: "v8"},
    config: %{
      os: "linux",
      architecture: "arm64",
      variant: "v8",
      config: %{
        "Env" => @env,
        "Labels" => @labels
      }
    }
  }

  # Vminit selected manifest: platform/digest evidence only (no workload Env/Labels).
  @valid_vminit_arm64_variant %{
    digest: @vminit_manifest_digest,
    platform: %{os: "linux", architecture: "arm64", variant: "v8"},
    config: %{
      os: "linux",
      architecture: "arm64",
      variant: "v8"
    }
  }

  # Realistic container 1.1.0 service-status + image-inspect shape (projected
  # to the closed evidence surface the pure core admits), plus nested control-plane.
  # image_inspect / vminit_image_inspect names are derived local execution aliases.
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
        name: @workload_execution_ref
      },
      variants: [@valid_arm64_variant]
    },
    vminit_image_inspect: %{
      configuration: %{
        descriptor: %{
          digest: @vminit_index_digest,
          mediaType: "application/vnd.oci.image.index.v1+json",
          size: 512
        },
        name: @vminit_execution_ref
      },
      variants: [@valid_vminit_arm64_variant]
    },
    dependency_baseline: %{
      schema: "1",
      platform: "linux/arm64",
      image_index_digest: @index_digest,
      image_manifest_digest: @manifest_digest,
      mix_lock_digest: @mix_lock_hex,
      baseline_tree_digest: @tree_hex,
      toolchain: %{
        erlang: @erlang_version,
        elixir: @elixir_version
      },
      entry_count: 1,
      total_bytes: 0
    },
    control_plane: @control_plane_evidence
  }

  @valid_input %{
    policy: @valid_policy,
    evidence: @valid_evidence
  }

  @invalid_utf8 <<0xC3, 0x28>>

  # --- Positive path ---

  describe "positive admission" do
    test "admits complete policy + realistic 1.1.0 evidence and binds all fields" do
      assert {:ok, receipt} = admit(@valid_input)

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
      assert receipt.control_plane.admitted == true
      assert receipt.control_plane.app_root == @app_root
      assert receipt.control_plane.cli.sha256 == @cli_sha
      assert receipt.control_plane.apiserver.version == @version
      assert receipt.control_plane.apiserver.sha256 == @api_sha
      assert receipt.control_plane.runtime_plugin.sha256 == @plugin_sha
      assert receipt.control_plane.kernel.sha256 == @kernel_sha
      assert receipt.control_plane.service.corroborated == true

      assert receipt.control_plane.apiserver.launchd.environment == %{
               "CONTAINER_APP_ROOT" => @app_root,
               "CONTAINER_INSTALL_ROOT" => "/usr/local"
             }

      assert receipt.image == %{
               reference: @image,
               execution_reference: @workload_execution_ref,
               index_digest: @index_digest,
               manifest_digest: @manifest_digest,
               platform: "linux/arm64",
               env: @env,
               labels: @labels
             }

      assert receipt.vminit == %{
               reference: @vminit_image,
               execution_reference: @vminit_execution_ref,
               index_digest: @vminit_index_digest,
               manifest_digest: @vminit_manifest_digest,
               platform: "linux/arm64"
             }

      assert receipt.toolchain == %{erlang: @erlang_version, elixir: @elixir_version}

      assert receipt.dependency_baseline == %{
               schema: "1",
               platform: "linux/arm64",
               image_index_digest: @index_digest,
               image_manifest_digest: @manifest_digest,
               mix_lock_digest: @mix_lock_hex,
               baseline_tree_digest: @tree_hex,
               toolchain: %{erlang: @erlang_version, elixir: @elixir_version},
               entry_count: 1,
               total_bytes: 0
             }

      shown = AppleContainerAdmissionCore.show(receipt)
      assert shown["admitted"] == true
      assert shown["runtime"]["designated_requirement"] == @designated_requirement
      assert shown["runtime"]["codesign_verified"] == true
      assert shown["runtime"]["executable_sha256"] == @executable_sha256
      assert shown["image"]["reference"] == @image
      assert shown["image"]["execution_reference"] == @workload_execution_ref
      assert shown["vminit"]["reference"] == @vminit_image
      assert shown["vminit"]["execution_reference"] == @vminit_execution_ref
      assert shown["vminit"]["index_digest"] == @vminit_index_digest
      assert shown["vminit"]["manifest_digest"] == @vminit_manifest_digest
      assert shown["vminit"]["platform"] == "linux/arm64"
      # Receipt exposes only normalized fields — no raw inspect blobs / config.
      refute Map.has_key?(shown["vminit"], "env")
      refute Map.has_key?(shown["vminit"], "labels")
      refute Map.has_key?(shown["vminit"], "config")
      refute Map.has_key?(shown["image"], "raw")
      assert shown["toolchain"]["erlang"] == @erlang_version
      assert shown["toolchain"]["elixir"] == @elixir_version

      assert shown["dependency_baseline"] == %{
               "schema" => "1",
               "platform" => "linux/arm64",
               "image_index_digest" => @index_digest,
               "image_manifest_digest" => @manifest_digest,
               "mix_lock_digest" => @mix_lock_hex,
               "baseline_tree_digest" => @tree_hex,
               "toolchain" => %{
                 "erlang" => @erlang_version,
                 "elixir" => @elixir_version
               },
               "entry_count" => 1,
               "total_bytes" => 0
             }

      # Compact baseline attestation — never provisioning/status/mode claims.
      refute Map.has_key?(shown["dependency_baseline"], "provisioning")
      refute Map.has_key?(shown["dependency_baseline"], "status")
      refute Map.has_key?(shown["dependency_baseline"], "mode")
      refute Map.has_key?(receipt.dependency_baseline, :provisioning)
      refute Map.has_key?(receipt.dependency_baseline, :status)
      refute Map.has_key?(receipt.dependency_baseline, :mode)
      assert shown["control_plane"]["admitted"] == true
      assert shown["control_plane"]["app_root"] == @app_root
      assert shown["control_plane"]["cli"]["sha256"] == @cli_sha
      assert shown["control_plane"]["apiserver"]["version"] == @version
      assert shown["control_plane"]["apiserver"]["sha256"] == @api_sha
      assert shown["control_plane"]["runtime_plugin"]["sha256"] == @plugin_sha
      assert shown["control_plane"]["kernel"]["sha256"] == @kernel_sha
      assert shown["control_plane"]["service"]["corroborated"] == true
      assert is_map(shown["control_plane"]["apiserver"]["launchd"])
      # No raw command output / oversized blobs in the receipt surface.
      refute Map.has_key?(shown, "stdout")
      refute Map.has_key?(shown, "raw")
      assert Jason.encode!(shown)
    end

    test "is deterministic for the same input" do
      assert {:ok, a} = admit(@valid_input)
      assert {:ok, b} = admit(@valid_input)
      assert a == b
      assert AppleContainerAdmissionCore.show(a) == AppleContainerAdmissionCore.show(b)
    end

    test "accepts string-keyed policy and evidence maps" do
      control_plane =
        @control_plane_evidence
        |> put_in([:cli, :version], "1.1.2")
        |> put_in([:apiserver, :version], "1.1.2")
        |> put_in([:service_status, :apiserver_version], "1.1.2")

      input = %{
        "policy" => %{
          "image" => @image,
          "manifest_digest" => @manifest_digest,
          "vminit_image" => @vminit_image,
          "vminit_manifest_digest" => @vminit_manifest_digest,
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
              "name" => @workload_execution_ref
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
          "vminit_image_inspect" => %{
            "configuration" => %{
              "descriptor" => %{
                "digest" => @vminit_index_digest,
                "media_type" => "application/vnd.docker.distribution.manifest.list.v2+json",
                "size" => 400
              },
              "name" => @vminit_execution_ref
            },
            "variants" => [
              %{
                "digest" => @vminit_manifest_digest,
                "platform" => %{"os" => "linux", "architecture" => "arm64", "variant" => "v8"},
                "config" => %{
                  "os" => "linux",
                  "architecture" => "arm64",
                  "variant" => "v8"
                }
              }
            ]
          },
          "dependency_baseline" => %{
            "schema" => "1",
            "platform" => "linux/arm64",
            "image_index_digest" => @index_digest,
            "image_manifest_digest" => @manifest_digest,
            "mix_lock_digest" => @mix_lock_hex,
            "baseline_tree_digest" => @tree_hex,
            "toolchain" => %{
              "erlang" => @erlang_version,
              "elixir" => @elixir_version
            },
            "entry_count" => 1,
            "total_bytes" => 0
          },
          "control_plane" => control_plane
        }
      }

      assert {:ok, receipt} = admit(input)
      assert receipt.platform.version == "26.1"
      assert receipt.runtime.cli_version == "1.1.2"
      assert receipt.runtime.api_version == "1.1.2"
      assert receipt.runtime.executable_sha256 == @executable_sha256
      assert receipt.toolchain.erlang == @erlang_version
      assert receipt.control_plane.apiserver.version == "1.1.2"
      assert receipt.image.execution_reference == @workload_execution_ref
      assert receipt.vminit.execution_reference == @vminit_execution_ref
      assert receipt.dependency_baseline.schema == "1"
      assert receipt.dependency_baseline.toolchain.elixir == @elixir_version
      refute Map.has_key?(receipt.dependency_baseline, :status)
      refute Map.has_key?(receipt.dependency_baseline, :mode)
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
      assert {:error, :invalid_request} = admit("nope")
      assert {:error, :invalid_request} = admit([])

      assert {:error, :missing_policy} =
               admit(%{evidence: @valid_evidence})

      assert {:error, :missing_evidence} =
               admit(%{policy: @valid_policy})

      assert {:error, :missing_control_plane} =
               admit(%{
                 policy: @valid_policy,
                 evidence: Map.delete(@valid_evidence, :control_plane)
               })
    end

    test "rejects unknown top-level keys without echoing key material" do
      assert {:error, {:unsupported_keys, :request}} =
               admit(Map.put(@valid_input, :callback, fn -> :ok end))

      assert {:error, {:unsupported_keys, :request}} =
               admit(Map.put(@valid_input, :extra, 1))
    end

    test "rejects dual atom/string aliases at every closed surface" do
      dual_policy =
        Map.put(@valid_input, :policy, Map.merge(@valid_policy, %{"image" => @image}))

      assert {:error, {:duplicate_key_alias, :policy, :image}} =
               admit(dual_policy)

      dual_request = Map.merge(@valid_input, %{"policy" => @valid_policy})

      assert {:error, {:duplicate_key_alias, :request, :policy}} =
               admit(dual_request)

      dual_host =
        put_in(
          @valid_input,
          [:evidence, :host_platform],
          Map.merge(%{os: "macos", version: "26.0", architecture: "arm64"}, %{"os" => "macos"})
        )

      assert {:error, {:duplicate_key_alias, :host_platform, :os}} =
               admit(dual_host)

      dual_runtime =
        put_in(
          @valid_input,
          [:evidence, :runtime],
          Map.merge(@valid_evidence.runtime, %{"path" => "/usr/local/bin/container"})
        )

      assert {:error, {:duplicate_key_alias, :runtime, :path}} =
               admit(dual_runtime)

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

      assert {:error, :ambiguous_env_alias} = admit(dual_env)
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
               admit(dual_variant_platform)

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
               admit(dual_variant_config)
    end

    test "rejects every duplicate descriptor media-type representation" do
      base_descriptor = @valid_evidence.image_inspect.configuration.descriptor
      media = "application/vnd.docker.distribution.manifest.list.v2+json"

      # Same-spelling snake atom + string.
      dual_snake =
        base_descriptor
        |> Map.delete(:mediaType)
        |> Map.merge(%{"media_type" => media, media_type: media})

      input =
        put_in(
          @valid_input,
          [:evidence, :image_inspect, :configuration, :descriptor],
          dual_snake
        )

      assert {:error, {:duplicate_key_alias, :descriptor, :media_type}} =
               admit(input)

      # Same-spelling camel atom + string.
      dual_camel =
        %{
          "mediaType" => media,
          digest: @index_digest,
          size: 772,
          mediaType: media
        }

      input =
        put_in(
          @valid_input,
          [:evidence, :image_inspect, :configuration, :descriptor],
          dual_camel
        )

      assert {:error, {:duplicate_key_alias, :descriptor, :media_type}} =
               admit(input)

      # Cross-spelling snake + camel.
      dual_cross =
        %{
          digest: @index_digest,
          size: 772,
          media_type: media,
          mediaType: media
        }

      input =
        put_in(
          @valid_input,
          [:evidence, :image_inspect, :configuration, :descriptor],
          dual_cross
        )

      assert {:error, {:duplicate_key_alias, :descriptor, :media_type}} =
               admit(input)
    end

    test "rejects policy callbacks/modules and unknown policy keys" do
      assert {:error, {:unsupported_keys, :policy}} =
               admit(put_in(@valid_input, [:policy], Map.put(@valid_policy, :validator, & &1)))

      assert {:error, {:unsupported_keys, :policy}} =
               admit(put_in(@valid_input, [:policy], Map.put(@valid_policy, :module, __MODULE__)))
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

        assert {:error, ^expected} = admit(input),
               "expected #{inspect(expected)} for host_platform.#{field}=#{inspect(value)}"
      end
    end

    test "accepts macOS major 26 and newer" do
      for version <- ["26", "26.0", "26.0.1", "27.1"] do
        input = put_in(@valid_input, [:evidence, :host_platform, :version], version)
        assert {:ok, receipt} = admit(input)
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
        assert {:error, :runtime_path_mismatch} = admit(input)
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

      assert {:error, :cli_api_version_mismatch} = admit(input)

      # Outside 1.1.x line
      input =
        @valid_input
        |> put_in([:evidence, :runtime, :cli_version], "1.2.0")
        |> put_in(
          [:evidence, :service_status, :apiserver_version],
          "container-apiserver version 1.2.0 (build: release, commit: abcdef1)"
        )

      assert {:error, :cli_version_not_supported} = admit(input)

      input =
        @valid_input
        |> put_in([:evidence, :runtime, :cli_version], "0.1.0")
        |> put_in(
          [:evidence, :service_status, :apiserver_version],
          "container-apiserver version 0.1.0 (build: release, commit: abcdef1)"
        )

      assert {:error, :cli_version_not_supported} = admit(input)
    end

    test "rejects non-release builds" do
      input = put_in(@valid_input, [:evidence, :runtime, :cli_build], "debug")
      assert {:error, :non_release_cli_build} = admit(input)

      input = put_in(@valid_input, [:evidence, :service_status, :apiserver_build], "debug")
      assert {:error, :non_release_api_build} = admit(input)

      input =
        put_in(
          @valid_input,
          [:evidence, :service_status, :apiserver_version],
          "container-apiserver version 1.1.0 (build: debug, commit: abcdef1)"
        )

      assert {:error, :non_release_api_version} = admit(input)
    end

    test "requires and carries pinned executable sha256" do
      input =
        put_in(
          @valid_input,
          [:evidence, :runtime],
          Map.delete(@valid_evidence.runtime, :executable_sha256)
        )

      assert {:error, :missing_executable_sha256} = admit(input)

      input = put_in(@valid_input, [:evidence, :runtime, :executable_sha256], "not-hex")
      assert {:error, :invalid_executable_sha256} = admit(input)

      input =
        put_in(
          @valid_input,
          [:evidence, :runtime, :executable_sha256],
          String.upcase(@executable_sha256)
        )

      assert {:error, :invalid_executable_sha256} = admit(input)
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

        assert {:error, ^expected} = admit(input),
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

      assert {:error, :verified_against_mismatch} = admit(input)

      # Missing signing block entirely.
      runtime = Map.delete(@valid_evidence.runtime, :signing)
      input = put_in(@valid_input, [:evidence, :runtime], runtime)
      assert {:error, :missing_signing} = admit(input)
    end
  end

  # --- Service status ---

  describe "service-status mutations" do
    test "requires running status and /usr/local/ installRoot" do
      input = put_in(@valid_input, [:evidence, :service_status, :status], "stopped")
      assert {:error, :service_not_running} = admit(input)

      for root <- [
            "/opt/homebrew/Cellar/container/1.1.0/",
            "/usr/local",
            "/usr/local/bin/",
            "/Applications/"
          ] do
        input = put_in(@valid_input, [:evidence, :service_status, :install_root], root)
        assert {:error, :install_root_mismatch} = admit(input)
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

        assert match?({:error, _}, admit(input)),
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
            "arbor/validation@sha256:#{@index_hex}",
            # Default-registry-ambiguous host (no '.' in first segment).
            "registry/arbor/validation@sha256:#{@index_hex}"
          ] do
        input = put_in(@valid_input, [:policy, :image], image)

        assert match?({:error, _}, admit(input)),
               "expected rejection for image=#{inspect(image)}"
      end
    end

    @tag :security_regression
    test "rejects default-registry-ambiguous host without a dot while accepting docker.io" do
      ambiguous = "registry/arbor/validation@sha256:#{@index_hex}"
      input = put_in(@valid_input, [:policy, :image], ambiguous)

      assert {:error, :malformed_image} = admit(input)

      # Positive fully-qualified form remains accepted (fixture uses docker.io/...).
      assert {:ok, receipt} = admit(@valid_input)
      assert receipt.image.reference == @image
      assert receipt.image.execution_reference == @workload_execution_ref
      assert String.starts_with?(@image, "docker.io/")
    end

    test "requires inspect name to equal derived local execution alias (not source ref)" do
      input =
        put_in(
          @valid_input,
          [:evidence, :image_inspect, :configuration, :descriptor, :digest],
          "sha256:#{@other_hex}"
        )

      assert {:error, :image_index_digest_mismatch} = admit(input)

      # Source reference is policy-only; inspect must present the local alias.
      input =
        put_in(
          @valid_input,
          [:evidence, :image_inspect, :configuration, :name],
          @image
        )

      assert {:error, :image_name_digest_mismatch} = admit(input)

      input =
        put_in(
          @valid_input,
          [:evidence, :image_inspect, :configuration, :name],
          "docker.io/other/image@sha256:#{@index_hex}"
        )

      assert {:error, :image_name_digest_mismatch} = admit(input)

      input =
        put_in(
          @valid_input,
          [:evidence, :image_inspect, :configuration, :name],
          "127.0.0.1:0/arbor/workload@sha256:#{@other_hex}"
        )

      assert {:error, :image_name_digest_mismatch} = admit(input)

      # Near-collision: attacker prefix ending in the alias repository.
      near_collision =
        "evil.example/127.0.0.1:0/arbor/workload@sha256:#{@index_hex}"

      input =
        put_in(
          @valid_input,
          [:evidence, :image_inspect, :configuration, :name],
          near_collision
        )

      assert {:error, :image_name_digest_mismatch} = admit(input)

      # Wrong role alias with correct digest.
      input =
        put_in(
          @valid_input,
          [:evidence, :image_inspect, :configuration, :name],
          "127.0.0.1:0/arbor/vminit@sha256:#{@index_hex}"
        )

      assert {:error, :image_name_digest_mismatch} = admit(input)
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
                 admit(input)
               ),
               "expected media type rejection for #{inspect(media)}"
      end
    end

    test "requires exactly one linux/arm64 variant with pinned manifest digest" do
      input = put_in(@valid_input, [:evidence, :image_inspect, :variants], [])
      assert {:error, :missing_variants} = admit(input)

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
      assert {:error, :linux_arm64_variant_missing} = admit(input)

      dup = [
        @valid_arm64_variant,
        Map.put(@valid_arm64_variant, :digest, "sha256:#{@other_hex}")
      ]

      input = put_in(@valid_input, [:evidence, :image_inspect, :variants], dup)
      assert {:error, :duplicate_linux_arm64_variants} = admit(input)

      wrong_manifest =
        put_in(@valid_arm64_variant, [:digest], "sha256:#{@other_hex}")

      input =
        put_in(@valid_input, [:evidence, :image_inspect, :variants], [wrong_manifest])

      assert {:error, :manifest_digest_mismatch} = admit(input)
    end

    test "rejects nested os/architecture mismatch on selected variant" do
      variant =
        @valid_arm64_variant
        |> put_in([:config, :os], "windows")

      input = put_in(@valid_input, [:evidence, :image_inspect, :variants], [variant])
      assert {:error, :variant_config_platform_mismatch} = admit(input)

      variant =
        @valid_arm64_variant
        |> put_in([:config, :architecture], "amd64")

      input = put_in(@valid_input, [:evidence, :image_inspect, :variants], [variant])
      assert {:error, :variant_config_platform_mismatch} = admit(input)
    end

    test "normalizes OCI arm64 variant v8 and rejects unsupported or malformed variants" do
      # Positive path fixture already projects platform+config variant "v8".
      assert {:ok, _receipt} = admit(@valid_input)

      # Absence of optional variant remains accepted (OCI field is optional).
      without_variant = %{
        digest: @manifest_digest,
        platform: %{os: "linux", architecture: "arm64"},
        config: %{
          os: "linux",
          architecture: "arm64",
          config: %{"Env" => @env, "Labels" => @labels}
        }
      }

      input = put_in(@valid_input, [:evidence, :image_inspect, :variants], [without_variant])
      assert {:ok, _} = admit(input)

      # Platform-only or config-only "v8" is accepted.
      platform_only =
        without_variant
        |> put_in([:platform, :variant], "v8")

      input = put_in(@valid_input, [:evidence, :image_inspect, :variants], [platform_only])
      assert {:ok, _} = admit(input)

      config_only =
        without_variant
        |> put_in([:config, :variant], "v8")

      input = put_in(@valid_input, [:evidence, :image_inspect, :variants], [config_only])
      assert {:ok, _} = admit(input)

      # Unsupported but safe token on selected arm64.
      for path <- [[:platform, :variant], [:config, :variant]] do
        variant = put_in(@valid_arm64_variant, path, "v9")
        input = put_in(@valid_input, [:evidence, :image_inspect, :variants], [variant])

        assert {:error, :unsupported_arm64_variant} = admit(input),
               "expected unsupported_arm64_variant for #{inspect(path)}=v9"
      end

      # Non-binary variant values fail closed during normalization.
      for path <- [[:platform, :variant], [:config, :variant]] do
        variant = put_in(@valid_arm64_variant, path, :v8)
        input = put_in(@valid_input, [:evidence, :image_inspect, :variants], [variant])

        assert {:error, :invalid_variant} = admit(input),
               "expected invalid_variant for non-binary at #{inspect(path)}"
      end

      # Oversized variant values fail closed during normalization.
      oversized = String.duplicate("v", 64)

      for path <- [[:platform, :variant], [:config, :variant]] do
        variant = put_in(@valid_arm64_variant, path, oversized)
        input = put_in(@valid_input, [:evidence, :image_inspect, :variants], [variant])

        assert {:error, :variant_too_long} = admit(input),
               "expected variant_too_long for #{inspect(path)}"
      end

      # Non-selected variants are still bounded/normalized (not ignored).
      amd64_oversized = %{
        digest: "sha256:#{@other_hex}",
        platform: %{os: "linux", architecture: "amd64", variant: oversized},
        config: %{
          os: "linux",
          architecture: "amd64",
          config: %{"Env" => @env, "Labels" => @labels}
        }
      }

      input =
        put_in(
          @valid_input,
          [:evidence, :image_inspect, :variants],
          [@valid_arm64_variant, amd64_oversized]
        )

      assert {:error, :variant_too_long} = admit(input)

      amd64_non_binary = %{
        digest: "sha256:#{@other_hex}",
        platform: %{os: "linux", architecture: "amd64", variant: 8},
        config: %{
          os: "linux",
          architecture: "amd64",
          config: %{"Env" => @env, "Labels" => @labels}
        }
      }

      input =
        put_in(
          @valid_input,
          [:evidence, :image_inspect, :variants],
          [@valid_arm64_variant, amd64_non_binary]
        )

      assert {:error, :invalid_variant} = admit(input)
    end

    test "requires fixed attestation labels bound to toolchain and digests" do
      # Missing fixed label
      labels = Map.delete(@labels, "org.arbor.validation.schema")
      input = put_in(@valid_input, [:policy, :labels], labels)
      assert {:error, :missing_fixed_attestation_label} = admit(input)

      # Wrong schema value
      labels = Map.put(@labels, "org.arbor.validation.schema", "2")
      input = put_in(@valid_input, [:policy, :labels], labels)
      assert {:error, :fixed_attestation_label_mismatch} = admit(input)

      # Erlang label not bound to policy toolchain
      labels = Map.put(@labels, "org.arbor.validation.erlang", "27.0")
      input = put_in(@valid_input, [:policy, :labels], labels)
      assert {:error, :fixed_attestation_label_mismatch} = admit(input)

      # mix-lock label not bound to policy digest
      labels = Map.put(@labels, "org.arbor.validation.mix-lock-sha256", @other_hex)
      input = put_in(@valid_input, [:policy, :labels], labels)
      assert {:error, :fixed_attestation_label_mismatch} = admit(input)

      # Missing toolchain map
      policy = Map.delete(@valid_policy, :toolchain)

      assert {:error, :missing_toolchain} =
               admit(%{policy: policy, evidence: @valid_evidence})

      # Empty/arbitrary labels no longer satisfy attestation
      empty_labels = %{"org.arbor.attestation" => "validation-image-v1"}
      input = put_in(@valid_input, [:policy, :labels], empty_labels)
      assert match?({:error, _}, admit(input))
    end

    test "requires exact operator-approved Env and Labels" do
      # Unexpected inherited Env entry
      variant =
        put_in(@valid_arm64_variant, [:config, :config, "Env"], @env ++ ["EXTRA=1"])

      input = put_in(@valid_input, [:evidence, :image_inspect, :variants], [variant])
      assert {:error, :env_mismatch} = admit(input)

      # Missing Env entry
      variant = put_in(@valid_arm64_variant, [:config, :config, "Env"], Enum.take(@env, 1))
      input = put_in(@valid_input, [:evidence, :image_inspect, :variants], [variant])
      assert {:error, :env_mismatch} = admit(input)

      # Reordered Env is a mismatch (exact list equality)
      variant = put_in(@valid_arm64_variant, [:config, :config, "Env"], Enum.reverse(@env))
      input = put_in(@valid_input, [:evidence, :image_inspect, :variants], [variant])
      assert {:error, :env_mismatch} = admit(input)

      # Label mutation
      variant =
        put_in(@valid_arm64_variant, [:config, :config, "Labels"], Map.put(@labels, "extra", "1"))

      input = put_in(@valid_input, [:evidence, :image_inspect, :variants], [variant])
      assert {:error, :labels_mismatch} = admit(input)

      variant =
        put_in(
          @valid_arm64_variant,
          [:config, :config, "Labels"],
          Map.delete(@labels, "org.arbor.operator.note")
        )

      input = put_in(@valid_input, [:evidence, :image_inspect, :variants], [variant])
      assert {:error, :labels_mismatch} = admit(input)
    end

    test "rejects partial image evidence and unknown fields" do
      inspect_missing =
        Map.delete(@valid_evidence.image_inspect, :variants)

      input = put_in(@valid_input, [:evidence, :image_inspect], inspect_missing)
      assert {:error, :missing_variants} = admit(input)

      input =
        put_in(
          @valid_input,
          [:evidence, :image_inspect],
          Map.put(@valid_evidence.image_inspect, :history, [])
        )

      assert {:error, {:unsupported_keys, :image_inspect}} =
               admit(input)

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

      assert {:error, :partial_image_descriptor} = admit(input)
    end
  end

  # --- Vminit + local execution aliases ---

  describe "vminit and local-alias contract" do
    test "rejects missing or unknown vminit policy/evidence keys" do
      assert {:error, :missing_vminit_image} =
               admit(%{
                 policy: Map.delete(@valid_policy, :vminit_image),
                 evidence: @valid_evidence
               })

      assert {:error, :missing_vminit_manifest_digest} =
               admit(%{
                 policy: Map.delete(@valid_policy, :vminit_manifest_digest),
                 evidence: @valid_evidence
               })

      assert {:error, :missing_vminit_image_inspect} =
               admit(%{
                 policy: @valid_policy,
                 evidence: Map.delete(@valid_evidence, :vminit_image_inspect)
               })

      assert {:error, {:unsupported_keys, :policy}} =
               admit(
                 put_in(
                   @valid_input,
                   [:policy],
                   Map.put(@valid_policy, :workload_execution_reference, @workload_execution_ref)
                 )
               )

      assert {:error, {:unsupported_keys, :evidence}} =
               admit(
                 put_in(
                   @valid_input,
                   [:evidence],
                   Map.put(@valid_evidence, :extra_inspect, %{})
                 )
               )

      assert {:error, {:duplicate_key_alias, :policy, :vminit_image}} =
               admit(
                 put_in(
                   @valid_input,
                   [:policy],
                   Map.merge(@valid_policy, %{"vminit_image" => @vminit_image})
                 )
               )

      assert {:error, {:duplicate_key_alias, :evidence, :vminit_image_inspect}} =
               admit(
                 put_in(
                   @valid_input,
                   [:evidence],
                   Map.put(
                     @valid_evidence,
                     "vminit_image_inspect",
                     @valid_evidence.vminit_image_inspect
                   )
                 )
               )
    end

    test "rejects mutable, ambiguous, uppercase, and local-alias vminit policy sources" do
      for image <- [
            "arbor/vminit:latest",
            "arbor/vminit",
            "registry/arbor/vminit@sha256:#{@vminit_index_hex}",
            "docker.io/arbor/vminit@sha256:#{String.upcase(@vminit_index_hex)}",
            @vminit_execution_ref,
            "127.0.0.1:0/arbor/vminit@sha256:#{@vminit_index_hex}"
          ] do
        input = put_in(@valid_input, [:policy, :vminit_image], image)

        assert match?({:error, _}, admit(input)),
               "expected rejection for vminit_image=#{inspect(image)}"
      end

      assert {:error, :local_alias_not_policy} =
               admit(put_in(@valid_input, [:policy, :image], @workload_execution_ref))

      assert {:error, :local_alias_not_policy} =
               admit(put_in(@valid_input, [:policy, :vminit_image], @vminit_execution_ref))
    end

    test "rejects vminit alias/descriptor/platform/manifest mismatches" do
      input =
        put_in(
          @valid_input,
          [:evidence, :vminit_image_inspect, :configuration, :name],
          @vminit_image
        )

      assert {:error, :vminit_name_digest_mismatch} = admit(input)

      input =
        put_in(
          @valid_input,
          [:evidence, :vminit_image_inspect, :configuration, :name],
          @workload_execution_ref
        )

      assert {:error, :vminit_name_digest_mismatch} = admit(input)

      input =
        put_in(
          @valid_input,
          [:evidence, :vminit_image_inspect, :configuration, :descriptor, :digest],
          @index_digest
        )

      assert {:error, :vminit_index_digest_mismatch} = admit(input)

      wrong_manifest =
        put_in(@valid_vminit_arm64_variant, [:digest], @manifest_digest)

      input =
        put_in(
          @valid_input,
          [:evidence, :vminit_image_inspect, :variants],
          [wrong_manifest]
        )

      assert {:error, :vminit_manifest_digest_mismatch} = admit(input)

      amd64 = %{
        digest: @vminit_manifest_digest,
        platform: %{os: "linux", architecture: "amd64"},
        config: %{os: "linux", architecture: "amd64"}
      }

      input =
        put_in(@valid_input, [:evidence, :vminit_image_inspect, :variants], [amd64])

      assert {:error, :vminit_linux_arm64_variant_missing} = admit(input)

      input =
        put_in(
          @valid_input,
          [:evidence, :vminit_image_inspect, :variants],
          [
            @valid_vminit_arm64_variant,
            Map.put(@valid_vminit_arm64_variant, :digest, "sha256:#{@other_hex}")
          ]
        )

      assert {:error, :duplicate_vminit_linux_arm64_variants} = admit(input)

      bad_platform =
        @valid_vminit_arm64_variant
        |> put_in([:config, :os], "windows")

      input =
        put_in(@valid_input, [:evidence, :vminit_image_inspect, :variants], [bad_platform])

      assert {:error, :variant_config_platform_mismatch} = admit(input)
    end

    test "does not require workload Env/Labels attestation on vminit inspect" do
      # Nested vminit config with unrelated Env/Labels is bounded evidence only.
      variant =
        put_in(
          @valid_vminit_arm64_variant,
          [:config, :config],
          %{"Env" => ["UNRELATED=1"], "Labels" => %{"role" => "vminit"}}
        )

      input =
        put_in(@valid_input, [:evidence, :vminit_image_inspect, :variants], [variant])

      assert {:ok, receipt} = admit(input)
      refute Map.has_key?(receipt.vminit, :env)
      refute Map.has_key?(receipt.vminit, :labels)
    end

    test "rejects workload/vminit source, index, and manifest collisions" do
      assert {:error, :workload_vminit_image_collision} =
               admit(put_in(@valid_input, [:policy, :vminit_image], @image))

      assert {:error, :workload_vminit_index_collision} =
               admit(
                 put_in(
                   @valid_input,
                   [:policy, :vminit_image],
                   "docker.io/arbor/vminit@sha256:#{@index_hex}"
                 )
               )

      assert {:error, :workload_vminit_manifest_collision} =
               admit(put_in(@valid_input, [:policy, :vminit_manifest_digest], @manifest_digest))

      assert {:error, :workload_index_manifest_collision} =
               admit(put_in(@valid_input, [:policy, :manifest_digest], @index_digest))

      assert {:error, :vminit_index_manifest_collision} =
               admit(
                 put_in(
                   @valid_input,
                   [:policy, :vminit_manifest_digest],
                   @vminit_index_digest
                 )
               )
    end

    test "baseline remains bound only to workload digests, not vminit" do
      # Vminit digests must not be accepted as the workload baseline binding.
      input =
        put_in(
          @valid_input,
          [:evidence, :dependency_baseline, :image_index_digest],
          @vminit_index_digest
        )

      assert {:error, :baseline_image_index_mismatch} = admit(input)

      input =
        put_in(
          @valid_input,
          [:evidence, :dependency_baseline, :image_manifest_digest],
          @vminit_manifest_digest
        )

      assert {:error, :baseline_image_manifest_mismatch} = admit(input)

      assert {:ok, receipt} = admit(@valid_input)
      assert receipt.dependency_baseline.image_index_digest == @index_digest
      assert receipt.dependency_baseline.image_manifest_digest == @manifest_digest
      refute receipt.dependency_baseline.image_index_digest == @vminit_index_digest
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

        assert {:error, ^expected} = admit(input),
               "expected #{inspect(expected)} for #{inspect(path)}"
      end
    end

    test "requires linux/arm64 compact baseline platform; rejects macOS/host snapshots" do
      for platform <- ["macos", "darwin", "macos/arm64", "darwin/arm64", "linux/amd64"] do
        input = put_in(@valid_input, [:evidence, :dependency_baseline, :platform], platform)

        assert match?(
                 {:error, reason}
                 when reason in [
                        :unsupported_platform,
                        :macos_deps_snapshot_rejected,
                        :baseline_platform_mismatch
                      ],
                 admit(input)
               ),
               "expected rejection for baseline platform=#{inspect(platform)}"
      end
    end

    test "binds baseline toolchain to policy toolchain" do
      input =
        put_in(@valid_input, [:evidence, :dependency_baseline, :toolchain, :erlang], "27.0")

      assert {:error, :baseline_toolchain_mismatch} = admit(input)

      input =
        put_in(@valid_input, [:evidence, :dependency_baseline, :toolchain, :elixir], "1.18.0")

      assert {:error, :baseline_toolchain_mismatch} = admit(input)
    end

    test "rejects malformed compact baseline schema, counts, duplicates, and unknown keys" do
      assert {:error, :unsupported_schema} =
               admit(put_in(@valid_input, [:evidence, :dependency_baseline, :schema], "2"))

      assert {:error, {:invalid, :entry_count}} =
               admit(
                 put_in(
                   @valid_input,
                   [:evidence, :dependency_baseline, :entry_count],
                   "1"
                 )
               )

      assert {:error, {:negative, :total_bytes}} =
               admit(
                 put_in(
                   @valid_input,
                   [:evidence, :dependency_baseline, :total_bytes],
                   -1
                 )
               )

      dual =
        put_in(
          @valid_input,
          [:evidence, :dependency_baseline],
          Map.put(@valid_evidence.dependency_baseline, "schema", "1")
        )

      assert {:error, {:duplicate_key_alias, :compact_receipt, :schema}} = admit(dual)

      assert {:error, {:unsupported_keys, :compact_receipt}} =
               admit(
                 put_in(
                   @valid_input,
                   [:evidence, :dependency_baseline],
                   Map.put(@valid_evidence.dependency_baseline, :extra, true)
                 )
               )
    end

    @tag :security_regression
    test "security regression: legacy provisioning ready/read_only map cannot confer readiness" do
      # Caller-supplied provisioning claims are no longer an accepted surface.
      # Aggregate admission attests only the compact baseline receipt.
      legacy_ready = %{
        schema: "1",
        platform: "linux/arm64",
        image_index_digest: @index_digest,
        image_manifest_digest: @manifest_digest,
        mix_lock_digest: @mix_lock_hex,
        baseline_tree_digest: @tree_hex,
        toolchain: %{
          erlang: @erlang_version,
          elixir: @elixir_version
        },
        entry_count: 1,
        total_bytes: 0,
        provisioning: %{
          status: "ready",
          mode: "read_only"
        }
      }

      input = put_in(@valid_input, [:evidence, :dependency_baseline], legacy_ready)

      assert {:error, {:unsupported_keys, :compact_receipt}} = admit(input)
      refute match?({:ok, _}, admit(input))

      # Status/mode alone (legacy receipt projection) also fail closed.
      status_mode_only = %{
        image_index_digest: @index_digest,
        image_manifest_digest: @manifest_digest,
        mix_lock_digest: @mix_lock_hex,
        baseline_tree_digest: @tree_hex,
        platform: "linux/arm64",
        status: "ready",
        mode: "read_only"
      }

      input = put_in(@valid_input, [:evidence, :dependency_baseline], status_mode_only)
      assert {:error, {:unsupported_keys, :compact_receipt}} = admit(input)

      assert {:ok, receipt} = admit(@valid_input)
      shown = AppleContainerAdmissionCore.show(receipt)
      refute Map.has_key?(shown["dependency_baseline"], "provisioning")
      refute Map.has_key?(shown["dependency_baseline"], "status")
      refute Map.has_key?(shown["dependency_baseline"], "mode")
    end

    test "rejects non-hex digests and oversized/invalid UTF-8 policy digests" do
      assert {:error, {:invalid, :mix_lock_digest}} =
               admit(put_in(@valid_input, [:policy, :mix_lock_digest], "not-hex"))

      assert {:error, {:invalid, :baseline_tree_digest}} =
               admit(
                 put_in(@valid_input, [:policy, :baseline_tree_digest], String.duplicate("g", 64))
               )

      assert {:error, :invalid_utf8} =
               admit(put_in(@valid_input, [:policy, :mix_lock_digest], @invalid_utf8))
    end
  end

  describe "execution_references/1 preflight" do
    test "aliases exactly match admission receipt aliases" do
      assert {:ok, refs} = AppleContainerAdmissionCore.execution_references(@valid_policy)
      assert {:ok, receipt} = admit(@valid_input)

      assert refs.image.reference == receipt.image.reference
      assert refs.image.execution_reference == receipt.image.execution_reference
      assert refs.image.index_digest == receipt.image.index_digest
      assert refs.image.manifest_digest == receipt.image.manifest_digest

      assert refs.vminit.reference == receipt.vminit.reference
      assert refs.vminit.execution_reference == receipt.vminit.execution_reference
      assert refs.vminit.index_digest == receipt.vminit.index_digest
      assert refs.vminit.manifest_digest == receipt.vminit.manifest_digest

      assert refs.image.execution_reference == @workload_execution_ref
      assert refs.vminit.execution_reference == @vminit_execution_ref
    end

    test "accepts string-keyed policy and rejects unknown/malformed policy" do
      string_policy = %{
        "image" => @image,
        "manifest_digest" => @manifest_digest,
        "vminit_image" => @vminit_image,
        "vminit_manifest_digest" => @vminit_manifest_digest,
        "env" => @env,
        "labels" => @labels,
        "mix_lock_digest" => @mix_lock_hex,
        "baseline_tree_digest" => @tree_hex,
        "toolchain" => %{
          "erlang" => @erlang_version,
          "elixir" => @elixir_version
        }
      }

      assert {:ok, refs} = AppleContainerAdmissionCore.execution_references(string_policy)
      assert refs.image.execution_reference == @workload_execution_ref

      assert {:error, {:unsupported_keys, :policy}} =
               AppleContainerAdmissionCore.execution_references(
                 Map.put(@valid_policy, :extra, true)
               )

      assert {:error, :missing_image} =
               AppleContainerAdmissionCore.execution_references(Map.delete(@valid_policy, :image))

      assert {:error, :invalid_policy} =
               AppleContainerAdmissionCore.execution_references("nope")

      assert {:error, :invalid_policy} =
               AppleContainerAdmissionCore.execution_references([])
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
        assert {:error, :invalid_utf8} = admit(input)
      end
    end

    test "rejects missing evidence sections as partial" do
      for key <- [
            :host_platform,
            :runtime,
            :service_status,
            :image_inspect,
            :vminit_image_inspect,
            :dependency_baseline,
            :control_plane
          ] do
        evidence = Map.delete(@valid_evidence, key)
        input = %{policy: @valid_policy, evidence: evidence}

        assert match?({:error, _}, admit(input)),
               "expected rejection when evidence lacks #{key}"
      end
    end

    test "rejects oversized env and labels" do
      huge_env = Enum.map(1..100, &"VAR#{&1}=x")

      assert {:error, :too_many_env_entries} =
               admit(put_in(@valid_input, [:policy, :env], huge_env))

      huge_labels =
        Map.new(1..64, fn i -> {"k#{i}", "v"} end)

      assert {:error, :too_many_labels} =
               admit(put_in(@valid_input, [:policy, :labels], huge_labels))
    end

    test "rejects atom-keyed labels as invalid shape" do
      assert {:error, :invalid_labels} =
               admit(put_in(@valid_input, [:policy, :labels], %{attestation: "x"}))
    end

    test "rejects large unknown binary keys without echoing attacker material" do
      huge_key = String.duplicate("A", 100_000)
      input = Map.put(@valid_input, huge_key, "x")

      assert {:error, err} = admit(input)
      assert err == {:unsupported_keys, :request}

      err_text = inspect(err)
      refute String.contains?(err_text, huge_key)
      refute String.contains?(err_text, String.duplicate("A", 32))
    end

    test "rejects oversized host version and fixed/signing/service/baseline fields" do
      oversized = String.duplicate("9", 10_000)

      assert {:error, :host_version_too_long} =
               admit(put_in(@valid_input, [:evidence, :host_platform, :version], oversized))

      assert {:error, :designated_requirement_too_long} =
               admit(
                 put_in(
                   @valid_input,
                   [:evidence, :runtime, :signing, :designated_requirement],
                   oversized
                 )
               )

      assert {:error, :apiserver_version_too_long} =
               admit(
                 put_in(
                   @valid_input,
                   [:evidence, :service_status, :apiserver_version],
                   oversized
                 )
               )

      assert {:error, :platform_too_long} =
               admit(
                 put_in(
                   @valid_input,
                   [:evidence, :dependency_baseline, :platform],
                   oversized
                 )
               )

      assert {:error, :image_name_too_long} =
               admit(
                 put_in(
                   @valid_input,
                   [:evidence, :image_inspect, :configuration, :name],
                   oversized
                 )
               )

      assert {:error, :toolchain_erlang_too_long} =
               admit(put_in(@valid_input, [:policy, :toolchain, :erlang], oversized))
    end

    test "rejects oversized maps and lists without raising" do
      huge_map =
        Map.new(1..200, fn i -> {:"k#{i}", i} end)

      assert {:error, :map_too_large} =
               admit(Map.merge(@valid_input, huge_map))

      huge_variants = List.duplicate(@valid_arm64_variant, 64)

      assert {:error, :too_many_variants} =
               admit(put_in(@valid_input, [:evidence, :image_inspect, :variants], huge_variants))
    end

    test "public new/2 returns errors for malformed inputs rather than raising" do
      malformed = [
        nil,
        :atom,
        42,
        [policy: @valid_policy],
        %{policy: "nope", evidence: @valid_evidence},
        %{policy: @valid_policy, evidence: "nope"},
        %{policy: @valid_policy, evidence: Map.put(@valid_evidence, :runtime, [])},
        %{policy: @valid_policy, evidence: Map.put(@valid_evidence, :control_plane, [])},
        %{
          policy: @valid_policy,
          evidence: Map.put(@valid_evidence, :control_plane, %{cli: "nope"})
        }
      ]

      for input <- malformed do
        assert match?({:error, _}, admit(input)),
               "expected error for #{inspect(input)}"
      end

      assert {:error, :invalid_request} =
               AppleContainerAdmissionCore.new(@valid_input, "not-bindings")

      assert {:error, :invalid_request} =
               AppleContainerAdmissionCore.new(@valid_input, [])
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

      assert {:ok, _} = admit(@valid_input)

      for {path, value} <- bound_mutations do
        input = put_in(@valid_input, path, value)

        assert match?({:error, _}, admit(input)),
               "expected fail-closed for mutation #{inspect(path)}=#{inspect(value)}"
      end
    end
  end

  describe "security regression: control-plane composition" do
    @tag :security_regression
    test "new/1 always requires control_plane_bindings for every term" do
      terms = [
        nil,
        :atom,
        42,
        "nope",
        [],
        %{},
        @valid_input,
        %{
          policy: @valid_policy,
          evidence: @valid_evidence,
          control_plane: @control_plane_evidence
        }
      ]

      for term <- terms do
        assert {:error, :control_plane_bindings_required} =
                 AppleContainerAdmissionCore.new(term)
      end
    end

    @tag :security_regression
    test "changing only aggregate runtime.executable_sha256 to another valid hex rejects" do
      input =
        put_in(@valid_input, [:evidence, :runtime, :executable_sha256], @other_hex)

      assert {:error, :aggregate_executable_sha256_mismatch} = admit(input)
      refute match?({:ok, _}, admit(input))
    end

    @tag :security_regression
    test "aggregate CLI+service 1.1.1 cannot override signed child API 1.1.0" do
      input =
        @valid_input
        |> put_in([:evidence, :runtime, :cli_version], "1.1.1")
        |> put_in(
          [:evidence, :service_status, :apiserver_version],
          "container-apiserver version 1.1.1 (build: release, commit: abcdef1)"
        )

      # Nested control-plane remains at signed 1.1.0; service self-report + CLI
      # must not establish a different admitted API version.
      assert {:error, :aggregate_cli_version_mismatch} = admit(input)
      refute match?({:ok, _}, admit(input))
    end

    @tag :security_regression
    test "changing nested child CLI identity SHA while startup binding remains fixed rejects" do
      altered_identity = %{@cli_identity | sha256: @other_hex}

      input =
        put_in(
          @valid_input,
          [:evidence, :control_plane, :cli, :identity],
          altered_identity
        )

      assert {:error, :cli_identity_mismatch} = admit(input)
      refute match?({:ok, _}, admit(input))
    end

    @tag :security_regression
    test "missing or malformed nested control-plane evidence and bindings fail closed" do
      assert {:error, :missing_control_plane} =
               admit(%{
                 policy: @valid_policy,
                 evidence: Map.delete(@valid_evidence, :control_plane)
               })

      assert {:error, {:unsupported_keys, :evidence}} =
               admit(
                 put_in(
                   @valid_input,
                   [:evidence],
                   Map.put(@valid_evidence, :extra_control, %{})
                 )
               )

      assert {:error, {:duplicate_key_alias, :evidence, :control_plane}} =
               admit(
                 put_in(
                   @valid_input,
                   [:evidence],
                   Map.put(@valid_evidence, "control_plane", @control_plane_evidence)
                 )
               )

      assert {:error, :invalid_control_plane} =
               admit(put_in(@valid_input, [:evidence, :control_plane], "nope"))

      assert {:error, _} = admit(@valid_input, %{})
      assert {:error, _} = admit(@valid_input, "bindings")
      assert {:error, _} = admit(@valid_input, Map.delete(@control_plane_bindings, :cli_identity))
    end
  end

  # Local helper: ordinary aggregate tests use startup bindings via new/2.
  defp admit(input, bindings \\ @control_plane_bindings) do
    AppleContainerAdmissionCore.new(input, bindings)
  end
end
