Code.require_file("trusted_build_test_helpers.exs", __DIR__)

defmodule Arbor.Shell.TrustedBuildCanonicalSourceTest do
  @moduledoc """
  A trusted-build source must be attested under its resolved path.

  The Darwin launcher passes the source path as spelled to Seatbelt and to its
  own overlap checks, while the kernel matches the resolved path. A source
  reached through a symlink (the macOS default `TMPDIR` under `/var` is one)
  used to be admitted and then fail inside the build with denied Hex temp
  writes. It is now refused at acquisition with a reason that names the cause.
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Shell
  alias Arbor.Shell.TrustedBuild
  alias Arbor.Shell.TrustedBuildTestHelpers, as: Helpers

  setup do
    suffix = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    real_parent = Path.join(Helpers.canonical_tmp_dir!(), "arbor-tb-canon-#{suffix}")
    link = Path.join(Helpers.canonical_tmp_dir!(), "arbor-tb-canon-link-#{suffix}")
    File.mkdir!(real_parent)
    File.chmod!(real_parent, 0o700)
    File.ln_s!(real_parent, link)

    on_exit(fn ->
      _ = File.rm(link)
      _ = File.rmdir(real_parent)
    end)

    {:ok, real_parent: real_parent, link: link}
  end

  test "a source attested through a symlinked ancestor is refused before any build state exists",
       %{real_parent: real_parent, link: link} do
    {:ok, identity} = Shell.create_private_owned_tree(Path.join(link, "tree"))
    on_exit(fn -> _ = Shell.remove_owned_tree(identity) end)

    assert String.starts_with?(identity.path, link <> "/")
    assert File.dir?(Path.join(real_parent, "tree"))

    assert {:error, :trusted_build_source_not_canonical} =
             TrustedBuild.acquire(request_for(identity))

    # The refusal happens before the source is bound: the tree is still unbound
    # and removable by its owner.
    assert :ok = Shell.remove_owned_tree(identity)
  end

  test "the same tree attested under its resolved path passes the canonical check",
       %{real_parent: real_parent} do
    {:ok, identity} = Shell.create_private_owned_tree(Path.join(real_parent, "tree"))
    on_exit(fn -> _ = Shell.remove_owned_tree(identity) end)

    # No project is planted, so acquisition stops at a later check; the point is
    # that it is no longer the canonical-path refusal.
    assert {:error, reason} = TrustedBuild.acquire(request_for(identity))
    refute reason == :trusted_build_source_not_canonical
  end

  defp request_for(identity) do
    %{
      "schema" => "arbor.shell.trusted_build.request.v1",
      "source" => %{
        "schema" => "arbor.shell.trusted_build.source.v1",
        "identity" => %{
          "path" => identity.path,
          "type" => "directory",
          "device" => identity.device,
          "minor_device" => identity.minor_device,
          "inode" => identity.inode
        }
      }
    }
  end
end
