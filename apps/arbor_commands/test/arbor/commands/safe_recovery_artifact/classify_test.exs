defmodule Arbor.Commands.SafeRecoveryArtifact.ClassifyTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.SafeRecoveryArtifact.Classify
  alias Arbor.Commands.SafeRecoveryArtifactFixture, as: Fixture

  @moduletag :fast

  @identities [{"arbor_trust", "0.1.0"}]

  test "validates FOR1/BEAM size framing" do
    beam = Fixture.beam_bytes()

    assert {:ok, "beam"} =
             kind("lib/arbor_trust-0.1.0/ebin/x.beam", beam, byte_size(beam), false, nil)

    truncated = binary_part(beam, 0, 8)
    assert {:error, :truncated_beam} = kind("x.beam", truncated, 8, false, nil)

    assert {:error, :malformed_signature} =
             kind("x.beam", <<"FOR1", 99::unsigned-big-32, "BEAM">>, 20, false, nil)

    assert {:error, :suffix_signature_mismatch} =
             kind("x.bin", beam, byte_size(beam), false, nil)
  end

  test "admits thin arm64 and rejects wrong architecture or short headers" do
    arm = Fixture.thin_arm64()
    assert {:ok, "native"} = kind("priv/lib.so", arm, byte_size(arm), false, "arbor_trust")

    x86 = Fixture.thin_x86_64()
    assert {:error, :target_mismatch} = kind("priv/lib.so", x86, byte_size(x86), false, nil)

    short = binary_part(arm, 0, 16)
    assert {:error, :malformed_signature} = kind("priv/lib.so", short, 16, false, nil)

    assert {:error, :target_mismatch} =
             kind("priv/lib.so", <<0xFEEDFACE::unsigned-big-32, 0, 0, 0, 0>>, 8, false, nil)
  end

  test "admits bounded fat32 with a well-formed ARM64 slice" do
    fat = Fixture.fat32_arm64()
    assert {:ok, "native"} = kind("bin/fat", fat, byte_size(fat), true, nil)
    cigam32 = fat_variant(:cigam32)
    magic64 = fat_variant(:magic64)
    cigam64 = fat_variant(:cigam64)
    assert {:ok, "native"} = kind("bin/fat", cigam32, byte_size(cigam32), true, nil)
    assert {:ok, "native"} = kind("bin/fat", magic64, byte_size(magic64), true, nil)
    assert {:ok, "native"} = kind("bin/fat", cigam64, byte_size(cigam64), true, nil)
  end

  test "rejects truncated fat tables, reserved, overlap, and out-of-file slices" do
    header = <<0xCAFEBABE::unsigned-big-32, 2::unsigned-big-32>>
    assert {:error, :malformed_signature} = kind("bin/fat", header, 8, false, nil)

    bad_reserved = fat64_record(reserved: 1)
    assert {:error, :malformed_signature} = kind("bin/fat", bad_reserved, byte_size(bad_reserved), false, nil)

    overlap = overlapping_fat()
    assert {:error, :malformed_signature} = kind("bin/fat", overlap, byte_size(overlap), false, nil)

    oob = out_of_file_fat()
    assert {:error, :malformed_signature} = kind("bin/fat", oob, 40, false, nil)
  end

  test "does not count ARM64 in a malformed fat slice" do
    # nfat=1, ARM64 cputype, but size 0.
    header = <<0xCAFEBABE::unsigned-big-32, 1::unsigned-big-32>>

    arch =
      <<0x0100000C::unsigned-big-32, 0::unsigned-big-32, 28::unsigned-big-32, 0::unsigned-big-32,
        2::unsigned-big-32>>

    bytes = header <> arch
    assert {:error, :malformed_signature} = kind("bin/fat", bytes, byte_size(bytes), false, nil)
  end

  test "rejects ELF and PE as target mismatches" do
    assert {:error, :target_mismatch} = kind("bin/a", <<"\x7FELF", 0, 0, 0, 0>>, 8, true, nil)
    assert {:error, :target_mismatch} = kind("bin/a", <<"MZ", 0, 0, 0, 0>>, 6, true, nil)
  end

  test "applies executable, priv, release, and other precedence" do
    assert {:ok, "executable"} = kind("bin/script", "hello", 5, true, nil)

    assert {:ok, "private_asset"} =
             kind("lib/arbor_trust-0.1.0/priv/data.txt", "xx", 2, false, "arbor_trust")

    assert {:ok, "release_metadata"} = kind("releases/0.1.0/vm.args", "a", 1, false, nil)
    assert {:ok, "other"} = kind("README", "x", 1, false, nil)
    assert {:ok, "app_spec"} = kind("lib/kernel-1.0.0/ebin/kernel.app", "x", 1, false, nil, :app)
    assert {:ok, "release_metadata"} = kind("releases/0.1.0/x.rel", "x", 1, false, nil, :rel)
  end

  test "rejects cookie and suffix/signature disagreement" do
    assert {:error, :cookie_present} = kind("releases/COOKIE", "secret", 6, false, nil)

    assert {:error, :suffix_signature_mismatch} =
             kind("x.app", Fixture.thin_arm64(), 32, false, nil)
  end

  defp kind(path, prefix, size, executable?, owner, role \\ nil) do
    Classify.kind(%{
      path: path,
      size: size,
      prefix: prefix,
      executable: executable?,
      term_role: role,
      owner: owner,
      identities: @identities
    })
  end

  defp fat64_record(opts) do
    reserved = Keyword.get(opts, :reserved, 0)
    header = <<0xCAFEBABF::unsigned-big-32, 1::unsigned-big-32>>
    offset = 40
    size = 16
    align = 3

    arch =
      <<0x0100000C::unsigned-big-32, 0::unsigned-big-32, offset::unsigned-big-64,
        size::unsigned-big-64, align::unsigned-big-32, reserved::unsigned-big-32>>

    header <> arch <> :binary.copy(<<0>>, size)
  end

  defp overlapping_fat do
    header = <<0xCAFEBABE::unsigned-big-32, 2::unsigned-big-32>>

    a =
      <<0x0100000C::unsigned-big-32, 0::unsigned-big-32, 48::unsigned-big-32, 16::unsigned-big-32,
        2::unsigned-big-32>>

    b =
      <<0x00000007::unsigned-big-32, 0::unsigned-big-32, 56::unsigned-big-32, 16::unsigned-big-32,
        2::unsigned-big-32>>

    header <> a <> b <> :binary.copy(<<0>>, 32)
  end

  defp fat_variant(:cigam32) do
    header = <<0xCAFEBABE::unsigned-little-32, 1::unsigned-little-32>>
    offset = 28
    size = 32
    align = 2

    arch =
      <<0x0100000C::unsigned-little-32, 0::unsigned-little-32, offset::unsigned-little-32,
        size::unsigned-little-32, align::unsigned-little-32>>

    header <> arch <> :binary.copy(<<0>>, size)
  end

  defp fat_variant(:magic64), do: fat64_record(reserved: 0)
  defp fat_variant(:cigam64), do: fat64_le()

  defp fat64_le do
    header = <<0xCAFEBABF::unsigned-little-32, 1::unsigned-little-32>>
    offset = 40
    size = 16
    align = 3

    arch =
      <<0x0100000C::unsigned-little-32, 0::unsigned-little-32, offset::unsigned-little-64,
        size::unsigned-little-64, align::unsigned-little-32, 0::unsigned-little-32>>

    header <> arch <> :binary.copy(<<0>>, size)
  end

  defp out_of_file_fat do
    header = <<0xCAFEBABE::unsigned-big-32, 1::unsigned-big-32>>

    arch =
      <<0x0100000C::unsigned-big-32, 0::unsigned-big-32, 28::unsigned-big-32, 100::unsigned-big-32,
        2::unsigned-big-32>>

    header <> arch
  end
end
