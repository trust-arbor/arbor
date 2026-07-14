defmodule Arbor.Shell.AppleContainerControlPlaneAuthorityTest do
  use ExUnit.Case, async: false

  alias Arbor.Shell
  alias Arbor.Shell.AppleContainerControlPlaneAdmissionCore, as: ControlPlane
  alias Arbor.Shell.AppleContainerControlPlaneAuthority, as: Authority
  alias Arbor.Shell.TrustedPath.Identity

  @app :arbor_shell
  @config_key :apple_container
  @kernel_path "/usr/local/share/container/kernels/default.img"
  @app_root "/Users/operator/Library/Application Support/com.apple.container"

  defmodule FakeTrustedPath do
    @moduledoc false

    alias Arbor.Shell.TrustedPath.Identity

    def reset do
      :persistent_term.put({__MODULE__, :pins}, [])
      :persistent_term.put({__MODULE__, :verifications}, [])
      :persistent_term.put({__MODULE__, :canonicalizations}, [])
      :persistent_term.put({__MODULE__, :verify_mode}, :ok)
      :persistent_term.put({__MODULE__, :identities}, %{})
      :persistent_term.put({__MODULE__, :app_root_mode}, :ok)
    end

    def pin_attempts do
      :persistent_term.get({__MODULE__, :pins}, [])
    end

    def verification_attempts do
      :persistent_term.get({__MODULE__, :verifications}, [])
    end

    def canonicalization_attempts do
      :persistent_term.get({__MODULE__, :canonicalizations}, [])
    end

    def reset_checkout_attempts do
      :persistent_term.put({__MODULE__, :verifications}, [])
      :persistent_term.put({__MODULE__, :canonicalizations}, [])
    end

    def set_verify_mode(mode) do
      :persistent_term.put({__MODULE__, :verify_mode}, mode)
    end

    def set_app_root_mode(mode) do
      :persistent_term.put({__MODULE__, :app_root_mode}, mode)
    end

    def pin_root_owned_regular_file(path, opts \\ []) when is_binary(path) do
      executable? =
        case Keyword.get(opts, :executable, false) do
          value when is_boolean(value) -> value
          _ -> false
        end

      :persistent_term.put(
        {__MODULE__, :pins},
        pin_attempts() ++ [{path, executable?}]
      )

      identity = identity_for(path, executable?)
      identities = :persistent_term.get({__MODULE__, :identities}, %{})
      :persistent_term.put({__MODULE__, :identities}, Map.put(identities, path, identity))
      {:ok, identity}
    end

    def verify_pinned(%Identity{} = identity) do
      :persistent_term.put(
        {__MODULE__, :verifications},
        verification_attempts() ++ [identity.path]
      )

      case :persistent_term.get({__MODULE__, :verify_mode}, :ok) do
        :ok ->
          identities = :persistent_term.get({__MODULE__, :identities}, %{})

          case Map.get(identities, identity.path) do
            %Identity{} = current ->
              if same?(identity, current), do: :ok, else: {:error, :identity_mismatch}

            nil ->
              {:error, :path_not_found}
          end

        :drift ->
          {:error, :identity_mismatch}

        {:error, reason} ->
          {:error, reason}
      end
    end

    def verify_pinned(_identity), do: {:error, :invalid_identity}

    def canonicalize_absolute(path) when is_binary(path) do
      :persistent_term.put(
        {__MODULE__, :canonicalizations},
        canonicalization_attempts() ++ [path]
      )

      case :persistent_term.get({__MODULE__, :app_root_mode}, :ok) do
        :ok ->
          if Path.type(path) == :absolute, do: {:ok, path}, else: {:error, :relative_path}

        :rewrite ->
          {:ok, path <> "-rewritten"}

        {:error, reason} ->
          {:error, reason}
      end
    end

    def canonicalize_absolute(_path), do: {:error, :invalid_path}

    defp identity_for(path, executable?) do
      digest =
        path
        |> :erlang.phash2()
        |> Integer.to_string(16)
        |> String.pad_leading(64, "0")
        |> String.slice(0, 64)
        |> String.downcase()

      %Identity{
        path: path,
        type: :regular,
        device: 1,
        inode: :erlang.phash2(path),
        size: 100,
        mtime: 1,
        ctime: 1,
        mode: if(executable?, do: 0o755, else: 0o644),
        uid: 0,
        gid: 0,
        sha256: digest,
        executable_required: executable?
      }
    end

    defp same?(%Identity{} = left, %Identity{} = right) do
      left.path == right.path and left.sha256 == right.sha256 and
        left.executable_required == right.executable_required and
        left.inode == right.inode
    end
  end

  defmodule FailingPinTrustedPath do
    @moduledoc false

    def pin_root_owned_regular_file(_path, _opts \\ []), do: {:error, :path_not_found}
    def verify_pinned(_identity), do: {:error, :path_not_found}
    def canonicalize_absolute(path) when is_binary(path), do: {:ok, path}
    def canonicalize_absolute(_), do: {:error, :invalid_path}
  end

  setup do
    previous = Application.get_env(@app, @config_key)
    FakeTrustedPath.reset()

    on_exit(fn ->
      restore_env(previous)
      FakeTrustedPath.reset()
    end)

    :ok
  end

  describe "unsupported and unavailable hosts" do
    test "unsupported host performs zero pin attempts and stays alive" do
      {:ok, pid} =
        start_authority(
          name: unique_name(),
          host_platform: :linux_x86_64,
          trusted_path: FakeTrustedPath
        )

      assert Process.alive?(pid)
      assert FakeTrustedPath.pin_attempts() == []

      assert Authority.public_status(pid) == %{
               "state" => "unsupported",
               "reason" => "unsupported_host",
               "platform" => "linux_x86_64"
             }

      assert {:error, :control_plane_unsupported} = Authority.checkout_bindings(pid)
    end

    test "missing config stays alive as unavailable without crashing" do
      Application.delete_env(@app, @config_key)

      {:ok, pid} =
        start_authority(
          name: unique_name(),
          host_platform: :darwin_arm64,
          trusted_path: FakeTrustedPath
        )

      assert Process.alive?(pid)
      assert FakeTrustedPath.pin_attempts() == []

      status = Authority.public_status(pid)
      assert status["state"] == "unavailable"
      assert status["reason"] == "missing_config"
      assert status["platform"] == "darwin_arm64"
      refute Map.has_key?(status, "bindings")
      refute Map.has_key?(status, "app_root")

      assert {:error, :control_plane_unavailable} = Authority.checkout_bindings(pid)
    end

    test "missing artifact stays alive as unavailable" do
      put_valid_config()

      {:ok, pid} =
        start_authority(
          name: unique_name(),
          host_platform: :darwin_arm64,
          trusted_path: FailingPinTrustedPath
        )

      assert Process.alive?(pid)
      status = Authority.public_status(pid)
      assert status["state"] == "unavailable"
      assert is_binary(status["reason"])
      assert {:error, :control_plane_unavailable} = Authority.checkout_bindings(pid)
    end
  end

  describe "positive macOS arm64 pinning" do
    test "builds only owner-held bindings and reports redacted pinned status" do
      put_valid_config()

      {:ok, pid} =
        start_authority(
          name: unique_name(),
          host_platform: :darwin_arm64,
          trusted_path: FakeTrustedPath
        )

      assert Process.alive?(pid)

      assert FakeTrustedPath.pin_attempts() == [
               {ControlPlane.cli_path(), true},
               {ControlPlane.apiserver_path(), true},
               {ControlPlane.plugin_path(), true},
               {ControlPlane.plugin_config_path(), false},
               {@kernel_path, false}
             ]

      status = Authority.public_status(pid)
      assert status == %{"state" => "pinned", "reason" => nil, "platform" => "darwin_arm64"}
      refute inspect(status) =~ "Identity"
      refute inspect(status) =~ "sha256"
      refute inspect(status) =~ "inode"
      refute inspect(status) =~ "device"
      refute inspect(status) =~ @app_root
      refute Map.has_key?(status, "bindings")
      refute Map.has_key?(status, "app_root")
      refute Map.has_key?(status, "checkout")

      assert {:ok, bindings} = Authority.checkout_bindings(pid)

      assert Map.keys(bindings) |> Enum.sort() ==
               [
                 :apiserver_identity,
                 :app_root,
                 :cli_identity,
                 :kernel_identity,
                 :runtime_plugin_config_identity,
                 :runtime_plugin_identity
               ]
               |> Enum.sort()

      assert %Identity{path: path, executable_required: true} = bindings.cli_identity
      assert path == ControlPlane.cli_path()

      assert %Identity{path: path, executable_required: true} = bindings.apiserver_identity
      assert path == ControlPlane.apiserver_path()

      assert %Identity{path: path, executable_required: true} = bindings.runtime_plugin_identity
      assert path == ControlPlane.plugin_path()

      assert %Identity{path: path, executable_required: false} =
               bindings.runtime_plugin_config_identity

      assert path == ControlPlane.plugin_config_path()

      assert %Identity{path: @kernel_path, executable_required: false} = bindings.kernel_identity
      assert bindings.app_root == @app_root
    end

    test "executable flags are exact for fixed paths and kernel" do
      put_valid_config()

      {:ok, _pid} =
        start_authority(
          name: unique_name(),
          host_platform: :darwin_arm64,
          trusted_path: FakeTrustedPath
        )

      executable_paths =
        MapSet.new([
          ControlPlane.cli_path(),
          ControlPlane.apiserver_path(),
          ControlPlane.plugin_path()
        ])

      non_executable_paths =
        MapSet.new([
          ControlPlane.plugin_config_path(),
          @kernel_path
        ])

      assert Enum.all?(FakeTrustedPath.pin_attempts(), fn
               {path, true} -> MapSet.member?(executable_paths, path)
               {path, false} -> MapSet.member?(non_executable_paths, path)
               _other -> false
             end)
    end

    test "fixed Apple paths cannot be overridden via start opts or config" do
      Application.put_env(@app, @config_key,
        kernel_path: @kernel_path,
        app_root: @app_root,
        cli_path: "/evil/container"
      )

      # Unknown config key fails closed before pinning.
      {:ok, pid} =
        start_authority(
          name: unique_name(),
          host_platform: :darwin_arm64,
          trusted_path: FakeTrustedPath
        )

      assert Authority.public_status(pid)["state"] == "unavailable"
      assert FakeTrustedPath.pin_attempts() == []

      put_valid_config()

      assert {:ok, pid2} =
               Authority.start_link(
                 name: unique_name(),
                 host_platform: :darwin_arm64,
                 trusted_path: FakeTrustedPath,
                 cli_path: "/evil/container"
               )

      # Unknown start option is rejected; owner stays unavailable, not pinned with evil path.
      assert Authority.public_status(pid2)["state"] == "unavailable"
      assert FakeTrustedPath.pin_attempts() == []

      refute Enum.any?(FakeTrustedPath.pin_attempts(), fn {path, _} ->
               path == "/evil/container"
             end)
    end

    test "checkout re-verifies all five identities and app_root" do
      put_valid_config()

      {:ok, pid} =
        start_authority(
          name: unique_name(),
          host_platform: :darwin_arm64,
          trusted_path: FakeTrustedPath
        )

      FakeTrustedPath.reset_checkout_attempts()
      assert {:ok, bindings} = Authority.checkout_bindings(pid)
      assert map_size(bindings) == 6

      assert FakeTrustedPath.verification_attempts() == [
               ControlPlane.cli_path(),
               ControlPlane.apiserver_path(),
               ControlPlane.plugin_path(),
               ControlPlane.plugin_config_path(),
               @kernel_path
             ]

      assert FakeTrustedPath.canonicalization_attempts() == [@app_root]

      ref = Process.monitor(pid)
      FakeTrustedPath.set_app_root_mode(:rewrite)

      assert {:error, {:control_plane_identity_drift, :app_root_not_canonical}} =
               Authority.checkout_bindings(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid,
                      {:control_plane_identity_drift, :app_root_not_canonical}}
    end

    test "identity drift fails closed and terminates the owner" do
      put_valid_config()

      {:ok, pid} =
        start_authority(
          name: unique_name(),
          host_platform: :darwin_arm64,
          trusted_path: FakeTrustedPath
        )

      ref = Process.monitor(pid)
      FakeTrustedPath.set_verify_mode(:drift)

      assert {:error, {:control_plane_identity_drift, :identity_mismatch}} =
               Authority.checkout_bindings(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid,
                      {:control_plane_identity_drift, :identity_mismatch}}
    end

    test "security regression: drift poisons the boot epoch instead of accepting a new baseline" do
      put_valid_config()
      boot_epoch = make_ref()
      pinning_name = unique_name()

      {:ok, pid} =
        start_authority(
          name: pinning_name,
          host_platform: :darwin_arm64,
          trusted_path: FakeTrustedPath,
          boot_epoch: boot_epoch
        )

      initial_pin_attempts = FakeTrustedPath.pin_attempts()
      ref = Process.monitor(pid)
      FakeTrustedPath.set_verify_mode(:drift)

      assert {:error, {:control_plane_identity_drift, :identity_mismatch}} =
               Authority.checkout_bindings(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid,
                      {:control_plane_identity_drift, :identity_mismatch}}

      FakeTrustedPath.set_verify_mode(:ok)

      {:ok, restarted} =
        start_authority(
          name: unique_name(),
          host_platform: :darwin_arm64,
          trusted_path: FakeTrustedPath,
          boot_epoch: boot_epoch
        )

      assert Authority.public_status(restarted) == %{
               "state" => "unavailable",
               "reason" => "boot_epoch_poisoned",
               "platform" => "darwin_arm64"
             }

      assert {:error, :control_plane_unavailable} = Authority.checkout_bindings(restarted)
      assert FakeTrustedPath.pin_attempts() == initial_pin_attempts
    end

    test "an initially unavailable boot epoch cannot become pinned after restart" do
      boot_epoch = make_ref()
      Application.delete_env(@app, @config_key)

      {:ok, unavailable} =
        start_authority(
          name: unique_name(),
          host_platform: :darwin_arm64,
          trusted_path: FakeTrustedPath,
          boot_epoch: boot_epoch
        )

      assert Authority.public_status(unavailable)["reason"] == "missing_config"
      Process.exit(unavailable, :shutdown)
      put_valid_config()

      {:ok, restarted} =
        start_authority(
          name: unique_name(),
          host_platform: :darwin_arm64,
          trusted_path: FakeTrustedPath,
          boot_epoch: boot_epoch
        )

      assert Authority.public_status(restarted)["reason"] == "boot_epoch_unavailable"
      assert FakeTrustedPath.pin_attempts() == []
    end

    test "returned checkout maps cannot mutate owner state" do
      put_valid_config()

      {:ok, pid} =
        start_authority(
          name: unique_name(),
          host_platform: :darwin_arm64,
          trusted_path: FakeTrustedPath
        )

      assert {:ok, bindings} = Authority.checkout_bindings(pid)
      original_app_root = bindings.app_root
      _ = Map.put(bindings, :app_root, "/evil/app-root")
      _ = Map.put(bindings, :cli_identity, :forged)

      assert {:ok, again} = Authority.checkout_bindings(pid)
      assert again.app_root == original_app_root
      assert %Identity{path: path} = again.cli_identity
      assert path == ControlPlane.cli_path()
    end

    test "caller cannot supply bindings or evidence through start API" do
      put_valid_config()

      assert {:ok, pid} =
               Authority.start_link(
                 name: unique_name(),
                 host_platform: :darwin_arm64,
                 trusted_path: FakeTrustedPath,
                 bindings: %{app_root: "/evil"},
                 evidence: %{service_status: "running"},
                 identities: [%{}]
               )

      assert Authority.public_status(pid)["state"] == "unavailable"
      assert FakeTrustedPath.pin_attempts() == []
    end
  end

  describe "public facade and production invariants" do
    test "public facade status contains no bindings, identities, digests, or app_root" do
      status = Shell.apple_container_control_plane_status()
      assert is_map(status)
      assert Map.has_key?(status, "state")
      assert Map.has_key?(status, "platform")

      rendered = inspect(status)
      refute rendered =~ "Identity"
      refute rendered =~ "sha256"
      refute rendered =~ "inode"
      refute rendered =~ "device"
      refute Map.has_key?(status, "bindings")
      refute Map.has_key?(status, "app_root")
      refute Map.has_key?(status, "cli_identity")
      refute function_exported?(Shell, :apple_container_control_plane_checkout, 0)
    end

    test "execute_spawn_capable remains production_backend_missing" do
      assert {:error, {:spawn_backend_unavailable, :production_backend_missing}} =
               Shell.execute_spawn_capable("mix", ["test"], [])
    end

    test "security regression: OTP status and formatter redact state, messages, reasons, and logs" do
      put_valid_config()

      {:ok, pid} =
        start_authority(
          name: unique_name(),
          host_platform: :darwin_arm64,
          trusted_path: FakeTrustedPath
        )

      assert {:ok, bindings} = Authority.checkout_bindings(pid)

      rendered = pid |> :sys.get_status() |> inspect(limit: :infinity)

      refute rendered =~ @app_root
      refute rendered =~ bindings.cli_identity.sha256
      refute rendered =~ "runtime_plugin_config_identity"
      assert rendered =~ "redacted"

      formatted =
        Authority.format_status(%{
          message: {:checkout_bindings, bindings},
          reason: {:failed, @app_root},
          log: [{:reply, bindings}],
          state: %{status: :pinned, reason: nil, bindings: bindings, boot_epoch: make_ref()}
        })

      assert formatted.message == :redacted
      assert formatted.reason == :redacted
      assert formatted.log == :redacted
      refute inspect(formatted, limit: :infinity) =~ @app_root
      refute inspect(formatted, limit: :infinity) =~ bindings.cli_identity.sha256
    end

    test "malformed registration names return typed errors before GenServer startup" do
      assert {:error, :invalid_control_plane_authority_name} =
               Authority.start_link(name: self())

      assert {:error, :invalid_control_plane_authority_name} =
               Authority.start_link(name: "not-a-registration-name")

      assert {:error, :duplicate_control_plane_authority_name} =
               Authority.start_link(name: unique_name(), name: unique_name())

      assert {:error, :malformed_control_plane_authority_options} =
               Authority.start_link(%{name: unique_name()})
    end

    test "application production child order places authority after policy and before registry" do
      boot_epoch = make_ref()
      children = Arbor.Shell.Application.production_children([startup_path: "/bin"], boot_epoch)
      modules = Enum.map(children, &child_module/1)

      assert modules == [
               Arbor.Shell.ExecutablePolicy,
               Arbor.Shell.AppleContainerControlPlaneAuthority,
               Arbor.Shell.LinuxDependencyBaselineAuthority,
               Arbor.Shell.LinuxDependencyBaselineMaterializerSupervisor,
               Arbor.Shell.ExecutionRegistry,
               DynamicSupervisor
             ]

      authority_child = Enum.at(children, 1)
      linux_child = Enum.at(children, 2)
      materializer_sup = Enum.at(children, 3)

      assert authority_child ==
               {Arbor.Shell.AppleContainerControlPlaneAuthority, [boot_epoch: boot_epoch]}

      assert linux_child ==
               {Arbor.Shell.LinuxDependencyBaselineAuthority, [boot_epoch: boot_epoch]}

      assert match?(
               %{id: Arbor.Shell.LinuxDependencyBaselineMaterializerSupervisor},
               materializer_sup
             )

      assert Arbor.Shell.Application.supervisor_options() ==
               [strategy: :rest_for_one, name: Arbor.Shell.Supervisor]
    end

    test "security regression: drift turns over downstream owners and stays poisoned" do
      put_valid_config()
      boot_epoch = make_ref()

      replace_global_authority_stack!(
        host_platform: :darwin_arm64,
        trusted_path: FakeTrustedPath,
        boot_epoch: boot_epoch
      )

      on_exit(fn ->
        restore_global_authority_stack!()
        Authority.clear_boot_epoch(boot_epoch)
        Arbor.Shell.LinuxDependencyBaselineAuthority.clear_boot_epoch(boot_epoch)
      end)

      policy_before = Process.whereis(Arbor.Shell.ExecutablePolicy)
      authority_before = Process.whereis(Authority)
      linux_before = Process.whereis(Arbor.Shell.LinuxDependencyBaselineAuthority)

      materializer_before =
        Process.whereis(Arbor.Shell.LinuxDependencyBaselineMaterializerSupervisor)

      registry_before = Process.whereis(Arbor.Shell.ExecutionRegistry)
      sessions_before = Process.whereis(Arbor.Shell.PortSessionSupervisor)

      {:ok, session} =
        DynamicSupervisor.start_child(
          Arbor.Shell.PortSessionSupervisor,
          {Task, fn -> Process.sleep(:infinity) end}
        )

      session_ref = Process.monitor(session)
      authority_ref = Process.monitor(authority_before)
      linux_ref = Process.monitor(linux_before)
      materializer_ref = Process.monitor(materializer_before)
      registry_ref = Process.monitor(registry_before)
      sessions_ref = Process.monitor(sessions_before)
      initial_pin_attempts = FakeTrustedPath.pin_attempts()

      FakeTrustedPath.set_verify_mode(:drift)

      assert {:error, {:control_plane_identity_drift, :identity_mismatch}} =
               Authority.checkout_bindings()

      assert_receive {:DOWN, ^authority_ref, :process, ^authority_before, _reason}
      assert_receive {:DOWN, ^linux_ref, :process, ^linux_before, :shutdown}
      assert_receive {:DOWN, ^materializer_ref, :process, ^materializer_before, :shutdown}
      assert_receive {:DOWN, ^registry_ref, :process, ^registry_before, :shutdown}
      assert_receive {:DOWN, ^sessions_ref, :process, ^sessions_before, :shutdown}
      assert_receive {:DOWN, ^session_ref, :process, ^session, :shutdown}

      assert eventually?(fn ->
               new_authority = Process.whereis(Authority)
               new_linux = Process.whereis(Arbor.Shell.LinuxDependencyBaselineAuthority)

               new_materializer =
                 Process.whereis(Arbor.Shell.LinuxDependencyBaselineMaterializerSupervisor)

               new_registry = Process.whereis(Arbor.Shell.ExecutionRegistry)
               new_sessions = Process.whereis(Arbor.Shell.PortSessionSupervisor)

               is_pid(new_authority) and new_authority != authority_before and
                 is_pid(new_linux) and new_linux != linux_before and
                 is_pid(new_materializer) and new_materializer != materializer_before and
                 is_pid(new_registry) and new_registry != registry_before and
                 is_pid(new_sessions) and new_sessions != sessions_before
             end)

      assert Process.whereis(Arbor.Shell.ExecutablePolicy) == policy_before
      assert Authority.public_status()["reason"] == "boot_epoch_poisoned"
      assert {:error, :control_plane_unavailable} = Authority.checkout_bindings()
      assert FakeTrustedPath.pin_attempts() == initial_pin_attempts
    end
  end

  defp start_authority(opts) do
    name = Keyword.fetch!(opts, :name)

    if boot_epoch = Keyword.get(opts, :boot_epoch) do
      on_exit(fn -> Authority.clear_boot_epoch(boot_epoch) end)
    end

    case Authority.start_link(opts) do
      {:ok, pid} ->
        # Unlink so intentional abnormal drift stops do not kill the test process.
        Process.unlink(pid)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :shutdown)
          end

          # Ensure the name is free for later tests if shutdown races.
          wait_until_unregistered(name)
        end)

        {:ok, pid}

      other ->
        other
    end
  end

  defp wait_until_unregistered(name) when is_atom(name) do
    Enum.reduce_while(1..50, :ok, fn _, acc ->
      case Process.whereis(name) do
        nil ->
          {:halt, acc}

        _pid ->
          Process.sleep(1)
          {:cont, acc}
      end
    end)
  end

  defp put_valid_config do
    Application.put_env(@app, @config_key,
      kernel_path: @kernel_path,
      app_root: @app_root
    )
  end

  defp restore_env(nil), do: Application.delete_env(@app, @config_key)
  defp restore_env(value), do: Application.put_env(@app, @config_key, value)

  defp unique_name do
    :"apple_cp_authority_#{System.unique_integer([:positive])}"
  end

  defp replace_global_authority_stack!(authority_opts) do
    remove_global_authority_stack!()

    {:ok, _authority} =
      Supervisor.start_child(Arbor.Shell.Supervisor, {Authority, authority_opts})

    {:ok, _linux} =
      Supervisor.start_child(
        Arbor.Shell.Supervisor,
        {Arbor.Shell.LinuxDependencyBaselineAuthority, []}
      )

    {:ok, _materializer} =
      Supervisor.start_child(
        Arbor.Shell.Supervisor,
        Arbor.Shell.LinuxDependencyBaselineMaterializer.supervisor_child_spec()
      )

    {:ok, _registry} =
      Supervisor.start_child(
        Arbor.Shell.Supervisor,
        {Arbor.Shell.ExecutionRegistry, []}
      )

    {:ok, _sessions} =
      Supervisor.start_child(
        Arbor.Shell.Supervisor,
        {DynamicSupervisor, name: Arbor.Shell.PortSessionSupervisor, strategy: :one_for_one}
      )

    :ok
  end

  defp restore_global_authority_stack! do
    remove_global_authority_stack!()

    {:ok, _authority} = Supervisor.start_child(Arbor.Shell.Supervisor, {Authority, []})

    {:ok, _linux} =
      Supervisor.start_child(
        Arbor.Shell.Supervisor,
        {Arbor.Shell.LinuxDependencyBaselineAuthority, []}
      )

    {:ok, _materializer} =
      Supervisor.start_child(
        Arbor.Shell.Supervisor,
        Arbor.Shell.LinuxDependencyBaselineMaterializer.supervisor_child_spec()
      )

    {:ok, _registry} =
      Supervisor.start_child(
        Arbor.Shell.Supervisor,
        {Arbor.Shell.ExecutionRegistry, []}
      )

    {:ok, _sessions} =
      Supervisor.start_child(
        Arbor.Shell.Supervisor,
        {DynamicSupervisor, name: Arbor.Shell.PortSessionSupervisor, strategy: :one_for_one}
      )

    :ok
  end

  defp remove_global_authority_stack! do
    for child_id <- [
          Arbor.Shell.PortSessionSupervisor,
          Arbor.Shell.ExecutionRegistry,
          Arbor.Shell.LinuxDependencyBaselineMaterializerSupervisor,
          Arbor.Shell.LinuxDependencyBaselineAuthority,
          Authority
        ] do
      case Supervisor.terminate_child(Arbor.Shell.Supervisor, child_id) do
        :ok -> :ok
        {:error, :not_found} -> :ok
      end

      case Supervisor.delete_child(Arbor.Shell.Supervisor, child_id) do
        :ok -> :ok
        {:error, :not_found} -> :ok
      end
    end

    :ok
  end

  defp eventually?(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        do_eventually(fun, deadline)
      else
        false
      end
    end
  end

  defp child_module({module, _opts}) when is_atom(module), do: module
  defp child_module(%{id: module}) when is_atom(module), do: module
  defp child_module(module) when is_atom(module), do: module
end
