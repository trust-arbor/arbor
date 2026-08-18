defmodule Arbor.Commands.SafeManagementSurfaceTest do
  use ExUnit.Case, async: false

  alias Arbor.Commands.SafeManagementSurface
  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Extension.Envelope
  alias Arbor.KernelRuntime.SafeManagementSurface.Core

  @moduletag :fast

  setup do
    root = temp_umbrella_root!()
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "production rejects every caller-supplied authorization or execution seam" do
    forbidden = [
      authorization_status: "verified",
      candidate: %{},
      receipt_map: %{},
      profile: %{},
      mfa: {__MODULE__, :receipt, []},
      decoder: Jason,
      callback: fn -> :ok end
    ]

    for {key, value} <- forbidden do
      assert {:error, {:production_opts_forbid_synthetic, [^key]}} =
               SafeManagementSurface.run([
                 {:operation, "list"},
                 {:receipt, "apps/arbor_commands/priv/packaging/receipt.json"},
                 {key, value}
               ])
    end
  end

  test "strictly admits production option shape, keys, duplicates, and values" do
    assert {:error, :invalid_opts} = SafeManagementSurface.run(%{})
    assert {:error, :invalid_opts} = SafeManagementSurface.run([:operation])
    assert {:error, :invalid_opts} = SafeManagementSurface.run([{"operation", "list"}])
    assert {:error, {:missing_option, :operation}} = SafeManagementSurface.run([])
    assert {:error, {:missing_option, :receipt}} = SafeManagementSurface.run(operation: "list")

    assert {:error, {:duplicate_option, :operation}} =
             SafeManagementSurface.run(operation: "list", operation: "revoke", receipt: "x.json")

    assert {:error, {:invalid_option, :operation}} =
             SafeManagementSurface.run(operation: "purge", receipt: "x.json")

    assert {:error, {:invalid_option, :operation}} =
             SafeManagementSurface.run(operation: :list, receipt: "x.json")

    assert {:error, {:invalid_option, :receipt}} =
             SafeManagementSurface.run(operation: "list", receipt: "")

    assert {:error, {:invalid_option, :root}} =
             SafeManagementSurface.run(operation: "list", receipt: "x.json", root: 1)
  end

  test "a valid fixture receipt is never bearer authority on the production path", %{
    root: root
  } do
    receipt = Envelope.fixture(:activation_receipt)
    assert {:ok, ^receipt} = Envelope.validate(:activation_receipt, receipt)
    rel = write_receipt!(root, receipt)

    assert {:ok, document} =
             SafeManagementSurface.run(root: root, operation: "list", receipt: rel)

    assert document["schema"] == Core.schema()
    assert document["operation"] == "list"
    assert document["authorization_status"] == "absent"
    assert document["decision"] == "denied"
    assert document["error"] == "authorization_absent"
    assert Envelope.error_code?(:activation, document["error"])
    assert document["effects"] == []
    assert document["architecture_status"] == "blocked"
    assert document["receipt"] == receipt

    assert {:ok, revoked} =
             SafeManagementSurface.run(root: root, operation: "revoke", receipt: rel)

    assert revoked["decision"] == "denied"
    assert revoked["error"] == "authorization_absent"
    assert revoked["effects"] == []
    assert revoked["architecture_status"] == "blocked"
  end

  test "run_for_test verified list admits with no mutation effects or ProtectedRegistry", %{
    root: root
  } do
    receipt = Envelope.fixture(:activation_receipt)
    rel = write_receipt!(root, receipt)
    before = Process.whereis(Arbor.Common.Extension.ProtectedRegistry)

    assert {:ok, document} =
             SafeManagementSurface.run_for_test(
               root: root,
               operation: "list",
               receipt: rel,
               authorization_status: "verified"
             )

    assert document["decision"] == "admitted"
    assert document["error"] == nil
    assert document["effects"] == []
    assert document["authorization_status"] == "verified"
    assert document["architecture_status"] == "blocked"
    assert Process.whereis(Arbor.Common.Extension.ProtectedRegistry) == before

    assert {:ok, revoked} =
             SafeManagementSurface.run_for_test(
               root: root,
               operation: "revoke",
               receipt: rel,
               authorization_status: "verified"
             )

    assert revoked["decision"] == "admitted"

    assert revoked["effects"] == [
             %{"kind" => "revoke", "transaction_id" => receipt["transaction_id"]}
           ]

    assert Process.whereis(Arbor.Common.Extension.ProtectedRegistry) == before
  end

  test "run_for_test rejects extra seams and forged authorization", %{root: root} do
    rel = write_receipt!(root)

    assert {:error, {:unknown_option, :candidate}} =
             SafeManagementSurface.run_for_test(
               root: root,
               operation: "list",
               receipt: rel,
               authorization_status: "verified",
               candidate: %{}
             )

    assert {:error, {:invalid_option, :authorization_status}} =
             SafeManagementSurface.run_for_test(
               root: root,
               operation: "list",
               receipt: rel,
               authorization_status: "forged"
             )
  end

  test "root and receipt escape attempts fail closed", %{root: root} do
    rel = write_receipt!(root)

    assert {:error, :invalid_root_marker} =
             SafeManagementSurface.run(root: "../outside", operation: "list", receipt: rel)

    assert {:error, {:root_path, :null_byte}} =
             SafeManagementSurface.run(root: "ok\0bad", operation: "list", receipt: rel)

    assert {:error, :receipt_path_escape} =
             SafeManagementSurface.run(
               root: root,
               operation: "list",
               receipt: "../outside.json"
             )

    assert {:error, {:receipt_path, :null_byte}} =
             SafeManagementSurface.run(root: root, operation: "list", receipt: "ok\0bad.json")

    outside = Path.join(Path.dirname(root), "outside-receipt.json")
    on_exit(fn -> File.rm_rf(outside) end)
    File.write!(outside, Jason.encode!(Envelope.fixture(:activation_receipt)))

    assert {:error, :receipt_path_escape} =
             SafeManagementSurface.run(root: root, operation: "list", receipt: outside)
  end

  test "receipt symlink inside or outside the root is rejected", %{root: root} do
    target = Path.join(root, "apps/arbor_commands/priv/packaging/target.json")
    File.mkdir_p!(Path.dirname(target))
    File.write!(target, Jason.encode!(Envelope.fixture(:activation_receipt)))

    rel = "apps/arbor_commands/priv/packaging/receipt.json"
    :ok = File.ln_s(target, Path.join(root, rel))

    assert {:error, :receipt_symlink_redirection} =
             SafeManagementSurface.run(root: root, operation: "list", receipt: rel)

    File.rm!(Path.join(root, rel))
    outside = Path.join(Path.dirname(root), "outside-linked-receipt.json")
    on_exit(fn -> File.rm_rf(outside) end)
    File.write!(outside, Jason.encode!(Envelope.fixture(:activation_receipt)))
    :ok = File.ln_s(outside, Path.join(root, rel))

    assert {:error, :receipt_path_escape} =
             SafeManagementSurface.run(root: root, operation: "list", receipt: rel)
  end

  test "reader is bounded independently of stat size by the ceiling+1 path", %{root: root} do
    rel = "apps/arbor_commands/priv/packaging/huge.json"
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    max_receipt_bytes = SafeManagementSurface.max_receipt_bytes()
    {:ok, io} = File.open(path, [:write, :binary])

    try do
      assert {:ok, ^max_receipt_bytes} = :file.position(io, max_receipt_bytes)
      :ok = IO.binwrite(io, <<0>>)
    after
      File.close(io)
    end

    assert File.stat!(path).size == max_receipt_bytes + 1

    assert {:error, :receipt_too_large} =
             SafeManagementSurface.run(root: root, operation: "list", receipt: rel)
  end

  test "missing, non-regular, and invalid receipt JSON fail closed", %{root: root} do
    missing = "apps/arbor_commands/priv/packaging/missing.json"

    assert {:error, :receipt_missing} =
             SafeManagementSurface.run(root: root, operation: "list", receipt: missing)

    dir = Path.join(root, missing)
    File.mkdir_p!(dir)

    assert {:error, :receipt_not_regular} =
             SafeManagementSurface.run(root: root, operation: "list", receipt: missing)

    File.rmdir!(dir)
    File.write!(dir, "[")

    assert {:error, :receipt_invalid_json} =
             SafeManagementSurface.run(root: root, operation: "list", receipt: missing)
  end

  test "production Application.start stays start_profile :full and the adapter never applies mutations" do
    assert Arbor.KernelRuntime.Config.start_profile() == :full

    config =
      File.read!(Path.expand("../../../../../config/config.exs", __DIR__))

    assert config =~ ~r/kernel_runtime:\s*\[\n\s+start_profile: :full/

    application =
      File.read!(
        Path.expand(
          "../../../../../apps/arbor_kernel_runtime/lib/arbor/kernel_runtime/application.ex",
          __DIR__
        )
      )

    assert application =~ "defp children_for_profile(:full), do: {:ok, @full_children}"

    shell =
      File.read!(Path.expand("../../../lib/arbor/commands/safe_management_surface.ex", __DIR__))

    mix =
      File.read!(
        Path.expand(
          "../../../lib/mix/tasks/arbor.packaging.safe_management_surface.ex",
          __DIR__
        )
      )

    Enum.each([shell, mix], fn src ->
      refute src =~ "ProtectedRegistry"
      refute src =~ "owner_token"
      refute src =~ "Application.start"
      refute src =~ "Application.ensure_all_started"
      refute src =~ "Extension.Activation"
    end)

    refute mix =~ "--authorization-status"
  end

  defp write_receipt!(root, receipt \\ Envelope.fixture(:activation_receipt)) do
    rel = "apps/arbor_commands/priv/packaging/activation_receipt.json"
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(receipt))
    rel
  end

  defp temp_umbrella_root! do
    root =
      Path.join(
        System.tmp_dir!(),
        "arbor-safe-management-#{System.unique_integer([:positive, :monotonic])}"
      )

    for marker <- ["mix.exs", "apps/arbor_commands/mix.exs", "apps/arbor_kernel/mix.exs"] do
      path = Path.join(root, marker)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "# marker\n")
    end

    {:ok, real_root} = SafePath.resolve_real(root)
    real_root
  end
end
