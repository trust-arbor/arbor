defmodule Arbor.Actions.Coding.Workspace.DeltaRanges do
  @moduledoc false

  alias Arbor.Actions.Coding.ReviewTree

  @max_diff_bytes 1_048_576
  @max_files 2_000
  @max_hunks 10_000
  @max_line_number 10_000_000

  @doc false
  def max_diff_bytes, do: @max_diff_bytes

  @doc false
  def max_line_number, do: @max_line_number

  @doc false
  @spec parse_material(String.t(), String.t(), [String.t()]) ::
          {:ok, %{ranges: %{String.t() => [[pos_integer()]]}, files: [String.t()]}}
          | {:error, atom()}
  def parse_material(ordinary_diff, opaque_diff, opaque_paths)
      when is_binary(ordinary_diff) and is_binary(opaque_diff) and is_list(opaque_paths) do
    combined = ordinary_diff <> opaque_diff

    with :ok <- validate_diff(combined),
         :ok <- validate_opaque_paths(opaque_paths),
         {:ok, ordinary_ranges} <- parse_optional_ordinary(ordinary_diff),
         {:ok, ordinary_files} <- ordinary_files(ordinary_diff),
         {:ok, opaque} <- parse_optional_opaque(opaque_diff, MapSet.new(opaque_paths)),
         :ok <- require_disjoint_files(ordinary_files, opaque.files),
         files <- ordinary_files ++ opaque.files,
         :ok <- validate_material_bounds(combined, files),
         {:ok, ranges} <- merge_material_ranges(ordinary_ranges, opaque.ranges) do
      {:ok, %{ranges: ranges, files: Enum.sort(files)}}
    end
  end

  def parse_material(_, _, _), do: {:error, :invalid_unified_diff}

  @doc false
  @spec parse(String.t()) ::
          {:ok, %{String.t() => [[pos_integer()]]}} | {:error, atom()}
  def parse(diff) when is_binary(diff) do
    with :ok <- validate_diff(diff),
         {:ok, state} <- parse_lines(String.split(diff, "\n", trim: false)),
         :ok <- validate_terminal_state(state) do
      {:ok, state.ranges}
    end
  end

  def parse(_), do: {:error, :invalid_unified_diff}

  defp validate_diff(diff) do
    cond do
      diff == "" -> {:error, :empty_unified_diff}
      byte_size(diff) > @max_diff_bytes -> {:error, :unified_diff_too_large}
      not String.valid?(diff) -> {:error, :invalid_unified_diff}
      String.contains?(diff, <<0>>) -> {:error, :binary_unified_diff}
      true -> :ok
    end
  end

  defp parse_lines(lines) do
    Enum.reduce_while(lines, {:ok, initial_state()}, fn line, {:ok, state} ->
      case parse_line(line, state) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp initial_state do
    %{
      files: 0,
      hunks: 0,
      seen_file?: false,
      old_path: nil,
      new_path: :pending,
      ranges: %{}
    }
  end

  defp parse_line("diff --git " <> rest, state) do
    with :ok <- require_complete_file(state),
         :ok <- validate_diff_header(rest),
         :ok <- require_file_capacity(state) do
      {:ok,
       %{state | files: state.files + 1, seen_file?: true, old_path: nil, new_path: :pending}}
    end
  end

  defp parse_line("Binary files " <> _rest, _state), do: {:error, :binary_unified_diff}
  defp parse_line("GIT binary patch", _state), do: {:error, :binary_unified_diff}

  defp parse_line("--- " <> path, %{seen_file?: true, old_path: nil, new_path: :pending} = state) do
    with {:ok, old_path} <- parse_old_path(path) do
      {:ok, %{state | old_path: old_path}}
    end
  end

  defp parse_line(
         "+++ " <> path,
         %{seen_file?: true, old_path: old_path, new_path: :pending} = state
       )
       when not is_nil(old_path) do
    with {:ok, new_path} <- parse_new_path(path) do
      {:ok, %{state | new_path: new_path}}
    end
  end

  defp parse_line("@@ " <> hunk, %{new_path: nil} = state) do
    with {:ok, nil} <- parse_hunk(hunk),
         :ok <- require_hunk_capacity(state) do
      {:ok, %{state | hunks: state.hunks + 1}}
    else
      {:ok, _range} -> {:error, :malformed_unified_diff}
      {:error, _reason} = error -> error
    end
  end

  defp parse_line("@@ " <> hunk, %{new_path: path} = state) when is_binary(path) do
    with {:ok, range} <- parse_hunk(hunk),
         :ok <- require_hunk_capacity(state),
         {:ok, ranges} <- add_range(state.ranges, path, range) do
      {:ok, %{state | hunks: state.hunks + 1, ranges: ranges}}
    end
  end

  defp parse_line("@@ " <> _rest, _state), do: {:error, :malformed_unified_diff}

  defp parse_line("--- " <> _path, _state), do: {:error, :malformed_unified_diff}
  defp parse_line("+++ " <> _path, _state), do: {:error, :malformed_unified_diff}
  defp parse_line(_line, state), do: {:ok, state}

  defp validate_diff_header(rest) do
    cond do
      rest == "" -> {:error, :malformed_unified_diff}
      String.contains?(rest, "\"") -> {:error, :quoted_unified_diff_path}
      not String.contains?(rest, " b/") -> {:error, :malformed_unified_diff}
      true -> :ok
    end
  end

  defp parse_old_path("/dev/null"), do: {:ok, :dev_null}

  defp parse_old_path("a/" <> path) do
    validate_path(path)
  end

  defp parse_old_path(_), do: {:error, :malformed_unified_diff}

  defp parse_new_path("/dev/null"), do: {:ok, nil}

  defp parse_new_path("b/" <> path) do
    validate_path(path)
  end

  defp parse_new_path(_), do: {:error, :malformed_unified_diff}

  defp validate_path(path) do
    case ReviewTree.validate_repo_relative_path(path) do
      {:ok, path} -> {:ok, path}
      {:error, _reason} -> {:error, :invalid_unified_diff_path}
    end
  end

  defp parse_hunk(hunk) do
    case Regex.run(~r/\A-(\d+(?:,\d+)?) \+(\d+(?:,\d+)?) @@(?: .*)?\z/, hunk) do
      [_, old_range, new_range] ->
        with {:ok, _old_range} <- parse_hunk_range(old_range),
             {:ok, new_range} <- parse_hunk_range(new_range) do
          {:ok, new_range}
        end

      _ ->
        {:error, :malformed_unified_diff}
    end
  end

  defp parse_hunk_range(range) do
    case String.split(range, ",", parts: 2) do
      [start_text] -> new_range(start_text, "1")
      [start_text, count_text] -> new_range(start_text, count_text)
      _ -> {:error, :malformed_unified_diff}
    end
  end

  defp new_range(start_text, count_text) do
    with {:ok, start} <- parse_line_number(start_text),
         {:ok, count} <- parse_line_number(count_text),
         :ok <- validate_range_bounds(start, count) do
      if count == 0, do: {:ok, nil}, else: {:ok, [start, start + count - 1]}
    end
  end

  defp parse_line_number(number) do
    case Integer.parse(number) do
      {value, ""} when value >= 0 and value <= @max_line_number -> {:ok, value}
      _ -> {:error, :malformed_unified_diff}
    end
  end

  defp validate_range_bounds(0, 0), do: :ok

  defp validate_range_bounds(start, count)
       when start > 0 and count > 0 and start + count - 1 <= @max_line_number,
       do: :ok

  defp validate_range_bounds(_, _), do: {:error, :malformed_unified_diff}

  defp add_range(ranges, _path, nil), do: {:ok, ranges}

  defp add_range(ranges, path, [start, finish]) do
    with {:ok, updated} <- merge_range(Map.get(ranges, path, []), start, finish) do
      {:ok, Map.put(ranges, path, updated)}
    end
  end

  defp merge_range([], start, finish), do: {:ok, [[start, finish]]}

  defp merge_range(ranges, start, finish) do
    case List.last(ranges) do
      [previous_start, _previous_finish] when start < previous_start ->
        {:error, :out_of_order_unified_diff_hunk}

      [previous_start, previous_finish] when start <= previous_finish + 1 ->
        {:ok, List.replace_at(ranges, -1, [previous_start, max(previous_finish, finish)])}

      _other ->
        {:ok, ranges ++ [[start, finish]]}
    end
  end

  defp require_complete_file(%{old_path: nil, new_path: :pending}), do: :ok

  defp require_complete_file(%{old_path: old_path, new_path: new_path})
       when not is_nil(old_path) and new_path != :pending,
       do: :ok

  defp require_complete_file(_), do: {:error, :malformed_unified_diff}

  defp require_file_capacity(%{files: files}) when files < @max_files, do: :ok
  defp require_file_capacity(_), do: {:error, :too_many_unified_diff_files}

  defp require_hunk_capacity(%{hunks: hunks}) when hunks < @max_hunks, do: :ok
  defp require_hunk_capacity(_), do: {:error, :too_many_unified_diff_hunks}

  defp validate_terminal_state(%{seen_file?: true} = state), do: require_complete_file(state)
  defp validate_terminal_state(_), do: {:error, :malformed_unified_diff}

  defp validate_opaque_paths(paths) do
    if paths != [] and paths == Enum.sort(paths) and paths == Enum.uniq(paths) and
         Enum.all?(paths, &match?({:ok, _}, validate_path(&1))) do
      :ok
    else
      {:error, :invalid_opaque_paths}
    end
  end

  defp parse_optional_ordinary(""), do: {:ok, %{}}
  defp parse_optional_ordinary(diff), do: parse(diff)

  defp ordinary_files(""), do: {:ok, []}

  defp ordinary_files(diff) do
    diff
    |> String.split("\n", trim: false)
    |> Enum.reduce_while({:ok, nil, []}, fn line, {:ok, current, files} ->
      case {line, current} do
        {"diff --git " <> rest, nil} ->
          case parse_header_paths(rest) do
            {:ok, old_path, new_path} -> {:cont, {:ok, {old_path, new_path, nil}, files}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {"diff --git " <> rest, {old_path, new_path, nil}} when old_path != new_path ->
          case parse_header_paths(rest) do
            {:ok, next_old, next_new} ->
              {:cont, {:ok, {next_old, next_new, nil}, [new_path | files]}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end

        {"+++ /dev/null", {old_path, _new_path, _old_marker}} ->
          {:cont, {:ok, nil, [old_path | files]}}

        {"+++ b/" <> path, {_old_path, new_path, _old_marker}} ->
          with {:ok, path} <- validate_path(path),
               true <- path == new_path do
            {:cont, {:ok, nil, [path | files]}}
          else
            _ -> {:halt, {:error, :malformed_unified_diff}}
          end

        {"--- " <> marker, {old_path, new_path, nil}} ->
          expected = if marker == "/dev/null", do: :dev_null, else: old_path

          case parse_old_path(marker) do
            {:ok, ^expected} ->
              {:cont, {:ok, {old_path, new_path, expected}, files}}

            _ ->
              {:halt, {:error, :malformed_unified_diff}}
          end

        {"diff --git " <> _rest, _current} ->
          {:halt, {:error, :malformed_unified_diff}}

        {_line, _current} ->
          {:cont, {:ok, current, files}}
      end
    end)
    |> case do
      {:ok, nil, files} ->
        validate_file_list(Enum.reverse(files))

      {:ok, {old_path, new_path, nil}, files} when old_path != new_path ->
        validate_file_list(Enum.reverse([new_path | files]))

      {:ok, _current, _files} ->
        {:error, :malformed_unified_diff}

      {:error, _reason} = error ->
        error
    end
  end

  defp parse_header_paths(rest) do
    case String.split(rest, " ", parts: 2) do
      ["a/" <> old_path, "b/" <> new_path] ->
        with {:ok, old_path} <- validate_path(old_path),
             {:ok, new_path} <- validate_path(new_path) do
          {:ok, old_path, new_path}
        end

      _ ->
        {:error, :malformed_unified_diff}
    end
  end

  defp parse_optional_opaque("", _allowed), do: {:ok, %{files: [], ranges: %{}}}

  defp parse_optional_opaque(diff, allowed) do
    diff
    |> String.split("\n", trim: false)
    |> Enum.reduce_while({:ok, nil, [], %{}}, fn line, {:ok, current, files, ranges} ->
      case parse_opaque_line(line, current, allowed, files, ranges) do
        {:ok, next, next_files, next_ranges} ->
          {:cont, {:ok, next, next_files, next_ranges}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, nil, files, ranges} when files != [] ->
        with {:ok, files} <- validate_file_list(Enum.reverse(files)) do
          {:ok, %{files: files, ranges: ranges}}
        end

      {:ok, _current, _files, _ranges} ->
        {:error, :malformed_binary_marker}

      {:error, _reason} = error ->
        error
    end
  end

  defp parse_opaque_line("", current, _allowed, files, ranges),
    do: {:ok, current, files, ranges}

  defp parse_opaque_line("diff --git " <> rest, nil, allowed, files, ranges) do
    with {:ok, path, path} <- parse_header_paths(rest),
         true <- MapSet.member?(allowed, path) do
      {:ok, %{path: path, kind: :modified, index: nil}, files, ranges}
    else
      false -> {:error, :unapproved_binary_marker_path}
      {:ok, _, _} -> {:error, :opaque_rename_not_supported}
      {:error, _reason} = error -> error
    end
  end

  defp parse_opaque_line("new file mode 100644", %{kind: :modified} = current, _, files, ranges),
    do: {:ok, %{current | kind: :added}, files, ranges}

  defp parse_opaque_line(
         "deleted file mode 100644",
         %{kind: :modified} = current,
         _,
         files,
         ranges
       ),
       do: {:ok, %{current | kind: :deleted}, files, ranges}

  defp parse_opaque_line("index " <> value, %{index: nil} = current, _, files, ranges) do
    with {:ok, index} <- parse_opaque_index(value, current.kind) do
      {:ok, %{current | index: index}, files, ranges}
    end
  end

  defp parse_opaque_line(
         "Binary files " <> marker,
         %{path: path, kind: kind, index: index},
         _allowed,
         files,
         ranges
       )
       when not is_nil(index) do
    with :ok <- validate_binary_marker(marker, path, kind) do
      ranges =
        if kind in [:modified, :added],
          do: Map.put(ranges, path, [[1, @max_line_number]]),
          else: ranges

      {:ok, nil, [path | files], ranges}
    end
  end

  defp parse_opaque_line("GIT binary patch", _current, _allowed, _files, _ranges),
    do: {:error, :binary_unified_diff}

  defp parse_opaque_line("diff --git " <> _rest, _current, _allowed, _files, _ranges),
    do: {:error, :malformed_binary_marker}

  defp parse_opaque_line(_line, _current, _allowed, _files, _ranges),
    do: {:error, :malformed_binary_marker}

  defp parse_opaque_index(value, :modified) do
    case Regex.run(~r/\A([0-9a-f]+)\.\.([0-9a-f]+) 100644\z/, value) do
      [_, old_oid, new_oid] ->
        validate_opaque_oids(old_oid, new_oid, :modified)

      _ ->
        {:error, :malformed_binary_index}
    end
  end

  defp parse_opaque_index(value, kind) when kind in [:added, :deleted] do
    case Regex.run(~r/\A([0-9a-f]+)\.\.([0-9a-f]+)\z/, value) do
      [_, old_oid, new_oid] -> validate_opaque_oids(old_oid, new_oid, kind)
      _ -> {:error, :malformed_binary_index}
    end
  end

  defp validate_opaque_oids(old_oid, new_oid, kind) do
    width = byte_size(old_oid)
    old_zero? = all_zero_oid?(old_oid)
    new_zero? = all_zero_oid?(new_oid)

    valid? =
      width in [40, 64] and byte_size(new_oid) == width and
        case kind do
          :modified -> not old_zero? and not new_zero? and old_oid != new_oid
          :added -> old_zero? and not new_zero?
          :deleted -> not old_zero? and new_zero?
        end

    if valid?,
      do: {:ok, %{old_oid: old_oid, new_oid: new_oid}},
      else: {:error, :malformed_binary_index}
  end

  defp all_zero_oid?(oid), do: oid == String.duplicate("0", byte_size(oid))

  defp validate_binary_marker(marker, path, :modified),
    do: exact_marker(marker, "a/#{path}", "b/#{path}")

  defp validate_binary_marker(marker, path, :added),
    do: exact_marker(marker, "/dev/null", "b/#{path}")

  defp validate_binary_marker(marker, path, :deleted),
    do: exact_marker(marker, "a/#{path}", "/dev/null")

  defp exact_marker(marker, old_path, new_path) do
    if marker == "#{old_path} and #{new_path} differ",
      do: :ok,
      else: {:error, :binary_marker_path_mismatch}
  end

  defp validate_file_list(files) do
    if files != [] and files == Enum.uniq(files) and Enum.all?(files, &is_binary/1),
      do: {:ok, files},
      else: {:error, :invalid_unified_diff_files}
  end

  defp require_disjoint_files(left, right) do
    if MapSet.disjoint?(MapSet.new(left), MapSet.new(right)),
      do: :ok,
      else: {:error, :duplicate_unified_diff_file}
  end

  defp validate_material_bounds(diff, files) do
    hunk_count =
      diff
      |> String.split("\n", trim: false)
      |> Enum.count(&String.starts_with?(&1, "@@ "))

    cond do
      length(files) > @max_files -> {:error, :too_many_unified_diff_files}
      hunk_count > @max_hunks -> {:error, :too_many_unified_diff_hunks}
      true -> :ok
    end
  end

  defp merge_material_ranges(left, right) do
    if MapSet.disjoint?(MapSet.new(Map.keys(left)), MapSet.new(Map.keys(right))),
      do: {:ok, Map.merge(left, right)},
      else: {:error, :duplicate_unified_diff_file}
  end
end
