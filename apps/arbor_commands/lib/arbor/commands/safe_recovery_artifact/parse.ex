defmodule Arbor.Commands.SafeRecoveryArtifact.Parse do
  @moduledoc false

  # Bounded atom-as-text parser for generated OTP .app/.rel literals.
  # Atoms stay binaries. Semantic positions use a closed allowlist.

  @max_body 256 * 1024
  @max_nesting 64
  @max_nodes 32_768
  @max_atom 255
  @max_string 256 * 1024
  @max_list 16_384
  @max_tuple 8
  @max_int_digits 20

  @property_keys MapSet.new([
                   "description",
                   "vsn",
                   "modules",
                   "registered",
                   "applications",
                   "included_applications",
                   "optional_applications",
                   "mod",
                   "env",
                   "extra_applications",
                   "start_phases",
                   "maxT",
                   "maxP",
                   "licenses",
                   "links",
                   "maintainers",
                   "files",
                   "id",
                   "runtime_dependencies",
                   "metadata"
                 ])

  @start_types MapSet.new(["permanent", "transient", "temporary", "load", "none"])
  @rel_info_atoms MapSet.new(["unix", "win32"])

  @type term_value ::
          integer()
          | binary()
          | {:atom, binary()}
          | {:tuple, [term_value()]}
          | [term_value()]

  @spec term(term()) :: {:ok, term_value()} | {:error, atom()}
  def term(bytes) when is_binary(bytes) do
    case admit_body(bytes) do
      :ok -> parse_and_finish(bytes)
      error -> error
    end
  end

  def term(_), do: {:error, :malformed_term}

  @spec app_spec(term()) :: {:ok, map()} | {:error, atom()}
  def app_spec(bytes) do
    case term(bytes) do
      {:ok, value} -> interpret_app(value)
      error -> error
    end
  end

  @spec release(term()) :: {:ok, map()} | {:error, atom()}
  def release(bytes) do
    case term(bytes) do
      {:ok, value} -> interpret_release(value)
      error -> error
    end
  end

  defp new_state, do: %{nodes: 0, depth: 0}

  defp admit_body(bytes) do
    cond do
      byte_size(bytes) > @max_body -> {:error, :unbounded}
      not String.valid?(bytes) -> {:error, :invalid_utf8}
      illegal_control?(bytes) -> {:error, :control_character}
      true -> :ok
    end
  end

  defp illegal_control?(bytes) do
    bytes
    |> String.to_charlist()
    |> Enum.any?(&forbidden_control?/1)
  end

  defp forbidden_control?(c) when c in [?\s, ?\t, ?\n, ?\r, ?\f], do: false
  defp forbidden_control?(c) when c <= 0x1F or c == 0x7F, do: true
  defp forbidden_control?(c) when c >= 0x80 and c <= 0x9F, do: true
  defp forbidden_control?(_), do: false

  defp parse_and_finish(bytes) do
    case parse_value(skip(bytes), new_state()) do
      {:ok, value, rest, _state} -> finish_term(skip(rest), value)
      error -> error
    end
  end

  defp finish_term(<<?., rest::binary>>, value) do
    case skip(rest) do
      <<>> -> {:ok, value}
      _other -> {:error, :trailing_terms}
    end
  end

  defp finish_term(_rest, _value), do: {:error, :malformed_term}

  defp skip(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r, ?\f], do: skip(rest)
  defp skip(<<?%, rest::binary>>), do: skip(skip_comment(rest))
  defp skip(rest), do: rest

  defp skip_comment(<<?\n, rest::binary>>), do: rest
  defp skip_comment(<<?\r, rest::binary>>), do: rest
  defp skip_comment(<<_, rest::binary>>), do: skip_comment(rest)
  defp skip_comment(<<>>), do: <<>>

  defp parse_value(bytes, state) do
    case bump_node(state) do
      {:ok, state} -> do_parse_value(bytes, state)
      error -> error
    end
  end

  defp do_parse_value(<<?{, rest::binary>>, state), do: parse_tuple(rest, state)
  defp do_parse_value(<<?[, rest::binary>>, state), do: parse_list(rest, state)
  defp do_parse_value(<<"<<", rest::binary>>, state), do: parse_binary(rest, state)
  defp do_parse_value(<<?", rest::binary>>, state), do: parse_quoted(rest, state, :string)
  defp do_parse_value(<<?', rest::binary>>, state), do: parse_quoted(rest, state, :atom)
  defp do_parse_value(<<?-, rest::binary>>, state), do: parse_integer(rest, state, true)

  defp do_parse_value(<<c, _::binary>> = bytes, state) when c >= ?0 and c <= ?9 do
    parse_integer(bytes, state, false)
  end

  defp do_parse_value(<<c, _::binary>> = bytes, state) when c >= ?a and c <= ?z do
    parse_unquoted_atom(bytes, state)
  end

  defp do_parse_value(<<c, _::binary>>, _state) when c >= ?A and c <= ?Z, do: {:error, :variable}
  defp do_parse_value(<<?_, _::binary>>, _state), do: {:error, :variable}
  defp do_parse_value(<<?$, _::binary>>, _state), do: {:error, :unsupported_syntax}
  defp do_parse_value(<<??, _::binary>>, _state), do: {:error, :unsupported_syntax}
  defp do_parse_value(<<?#, _::binary>>, _state), do: {:error, :unsupported_syntax}
  defp do_parse_value(<<?(, _::binary>>, _state), do: {:error, :executable_form}
  defp do_parse_value(_bytes, _state), do: {:error, :unsupported_syntax}

  defp bump_node(%{nodes: nodes}) when nodes >= @max_nodes, do: {:error, :node_limit}
  defp bump_node(state), do: {:ok, %{state | nodes: state.nodes + 1}}

  defp enter(%{depth: depth}) when depth >= @max_nesting, do: {:error, :nesting_exceeded}
  defp enter(state), do: {:ok, %{state | depth: state.depth + 1}}

  defp leave(state), do: %{state | depth: state.depth - 1}

  defp parse_tuple(bytes, state) do
    with {:ok, state} <- enter(state),
         {:ok, items, rest, state} <- parse_comma_seq(skip(bytes), state, :tuple, 0, []) do
      {:ok, {:tuple, items}, rest, leave(state)}
    end
  end

  defp parse_list(bytes, state) do
    with {:ok, state} <- enter(state),
         {:ok, items, rest, state} <- parse_comma_seq(skip(bytes), state, :list, 0, []) do
      {:ok, items, rest, leave(state)}
    end
  end

  defp parse_comma_seq(<<?}, rest::binary>>, state, :tuple, _count, acc) do
    {:ok, Enum.reverse(acc), rest, state}
  end

  defp parse_comma_seq(<<?], rest::binary>>, state, :list, _count, acc) do
    {:ok, Enum.reverse(acc), rest, state}
  end

  defp parse_comma_seq(<<?|, _::binary>>, _state, :list, _count, _acc),
    do: {:error, :improper_list}

  defp parse_comma_seq(bytes, state, kind, count, acc) do
    max = if kind == :tuple, do: @max_tuple, else: @max_list

    if count >= max do
      {:error, :unbounded}
    else
      parse_seq_item(bytes, state, kind, count, acc)
    end
  end

  defp parse_seq_item(bytes, state, kind, count, acc) do
    case parse_value(skip(bytes), state) do
      {:ok, value, rest, state} ->
        continue_seq(skip(rest), state, kind, count + 1, [value | acc])

      error ->
        error
    end
  end

  defp continue_seq(<<?,, rest::binary>>, state, kind, count, acc) do
    parse_comma_seq(skip(rest), state, kind, count, acc)
  end

  defp continue_seq(<<?}, rest::binary>>, state, :tuple, _count, acc) do
    {:ok, Enum.reverse(acc), rest, state}
  end

  defp continue_seq(<<?], rest::binary>>, state, :list, _count, acc) do
    {:ok, Enum.reverse(acc), rest, state}
  end

  defp continue_seq(<<?|, _::binary>>, _state, :list, _count, _acc), do: {:error, :improper_list}
  defp continue_seq(_bytes, _state, _kind, _count, _acc), do: {:error, :malformed_term}

  defp parse_binary(bytes, state) do
    case enter(state) do
      {:ok, state} -> read_binary_body(skip(bytes), state, 0, [])
      error -> error
    end
  end

  defp read_binary_body(<<">>", rest::binary>>, state, _count, acc) do
    finalize_binary(Enum.reverse(acc), rest, leave(state))
  end

  defp read_binary_body(bytes, state, count, acc) when count >= @max_list do
    _ = {bytes, state, acc}
    {:error, :unbounded}
  end

  defp read_binary_body(<<?", rest::binary>>, state, count, acc) do
    with {:ok, state} <- bump_node(state),
         {:ok, string, rest} <- read_quoted(rest, :string) do
      continue_binary(skip(rest), state, count + 1, [{:str, string} | acc])
    end
  end

  defp read_binary_body(<<c, _::binary>> = bytes, state, count, acc)
       when (c >= ?0 and c <= ?9) or c == ?- do
    with {:ok, state} <- bump_node(state),
         {:ok, int, rest, state} <- parse_integer_allow(bytes, state) do
      admit_binary_byte(int, skip(rest), state, count, acc)
    end
  end

  defp read_binary_body(_bytes, _state, _count, _acc), do: {:error, :unsupported_syntax}

  defp parse_integer_allow(<<?-, rest::binary>>, state), do: parse_integer(rest, state, true)
  defp parse_integer_allow(bytes, state), do: parse_integer(bytes, state, false)

  defp admit_binary_byte(int, rest, state, count, acc) when int >= 0 and int <= 255 do
    continue_binary(rest, state, count + 1, [{:byte, int} | acc])
  end

  defp admit_binary_byte(_int, _rest, _state, _count, _acc), do: {:error, :malformed_term}

  defp continue_binary(<<">>", rest::binary>>, state, _count, acc) do
    finalize_binary(Enum.reverse(acc), rest, leave(state))
  end

  defp continue_binary(<<?,, rest::binary>>, state, count, acc) do
    read_binary_body(skip(rest), state, count, acc)
  end

  defp continue_binary(_bytes, _state, _count, _acc), do: {:error, :malformed_term}

  defp finalize_binary(parts, rest, state) do
    case binary_parts_to_iodata(parts, :empty, []) do
      {:ok, iodata} -> {:ok, IO.iodata_to_binary(iodata), rest, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp binary_parts_to_iodata([], _mode, acc), do: {:ok, Enum.reverse(acc)}
  defp binary_parts_to_iodata([{:str, s}], :empty, []), do: {:ok, [s]}
  defp binary_parts_to_iodata([{:str, _} | _], _mode, _acc), do: {:error, :unsupported_syntax}

  defp binary_parts_to_iodata([{:byte, b} | rest], mode, acc) when mode in [:empty, :bytes] do
    binary_parts_to_iodata(rest, :bytes, [b | acc])
  end

  defp binary_parts_to_iodata(_parts, _mode, _acc), do: {:error, :unsupported_syntax}

  defp parse_quoted(bytes, state, kind) do
    case read_quoted(bytes, kind) do
      {:ok, text, rest} -> quoted_value(kind, text, rest, state)
      error -> error
    end
  end

  defp quoted_value(:string, text, rest, state), do: {:ok, text, rest, state}

  defp quoted_value(:atom, text, rest, state) do
    if byte_size(text) > @max_atom do
      {:error, :unbounded}
    else
      {:ok, {:atom, text}, rest, state}
    end
  end

  defp read_quoted(bytes, kind), do: read_quoted(bytes, kind, [])

  defp read_quoted(<<?", rest::binary>>, :string, acc) do
    finish_quoted(Enum.reverse(acc), rest)
  end

  defp read_quoted(<<?', rest::binary>>, :atom, acc) do
    finish_quoted(Enum.reverse(acc), rest)
  end

  defp read_quoted(<<?\\, rest::binary>>, kind, acc) do
    case take_escape(rest) do
      {:ok, char, rest} -> read_quoted(rest, kind, [char | acc])
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_quoted(<<c, _::binary>>, _kind, _acc) when c <= 0x1F or c == 0x7F do
    {:error, :control_character}
  end

  defp read_quoted(<<c, rest::binary>>, kind, acc), do: read_quoted(rest, kind, [c | acc])
  defp read_quoted(<<>>, _kind, _acc), do: {:error, :malformed_term}

  defp finish_quoted(chars, rest) do
    bytes = :erlang.list_to_binary(chars)

    cond do
      byte_size(bytes) > @max_string -> {:error, :unbounded}
      not String.valid?(bytes) -> {:error, :invalid_utf8}
      true -> {:ok, bytes, rest}
    end
  end

  defp take_escape(<<?n, rest::binary>>), do: {:ok, ?\n, rest}
  defp take_escape(<<?t, rest::binary>>), do: {:ok, ?\t, rest}
  defp take_escape(<<?r, rest::binary>>), do: {:ok, ?\r, rest}
  defp take_escape(<<?\\, rest::binary>>), do: {:ok, ?\\, rest}
  defp take_escape(<<?', rest::binary>>), do: {:ok, ?', rest}
  defp take_escape(<<?", rest::binary>>), do: {:ok, ?", rest}

  defp take_escape(<<a, b, c, rest::binary>>)
       when a >= ?0 and a <= ?7 and b >= ?0 and b <= ?7 and c >= ?0 and c <= ?7 do
    value = (a - ?0) * 64 + (b - ?0) * 8 + (c - ?0)

    cond do
      value > 255 -> {:error, :unsupported_syntax}
      octal_control?(value) -> {:error, :control_character}
      true -> {:ok, value, rest}
    end
  end

  defp take_escape(_rest), do: {:error, :unsupported_syntax}

  # Symbolic \n, \t, and \r stay allowed above. Octal must not reintroduce
  # NUL, C0, C1, or DEL after decoding.
  defp octal_control?(c) when c <= 0x1F or c == 0x7F, do: true
  defp octal_control?(c) when c >= 0x80 and c <= 0x9F, do: true
  defp octal_control?(_), do: false

  defp parse_unquoted_atom(bytes, state) do
    {atom, rest} = take_atom_chars(bytes, [])

    cond do
      byte_size(atom) > @max_atom ->
        {:error, :unbounded}

      match?(<<?(, _::binary>>, skip(rest)) ->
        {:error, :executable_form}

      true ->
        {:ok, {:atom, atom}, rest, state}
    end
  end

  defp take_atom_chars(<<c, rest::binary>>, acc) when c >= ?a and c <= ?z do
    take_atom_more(rest, [c | acc])
  end

  defp take_atom_chars(_bytes, _acc), do: {<<>>, <<>>}

  defp take_atom_more(<<c, rest::binary>>, acc)
       when (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or (c >= ?0 and c <= ?9) or c == ?_ or
              c == ?@ do
    take_atom_more(rest, [c | acc])
  end

  defp take_atom_more(rest, acc) do
    {:erlang.list_to_binary(Enum.reverse(acc)), rest}
  end

  defp parse_integer(bytes, state, negative) do
    case take_digits(bytes, []) do
      {<<>>, _rest} ->
        {:error, :malformed_term}

      {_digits, <<?., c, _::binary>>} when c >= ?0 and c <= ?9 ->
        {:error, :unsupported_syntax}

      {digits, rest} ->
        build_integer(digits, rest, state, negative)
    end
  end

  defp take_digits(<<c, rest::binary>>, acc) when c >= ?0 and c <= ?9 do
    take_digits(rest, [c | acc])
  end

  defp take_digits(rest, acc), do: {:erlang.list_to_binary(Enum.reverse(acc)), rest}

  defp build_integer(digits, rest, state, negative) do
    if byte_size(digits) > @max_int_digits do
      {:error, :unbounded}
    else
      value = digits_to_int(digits, 0)
      signed = if negative, do: -value, else: value
      admit_integer(signed, rest, state)
    end
  end

  defp admit_integer(value, rest, state)
       when value >= -9_223_372_036_854_775_808 and value <= 9_223_372_036_854_775_807 do
    {:ok, value, rest, state}
  end

  defp admit_integer(_value, _rest, _state), do: {:error, :unbounded}

  defp digits_to_int(<<c, rest::binary>>, acc), do: digits_to_int(rest, acc * 10 + (c - ?0))
  defp digits_to_int(<<>>, acc), do: acc

  defp interpret_app({:tuple, [{:atom, "application"}, name, props]}) do
    with {:ok, name} <- stringify_name(name),
         {:ok, props} <- interpret_props(props),
         {:ok, version} <- fetch_vsn(props),
         {:ok, required} <- fetch_name_list(props, "applications"),
         {:ok, included} <- fetch_name_list(props, "included_applications"),
         {:ok, optional} <- fetch_name_list(props, "optional_applications"),
         :ok <- disjoint_deps(required, included, optional) do
      {:ok,
       %{
         name: name,
         version: version,
         required: required,
         included: included,
         optional: optional
       }}
    end
  end

  defp interpret_app({:tuple, [{:atom, _other}, _name, _props]}), do: {:error, :unknown_atom}
  defp interpret_app(_term), do: {:error, :malformed_term}

  defp interpret_release({:tuple, items}) do
    interpret_release_items(items)
  end

  defp interpret_release(_term), do: {:error, :malformed_term}

  defp interpret_release_items([{:atom, "release"}, {:tuple, [name, vsn]}, erts, apps]) do
    interpret_release_parts(name, vsn, erts, apps, [])
  end

  defp interpret_release_items([{:atom, "release"}, {:tuple, [name, vsn]}, erts, apps, info]) do
    case interpret_rel_info(info) do
      :ok -> interpret_release_parts(name, vsn, erts, apps, [])
      error -> error
    end
  end

  defp interpret_release_items([{:atom, "release"}, name, vsn, erts_vsn, apps]) do
    interpret_release_parts(name, vsn, erts_vsn, apps, [])
  end

  defp interpret_release_items([{:atom, "release"}, name, vsn, erts_vsn, apps, info]) do
    case interpret_rel_info(info) do
      :ok -> interpret_release_parts(name, vsn, erts_vsn, apps, [])
      error -> error
    end
  end

  defp interpret_release_items([{:atom, _other} | _]), do: {:error, :unknown_atom}
  defp interpret_release_items(_items), do: {:error, :malformed_term}

  defp interpret_release_parts(name, vsn, erts, apps, _acc) do
    with {:ok, name} <- stringify_name(name),
         {:ok, version} <- stringify_name(vsn),
         {:ok, erts} <- interpret_erts(erts),
         {:ok, apps} <- interpret_rel_apps(apps) do
      {:ok, %{name: name, version: version, erts: erts, apps: apps}}
    end
  end

  defp interpret_erts({:tuple, [{:atom, "erts"}, vsn]}), do: stringify_name(vsn)
  defp interpret_erts({:atom, "erts"}), do: {:error, :malformed_term}
  defp interpret_erts(vsn), do: stringify_name(vsn)

  defp interpret_rel_info(list) when is_list(list), do: admit_rel_info(list)
  defp interpret_rel_info(_), do: {:error, :malformed_term}

  defp admit_rel_info([]), do: :ok

  defp admit_rel_info([{:atom, name} | rest]) do
    if MapSet.member?(@rel_info_atoms, name) do
      admit_rel_info(rest)
    else
      {:error, :unknown_atom}
    end
  end

  defp admit_rel_info(_), do: {:error, :malformed_term}

  defp interpret_rel_apps(list) when is_list(list) do
    if length(list) > @max_list do
      {:error, :unbounded}
    else
      collect_rel_apps(list, [])
    end
  end

  defp interpret_rel_apps(_), do: {:error, :malformed_term}

  defp collect_rel_apps([], acc), do: {:ok, Enum.reverse(acc)}

  defp collect_rel_apps([item | rest], acc) do
    case interpret_rel_app(item) do
      {:ok, app} -> collect_rel_apps(rest, [app | acc])
      {:error, reason} -> {:error, reason}
    end
  end

  defp interpret_rel_app({:tuple, [name, vsn]}) do
    build_rel_app(name, vsn, "permanent")
  end

  defp interpret_rel_app({:tuple, [name, vsn, {:atom, start_type}]}) do
    if MapSet.member?(@start_types, start_type) do
      build_rel_app(name, vsn, start_type)
    else
      {:error, :invalid_start_type}
    end
  end

  defp interpret_rel_app(_), do: {:error, :malformed_term}

  defp build_rel_app(name, vsn, start_type) do
    with {:ok, name} <- stringify_name(name),
         {:ok, version} <- stringify_name(vsn) do
      {:ok, %{name: name, version: version, start_type: start_type}}
    end
  end

  defp interpret_props(list) when is_list(list), do: collect_props(list, [], MapSet.new())
  defp interpret_props(_), do: {:error, :malformed_term}

  defp collect_props([], acc, _seen), do: {:ok, Map.new(acc)}

  defp collect_props([{:tuple, [{:atom, key}, value]} | rest], acc, seen) do
    cond do
      not MapSet.member?(@property_keys, key) ->
        {:error, :unknown_atom}

      MapSet.member?(seen, key) ->
        {:error, :duplicate_property}

      true ->
        collect_props(rest, [{key, value} | acc], MapSet.put(seen, key))
    end
  end

  defp collect_props(_other, _acc, _seen), do: {:error, :malformed_term}

  defp fetch_vsn(props) do
    case Map.fetch(props, "vsn") do
      {:ok, value} -> stringify_name(value)
      :error -> {:error, :malformed_term}
    end
  end

  defp fetch_name_list(props, key) do
    case Map.fetch(props, key) do
      :error -> {:ok, []}
      {:ok, list} when is_list(list) -> collect_names(list, [])
      {:ok, _} -> {:error, :invalid_dependency_list}
    end
  end

  defp collect_names([], acc), do: unique_names(Enum.reverse(acc))

  defp collect_names([item | rest], acc) do
    case stringify_name(item) do
      {:ok, name} -> collect_names(rest, [name | acc])
      {:error, reason} -> {:error, reason}
    end
  end

  defp unique_names(names) do
    if length(Enum.uniq(names)) == length(names) do
      {:ok, names}
    else
      {:error, :invalid_dependency_list}
    end
  end

  defp disjoint_deps(required, included, optional) do
    sets = [MapSet.new(required), MapSet.new(included), MapSet.new(optional)]
    overlap? = pairwise_overlap?(sets)

    if overlap?, do: {:error, :invalid_dependency_list}, else: :ok
  end

  defp pairwise_overlap?([a, b, c]) do
    not MapSet.disjoint?(a, b) or not MapSet.disjoint?(a, c) or not MapSet.disjoint?(b, c)
  end

  defp stringify_name({:atom, name}) when is_binary(name), do: {:ok, name}
  defp stringify_name(name) when is_binary(name), do: {:ok, name}
  defp stringify_name(_), do: {:error, :malformed_term}
end
