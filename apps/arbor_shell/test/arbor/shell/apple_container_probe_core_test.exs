defmodule Arbor.Shell.AppleContainerProbeCoreTest do
  @moduledoc """
  Focused pure projection tests for Apple Container 1.1.x probe evidence.

  Slice ownership is limited to the pure probe core. The production
  `Arbor.Shell.execute_spawn_capable/3` is the public Apple Container spawn facade.
  """

  use ExUnit.Case, async: true

  alias Arbor.Shell
  alias Arbor.Shell.AppleContainerProbeCore, as: Core

  @moduletag :fast

  @uid "501"
  @app_root_no_slash "/Users/arbor/Library/Application Support/com.apple.container"
  @install_root "/usr/local/"
  @api_full "container-apiserver version 1.1.0 (build: release, commit: unspeci)"
  @workload_digest "sha256:" <> String.duplicate("a", 64)
  @workload_manifest "sha256:" <> String.duplicate("b", 64)
  @vminit_digest "sha256:" <> String.duplicate("c", 64)
  @vminit_manifest "sha256:" <> String.duplicate("d", 64)
  @invalid_utf8 <<0xC3, 0x28>>

  @system_version_json Jason.encode!([
                         %{
                           "appName" => "container",
                           "buildType" => "release",
                           "commit" => "unspecified",
                           "version" => "1.1.0"
                         },
                         %{
                           "appName" => "container-apiserver",
                           "buildType" => "release",
                           "commit" => "unspecified",
                           "version" =>
                             "container-apiserver version 1.1.0 (build: release, commit: unspeci)"
                         }
                       ])

  @system_status_json Jason.encode!(%{
                        "apiServerAppName" => "container-apiserver",
                        "apiServerBuild" => "release",
                        "apiServerCommit" => "unspecified",
                        "apiServerVersion" =>
                          "container-apiserver version 1.1.0 (build: release, commit: unspeci)",
                        "appRoot" =>
                          "/Users/arbor/Library/Application Support/com.apple.container/",
                        "installRoot" => "/usr/local/",
                        "status" => "running"
                      })

  @system_status_with_log_root Jason.encode!(%{
                                 "apiServerAppName" => "container-apiserver",
                                 "apiServerBuild" => "release",
                                 "apiServerCommit" => "unspecified",
                                 "apiServerVersion" =>
                                   "container-apiserver version 1.1.0 (build: release, commit: unspeci)",
                                 "appRoot" =>
                                   "/Users/arbor/Library/Application Support/com.apple.container/",
                                 "installRoot" => "/usr/local/",
                                 "logRoot" => "/Users/arbor/Library/Logs/com.apple.container",
                                 "status" => "running"
                               })

  @plugin_toml """
  abstract = "Linux container runtime plugin"
  author = "Apple"
  version = 0.1

  [servicesConfig]
  loadAtBoot = false
  runAtLoad = false
  defaultArguments = []

  [[servicesConfig.services]]
  type = "runtime"
  """

  @launchctl_output """
  gui/501/com.apple.container.apiserver = {
  \tactive count = 2
  \tpath = /Users/arbor/Library/Application Support/com.apple.container/apiserver/apiserver.plist
  \ttype = LaunchAgent
  \tstate = running

  \tprogram = /usr/local/bin/container-apiserver
  \targuments = {
  \t\t/usr/local/bin/container-apiserver
  \t\tstart
  \t}

  \tinherited environment = {
  \t\tDISPLAY => /var/run/com.apple.launchd.gc5xeegCHU/org.xquartz:0
  \t\tSSH_AUTH_SOCK => /var/run/com.apple.launchd.Didhzubu3u/Listeners
  \t\tHTTP_PROXY => http://proxy.example:8080
  \t}

  \tdefault environment = {
  \t\tPATH => /usr/bin:/bin:/usr/sbin:/sbin
  \t}

  \tenvironment = {
  \t\tOSLogRateLimit => 64
  \t\tCONTAINER_INSTALL_ROOT => /usr/local
  \t\tCONTAINER_APP_ROOT => /Users/arbor/Library/Application Support/com.apple.container
  \t\tXPC_SERVICE_NAME => com.apple.container.apiserver
  \t}

  \tdomain = gui/501 [100025]
  \tpid = 59416
  \tendpoints = {
  \t\t"com.apple.container.apiserver" = {
  \t\t\tport = 0x9963f
  \t\t\tactive = 1
  \t\t}
  \t}

  \tjob state = running
  }
  """

  setup do
    {:ok, input: valid_input()}
  end

  describe "positive projection" do
    test "projects realistic 1.1.0 raw outputs into closed evidence fragments", %{input: input} do
      assert {:ok, projection} = Core.project(input)

      assert projection.host_platform == %{
               os: "macos",
               version: "26.5.2",
               architecture: "arm64"
             }

      assert projection.runtime == %{cli_version: "1.1.0", cli_build: "release"}

      assert projection.service_status == %{
               status: "running",
               install_root: @install_root,
               apiserver_version: @api_full,
               apiserver_build: "release"
             }

      assert projection.control_plane.cli == %{version: "1.1.0", build: "release"}
      assert projection.control_plane.apiserver.version == "1.1.0"
      assert projection.control_plane.apiserver.build == "release"

      launchd = projection.control_plane.apiserver.launchd
      assert launchd.label == "com.apple.container.apiserver"
      assert launchd.path == @app_root_no_slash <> "/apiserver/apiserver.plist"
      assert launchd.type == "LaunchAgent"
      assert launchd.state == "running"
      assert launchd.program == "/usr/local/bin/container-apiserver"
      assert launchd.argv == ["/usr/local/bin/container-apiserver", "start"]

      assert launchd.environment == %{
               "OSLogRateLimit" => "64",
               "CONTAINER_INSTALL_ROOT" => "/usr/local",
               "CONTAINER_APP_ROOT" => @app_root_no_slash,
               "XPC_SERVICE_NAME" => "com.apple.container.apiserver"
             }

      # Proxy values are preserved for the admission core to reject — never dropped.
      assert launchd.inherited_environment["HTTP_PROXY"] == "http://proxy.example:8080"
      assert launchd.inherited_environment["DISPLAY"] =~ "org.xquartz"
      assert launchd.inherited_environment["SSH_AUTH_SOCK"] =~ "Listeners"
      assert launchd.default_environment == %{"PATH" => "/usr/bin:/bin:/usr/sbin:/sbin"}

      assert projection.control_plane.service_status.app_root == @app_root_no_slash
      assert projection.control_plane.service_status.log_root == nil
      assert projection.control_plane.service_status.apiserver_version == "1.1.0"

      assert projection.control_plane.runtime_plugin.config == %{
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

      assert projection.image_inspect.configuration.descriptor.digest == @workload_digest
      assert projection.image_inspect.configuration.descriptor.media_type =~ "manifest"
      assert projection.image_inspect.configuration.name =~ "arbor/workload"
      assert [variant] = projection.image_inspect.variants
      assert variant.platform == %{os: "linux", architecture: "arm64", variant: "v8"}
      assert variant.config.os == "linux"
      assert variant.config.architecture == "arm64"
      assert variant.config.variant == "v8"
      assert variant.config.config["Env"] == ["PATH=/usr/local/bin"]
      assert variant.config.config["Labels"]["org.arbor.validation.schema"] == "1"
      refute Map.has_key?(variant, :history)
      refute Map.has_key?(projection.image_inspect.configuration, :creationDate)
      refute Map.has_key?(projection.image_inspect, :id)

      assert projection.vminit_image_inspect.configuration.descriptor.digest == @vminit_digest
      assert [vminit_variant] = projection.vminit_image_inspect.variants
      assert vminit_variant.platform.variant == "v8"
      refute Map.has_key?(vminit_variant.config, :config)

      shown = Core.show(projection)
      assert shown["host_platform"]["architecture"] == "arm64"
      assert shown["service_status"]["apiserver_version"] == @api_full
      assert shown["control_plane"]["service_status"]["app_root"] == @app_root_no_slash

      assert shown["control_plane"]["apiserver"]["launchd"]["inherited_environment"]["HTTP_PROXY"] ==
               "http://proxy.example:8080"

      refute Map.has_key?(shown, "system_version_json")
      refute Map.has_key?(shown, "launchctl_output")
      refute Map.has_key?(shown, "stdout")
      refute Map.has_key?(shown, "raw")
      assert Jason.encode!(shown)
    end

    test "normalizes appRoot trailing slash deterministically", %{input: input} do
      no_slash =
        put_in_status(input, %{
          "appRoot" => @app_root_no_slash,
          "logRoot" => nil
        })

      multi_slash =
        put_in_status(input, %{
          "appRoot" => @app_root_no_slash <> "///"
        })

      assert {:ok, a} = Core.project(no_slash)
      assert {:ok, b} = Core.project(multi_slash)
      assert a.control_plane.service_status.app_root == @app_root_no_slash
      assert b.control_plane.service_status.app_root == @app_root_no_slash
    end

    test "preserves non-nil logRoot", %{input: input} do
      input = Map.put(input, :system_status_json, @system_status_with_log_root)
      assert {:ok, projection} = Core.project(input)

      assert projection.control_plane.service_status.log_root ==
               "/Users/arbor/Library/Logs/com.apple.container"
    end

    test "accepts string-keyed request maps", %{input: input} do
      string_input =
        Map.new(input, fn {k, v} -> {Atom.to_string(k), v} end)

      assert {:ok, projection} = Core.project(string_input)
      assert projection.host_platform.architecture == "arm64"
    end

    test "is deterministic for the same input", %{input: input} do
      assert {:ok, a} = Core.project(input)
      assert {:ok, b} = Core.project(input)
      assert a == b
      assert Core.show(a) == Core.show(b)
    end
  end

  describe "adversarial inputs" do
    test "rejects malformed oversized and invalid UTF-8 without raising", %{input: input} do
      assert {:error, _} = Core.project(nil)
      assert {:error, _} = Core.project(%{})
      assert {:error, _} = Core.project("nope")

      assert {:error, {:unsupported_keys, :request}} =
               Core.project(Map.put(input, :extra, true))

      assert {:error, {:duplicate_key_alias, :request, :uid_output}} =
               Core.project(Map.put(input, "uid_output", @uid))

      assert {:error, :invalid_utf8} =
               Core.project(%{input | system_architecture: @invalid_utf8})

      assert {:error, :system_architecture_too_long} =
               Core.project(%{input | system_architecture: String.duplicate("a", 200)})

      assert {:error, :launchctl_output_too_long} =
               Core.project(%{input | launchctl_output: String.duplicate("x", 70_000)})

      assert {:error, :invalid_system_version_json} =
               Core.project(%{input | system_version_json: "{not-json"})

      assert {:error, :invalid_runtime_plugin_config_toml} =
               Core.project(%{input | runtime_plugin_config_toml: "[[[broken"})
    end

    test "rejects non-Apple-arm64 architectures", %{input: input} do
      for bad <- ["x86_64-apple-darwin", "aarch64-unknown-linux-gnu", "arm64", "amd64"] do
        assert {:error, :unsupported_system_architecture} =
                 Core.project(%{input | system_architecture: bad})
      end
    end

    test "rejects launchctl header/uid mismatch and incomplete root block", %{input: input} do
      bad_uid =
        String.replace(
          @launchctl_output,
          "gui/501/com.apple.container.apiserver",
          "gui/502/com.apple.container.apiserver",
          global: false
        )

      assert {:error, :launchctl_uid_mismatch} =
               Core.project(%{input | launchctl_output: bad_uid})

      incomplete = String.trim_trailing(@launchctl_output) |> String.trim_trailing("}")

      assert {:error, :incomplete_launchctl_block} =
               Core.project(%{input | launchctl_output: incomplete <> "\n"})
    end

    test "rejects missing and duplicate launchctl sections", %{input: input} do
      without_path =
        @launchctl_output
        |> String.split("\n")
        |> Enum.reject(&String.contains?(&1, "\tpath = "))
        |> Enum.join("\n")

      assert {:error, {:missing_launchd_field, :path}} =
               Core.project(%{input | launchctl_output: without_path})

      duplicate_path =
        String.replace(
          @launchctl_output,
          "\tpath = /Users/arbor/Library/Application Support/com.apple.container/apiserver/apiserver.plist\n",
          "\tpath = /tmp/a.plist\n\tpath = /tmp/b.plist\n"
        )

      assert {:error, {:duplicate_launchd_field, :path}} =
               Core.project(%{input | launchctl_output: duplicate_path})
    end

    test "preserves proxy env for later admission rejection and rejects malformed env lines", %{
      input: input
    } do
      assert {:ok, projection} = Core.project(input)
      assert projection.control_plane.apiserver.launchd.inherited_environment["HTTP_PROXY"]

      malformed =
        String.replace(
          @launchctl_output,
          "\t\tHTTP_PROXY => http://proxy.example:8080\n",
          "\t\tHTTP_PROXY = http://proxy.example:8080\n"
        )

      assert {:error, :malformed_launchctl_env} =
               Core.project(%{input | launchctl_output: malformed})
    end

    test "rejects version/status inconsistency", %{input: input} do
      bad_status =
        String.replace(
          @system_status_json,
          @api_full,
          "container-apiserver version 1.1.1 (build: release, commit: unspeci)"
        )

      assert {:error, :version_status_apiserver_version_mismatch} =
               Core.project(%{input | system_status_json: bad_status})

      bad_commit =
        String.replace(
          @system_status_json,
          "\"apiServerCommit\":\"unspecified\"",
          "\"apiServerCommit\":\"deadbeef\""
        )

      assert {:error, :version_status_commit_mismatch} =
               Core.project(%{input | system_status_json: bad_commit})
    end

    test "rejects extra TOML keys and non-runtime services", %{input: input} do
      extra = "extra = true\n" <> @plugin_toml

      assert {:error, {:unsupported_keys, :runtime_plugin_config}} =
               Core.project(%{input | runtime_plugin_config_toml: extra})

      extra_service_key =
        String.replace(@plugin_toml, "type = \"runtime\"", "type = \"runtime\"\nfoo = 1")

      assert {:error, {:unsupported_keys, :service_entry}} =
               Core.project(%{input | runtime_plugin_config_toml: extra_service_key})

      bad_service =
        String.replace(@plugin_toml, "type = \"runtime\"", "type = \"network\"")

      assert {:error, :plugin_services_config_mismatch} =
               Core.project(%{input | runtime_plugin_config_toml: bad_service})

      quoted_version = String.replace(@plugin_toml, "version = 0.1", ~s(version = "0.1"))

      assert {:error, :invalid_plugin_toml_version} =
               Core.project(%{input | runtime_plugin_config_toml: quoted_version})
    end

    test "rejects malformed image arrays descriptors and config", %{input: input} do
      assert {:error, :invalid_workload_image_array} =
               Core.project(%{input | workload_image_inspect_json: "[]"})

      assert {:error, :invalid_workload_image_array} =
               Core.project(%{
                 input
                 | workload_image_inspect_json: Jason.encode!([%{}, %{}])
               })

      bad_descriptor =
        workload_inspect()
        |> put_in([Access.at(0), "configuration", "descriptor", "digest"], "not-a-digest")
        |> Jason.encode!()

      assert {:error, :invalid_image_digest} =
               Core.project(%{input | workload_image_inspect_json: bad_descriptor})

      no_variants =
        workload_inspect()
        |> put_in([Access.at(0), "variants"], [])
        |> Jason.encode!()

      assert {:error, :missing_image_variants} =
               Core.project(%{input | workload_image_inspect_json: no_variants})
    end

    test "projection and show never include raw input strings", %{input: input} do
      assert {:ok, projection} = Core.project(input)
      shown = Core.show(projection)

      for payload <- [projection, shown, inspect(projection), inspect(shown)] do
        text = if is_binary(payload), do: payload, else: inspect(payload)
        refute text =~ "system_version_json"
        refute text =~ "launchctl_output"
        refute text =~ "workload_image_inspect_json"
        refute text =~ "runtime_plugin_config_toml"
        refute text =~ "active count = 2"
        refute text =~ ~s("appName")
      end
    end
  end

  describe "pure core constraints" do
    test "module source has no side-effect calls" do
      path =
        Path.expand(
          "../../../lib/arbor/shell/apple_container_probe_core.ex",
          __DIR__
        )

      source = File.read!(path)

      for forbidden <- [
            "File.",
            "System.",
            "Application.",
            "GenServer.",
            ":ets.",
            "IO.",
            "Process.",
            "DateTime.utc_now",
            "String.to_atom",
            "TrustedPath."
          ] do
        refute source =~ forbidden, "probe core must not call #{forbidden}"
      end
    end

    test "relative tool is pure preflight before admission" do
      assert {:error, {:invalid_tool_name, :relative_path}} =
               Shell.execute_spawn_capable("mix", ["test"], [])
    end
  end

  # --- Fixtures ---

  defp valid_input do
    %{
      system_architecture: "aarch64-apple-darwin24.0.0",
      sw_vers_output: "26.5.2\n",
      uid_output: @uid <> "\n",
      launchctl_output: @launchctl_output,
      system_version_json: @system_version_json,
      system_status_json: @system_status_json,
      workload_image_inspect_json: Jason.encode!(workload_inspect()),
      vminit_image_inspect_json: Jason.encode!(vminit_inspect()),
      runtime_plugin_config_toml: @plugin_toml
    }
  end

  defp workload_inspect do
    [
      %{
        "id" => String.duplicate("a", 64),
        "configuration" => %{
          "creationDate" => "2026-03-12T17:57:54Z",
          "descriptor" => %{
            "digest" => @workload_digest,
            "mediaType" => "application/vnd.docker.distribution.manifest.list.v2+json",
            "size" => 772
          },
          "name" => "127.0.0.1:0/arbor/workload@" <> @workload_digest
        },
        "variants" => [
          %{
            "digest" => @workload_manifest,
            "size" => 12_345,
            "platform" => %{
              "os" => "linux",
              "architecture" => "arm64",
              "variant" => "v8"
            },
            "config" => %{
              "os" => "linux",
              "architecture" => "arm64",
              "variant" => "v8",
              "history" => [%{"created_by" => "DROP"}],
              "rootfs" => %{"type" => "layers", "diff_ids" => []},
              "config" => %{
                "Cmd" => ["/bin/sh"],
                "Env" => ["PATH=/usr/local/bin"],
                "Labels" => %{
                  "org.arbor.validation.schema" => "1"
                },
                "WorkingDir" => "/"
              }
            }
          }
        ]
      }
    ]
  end

  defp vminit_inspect do
    [
      %{
        "id" => String.duplicate("c", 64),
        "configuration" => %{
          "creationDate" => "2026-01-01T00:00:00Z",
          "descriptor" => %{
            "digest" => @vminit_digest,
            "mediaType" => "application/vnd.oci.image.index.v1+json",
            "size" => 512
          },
          "name" => "127.0.0.1:0/arbor/vminit@" <> @vminit_digest
        },
        "variants" => [
          %{
            "digest" => @vminit_manifest,
            "platform" => %{
              "os" => "linux",
              "architecture" => "arm64",
              "variant" => "v8"
            },
            "config" => %{
              "os" => "linux",
              "architecture" => "arm64",
              "variant" => "v8"
            }
          }
        ]
      }
    ]
  end

  defp put_in_status(input, overrides) do
    status =
      input.system_status_json
      |> Jason.decode!()
      |> Map.merge(overrides)
      |> Jason.encode!()

    %{input | system_status_json: status}
  end
end
