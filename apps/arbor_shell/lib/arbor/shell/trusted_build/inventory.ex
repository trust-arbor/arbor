defmodule Arbor.Shell.TrustedBuild.Inventory do
  @moduledoc false

  alias Arbor.Shell.RegularTreeInventory

  @schema "arbor.shell.trusted_build.inventory.v1"

  @spec release_document(String.t()) :: {:ok, map()} | {:error, term()}
  def release_document(build_path) when is_binary(build_path) do
    rel_root = Path.join(build_path, "rel")

    case File.lstat(rel_root) do
      {:ok, %File.Stat{type: :directory}} ->
        case RegularTreeInventory.inventory(rel_root) do
          {:ok, document} ->
            {:ok,
             %{
               "schema" => @schema,
               "kind" => "release",
               "directories" => document["directories"],
               "regular_files" => document["regular_files"],
               "counts" => document["counts"]
             }}

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, %File.Stat{}} ->
        {:error, :trusted_build_release_absent}

      {:error, :enoent} ->
        {:error, :trusted_build_release_absent}

      {:error, _reason} ->
        {:error, :trusted_build_release_absent}
    end
  end

  def release_document(_build_path), do: {:error, :trusted_build_release_absent}
end
