defmodule Arbor.Shell.TrustedBuild.BeamIdentity do
  @moduledoc false

  import Bitwise

  @identity_head "/arbor/tb/I/"
  @workspace_head "/arbor/tb/W/"
  @max_entries 50_000
  @max_depth 48

  @spec replacements([String.t()], [String.t()]) :: [{String.t(), String.t()}]
  def replacements(identity_spellings, workspace_spellings)
      when is_list(identity_spellings) and is_list(workspace_spellings) do
    (pair(identity_spellings, @identity_head) ++ pair(workspace_spellings, @workspace_head))
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.sort_by(fn {prefix, _canonical} -> -byte_size(prefix) end)
  end

  def replacements(_identity_spellings, _workspace_spellings), do: []

  @spec normalize_beam(binary(), [{String.t(), String.t()}]) ::
          {:ok, binary()} | {:error, :trusted_build_beam_identity}
  def normalize_beam(bytes, replacements)
      when is_binary(bytes) and is_list(replacements) do
    case :beam_lib.info(bytes) do
      {:error, :beam_lib, _reason} ->
        {:error, :trusted_build_beam_identity}

      info when is_list(info) ->
        case Keyword.get(info, :chunks) do
          chunks when is_list(chunks) and chunks != [] ->
            names = Enum.map(chunks, fn {name, _pos, _len} -> name end)
            extract_and_rewrite(bytes, names, replacements)

          _other ->
            {:error, :trusted_build_beam_identity}
        end
    end
  end

  def normalize_beam(_bytes, _replacements), do: {:error, :trusted_build_beam_identity}

  @spec normalize_release_tree(String.t(), [{String.t(), String.t()}]) ::
          :ok | {:error, atom()}
  def normalize_release_tree(rel_root, replacements)
      when is_binary(rel_root) and is_list(replacements) do
    case File.lstat(rel_root, time: :posix) do
      {:ok, %File.Stat{type: :directory}} ->
        walk(rel_root, 0, 0, replacements)

      {:error, :enoent} ->
        :ok

      _other ->
        {:error, :trusted_build_beam_identity}
    end
  end

  def normalize_release_tree(_rel_root, _replacements),
    do: {:error, :trusted_build_beam_identity}

  @spec rewrite_paths(term(), [{String.t(), String.t()}]) :: term()
  def rewrite_paths(term, replacements) when is_list(replacements) do
    do_rewrite(term, replacements)
  end

  defp pair(spellings, head) do
    spellings
    |> Enum.filter(&valid_prefix?/1)
    |> Enum.flat_map(fn spelling ->
      case same_length_canonical(head, spelling) do
        {:ok, canonical} -> [{spelling, canonical}]
        :error -> []
      end
    end)
  end

  defp same_length_canonical(head, original) do
    pad = byte_size(original) - byte_size(head)

    if pad >= 0 do
      {:ok, head <> String.duplicate("0", pad)}
    else
      :error
    end
  end

  defp valid_prefix?(path) when is_binary(path) do
    byte_size(path) >= 2 and String.starts_with?(path, "/") and
      not String.contains?(path, <<0>>)
  end

  defp valid_prefix?(_path), do: false

  defp extract_and_rewrite(bytes, names, replacements) do
    case :beam_lib.chunks(bytes, names) do
      {:ok, {_module, chunks}} ->
        case rewrite_chunks(chunks, replacements, false, []) do
          {:ok, :unchanged, _chunks} ->
            {:ok, bytes}

          {:ok, :changed, rewritten} ->
            case :beam_lib.build_module(Enum.reverse(rewritten)) do
              {:ok, rebuilt} -> {:ok, rebuilt}
              {:error, _reason} -> {:error, :trusted_build_beam_identity}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :beam_lib, _reason} ->
        {:error, :trusted_build_beam_identity}
    end
  end

  defp rewrite_chunks([], _replacements, changed?, acc) do
    flag = if changed?, do: :changed, else: :unchanged
    {:ok, flag, acc}
  end

  defp rewrite_chunks([{name, chunk_bin} | rest], replacements, changed?, acc)
       when is_binary(chunk_bin) do
    rewritten = replace_text_prefixes(chunk_bin, replacements)

    cond do
      name == ~c"Attr" ->
        case stabilize_attr_vsn(rewritten) do
          {:ok, attr_bin} ->
            next_changed? = changed? or attr_bin != chunk_bin
            rewrite_chunks(rest, replacements, next_changed?, [{~c"Attr", attr_bin} | acc])

          {:error, reason} ->
            {:error, reason}
        end

      name == ~c"FunT" ->
        {:ok, funt_bin} = stabilize_funt(rewritten)
        next_changed? = changed? or funt_bin != chunk_bin
        rewrite_chunks(rest, replacements, next_changed?, [{~c"FunT", funt_bin} | acc])

      true ->
        next_changed? = changed? or rewritten != chunk_bin
        rewrite_chunks(rest, replacements, next_changed?, [{name, rewritten} | acc])
    end
  end

  defp rewrite_chunks([chunk | rest], replacements, changed?, acc) do
    rewrite_chunks(rest, replacements, changed?, [chunk | acc])
  end

  defp stabilize_attr_vsn(attr_bin) do
    try do
      term = :erlang.binary_to_term(attr_bin)
      rewritten = pin_vsn(term)

      if rewritten == term do
        {:ok, attr_bin}
      else
        {:ok, :erlang.term_to_binary(rewritten, [:deterministic])}
      end
    rescue
      ArgumentError -> {:error, :trusted_build_beam_identity}
    end
  end

  defp pin_vsn(term) when is_list(term) and term != [] do
    if Keyword.keyword?(term) and Keyword.has_key?(term, :vsn) do
      Keyword.put(term, :vsn, [0])
    else
      Enum.map(term, &pin_vsn/1)
    end
  end

  defp pin_vsn(term) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.map(&pin_vsn/1)
    |> List.to_tuple()
  end

  defp pin_vsn(term), do: term

  defp stabilize_funt(<<count::32, rest::binary>>)
       when count >= 0 and byte_size(rest) == count * 24 do
    entries =
      for <<prefix::binary-size(20), _uniq::32 <- rest>> do
        <<prefix::binary, 0::32>>
      end

    {:ok, IO.iodata_to_binary([<<count::32>> | entries])}
  end

  defp stabilize_funt(bin) when is_binary(bin), do: {:ok, bin}

  defp do_rewrite(value, replacements) when is_binary(value) do
    replace_prefix(value, replacements)
  end

  defp do_rewrite(value, replacements) when is_list(value) do
    cond do
      value != [] and printable_charlist?(value) ->
        value
        |> List.to_string()
        |> replace_prefix(replacements)
        |> String.to_charlist()

      true ->
        Enum.map(value, &do_rewrite(&1, replacements))
    end
  end

  defp do_rewrite(value, replacements) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&do_rewrite(&1, replacements))
    |> List.to_tuple()
  end

  defp do_rewrite(value, replacements) when is_map(value) do
    Map.new(value, fn {key, inner} ->
      {do_rewrite(key, replacements), do_rewrite(inner, replacements)}
    end)
  end

  defp do_rewrite(value, _replacements), do: value

  defp replace_prefix(value, replacements) do
    case match_prefix(value, replacements) do
      {prefix, canonical} ->
        rest_size = byte_size(value) - byte_size(prefix)
        canonical <> binary_part(value, byte_size(prefix), rest_size)

      nil ->
        value
    end
  end

  defp match_prefix(value, replacements) do
    Enum.find_value(replacements, fn {prefix, canonical} ->
      if String.starts_with?(value, prefix) do
        rest_size = byte_size(value) - byte_size(prefix)

        rest =
          if rest_size == 0 do
            ""
          else
            binary_part(value, byte_size(prefix), rest_size)
          end

        if rest == "" or String.starts_with?(rest, "/") do
          {prefix, canonical}
        end
      end
    end)
  end

  defp printable_charlist?([head | tail])
       when is_integer(head) and head >= 0 and head <= 0x10FFFF do
    Enum.all?(tail, &(is_integer(&1) and &1 >= 0 and &1 <= 0x10FFFF))
  end

  defp printable_charlist?(_other), do: false

  defp walk(_dir, _depth, count, _replacements) when count > @max_entries do
    {:error, :trusted_build_beam_identity}
  end

  defp walk(_dir, depth, _count, _replacements) when depth > @max_depth do
    {:error, :trusted_build_beam_identity}
  end

  defp walk(dir, depth, count, replacements) do
    case File.ls(dir) do
      {:ok, names} ->
        reduce_entries(Enum.sort(names), dir, depth, count, replacements)

      {:error, _reason} ->
        {:error, :trusted_build_beam_identity}
    end
  end

  defp reduce_entries([], _dir, _depth, _count, _replacements), do: :ok

  defp reduce_entries([name | rest], dir, depth, count, replacements) do
    path = Path.join(dir, name)

    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory}} ->
        case walk(path, depth + 1, count + 1, replacements) do
          :ok -> reduce_entries(rest, dir, depth, count + 1, replacements)
          {:error, reason} -> {:error, reason}
        end

      {:ok, %File.Stat{type: :regular}} ->
        case maybe_normalize_file(path, name, replacements) do
          :ok -> reduce_entries(rest, dir, depth, count + 1, replacements)
          {:error, reason} -> {:error, reason}
        end

      {:ok, %File.Stat{type: :symlink}} ->
        if String.ends_with?(name, ".beam") do
          {:error, :symlink_rejected}
        else
          reduce_entries(rest, dir, depth, count + 1, replacements)
        end

      {:ok, %File.Stat{}} ->
        reduce_entries(rest, dir, depth, count + 1, replacements)

      {:error, _reason} ->
        {:error, :trusted_build_beam_identity}
    end
  end

  defp maybe_normalize_file(path, name, replacements) do
    cond do
      String.ends_with?(name, ".beam") ->
        normalize_file(path, replacements)

      String.ends_with?(name, ".config") ->
        normalize_text_file(path, replacements)

      true ->
        :ok
    end
  end

  defp normalize_text_file(path, replacements) do
    case File.read(path) do
      {:ok, bytes} ->
        rewritten = replace_text_prefixes(bytes, replacements)

        if rewritten == bytes do
          :ok
        else
          write_preserving_mode(path, rewritten)
        end

      {:error, _reason} ->
        {:error, :trusted_build_beam_identity}
    end
  end

  defp replace_text_prefixes(bytes, replacements) do
    Enum.reduce(replacements, bytes, fn {prefix, canonical}, acc ->
      replace_text_prefix(acc, prefix, canonical, 0, acc)
    end)
  end

  defp replace_text_prefix(_original, _prefix, _canonical, offset, acc)
       when offset >= byte_size(acc) do
    acc
  end

  defp replace_text_prefix(original, prefix, canonical, offset, acc) do
    window = binary_part(acc, offset, byte_size(acc) - offset)

    case :binary.match(window, prefix) do
      :nomatch ->
        acc

      {rel, _} ->
        start = offset + rel
        rest_start = start + byte_size(prefix)
        rest = binary_part(acc, rest_start, byte_size(acc) - rest_start)

        if rest == "" or match?(<<?/, _::binary>>, rest) do
          rebuilt =
            binary_part(acc, 0, start) <> canonical <> rest

          replace_text_prefix(
            original,
            prefix,
            canonical,
            start + byte_size(canonical),
            rebuilt
          )
        else
          replace_text_prefix(original, prefix, canonical, start + 1, acc)
        end
    end
  end

  defp normalize_file(path, replacements) do
    case File.read(path) do
      {:ok, bytes} ->
        case normalize_beam(bytes, replacements) do
          {:ok, ^bytes} -> :ok
          {:ok, rewritten} -> write_preserving_mode(path, rewritten)
          {:error, reason} -> {:error, reason}
        end

      {:error, _reason} ->
        {:error, :trusted_build_beam_identity}
    end
  end

  defp write_preserving_mode(path, bytes) do
    with {:ok, %File.Stat{type: :regular, mode: mode}} <- File.lstat(path, time: :posix),
         preserved = mode &&& 0o777,
         :ok <- File.chmod(path, preserved ||| 0o200),
         :ok <- File.write(path, bytes),
         :ok <- File.chmod(path, preserved) do
      :ok
    else
      _other -> {:error, :trusted_build_beam_identity}
    end
  end
end
