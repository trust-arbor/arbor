defmodule Arbor.Common.SkillLibrary.ScanGuard do
  @moduledoc false

  @max_file_bytes 2 * 1024 * 1024
  @max_depth 32

  @spec directory?(String.t()) :: boolean()
  def directory?(path) when is_binary(path) do
    match?({:ok, %File.Stat{type: :directory}}, File.lstat(path))
  end

  @spec regular_file?(String.t()) :: boolean()
  def regular_file?(path) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} -> size <= @max_file_bytes
      _ -> false
    end
  end

  @spec read_regular(String.t()) :: {:ok, binary()} | {:error, term()}
  def read_regular(path) when is_binary(path) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_file_bytes <-
           File.lstat(path),
         {:ok, content} when byte_size(content) <= @max_file_bytes <- File.read(path) do
      {:ok, content}
    else
      {:ok, %File.Stat{type: :regular}} -> {:error, :file_too_large}
      {:ok, _other} -> {:error, :unsafe_file_type}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :file_too_large}
    end
  end

  @spec recursive_named_files(String.t(), String.t()) :: [String.t()]
  def recursive_named_files(root, filename)
      when is_binary(root) and is_binary(filename) do
    if directory?(root), do: walk(root, filename, 0), else: []
  end

  @spec entries(String.t()) :: [{String.t(), String.t(), File.Stat.t()}]
  def entries(dir) when is_binary(dir) do
    if directory?(dir) do
      case File.ls(dir) do
        {:ok, names} ->
          Enum.flat_map(names, fn name ->
            path = Path.join(dir, name)

            case File.lstat(path) do
              {:ok, %File.Stat{type: type} = stat} when type in [:directory, :regular] ->
                [{path, name, stat}]

              _symlink_or_unreadable ->
                []
            end
          end)

        {:error, _reason} ->
          []
      end
    else
      []
    end
  end

  defp walk(_dir, _filename, depth) when depth > @max_depth, do: []

  defp walk(dir, filename, depth) do
    dir
    |> entries()
    |> Enum.flat_map(fn
      {path, _name, %File.Stat{type: :directory}} ->
        walk(path, filename, depth + 1)

      {path, ^filename, %File.Stat{type: :regular, size: size}} when size <= @max_file_bytes ->
        [path]

      _other ->
        []
    end)
  end
end
