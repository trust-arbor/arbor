defmodule Arbor.Commands.SafeRecoveryClosure.ReleaseLayout do
  @moduledoc """
  Admit a Mix-release root at the fixed logical path `rel/arbor_trust`.

  Production never accepts a caller-selected executable or ebin list.
  The layout must be a regular directory tree: no `releases/COOKIE`, no
  symlinked `lib` entries, and every discovered code path is an `ebin`
  directory.
  """

  alias Arbor.Common.SafePath

  @logical_root "rel/arbor_trust"
  @max_ebins 256
  @max_path_bytes 4_096

  @spec logical_root() :: String.t()
  def logical_root, do: @logical_root

  @spec admit(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def admit(root) when is_binary(root) do
    with :ok <- reject_control(root),
         {:ok, real} <- resolve_dir(root),
         :ok <- reject_cookie(real),
         {:ok, lib} <- join_dir(real, "lib") do
      collect_ebins(lib)
    end
  end

  def admit(_), do: {:error, :invalid_release_root}

  defp reject_control(path) do
    if String.valid?(path) and not String.contains?(path, <<0>>) and
         not String.contains?(path, "\n") do
      :ok
    else
      {:error, :invalid_release_root}
    end
  end

  defp resolve_dir(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        case SafePath.resolve_real(path) do
          {:ok, real} ->
            if byte_size(real) <= @max_path_bytes do
              {:ok, real}
            else
              {:error, :release_path_unbounded}
            end

          {:error, reason} ->
            {:error, {:release_root_unresolved, reason}}
        end

      {:ok, %{type: :symlink}} ->
        {:error, :release_root_symlink}

      {:ok, _} ->
        {:error, :release_root_not_directory}

      {:error, :enoent} ->
        {:error, :release_root_missing}

      {:error, reason} ->
        {:error, {:release_root_unreadable, reason}}
    end
  end

  defp reject_cookie(root) do
    cookie = Path.join([root, "releases", "COOKIE"])

    case File.lstat(cookie) do
      {:error, :enoent} -> :ok
      {:ok, _} -> {:error, :cookie_present}
      {:error, reason} -> {:error, {:cookie_stat, reason}}
    end
  end

  defp join_dir(root, name) do
    path = Path.join(root, name)

    case File.lstat(path) do
      {:ok, %{type: :directory}} -> {:ok, path}
      {:ok, %{type: :symlink}} -> {:error, :release_lib_symlink}
      {:ok, _} -> {:error, :release_lib_not_directory}
      {:error, :enoent} -> {:error, :release_lib_missing}
      {:error, reason} -> {:error, {:release_lib_unreadable, reason}}
    end
  end

  defp collect_ebins(lib) do
    case File.ls(lib) do
      {:ok, entries} ->
        reduce_ebins(lib, Enum.sort(entries), [])

      {:error, reason} ->
        {:error, {:release_lib_list, reason}}
    end
  end

  defp reduce_ebins(_lib, [], acc) do
    paths = Enum.reverse(acc)

    cond do
      paths == [] -> {:error, :release_ebin_empty}
      length(paths) > @max_ebins -> {:error, :release_ebin_unbounded}
      true -> {:ok, paths}
    end
  end

  defp reduce_ebins(lib, [entry | rest], acc) do
    case admit_lib_entry(lib, entry) do
      {:ok, ebin} -> reduce_ebins(lib, rest, [ebin | acc])
      {:error, :skip} -> reduce_ebins(lib, rest, acc)
      {:error, _} = error -> error
    end
  end

  defp admit_lib_entry(lib, entry) do
    path = Path.join(lib, entry)

    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        ebin = Path.join(path, "ebin")

        case File.lstat(ebin) do
          {:ok, %{type: :directory}} -> {:ok, ebin}
          {:ok, %{type: :symlink}} -> {:error, :release_ebin_symlink}
          {:ok, _} -> {:error, :skip}
          {:error, :enoent} -> {:error, :skip}
          {:error, reason} -> {:error, {:release_ebin_unreadable, reason}}
        end

      {:ok, %{type: :symlink}} ->
        {:error, :release_lib_entry_symlink}

      {:ok, _} ->
        {:error, :skip}

      {:error, reason} ->
        {:error, {:release_lib_entry_unreadable, reason}}
    end
  end
end
