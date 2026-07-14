defmodule Arbor.Shell.AppleContainerControlPlaneAdmissionCoreTest do
  @moduledoc """
  Focused pure adversarial tests for Apple Container control-plane admission.

  Slice ownership is limited to the pure core. The production
  `Arbor.Shell.execute_spawn_capable/3` facade remains
  `production_backend_missing`.
  """

  use ExUnit.Case, async: true

  alias Arbor.Shell
  alias Arbor.Shell.AppleContainerControlPlaneAdmissionCore, as: Core
  alias Arbor.Shell.TrustedPath.Identity

  @moduletag :fast

  @cli_sha String.duplicate("a", 64)
  @api_sha String.duplicate("b", 64)
  @plugin_sha String.duplicate("c", 64)
  @config_sha String.duplicate("d", 64)
  @kernel_sha String.duplicate("e", 64)
  @other_sha String.duplicate("f", 64)

  @app_root "/Users/arbor/Library/Application Support/com.apple.container"
  @kernel_path "/usr/local/share/container/kernels/default.kernel"
  @version "1.1.0"

  @invalid_utf8 <<0xC3, 0x28>>

  # Root-owned regular file mode without group/other write; executable bits set.
  @exec_mode 0o100755
  # Root-owned regular non-executable config/kernel mode without group/other write.
  @file_mode 0o100644

  setup do
    bindings = valid_bindings()
    evidence = valid_evidence(bindings)
    {:ok, bindings: bindings, evidence: evidence}
  end

  describe "positive admission" do
    test "admits complete bindings + evidence and binds receipt/show fields", %{
      bindings: bindings,
      evidence: evidence
    } do
      assert {:ok, receipt} = Core.new(bindings, evidence)

      assert receipt.admitted == true
      assert receipt.app_root == @app_root

      assert receipt.cli == %{
               path: Core.cli_path(),
               version: @version,
               build: "release",
               sha256: @cli_sha,
               signing_identifier: "com.apple.container.cli",
               team_id: Core.team_id(),
               designated_requirement: Core.cli_designated_requirement(),
               codesign_verified: true
             }

      assert receipt.apiserver.path == Core.apiserver_path()
      assert receipt.apiserver.version == @version
      assert receipt.apiserver.sha256 == @api_sha

      assert receipt.apiserver.launchd == %{
               label: "com.apple.container.apiserver",
               path: @app_root <> "/apiserver/apiserver.plist",
               type: "LaunchAgent",
               state: "running",
               program: Core.apiserver_path(),
               argv: [Core.apiserver_path(), "start"],
               environment: %{
                 "CONTAINER_APP_ROOT" => @app_root,
                 "CONTAINER_INSTALL_ROOT" => "/usr/local"
               },
               inherited_environment_checked: true,
               default_environment_checked: true,
               proxy_free: true
             }

      assert receipt.runtime_plugin.path == Core.plugin_path()
      assert receipt.runtime_plugin.sha256 == @plugin_sha
      assert receipt.runtime_plugin.config.path == Core.plugin_config_path()
      assert receipt.runtime_plugin.config.sha256 == @config_sha
      assert receipt.runtime_plugin.config.abstract == "Linux container runtime plugin"
      assert receipt.runtime_plugin.config.author == "Apple"
      assert receipt.runtime_plugin.config.version == "0.1"

      assert receipt.runtime_plugin.config.services_config == %{
               load_at_boot: false,
               run_at_load: false,
               default_arguments: [],
               services: [%{type: "runtime"}]
             }

      assert receipt.user_plugin_root == %{
               path: Core.user_plugin_root_path(),
               status: "absent"
             }

      assert receipt.kernel == %{path: @kernel_path, sha256: @kernel_sha}

      assert receipt.service == %{
               status: "running",
               install_root: "/usr/local/",
               corroborated: true
             }

      shown = Core.show(receipt)
      assert shown["admitted"] == true
      assert shown["cli"]["version"] == @version
      assert shown["cli"]["sha256"] == @cli_sha
      assert shown["cli"]["designated_requirement"] == Core.cli_designated_requirement()
      assert shown["apiserver"]["version"] == @version
      assert shown["apiserver"]["sha256"] == @api_sha
      assert shown["apiserver"]["launchd"]["program"] == Core.apiserver_path()
      assert shown["apiserver"]["launchd"]["argv"] == [Core.apiserver_path(), "start"]
      assert shown["apiserver"]["launchd"]["path"] == @app_root <> "/apiserver/apiserver.plist"
      assert shown["apiserver"]["launchd"]["type"] == "LaunchAgent"
      assert shown["apiserver"]["launchd"]["state"] == "running"

      assert shown["apiserver"]["launchd"]["environment"] == %{
               "CONTAINER_APP_ROOT" => @app_root,
               "CONTAINER_INSTALL_ROOT" => "/usr/local"
             }

      assert shown["apiserver"]["launchd"]["inherited_environment_checked"] == true
      assert shown["apiserver"]["launchd"]["default_environment_checked"] == true
      assert shown["apiserver"]["launchd"]["proxy_free"] == true
      refute Map.has_key?(shown["apiserver"]["launchd"], "inherited_environment")
      refute Map.has_key?(shown["apiserver"]["launchd"], "default_environment")
      refute Map.has_key?(shown["apiserver"]["launchd"], "XPC_SERVICE_NAME")
      refute Map.has_key?(shown["apiserver"]["launchd"]["environment"], "XPC_SERVICE_NAME")
      refute Map.has_key?(shown["apiserver"]["launchd"]["environment"], "OSLogRateLimit")

      assert shown["runtime_plugin"]["path"] == Core.plugin_path()
      assert shown["runtime_plugin"]["sha256"] == @plugin_sha
      assert shown["runtime_plugin"]["config"]["sha256"] == @config_sha

      assert shown["runtime_plugin"]["config"]["services_config"]["services"] == [
               %{"type" => "runtime"}
             ]

      assert shown["user_plugin_root"]["status"] == "absent"
      assert shown["kernel"]["path"] == @kernel_path
      assert shown["kernel"]["sha256"] == @kernel_sha
      assert shown["service"]["corroborated"] == true
      refute Map.has_key?(shown, "stdout")
      refute Map.has_key?(shown, "raw")
      assert Jason.encode!(shown)
    end

    test "is deterministic for the same input", %{bindings: bindings, evidence: evidence} do
      assert {:ok, a} = Core.new(bindings, evidence)
      assert {:ok, b} = Core.new(bindings, evidence)
      assert a == b
      assert Core.show(a) == Core.show(b)
    end

    test "accepts string-keyed bindings and evidence maps", %{
      bindings: bindings,
      evidence: evidence
    } do
      string_bindings = stringify_keys(bindings)
      string_evidence = stringify_nested_evidence(evidence)
      assert {:ok, receipt} = Core.new(string_bindings, string_evidence)
      assert receipt.admitted == true
      assert receipt.cli.version == @version
    end
  end

  describe "security regression: identity binding" do
    @tag :security_regression
    test "changing only CLI evidence identity SHA to another valid hex fails", %{
      bindings: bindings,
      evidence: evidence
    } do
      altered =
        put_in(evidence, [:cli, :identity], %{
          evidence.cli.identity
          | sha256: @other_sha
        })

      assert {:error, :cli_identity_mismatch} = Core.new(bindings, altered)
      refute match?({:ok, _}, Core.new(bindings, altered))
    end

    @tag :security_regression
    test "service API version matching CLI cannot override different signed API version", %{
      bindings: bindings,
      evidence: evidence
    } do
      # Signed CLI remains 1.1.0; signed API is different; service tracks CLI only.
      evidence =
        evidence
        |> put_in([:apiserver, :version], "1.1.1")
        |> put_in([:service_status, :apiserver_version], "1.1.0")

      assert {:error, reason} = Core.new(bindings, evidence)
      assert reason in [:cli_api_version_mismatch, :service_apiserver_version_mismatch]
      refute match?({:ok, _}, Core.new(bindings, evidence))
    end

    @tag :security_regression
    test "service cannot corroborate CLI while disagreeing with signed API when versions otherwise match",
         %{
           bindings: bindings,
           evidence: evidence
         } do
      # CLI and signed API agree on 1.1.0; service reports a different version.
      evidence = put_in(evidence, [:service_status, :apiserver_version], "1.1.1")
      assert {:error, :service_apiserver_version_mismatch} = Core.new(bindings, evidence)
    end
  end

  describe "identity and path mutations" do
    test "rejects fixed-path identity path swaps", %{bindings: bindings, evidence: evidence} do
      for {binding_key, evidence_path, mismatch} <- [
            {:cli_identity, [:cli, :identity], :identity_path_mismatch},
            {:apiserver_identity, [:apiserver, :identity], :identity_path_mismatch},
            {:runtime_plugin_identity, [:runtime_plugin, :identity], :identity_path_mismatch},
            {:runtime_plugin_config_identity, [:runtime_plugin, :config_identity],
             :identity_path_mismatch}
          ] do
        bad_identity = %{Map.fetch!(bindings, binding_key) | path: "/tmp/evil"}
        bad_bindings = Map.put(bindings, binding_key, bad_identity)

        bad_evidence =
          case evidence_path do
            [top, nested] -> put_in(evidence, [top, nested], bad_identity)
            [top] -> Map.put(evidence, top, bad_identity)
          end

        assert {:error, ^mismatch} = Core.new(bad_bindings, bad_evidence)
      end
    end

    test "rejects non-root, group-writable, and non-executable executable bindings", %{
      bindings: bindings,
      evidence: evidence
    } do
      cli = bindings.cli_identity

      assert {:error, :identity_not_root_owned} =
               Core.new(%{bindings | cli_identity: %{cli | uid: 501}}, evidence)

      assert {:error, :identity_group_or_other_writable} =
               Core.new(%{bindings | cli_identity: %{cli | mode: 0o100775}}, evidence)

      assert {:error, :identity_not_executable} =
               Core.new(%{bindings | cli_identity: %{cli | mode: @file_mode}}, evidence)

      assert {:error, :identity_executable_flag_mismatch} =
               Core.new(
                 %{bindings | cli_identity: %{cli | executable_required: false}},
                 evidence
               )
    end

    test "rejects evidence identity replacements that only change device/inode", %{
      bindings: bindings,
      evidence: evidence
    } do
      altered = put_in(evidence, [:cli, :identity], %{evidence.cli.identity | inode: 999_999})
      assert {:error, :cli_identity_mismatch} = Core.new(bindings, altered)

      altered =
        put_in(evidence, [:apiserver, :identity], %{evidence.apiserver.identity | device: 42})

      assert {:error, :apiserver_identity_mismatch} = Core.new(bindings, altered)

      altered =
        put_in(evidence, [:runtime_plugin, :identity], %{
          evidence.runtime_plugin.identity
          | size: evidence.runtime_plugin.identity.size + 1
        })

      assert {:error, :runtime_plugin_identity_mismatch} = Core.new(bindings, altered)

      altered =
        put_in(evidence, [:runtime_plugin, :config_identity], %{
          evidence.runtime_plugin.config_identity
          | sha256: @other_sha
        })

      assert {:error, :runtime_plugin_config_identity_mismatch} = Core.new(bindings, altered)

      altered =
        Map.put(evidence, :kernel_identity, %{evidence.kernel_identity | sha256: @other_sha})

      assert {:error, :kernel_identity_mismatch} = Core.new(bindings, altered)
    end

    test "rejects kernel path that is relative or non-canonical", %{
      bindings: bindings,
      evidence: evidence
    } do
      for bad_path <- ["relative.kernel", "/usr/local/../evil", "/tmp//kernel", "/tmp/kernel/"] do
        identity = %{bindings.kernel_identity | path: bad_path}
        bad_bindings = %{bindings | kernel_identity: identity}
        bad_evidence = %{evidence | kernel_identity: identity}
        assert {:error, _reason} = Core.new(bad_bindings, bad_evidence)
      end
    end

    test "bounds identity paths before text validation", %{
      bindings: bindings,
      evidence: evidence
    } do
      oversized = "/" <> String.duplicate("a", 4_096)
      identity = %{bindings.cli_identity | path: oversized}

      assert {:error, :identity_path_too_long} =
               Core.new(
                 %{bindings | cli_identity: identity},
                 put_in(evidence, [:cli, :identity], identity)
               )
    end
  end

  describe "signing and version mutations" do
    test "rejects signing identifier/team/requirement/status mutations", %{
      bindings: bindings,
      evidence: evidence
    } do
      assert {:error, :signing_identifier_mismatch} =
               Core.new(
                 bindings,
                 put_in(evidence, [:cli, :signing, :identifier], "com.evil.cli")
               )

      assert {:error, :signing_team_mismatch} =
               Core.new(bindings, put_in(evidence, [:cli, :signing, :team_id], "AAAAAAAAAA"))

      assert {:error, :designated_requirement_mismatch} =
               Core.new(
                 bindings,
                 put_in(
                   evidence,
                   [:apiserver, :signing, :designated_requirement],
                   "identifier \"x\""
                 )
               )

      assert {:error, :verified_against_mismatch} =
               Core.new(
                 bindings,
                 put_in(evidence, [:runtime_plugin, :signing, :verified_against], "other")
               )

      assert {:error, :codesign_not_verified} =
               Core.new(bindings, put_in(evidence, [:cli, :signing, :status], "invalid"))
    end

    test "rejects non-1.1.x and non-release builds", %{bindings: bindings, evidence: evidence} do
      assert {:error, :version_not_supported} =
               Core.new(bindings, put_in(evidence, [:cli, :version], "1.2.0"))

      assert {:error, :version_not_supported} =
               Core.new(bindings, put_in(evidence, [:apiserver, :version], "2.0.0"))

      assert {:error, :non_release_cli_build} =
               Core.new(bindings, put_in(evidence, [:cli, :build], "debug"))

      assert {:error, :non_release_apiserver_build} =
               Core.new(bindings, put_in(evidence, [:apiserver, :build], "debug"))

      # CLI and API must exact-equal even when both are on the 1.1 line.
      evidence =
        evidence
        |> put_in([:cli, :version], "1.1.0")
        |> put_in([:apiserver, :version], "1.1.1")
        |> put_in([:service_status, :apiserver_version], "1.1.1")

      assert {:error, :cli_api_version_mismatch} = Core.new(bindings, evidence)
    end
  end

  describe "launchd mutations" do
    test "admits realistic launchctl projection with system job keys and safe inherited/default env",
         %{
           bindings: bindings,
           evidence: evidence
         } do
      launchd =
        evidence.apiserver.launchd
        |> Map.put(:environment, %{
          "CONTAINER_APP_ROOT" => @app_root,
          "CONTAINER_INSTALL_ROOT" => "/usr/local",
          "XPC_SERVICE_NAME" => "com.apple.container.apiserver",
          "OSLogRateLimit" => "64"
        })
        |> Map.put(:inherited_environment, %{
          "HOME" => "/Users/arbor",
          "TMPDIR" => "/var/folders/xx/secret/T/",
          "PATH" => "/usr/bin:/bin",
          "XPC_FLAGS" => "0x0"
        })
        |> Map.put(:default_environment, %{
          "PATH" => "/usr/bin:/bin:/usr/sbin:/sbin"
        })

      evidence = put_in(evidence, [:apiserver, :launchd], launchd)
      assert {:ok, receipt} = Core.new(bindings, evidence)

      # Authority receipt keeps only safe job env; system keys and inherited values are redacted.
      assert receipt.apiserver.launchd.environment == %{
               "CONTAINER_APP_ROOT" => @app_root,
               "CONTAINER_INSTALL_ROOT" => "/usr/local"
             }

      assert receipt.apiserver.launchd.inherited_environment_checked == true
      assert receipt.apiserver.launchd.default_environment_checked == true
      assert receipt.apiserver.launchd.proxy_free == true
      refute Map.has_key?(receipt.apiserver.launchd, :inherited_environment)
      refute Map.has_key?(receipt.apiserver.launchd, :default_environment)

      shown = Core.show(receipt)
      refute Map.has_key?(shown["apiserver"]["launchd"], "inherited_environment")
      refute Map.has_key?(shown["apiserver"]["launchd"], "default_environment")
      # Inherited TMPDIR secret path must not appear; app_root itself is authority data.
      refute inspect(shown) =~ "secret"
      refute inspect(shown) =~ "/var/folders/xx/secret"
      refute inspect(receipt) =~ "secret"
      refute inspect(receipt) =~ "XPC_FLAGS"
    end

    test "rejects label/path/type/state/program/argv mutations", %{
      bindings: bindings,
      evidence: evidence
    } do
      assert {:error, :launchd_label_mismatch} =
               Core.new(
                 bindings,
                 put_in(evidence, [:apiserver, :launchd, :label], "com.evil.apiserver")
               )

      assert {:error, :launchd_path_mismatch} =
               Core.new(
                 bindings,
                 put_in(
                   evidence,
                   [:apiserver, :launchd, :path],
                   "/tmp/evil/apiserver/apiserver.plist"
                 )
               )

      assert {:error, :launchd_type_mismatch} =
               Core.new(
                 bindings,
                 put_in(evidence, [:apiserver, :launchd, :type], "LaunchDaemon")
               )

      assert {:error, :launchd_state_mismatch} =
               Core.new(bindings, put_in(evidence, [:apiserver, :launchd, :state], "not running"))

      assert {:error, :launchd_program_mismatch} =
               Core.new(
                 bindings,
                 put_in(evidence, [:apiserver, :launchd, :program], "/tmp/apiserver")
               )

      assert {:error, :launchd_debug_forbidden} =
               Core.new(
                 bindings,
                 put_in(evidence, [:apiserver, :launchd, :argv], [
                   Core.apiserver_path(),
                   "start",
                   "--debug"
                 ])
               )

      assert {:error, :launchd_argv_mismatch} =
               Core.new(
                 bindings,
                 put_in(evidence, [:apiserver, :launchd, :argv], [Core.apiserver_path()])
               )
    end

    test "accepts allowed launchd system job keys and rejects unknown job keys", %{
      bindings: bindings,
      evidence: evidence
    } do
      allowed =
        put_in(evidence, [:apiserver, :launchd, :environment], %{
          "CONTAINER_APP_ROOT" => @app_root,
          "CONTAINER_INSTALL_ROOT" => "/usr/local",
          "XPC_SERVICE_NAME" => "com.apple.container.apiserver",
          "OSLogRateLimit" => "0"
        })

      assert {:ok, _} = Core.new(bindings, allowed)

      assert {:error, :launchd_environment_mismatch} =
               Core.new(
                 bindings,
                 put_in(evidence, [:apiserver, :launchd, :environment], %{
                   "CONTAINER_APP_ROOT" => @app_root,
                   "CONTAINER_INSTALL_ROOT" => "/usr/local",
                   "XPC_SERVICE_NAME" => "com.evil.service"
                 })
               )

      assert {:error, :launchd_environment_mismatch} =
               Core.new(
                 bindings,
                 put_in(evidence, [:apiserver, :launchd, :environment], %{
                   "CONTAINER_APP_ROOT" => @app_root,
                   "CONTAINER_INSTALL_ROOT" => "/usr/local",
                   "OSLogRateLimit" => "not-a-number"
                 })
               )

      assert {:error, :launchd_environment_forbidden} =
               Core.new(
                 bindings,
                 put_in(evidence, [:apiserver, :launchd, :environment], %{
                   "CONTAINER_APP_ROOT" => @app_root,
                   "CONTAINER_INSTALL_ROOT" => "/usr/local",
                   "EXTRA_JOB_KEY" => "nope"
                 })
               )

      assert {:error, :launchd_environment_mismatch} =
               Core.new(
                 bindings,
                 put_in(evidence, [:apiserver, :launchd, :environment], %{
                   "CONTAINER_APP_ROOT" => "/evil/app",
                   "CONTAINER_INSTALL_ROOT" => "/usr/local"
                 })
               )
    end

    test "rejects proxy, unexpected CONTAINER_, and log-root keys in each environment section", %{
      bindings: bindings,
      evidence: evidence
    } do
      forbidden_cases = [
        {:environment, "HTTP_PROXY", "http://evil.test"},
        {:environment, "Https_Proxy", "http://evil.test"},
        {:environment, "ALL_PROXY", "socks5://evil.test"},
        {:environment, "no_proxy", "*"},
        {:environment, "CONTAINER_LOG_ROOT", "/tmp/logs"},
        {:environment, "CONTAINER_DEBUG", "1"},
        {:inherited_environment, "http_proxy", "http://evil.test"},
        {:inherited_environment, "HTTPS_PROXY", "http://evil.test"},
        {:inherited_environment, "CONTAINER_FOO", "bar"},
        {:inherited_environment, "container_log_root", "/tmp/logs"},
        {:default_environment, "Http_Proxy", "http://evil.test"},
        {:default_environment, "NO_PROXY", "evil.test"},
        {:default_environment, "CONTAINER_INSTALL_ROOT_EXTRA", "/evil"},
        {:default_environment, "MY_LOG_ROOT", "/tmp/logs"}
      ]

      for {section, key, value} <- forbidden_cases do
        base = Map.fetch!(evidence.apiserver.launchd, section)
        altered = Map.put(base, key, value)

        assert {:error, reason} =
                 Core.new(bindings, put_in(evidence, [:apiserver, :launchd, section], altered))

        assert reason in [:launchd_environment_forbidden, :launchd_environment_mismatch],
               "expected forbid for #{section}/#{key}, got #{inspect(reason)}"
      end
    end

    @tag :security_regression
    test "security regression: proxy in inherited or default environment cannot be dropped and admitted",
         %{
           bindings: bindings,
           evidence: evidence
         } do
      # A parser that silently discarded inherited/default would admit this input.
      # The pure core must reject before any section can be dropped from the receipt.
      for {section, proxy_key} <- [
            {:inherited_environment, "HTTP_PROXY"},
            {:inherited_environment, "https_proxy"},
            {:default_environment, "ALL_PROXY"},
            {:default_environment, "No_Proxy"}
          ] do
        poisoned =
          put_in(
            evidence,
            [:apiserver, :launchd, section],
            Map.put(Map.fetch!(evidence.apiserver.launchd, section), proxy_key, "http://evil")
          )

        assert {:error, :launchd_environment_forbidden} = Core.new(bindings, poisoned)
        refute match?({:ok, _}, Core.new(bindings, poisoned))
      end
    end

    test "receipt redaction never exposes raw inherited or default environment values", %{
      bindings: bindings,
      evidence: evidence
    } do
      secret_socket = "/var/folders/xx/user-secret/T/com.apple.launchd.ABC/Listeners"

      evidence =
        put_in(evidence, [:apiserver, :launchd, :inherited_environment], %{
          "HOME" => "/Users/secret-user",
          "XPC_SERVICE_NAME" => secret_socket
        })
        |> put_in([:apiserver, :launchd, :default_environment], %{
          "TMPDIR" => "/private/var/folders/xx/user-secret/T/"
        })
        |> put_in([:apiserver, :launchd, :environment], %{
          "CONTAINER_APP_ROOT" => @app_root,
          "CONTAINER_INSTALL_ROOT" => "/usr/local",
          "XPC_SERVICE_NAME" => "com.apple.container.apiserver",
          "OSLogRateLimit" => "64"
        })

      assert {:ok, receipt} = Core.new(bindings, evidence)
      shown = Core.show(receipt)

      for payload <- [receipt, shown, inspect(receipt), inspect(shown)] do
        text = if is_binary(payload), do: payload, else: inspect(payload)
        refute text =~ "secret-user"
        refute text =~ "user-secret"
        refute text =~ secret_socket
        refute text =~ "Listeners"
      end

      refute Map.has_key?(receipt.apiserver.launchd, :inherited_environment)
      refute Map.has_key?(receipt.apiserver.launchd, :default_environment)
      refute Map.has_key?(shown["apiserver"]["launchd"], "inherited_environment")
      refute Map.has_key?(shown["apiserver"]["launchd"], "default_environment")
    end

    test "rejects invalid app_root bindings", %{bindings: bindings, evidence: evidence} do
      for bad_root <- [
            "relative",
            "/tmp/../evil",
            "/tmp//app",
            "/tmp/app/",
            <<"/tmp/", 0>>,
            @invalid_utf8,
            String.duplicate("a", 5_000)
          ] do
        bad_bindings = %{bindings | app_root: bad_root}

        bad_evidence =
          evidence
          |> put_in([:apiserver, :launchd, :path], bad_root <> "/apiserver/apiserver.plist")
          |> put_in([:apiserver, :launchd, :environment], %{
            "CONTAINER_APP_ROOT" => bad_root,
            "CONTAINER_INSTALL_ROOT" => "/usr/local"
          })

        assert {:error, _reason} = Core.new(bad_bindings, bad_evidence)
      end
    end
  end

  describe "plugin and shadow-root mutations" do
    test "rejects present shadow root and path swaps", %{bindings: bindings, evidence: evidence} do
      assert {:error, :user_plugin_root_not_absent} =
               Core.new(
                 bindings,
                 put_in(evidence, [:user_plugin_root, :status], "present")
               )

      assert {:error, :user_plugin_root_path_mismatch} =
               Core.new(
                 bindings,
                 put_in(evidence, [:user_plugin_root, :path], "/tmp/plugins")
               )
    end

    test "rejects weakened or expanded plugin config", %{bindings: bindings, evidence: evidence} do
      assert {:error, :plugin_services_config_mismatch} =
               Core.new(
                 bindings,
                 put_in(
                   evidence,
                   [:runtime_plugin, :config, :services_config, :load_at_boot],
                   true
                 )
               )

      assert {:error, :plugin_services_config_mismatch} =
               Core.new(
                 bindings,
                 put_in(
                   evidence,
                   [:runtime_plugin, :config, :services_config, :run_at_load],
                   true
                 )
               )

      assert {:error, :plugin_services_config_mismatch} =
               Core.new(
                 bindings,
                 put_in(
                   evidence,
                   [:runtime_plugin, :config, :services_config, :default_arguments],
                   ["--debug"]
                 )
               )

      assert {:error, :plugin_services_config_mismatch} =
               Core.new(
                 bindings,
                 put_in(evidence, [:runtime_plugin, :config, :services_config, :services], [
                   %{type: "runtime"},
                   %{type: "network"}
                 ])
               )

      assert {:error, :plugin_abstract_mismatch} =
               Core.new(
                 bindings,
                 put_in(evidence, [:runtime_plugin, :config, :abstract], "evil")
               )

      assert {:error, :plugin_author_mismatch} =
               Core.new(bindings, put_in(evidence, [:runtime_plugin, :config, :author], "Evil"))

      assert {:error, :plugin_config_version_mismatch} =
               Core.new(bindings, put_in(evidence, [:runtime_plugin, :config, :version], "0.2"))

      assert {:error, {:unsupported_keys, :plugin_config}} =
               Core.new(
                 bindings,
                 put_in(
                   evidence,
                   [:runtime_plugin, :config],
                   Map.put(evidence.runtime_plugin.config, :extra, true)
                 )
               )
    end
  end

  describe "malformed inputs never raise" do
    test "invalid UTF-8, oversize, unknown keys, and duplicates fail closed", %{
      bindings: bindings,
      evidence: evidence
    } do
      assert {:error, _} = Core.new(nil, evidence)
      assert {:error, _} = Core.new(bindings, nil)
      assert {:error, _} = Core.new(%{}, %{})
      assert {:error, _} = Core.new([:not_a_map], evidence)
      assert {:error, _} = Core.new(bindings, "nope")

      assert {:error, {:unsupported_keys, :bindings}} =
               Core.new(Map.put(bindings, :extra, true), evidence)

      assert {:error, {:unsupported_keys, :evidence}} =
               Core.new(bindings, Map.put(evidence, :extra, true))

      assert {:error, {:duplicate_key_alias, :bindings, :app_root}} =
               Core.new(Map.put(bindings, "app_root", @app_root), evidence)

      assert {:error, {:duplicate_key_alias, :cli, :version}} =
               Core.new(
                 bindings,
                 put_in(evidence, [:cli], Map.put(evidence.cli, "version", @version))
               )

      assert {:error, _} =
               Core.new(bindings, put_in(evidence, [:cli, :version], @invalid_utf8))

      assert {:error, _} =
               Core.new(
                 bindings,
                 put_in(evidence, [:cli, :version], String.duplicate("1", 200))
               )

      assert {:error, _} =
               Core.new(bindings, put_in(evidence, [:cli, :identity], %{path: Core.cli_path()}))

      assert {:error, _} =
               Core.new(%{bindings | cli_identity: %{path: Core.cli_path()}}, evidence)

      # Never raises on malformed nested structures.
      assert {:error, _} =
               Core.new(bindings, put_in(evidence, [:apiserver, :launchd, :argv], "x"))

      assert {:error, _} =
               Core.new(bindings, put_in(evidence, [:apiserver, :launchd, :environment], [:a]))

      assert {:error, _} =
               Core.new(
                 bindings,
                 put_in(evidence, [:runtime_plugin, :config, :services_config, :services], "x")
               )
    end
  end

  describe "production facade remains fail-closed" do
    test "execute_spawn_capable stays production_backend_missing" do
      assert {:error, {:spawn_backend_unavailable, :production_backend_missing}} =
               Shell.execute_spawn_capable("mix", ["test"], [])
    end
  end

  # --- Fixtures ---

  defp valid_bindings do
    %{
      cli_identity: identity(Core.cli_path(), @cli_sha, true, @exec_mode),
      apiserver_identity: identity(Core.apiserver_path(), @api_sha, true, @exec_mode),
      runtime_plugin_identity: identity(Core.plugin_path(), @plugin_sha, true, @exec_mode),
      runtime_plugin_config_identity:
        identity(Core.plugin_config_path(), @config_sha, false, @file_mode),
      kernel_identity: identity(@kernel_path, @kernel_sha, false, @file_mode),
      app_root: @app_root
    }
  end

  defp valid_evidence(bindings) do
    %{
      cli: %{
        identity: bindings.cli_identity,
        version: @version,
        build: "release",
        signing: signing("com.apple.container.cli", Core.cli_designated_requirement())
      },
      apiserver: %{
        identity: bindings.apiserver_identity,
        version: @version,
        build: "release",
        signing:
          signing("com.apple.container.apiserver", Core.apiserver_designated_requirement()),
        launchd: %{
          label: "com.apple.container.apiserver",
          path: @app_root <> "/apiserver/apiserver.plist",
          type: "LaunchAgent",
          state: "running",
          program: Core.apiserver_path(),
          argv: [Core.apiserver_path(), "start"],
          environment: %{
            "CONTAINER_APP_ROOT" => @app_root,
            "CONTAINER_INSTALL_ROOT" => "/usr/local"
          },
          inherited_environment: %{},
          default_environment: %{}
        }
      },
      service_status: %{
        status: "running",
        install_root: "/usr/local/",
        apiserver_version: @version,
        apiserver_build: "release"
      },
      runtime_plugin: %{
        identity: bindings.runtime_plugin_identity,
        config_identity: bindings.runtime_plugin_config_identity,
        signing:
          signing(
            "com.apple.container.container-runtime-linux",
            Core.plugin_designated_requirement()
          ),
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
        path: Core.user_plugin_root_path(),
        status: "absent"
      },
      kernel_identity: bindings.kernel_identity
    }
  end

  defp identity(path, sha256, executable_required, mode) do
    %Identity{
      path: path,
      type: :regular,
      device: 1,
      inode: :erlang.phash2(path),
      size: 4_096,
      mtime: 1_700_000_000,
      ctime: 1_700_000_000,
      mode: mode,
      uid: 0,
      gid: 0,
      sha256: sha256,
      executable_required: executable_required
    }
  end

  defp signing(identifier, requirement) do
    %{
      identifier: identifier,
      team_id: Core.team_id(),
      designated_requirement: requirement,
      verified_against: requirement,
      status: "valid"
    }
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp stringify_nested_evidence(evidence) do
    evidence
    |> stringify_keys()
    |> Map.new(fn
      {"cli" = k, v} ->
        {k, stringify_keys(Map.update!(v, :signing, &stringify_keys/1))}

      {"apiserver" = k, v} ->
        {k,
         v
         |> Map.update!(:signing, &stringify_keys/1)
         |> Map.update!(:launchd, &stringify_keys/1)
         |> stringify_keys()}

      {"service_status" = k, v} ->
        {k, stringify_keys(v)}

      {"runtime_plugin" = k, v} ->
        {k,
         v
         |> Map.update!(:signing, &stringify_keys/1)
         |> Map.update!(:config, fn config ->
           config
           |> Map.update!(:services_config, fn sc ->
             sc
             |> Map.update!(:services, fn services ->
               Enum.map(services, &stringify_keys/1)
             end)
             |> stringify_keys()
           end)
           |> stringify_keys()
         end)
         |> stringify_keys()}

      {"user_plugin_root" = k, v} ->
        {k, stringify_keys(v)}

      other ->
        other
    end)
  end
end
