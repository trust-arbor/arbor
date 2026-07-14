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
      :persistent_term.put({__MODULE__, :verify_mode}, :ok)
      :persistent_term.put({__MODULE__, :identities}, %{})
      :persistent_term.put({__MODULE__, :app_root_mode}, :ok)
    end

    def pin_attempts do
      :persistent_term.get({__MODULE__, :pins}, [])
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

      assert {:ok, bindings} = Authority.checkout_bindings(pid)
      assert map_size(bindings) == 6

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

    test "application production child order places authority after policy and before registry" do
      children = Arbor.Shell.Application.production_children(startup_path: "/bin")
      modules = Enum.map(children, &child_module/1)

      assert modules == [
               Arbor.Shell.ExecutablePolicy,
               Arbor.Shell.AppleContainerControlPlaneAuthority,
               Arbor.Shell.ExecutionRegistry,
               DynamicSupervisor
             ]

      authority_child = Enum.at(children, 1)
      assert authority_child == {Arbor.Shell.AppleContainerControlPlaneAuthority, []}
    end
  end

  defp start_authority(opts) do
    name = Keyword.fetch!(opts, :name)

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

  defp child_module({module, _opts}) when is_atom(module), do: module
  defp child_module(%{id: module}) when is_atom(module), do: module
  defp child_module(module) when is_atom(module), do: module
end
