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
end
