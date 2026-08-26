defmodule Arbor.Shell.ValidationRuntime.AuthorityTest do
  use ExUnit.Case, async: false

  alias Arbor.Shell
  alias Arbor.Shell.ValidationRuntime
  alias Arbor.Shell.ValidationRuntime.AppleContainer
  alias Arbor.Shell.ValidationRuntime.Authority

  @moduletag :fast

  defmodule FakeRuntime do
    @moduledoc false
    @behaviour ValidationRuntime

    def execute(_tool, _args, _opts) do
      send(test_pid(), :fake_runtime_execute)
      {:error, :fake_runtime_executed}
    end

    def probe, do: {:ok, %{"state" => "injected"}}
    def public_status, do: %{"state" => "injected", "driver" => "fake"}

    defp test_pid do
      :persistent_term.get({__MODULE__, :test_pid})
    end
  end

  setup do
    :persistent_term.put({FakeRuntime, :test_pid}, self())
    :ok
  end

  describe "production pin" do
    test "global owner pins Apple Container and ignores Application env" do
      Application.put_env(:arbor_shell, :validation_runtime, FakeRuntime)
      Application.put_env(:arbor_shell, :spawn_backend, FakeRuntime)

      on_exit(fn ->
        Application.delete_env(:arbor_shell, :validation_runtime)
        Application.delete_env(:arbor_shell, :spawn_backend)
      end)

      assert {:ok, AppleContainer} = Authority.checkout_implementation()
      assert Shell.validation_runtime_status()["state"] == "pinned"
      assert Shell.validation_runtime_status()["driver"] == "apple_container"

      assert {:error, {:invalid_tool_name, :relative_path}} =
               Shell.execute_spawn_capable("mix", ["compile"], [])

      refute_receive :fake_runtime_execute, 50
    end

    test "security regression: Application env kind cannot pin ValidationRuntime.Oci" do
      previous_kind = Application.get_env(:arbor_shell, :validation_runtime_kind)
      previous_path = Application.get_env(:arbor_shell, :validation_runtime_config_path)
      previous_family = Application.get_env(:arbor_shell, :validation_runtime_pin_family)

      Application.put_env(:arbor_shell, :validation_runtime_kind, :oci)
      Application.delete_env(:arbor_shell, :validation_runtime_config_path)
      Application.delete_env(:arbor_shell, :validation_runtime_pin_family)
      Application.put_env(:arbor_shell, :spawn_backend, FakeRuntime)

      on_exit(fn ->
        restore_env(:validation_runtime_kind, previous_kind)
        restore_env(:validation_runtime_config_path, previous_path)
        restore_env(:validation_runtime_pin_family, previous_family)
        Application.delete_env(:arbor_shell, :spawn_backend)
      end)

      name = unique_name()
      boot_epoch = make_ref()
      {:ok, pid} = start_authority(name: name, boot_epoch: boot_epoch)

      assert {:ok, AppleContainer} = Authority.checkout_implementation(pid)
      assert Authority.public_status(pid)["driver"] == "apple_container"
    end

    test "operator-owned OCI document pins ValidationRuntime.Oci" do
      {path, cleanup} = write_operator_owned_oci_document!()
      on_exit(cleanup)

      previous_path = Application.get_env(:arbor_shell, :validation_runtime_config_path)
      previous_family = Application.get_env(:arbor_shell, :validation_runtime_pin_family)
      previous_kind = Application.get_env(:arbor_shell, :validation_runtime_kind)

      Application.put_env(:arbor_shell, :validation_runtime_config_path, path)
      Application.put_env(:arbor_shell, :validation_runtime_pin_family, :operator_owned)
      Application.put_env(:arbor_shell, :validation_runtime_kind, :apple)

      on_exit(fn ->
        restore_env(:validation_runtime_config_path, previous_path)
        restore_env(:validation_runtime_pin_family, previous_family)
        restore_env(:validation_runtime_kind, previous_kind)
      end)

      assert {:ok, %{kind: :oci}} = Arbor.Shell.RuntimeConfigLoader.load_operator_owned(path)

      name = unique_name()
      boot_epoch = make_ref()
      {:ok, pid} = start_authority(name: name, boot_epoch: boot_epoch)

      assert {:ok, Arbor.Shell.ValidationRuntime.Oci} = Authority.checkout_implementation(pid)
      assert Authority.public_status(pid)["driver"] == "podman"
    end

    test "public status never includes the implementation module" do
      status = Authority.public_status()
      refute inspect(status) =~ "AppleContainer"
      refute Map.has_key?(status, "implementation")
    end
  end

  describe "direct-start injection" do
    test "injected implementation is checked out and used for execute" do
      name = unique_name()
      boot_epoch = make_ref()

      {:ok, pid} =
        start_authority(
          name: name,
          boot_epoch: boot_epoch,
          implementation: FakeRuntime
        )

      assert {:ok, FakeRuntime} = Authority.checkout_implementation(pid)
      status = Authority.public_status(pid)
      assert status["state"] == "pinned"
      assert status["driver"] == "injected"
      refute inspect(status) =~ "FakeRuntime"

      assert {:error, :fake_runtime_executed} = FakeRuntime.execute("mix", [], [])
      assert_received :fake_runtime_execute
    end

    test "invalid implementation starts unavailable without crashing" do
      name = unique_name()

      {:ok, pid} = start_authority(name: name, implementation: Kernel)

      assert {:error, :validation_runtime_unavailable} =
               Authority.checkout_implementation(pid)

      assert Authority.public_status(pid)["state"] == "unavailable"
      assert Authority.public_status(pid)["reason"] == "invalid_validation_runtime_implementation"
    end

    test "unknown start option starts unavailable" do
      name = unique_name()

      {:ok, pid} = start_authority(name: name, probe: :nope)

      assert {:error, :validation_runtime_unavailable} =
               Authority.checkout_implementation(pid)

      assert Authority.public_status(pid)["reason"] ==
               "unknown_validation_runtime_authority_option"
    end

    test "duplicate name is rejected before start" do
      assert {:error, :duplicate_validation_runtime_authority_name} =
               Authority.start_link(name: unique_name(), name: unique_name())
    end

    test "malformed opts start unavailable" do
      name = unique_name()

      assert {:error, :malformed_validation_runtime_authority_options} =
               Authority.start_link(%{name: name})
    end
  end

  describe "dead owner" do
    test "checkout and public status fail closed" do
      assert {:error, :validation_runtime_unavailable} =
               Authority.checkout_implementation(:validation_runtime_missing_owner)

      status = Authority.public_status(:validation_runtime_missing_owner)
      assert status["state"] == "unavailable"
      assert status["driver"] == "unavailable"
    end
  end

  describe "production child order" do
    test "places authority after image policy and before materializer" do
      boot_epoch = make_ref()
      children = Arbor.Shell.Application.production_children([startup_path: "/bin"], boot_epoch)

      assert Enum.at(children, 5) ==
               {Arbor.Shell.AppleContainerImagePolicyAuthority, [boot_epoch: boot_epoch]}

      assert Enum.at(children, 6) ==
               {Authority, [boot_epoch: boot_epoch]}
    end
  end

  defp start_authority(opts) do
    name = Keyword.fetch!(opts, :name)

    if boot_epoch = Keyword.get(opts, :boot_epoch) do
      on_exit(fn -> Authority.clear_boot_epoch(boot_epoch) end)
    end

    case Authority.start_link(opts) do
      {:ok, pid} ->
        Process.unlink(pid)

        on_exit(fn ->
          if Process.alive?(pid), do: Process.exit(pid, :shutdown)
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

  defp unique_name do
    :"validation_runtime_authority_#{System.unique_integer([:positive])}"
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_shell, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_shell, key, value)

  defp write_operator_owned_oci_document! do
    root =
      Path.join(
        System.tmp_dir!(),
        "arbor-validation-runtime-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    {:ok, root} = Arbor.Shell.TrustedPath.canonicalize_absolute(root)
    File.chmod!(root, 0o700)
    path = Path.join(root, "validation-runtime.json")
    File.write!(path, Jason.encode!(oci_document()))
    File.chmod!(path, 0o400)

    {path, fn -> File.rm_rf!(root) end}
  end

  defp oci_document do
    %{
      "runtime" => "oci",
      "linux_dependency_baseline" => %{
        "source_root" =>
          "/home/operator/.arbor/baseline/" <> String.duplicate("a", 64) <> "/tree",
        "manifest_path" =>
          "/home/operator/.arbor/baseline/" <> String.duplicate("a", 64) <> "/manifest.json"
      },
      "image_policy" => %{
        "image" => "docker.io/arbor/validation@sha256:" <> String.duplicate("a", 64),
        "manifest_digest" => "sha256:" <> String.duplicate("b", 64),
        "env" => ["MIX_HOME=/usr/local/.mix"],
        "labels" => %{"org.arbor.validation.schema" => "1"},
        "mix_lock_digest" => String.duplicate("e", 64),
        "baseline_tree_digest" => String.duplicate("f", 64),
        "toolchain" => %{"erlang" => "28.4.1", "elixir" => "1.19.5-otp-28"},
        "platform" => "linux/amd64"
      },
      "unit_journal_path" => "/home/operator/.arbor/oci-unit-journal.json"
    }
  end
end
