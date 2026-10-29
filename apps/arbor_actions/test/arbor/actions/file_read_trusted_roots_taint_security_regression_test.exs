defmodule Arbor.Actions.FileReadTrustedRootsTaintSecurityRegressionTest do
  @moduledoc """
  Security regression (Exposure Check AE): file content read from outside
  configured trusted roots must be labeled `:untrusted` so later capability
  checks and the taint policy see it. Reads inside those roots stay unlabeled.

  Paths are canonicalized with symlinks resolved before the root check, so a
  link planted inside a trusted root that points outside cannot launder
  foreign content as trusted input.

  These tests fail on HEAD~1, where `File.Read` / `path_provenance` only apply
  a path-string heuristic (`/tmp`, secrets, downloads) and leave ordinary
  out-of-root reads unlabeled.
  """
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Actions.File, as: FileActions
  alias Arbor.Actions.Taint
  alias Arbor.Common.SafePath

  setup do
    fixture_root = exclusive_home_fixture_root()
    trusted_root = Path.join(fixture_root, "trusted")
    outside_root = Path.join(fixture_root, "outside")
    File.mkdir_p!(trusted_root)
    File.mkdir_p!(outside_root)

    inside_path = Path.join(trusted_root, "notes.md")
    outside_path = Path.join(outside_root, "notes.md")
    File.write!(inside_path, "inside trusted root")
    File.write!(outside_path, "outside trusted root")

    {:ok, canonical_trusted} = SafePath.resolve_real(trusted_root)
    {:ok, canonical_inside} = SafePath.resolve_real(inside_path)
    {:ok, canonical_outside} = SafePath.resolve_real(outside_path)

    planted_link = Path.join(trusted_root, "planted.md")
    File.ln_s!(canonical_outside, planted_link)

    previous_roots = Application.fetch_env(:arbor_actions, :trusted_file_roots)
    previous_opt_out = Application.fetch_env(:arbor_actions, :taint_file_reads_outside_trusted_roots)

    Application.put_env(:arbor_actions, :trusted_file_roots, [canonical_trusted])
    Application.delete_env(:arbor_actions, :taint_file_reads_outside_trusted_roots)

    on_exit(fn ->
      restore_env(:trusted_file_roots, previous_roots)
      restore_env(:taint_file_reads_outside_trusted_roots, previous_opt_out)
      File.rm_rf(fixture_root)
    end)

    %{
      inside_path: canonical_inside,
      outside_path: canonical_outside,
      planted_link: planted_link
    }
  end

  test "security regression: reading a file outside trusted roots yields tainted content",
       %{outside_path: outside_path} do
    assert {:ok, result} = FileActions.Read.run(%{path: outside_path}, %{})
    assert result.content == "outside trusted root"

    assert result_taint(result) == :untrusted,
           "File.Read must label out-of-root content so capability checks and taint policy see it"

    assert Taint.output_taint_for(FileActions.Read, %{path: outside_path}) == :untrusted
    assert Taint.output_taint_for(FileActions.Read, %{"path" => outside_path}) == :untrusted
  end

  test "security regression: reading a file inside trusted roots stays untainted",
       %{inside_path: inside_path} do
    assert {:ok, result} = FileActions.Read.run(%{path: inside_path}, %{})
    assert result.content == "inside trusted root"

    assert result_taint(result) == nil,
           "in-root file content must not be labeled untrusted"

    assert Taint.output_taint_for(FileActions.Read, %{path: inside_path}) == nil
  end

  test "security regression: symlink into an untrusted path is labeled after canonicalization",
       %{planted_link: planted_link} do
    assert {:ok, result} = FileActions.Read.run(%{path: planted_link}, %{})
    assert result.content == "outside trusted root"

    assert result_taint(result) == :untrusted,
           "a trusted-root symlink whose real path is outside the roots must stay untrusted"

    assert Taint.output_taint_for(FileActions.Read, %{path: planted_link}) == :untrusted
  end

  defp result_taint(result) when is_map(result) do
    Map.get(result, :taint) || Map.get(result, "taint")
  end

  defp exclusive_home_fixture_root do
    Stream.repeatedly(fn ->
      Path.join(
        System.user_home!(),
        "arbor-file-taint-#{System.system_time(:nanosecond)}-#{:erlang.unique_integer([:positive])}"
      )
    end)
    |> Enum.find(fn path -> File.mkdir(path) == :ok end)
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:arbor_actions, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:arbor_actions, key)
end
