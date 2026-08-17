defmodule Arbor.Commands.SafeRecoveryClosure.ReleaseLayoutTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.SafeRecoveryClosure.ReleaseLayout

  @moduletag :fast

  test "admits a regular lib/*/ebin tree and rejects cookie or symlink entries" do
    root =
      Path.join(
        System.tmp_dir!(),
        "e0b3-rel-#{System.unique_integer([:positive, :monotonic])}"
      )

    ebin = Path.join(root, "lib/e0b3_fixture-0.1.0/ebin")
    File.mkdir_p!(ebin)
    File.write!(Path.join(ebin, "e0b3_fixture.app"), "{application, e0b3_fixture, []}.\n")
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, [admitted]} = ReleaseLayout.admit(root)
    {:ok, real_ebin} = Arbor.Common.SafePath.resolve_real(ebin)
    assert admitted == real_ebin

    File.mkdir_p!(Path.join(root, "releases"))
    File.write!(Path.join(root, "releases/COOKIE"), "leaked\n")
    assert {:error, :cookie_present} = ReleaseLayout.admit(root)
    File.rm!(Path.join(root, "releases/COOKIE"))

    link = Path.join(root, "lib/linked-0.1.0")
    File.ln_s!(ebin, link)
    assert {:error, :release_lib_entry_symlink} = ReleaseLayout.admit(root)
  end

  test "rejects a missing or non-directory root" do
    assert {:error, :release_root_missing} = ReleaseLayout.admit("/no/such/e0b3/release")
    assert {:error, :invalid_release_root} = ReleaseLayout.admit(:nope)
  end
end
