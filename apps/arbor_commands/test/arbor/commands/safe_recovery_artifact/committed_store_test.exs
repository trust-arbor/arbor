defmodule Arbor.Commands.SafeRecoveryArtifact.CommittedStoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.SafeRecoveryArtifact.{CommittedStore, SourcePolicy}
  alias Arbor.Common.SafePath

  @moduletag :fast

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "arbor-committed-store-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  describe "closed destination set" do
    test "paths/0 is exactly the two SourcePolicy-excluded committed paths" do
      assert CommittedStore.paths() == [
               "apps/arbor_commands/priv/packaging/safe_recovery_artifact.v1.json",
               "apps/arbor_commands/priv/packaging/safe_recovery_artifact.payload.v1.json"
             ]

      assert MapSet.new(CommittedStore.paths()) == SourcePolicy.excluded_paths()
      assert CommittedStore.paths_bound_to_source_policy?()
    end
  end

  describe "read/1 fail-closed discipline" do
    test "a fully absent pair is :artifact_missing", %{root: root} do
      assert {:error, :artifact_missing} = CommittedStore.read(real!(root))
    end

    test "a payload without an envelope is :envelope_missing", %{root: root} do
      plant_payload!(root, "payload")
      assert {:error, :envelope_missing} = CommittedStore.read(real!(root))
    end

    test "an envelope without a payload is :payload_missing", %{root: root} do
      plant_envelope!(root, "envelope")
      assert {:error, :payload_missing} = CommittedStore.read(real!(root))
    end

    test "an oversized envelope or payload fails closed before content is trusted", %{
      root: root
    } do
      root = real!(root)
      plant_envelope!(root, :binary.copy("e", 4_097))
      assert {:error, :envelope_unbounded} = CommittedStore.read(root)

      plant_pair!(root, "ok envelope", :binary.copy("p", 16_777_217))
      assert {:error, :payload_unbounded} = CommittedStore.read(root)
    end

    test "a directory or hard-linked destination is not regular", %{root: root} do
      root = real!(root)

      File.mkdir_p!(Path.join(root, rel(:envelope)))
      plant_payload!(root, "payload")
      assert {:error, :envelope_not_regular} = CommittedStore.read(root)

      File.rm_rf!(Path.join(root, rel(:envelope)))
      plant_envelope!(root, "envelope")
      linked = Path.join(root, "linked-copy")
      File.ln!(Path.join(root, rel(:envelope)), linked)
      plant_payload!(root, "payload")
      assert {:error, :envelope_not_regular} = CommittedStore.read(root)
    end

    test "a symlinked destination file is refused", %{root: root} do
      root = real!(root)
      outside = outside_dir!()

      try do
        File.write!(Path.join(outside, "steal-envelope"), "stolen")
        File.mkdir_p!(Path.dirname(Path.join(root, rel(:envelope))))
        File.ln_s!(Path.join(outside, "steal-envelope"), Path.join(root, rel(:envelope)))
        plant_payload!(root, "payload")

        assert {:error, :envelope_not_regular} = CommittedStore.read(root)
      after
        File.rm_rf!(outside)
      end
    end

    test "a symlinked ancestor chain is refused", %{root: root} do
      root = real!(root)
      outside = outside_dir!()

      try do
        # Swap priv for a symlink to an outside tree holding the payload.
        File.rm_rf!(Path.join(root, "apps/arbor_commands/priv"))
        File.mkdir_p!(Path.join(root, "apps/arbor_commands"))
        File.mkdir_p!(Path.join(outside, "packaging"))
        File.write!(Path.join(Path.join(outside, "packaging"), store_name(:payload)), "outside")
        File.ln_s!(Path.join(outside, "packaging"), Path.join(root, "apps/arbor_commands/priv"))
        plant_envelope!(root, "envelope")

        # The envelope (read first) resolves through the symlinked ancestor.
        assert {:error, :envelope_symlink_redirection} = CommittedStore.read(root)
      after
        File.rm_rf!(outside)
      end
    end

    test "a non-binary root is refused" do
      assert {:error, :invalid_root} = CommittedStore.read(:not_a_root)
    end
  end

  describe "write/3 discipline" do
    test "creates exactly the two committed paths, then reads back byte-identical", %{
      root: root
    } do
      root = real!(root)
      envelope_bytes = "envelope bytes"
      payload_bytes = "payload bytes"

      assert :ok = CommittedStore.write(root, envelope_bytes, payload_bytes)

      assert {:ok, %{envelope_bytes: ^envelope_bytes, payload_bytes: ^payload_bytes}} =
               CommittedStore.read(root)

      assert Enum.sort(File.ls!(Path.join(root, "apps/arbor_commands/priv/packaging"))) == [
               "safe_recovery_artifact.payload.v1.json",
               "safe_recovery_artifact.v1.json"
             ]
    end

    test "a repeat write of identical bytes is idempotent with identical digests", %{root: root} do
      root = real!(root)
      assert :ok = CommittedStore.write(root, "e1", "p1")

      envelope_path = Path.join(root, rel(:envelope))
      payload_path = Path.join(root, rel(:payload))
      first = {digest_of(envelope_path), digest_of(payload_path)}

      assert :ok = CommittedStore.write(root, "e1", "p1")
      assert first == {digest_of(envelope_path), digest_of(payload_path)}
    end

    test "replaces pre-existing regular files at exactly the two paths", %{root: root} do
      root = real!(root)
      plant_pair!(root, "old envelope", "old payload")

      assert :ok = CommittedStore.write(root, "new envelope", "new payload")

      assert {:ok, %{envelope_bytes: "new envelope", payload_bytes: "new payload"}} =
               CommittedStore.read(root)
    end

    test "refuses an out-of-bound envelope or payload", %{root: root} do
      root = real!(root)

      assert {:error, :envelope_unbounded} =
               CommittedStore.write(root, :binary.copy("e", 4_097), "p")

      assert {:error, :invalid_payload} = CommittedStore.write(root, "e", "")

      assert {:error, :payload_unbounded} =
               CommittedStore.write(root, "e", :binary.copy("p", 16_777_217))

      assert {:error, :invalid_input} = CommittedStore.write(:not_a_root, "e", "p")
    end

    test "security regression: a symlinked destination fails closed and is never written through",
         %{root: root} do
      root = real!(root)
      outside = outside_dir!()

      try do
        File.mkdir_p!(Path.dirname(Path.join(root, rel(:envelope))))

        target = Path.join(outside, "hijack.json")
        File.write!(target, "outside target")
        File.ln_s!(target, Path.join(root, rel(:envelope)))

        assert {:error, :destination_symlink} = CommittedStore.write(root, "e", "p")
        # The symlink survives unwritten-through; the outside target is untouched.
        assert File.read!(target) == "outside target"
        assert {:ok, _} = File.read_link(Path.join(root, rel(:envelope)))

        # The payload destination was never created either (write refused
        # before the first byte landed).
        assert {:error, :enoent} = File.lstat(Path.join(root, rel(:payload)))
      after
        File.rm_rf!(outside)
      end
    end

    test "security regression: a symlinked parent directory fails closed before any write",
         %{root: root} do
      root = real!(root)
      outside = outside_dir!()

      try do
        # The packaging parent itself is a symlink to an outside tree.
        File.mkdir_p!(Path.join(root, "apps/arbor_commands/priv"))
        File.mkdir_p!(Path.join(outside, "packaging"))

        File.ln_s!(
          Path.join(outside, "packaging"),
          Path.join(root, "apps/arbor_commands/priv/packaging")
        )

        assert {:error, :destination_parent_not_directory} =
                 CommittedStore.write(root, "e", "p")

        # Nothing landed outside the root through the symlinked parent.
        assert File.ls!(Path.join(outside, "packaging")) == []
      after
        File.rm_rf!(outside)
      end
    end

    test "a deeper symlinked ancestor fails closed as a parent symlink", %{root: root} do
      root = real!(root)
      outside = outside_dir!()

      try do
        # Swap `priv` itself for a symlink; `packaging` then resolves outside.
        File.rm_rf!(Path.join(root, "apps/arbor_commands/priv"))
        File.mkdir_p!(Path.join(root, "apps/arbor_commands"))
        File.mkdir_p!(Path.join(outside, "packaging"))
        File.ln_s!(Path.join(outside, "packaging"), Path.join(root, "apps/arbor_commands/priv"))

        assert {:error, :destination_parent_symlink} =
                 CommittedStore.write(root, "e", "p")
      after
        File.rm_rf!(outside)
      end
    end

    test "a directory parked at a destination is refused", %{root: root} do
      root = real!(root)
      File.mkdir_p!(Path.join(root, rel(:envelope)))

      assert {:error, :destination_not_regular} = CommittedStore.write(root, "e", "p")
    end

    test "security regression: repeat-write after symlink substitution fails closed, then a clean re-write succeeds",
         %{root: root} do
      root = real!(root)
      outside = outside_dir!()

      try do
        assert :ok = CommittedStore.write(root, "envelope", "payload")

        # Substitute the committed envelope with a symlink to an outside file.
        target = Path.join(outside, "substitute.json")
        File.write!(target, "substitute target")
        File.rm!(Path.join(root, rel(:envelope)))
        File.ln_s!(target, Path.join(root, rel(:envelope)))

        assert {:error, :destination_symlink} = CommittedStore.write(root, "envelope", "payload")
        assert File.read!(target) == "substitute target"

        # Cleaning the symlink restores the closed two-path write.
        File.rm!(Path.join(root, rel(:envelope)))
        assert :ok = CommittedStore.write(root, "envelope", "payload")

        assert {:ok, %{envelope_bytes: "envelope", payload_bytes: "payload"}} =
                 CommittedStore.read(root)
      after
        File.rm_rf!(outside)
      end
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp real!(root) do
    {:ok, real} = SafePath.resolve_real(root)
    real
  end

  defp rel(:envelope), do: "apps/arbor_commands/priv/packaging/safe_recovery_artifact.v1.json"

  defp rel(:payload),
    do: "apps/arbor_commands/priv/packaging/safe_recovery_artifact.payload.v1.json"

  defp store_name(:envelope), do: "safe_recovery_artifact.v1.json"
  defp store_name(:payload), do: "safe_recovery_artifact.payload.v1.json"

  defp plant_envelope!(root, bytes),
    do: plant_file!(root, rel(:envelope), bytes)

  defp plant_payload!(root, bytes),
    do: plant_file!(root, rel(:payload), bytes)

  defp plant_pair!(root, envelope_bytes, payload_bytes) do
    plant_envelope!(root, envelope_bytes)
    plant_payload!(root, payload_bytes)
  end

  defp plant_file!(root, rel, bytes) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end

  defp outside_dir! do
    Path.join(
      System.tmp_dir!(),
      "arbor-committed-outside-#{System.unique_integer([:positive, :monotonic])}"
    )
    |> tap(&File.mkdir_p!/1)
  end

  defp digest_of(path) do
    :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
  end
end
