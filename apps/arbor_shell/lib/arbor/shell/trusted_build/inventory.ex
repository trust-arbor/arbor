defmodule Arbor.Shell.TrustedBuild.Inventory do
  @moduledoc false

  alias Arbor.Shell.RegularTreeInventory
  alias Arbor.Shell.TrustedBuild.NativeOverlay

  @schema "arbor.shell.trusted_build.inventory.v1"

  @spec deps_document(String.t()) :: {:ok, map()} | {:error, term()}
  def deps_document(deps_path) when is_binary(deps_path) do
    snapshot(deps_path, "deps")
  end

  def deps_document(_deps_path), do: {:error, :identity_mismatch}

  @spec release_document(String.t()) :: {:ok, map()} | {:error, term()}
  def release_document(build_path) when is_binary(build_path) do
    rel_root = Path.join(build_path, "rel")

    case File.lstat(rel_root) do
      {:ok, %File.Stat{type: :directory}} ->
        snapshot(rel_root, "release")

      {:ok, %File.Stat{}} ->
        {:error, :trusted_build_release_absent}

      {:error, :enoent} ->
        {:error, :trusted_build_release_absent}

      {:error, _reason} ->
        {:error, :trusted_build_release_absent}
    end
  end

  def release_document(_build_path), do: {:error, :trusted_build_release_absent}

  @spec cookie_present?(map()) :: boolean()
  def cookie_present?(%{"regular_files" => files}) when is_list(files) do
    Enum.any?(files, &(&1["path"] == NativeOverlay.cookie_inventory_path()))
  end

  def cookie_present?(_document), do: true

  defp snapshot(root, kind) do
    case RegularTreeInventory.inventory(root) do
      {:ok, document} ->
        {:ok,
         %{
           "schema" => @schema,
           "kind" => kind,
           "directories" => document["directories"],
           "regular_files" => document["regular_files"],
           "counts" => document["counts"]
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
