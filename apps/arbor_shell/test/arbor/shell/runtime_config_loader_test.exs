defmodule Arbor.Shell.RuntimeConfigLoaderTest do
  use ExUnit.Case, async: false

  alias Arbor.Shell.Config
  alias Arbor.Shell.RuntimeConfigLoader
  alias Arbor.Shell.TrustedPath.Identity

  defmodule TestTrustedPath do
    alias Arbor.Shell.TrustedPath.Identity

    def canonicalize_absolute(path), do: Arbor.Shell.TrustedPath.canonicalize_absolute(path)

    def pin_root_owned_regular_file(path) do
      with {:ok, %File.Stat{type: :regular} = stat} <- File.stat(path, time: :posix),
           {:ok, contents} <- File.read(path) do
        {:ok,
         %Identity{
           path: path,
           type: :regular,
           device: stat.major_device,
           inode: stat.inode,
           size: stat.size,
           mtime: stat.mtime,
           ctime: stat.ctime,
           mode: stat.mode,
           uid: stat.uid,
           gid: stat.gid,
           sha256: Base.encode16(:crypto.hash(:sha256, contents), case: :lower),
           executable_required: false
         }}
      else
        {:ok, %File.Stat{}} -> {:error, :not_a_regular_file}
        {:error, reason} -> {:error, reason}
      end
    end

    def verify_pinned(%Identity{path: path} = expected) do
      case pin_root_owned_regular_file(path) do
        {:ok, ^expected} -> :ok
        {:ok, _current} -> {:error, :identity_mismatch}
        {:error, reason} -> {:error, reason}
      end
    end

    def verify_pinned(_identity), do: {:error, :invalid_identity}
  end

  @valid_document %{
    "apple_container" => %{
      "kernel_path" => "/var/db/container/kernel",
      "app_root" => "/opt/container-app"
    },
    "linux_dependency_baseline" => %{
      "source_root" => "/var/lib/arbor/linux-deps",
      "manifest_path" => "/var/lib/arbor/linux-deps/manifest.json"
    },
    "image_policy" => %{
      "image" => "docker.io/arbor/validation@sha256:" <> String.duplicate("a", 64),
      "manifest_digest" => "sha256:" <> String.duplicate("b", 64),
      "vminit_image" => "docker.io/arbor/vminit@sha256:" <> String.duplicate("c", 64),
      "vminit_manifest_digest" => "sha256:" <> String.duplicate("d", 64),
      "env" => ["PATH=/usr/bin"],
      "labels" => %{"org.arbor.validation.schema" => "1"},
      "mix_lock_digest" => String.duplicate("e", 64),
      "baseline_tree_digest" => String.duplicate("f", 64),
      "toolchain" => %{"erlang" => "28.4.1", "elixir" => "1.19.5-otp-28"}
    },
    "unit_journal_path" => "/var/lib/arbor/unit-journal.json"
  }

  setup do
    root =
      Path.join(System.tmp_dir!(), "arbor-runtime-config-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    {:ok, root} = Arbor.Shell.TrustedPath.canonicalize_absolute(root)

    config_keys = [
      :apple_container,
      :linux_dependency_baseline,
      :apple_container_image_policy,
      :apple_container_unit_journal_path
    ]

    previous = Map.new(config_keys, fn key -> {key, Application.get_env(:arbor_shell, key)} end)

    on_exit(fn ->
      File.rm_rf!(root)

      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:arbor_shell, key)
        {key, value} -> Application.put_env(:arbor_shell, key, value)
      end)
    end)

    {:ok, root: root}
  end

  test "loads a valid document and produces values accepted by Config", %{root: root} do
    path = write_document(root, @valid_document)

    assert {:ok, values} = RuntimeConfigLoader.load_with_trusted_path(path, TestTrustedPath)

    Application.put_env(:arbor_shell, :apple_container, values.apple_container)

    Application.put_env(
      :arbor_shell,
      :linux_dependency_baseline,
      values.linux_dependency_baseline
    )

    Application.put_env(
      :arbor_shell,
      :apple_container_image_policy,
      values.apple_container_image_policy
    )

    Application.put_env(
      :arbor_shell,
      :apple_container_unit_journal_path,
      values.apple_container_unit_journal_path
    )

    assert {:ok, values_apple} = Config.apple_container()
    assert values_apple == values.apple_container
    assert {:ok, values_linux} = Config.linux_dependency_baseline()
    assert values_linux == values.linux_dependency_baseline
    assert {:ok, values_policy} = Config.apple_container_image_policy()
    assert values_policy == values.apple_container_image_policy
    assert {:ok, values_journal} = Config.apple_container_unit_journal_path()
    assert values_journal == values.apple_container_unit_journal_path
  end

  test "bounded production-shaped identity reaches parsing and validation regression", %{
    root: root
  } do
    path = write_document(root, @valid_document)

    assert {:ok, %Identity{type: :regular, size: size}} =
             TestTrustedPath.pin_root_owned_regular_file(path)

    assert size <= 64 * 1024

    assert {:ok,
            %{
              apple_container: %{
                kernel_path: "/var/db/container/kernel",
                app_root: "/opt/container-app"
              },
              linux_dependency_baseline: %{
                source_root: "/var/lib/arbor/linux-deps",
                manifest_path: "/var/lib/arbor/linux-deps/manifest.json"
              },
              apple_container_image_policy: %{image: image},
              apple_container_unit_journal_path: "/var/lib/arbor/unit-journal.json"
            }} = RuntimeConfigLoader.load_with_trusted_path(path, TestTrustedPath)

    assert image == @valid_document["image_policy"]["image"]
  end

  test "runtime source keeps the optional loader branch data-only" do
    runtime = Path.expand("../../../../../config/runtime.exs", __DIR__) |> File.read!()

    assert runtime =~ "ARBOR_APPLE_CONTAINER_CONFIG_PATH"
    refute runtime =~ "Arbor.Orchestrator"
    refute runtime =~ "Arbor.Agent"
  end

  test "rejects blank, relative, noncanonical, and missing locators", %{root: root} do
    assert {:error, :config_locator_blank} = RuntimeConfigLoader.load(" ")
    assert {:error, :config_locator_relative} = RuntimeConfigLoader.load("config.json")
    assert {:error, :config_locator_noncanonical} = RuntimeConfigLoader.load("//tmp/config.json")

    missing = Path.join(root, "missing.json")
    assert {:error, :config_file_missing} = RuntimeConfigLoader.load(missing)
  end

  test "rejects directories and untrusted regular files", %{root: root} do
    assert {:error, :config_file_not_regular} = RuntimeConfigLoader.load("/")

    path = write_document(root, @valid_document)
    assert {:error, :config_file_untrusted} = RuntimeConfigLoader.load(path)
  end

  test "rejects oversized content before parsing", %{root: root} do
    path = Path.join(root, "oversized.json")
    File.write!(path, String.duplicate("x", 65 * 1024))

    assert {:error, :config_file_too_large} =
             RuntimeConfigLoader.load_with_trusted_path(path, TestTrustedPath)
  end

  test "rejects malformed JSON and closed-schema violations", %{root: root} do
    assert {:error, :config_file_invalid_json} =
             load_text(root, "{\"apple_container\":")

    assert {:error, :config_schema_extra_key} =
             load_document(root, Map.put(@valid_document, "extra", true))

    assert {:error, :config_schema_missing_key} =
             load_document(root, Map.delete(@valid_document, "image_policy"))

    duplicate =
      ~s({"apple_container":{},"linux_dependency_baseline":{},"image_policy":{},"unit_journal_path":"/j","unit_journal_path":"/other"})

    assert {:error, :config_schema_duplicate_key} = load_text(root, duplicate)
  end

  test "rejects malformed nested values", %{root: root} do
    malformed = put_in(@valid_document["apple_container"]["kernel_path"], "relative/kernel")

    assert {:error, {:config_nested_malformed, {:invalid_kernel_path, :relative_path}}} =
             load_document(root, malformed)
  end

  defp write_document(root, document) do
    path = Path.join(root, "config.json")
    File.write!(path, Jason.encode!(document))
    path
  end

  defp load_document(root, document), do: load_path(write_document(root, document))

  defp load_path(path), do: RuntimeConfigLoader.load_with_trusted_path(path, TestTrustedPath)

  defp load_text(root, text) do
    path = Path.join(root, "config.json")
    File.write!(path, text)
    load_path(path)
  end
end
