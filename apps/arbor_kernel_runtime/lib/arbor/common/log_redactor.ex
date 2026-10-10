defmodule Arbor.Common.LogRedactor do
  @moduledoc """
  Logger filter that redacts sensitive values from log output.

  Delegates to `Arbor.Common.SensitiveData.redact/1` for pattern matching,
  which covers both PII and secret patterns.

  Traversal is total and globally bounded:
  - Lists are peeled one cons cell at a time (proper and improper multi-cons)
    without using `is_list/1` to decide whether to continue the spine
  - Maps use `:maps.iterator` / `:maps.next` (no `Map.to_list/1`, no full copy)
  - Tuples use `tuple_size/1` + `elem/2` (no `Tuple.to_list/1`)
  - Struct-tagged maps never invoke Enumerable or `struct/2` callbacks
  - Both map keys and values share one remaining-node budget
  - Binary redaction fails closed to `"[REDACTED]"` on any exception/throw
  """

  alias Arbor.Common.SensitiveData

  # Logger filters must stay cheap. Global walk budget + depth ceiling.
  @max_depth 12
  @max_nodes 256
  @max_format_chars 4_096
  @max_rendered_bytes 65_536
  @max_flat_otp_report_keys 16

  # Plain map — never include :__struct__, so Inspect/protocol cannot dispatch.
  @redacted_marker %{redacted: true}
  @redacted_binary "[REDACTED]"
  @sensitive_key_pattern ~r/(?:^|_)(?:api_key|apikey|authorization|bearer|client_secret|cookie|credentials?|private_key|secret(?:_key)?|signed_request|access_token|refresh_token|auth_token|token|password|passwd|pwd)(?:$|_)/i

  @doc false
  def filter(%{msg: msg} = log_event, _extra) do
    try do
      redacted_event =
        case msg do
          {:string, str} when is_binary(str) ->
            %{log_event | msg: {:string, redact_binary(str)}}

          {:string, chardata} ->
            %{log_event | msg: {:string, chardata |> IO.chardata_to_string() |> redact_binary()}}

          {:report, report} when is_map(report) or is_list(report) ->
            redact_report(log_event, report)

          {:report, report} ->
            {redacted, _budget} = walk(report, @max_depth, @max_nodes)
            %{log_event | msg: {:report, redacted}}

          {format, args}
          when is_list(args) and (is_binary(format) or is_list(format)) ->
            redact_format_message(log_event, format, args)

          _ ->
            log_event
        end

      redact_metadata(redacted_event)
    rescue
      _ ->
        log_event |> fail_closed(msg) |> fail_closed_metadata()
    catch
      _, _ ->
        log_event |> fail_closed(msg) |> fail_closed_metadata()
    end
  end

  def filter(log_event, _extra), do: log_event

  # OTP crash reports (`%{label: {:gen_server, :terminate}, report: [...]}`,
  # supervisor / proc_lib reports) are the logs you need most and the ones the
  # node budget hits first: a GenServer state plus a stacktrace is far more than
  # 256 nodes, so the whole report collapsed to `%{redacted: true}` and Elixir's
  # OTP translator — which needs `label` and a keyword `report` — rendered it
  # as `[error] nil`. Every crash in Arbor logged as "nil" until 2026-08-25.
  #
  # Render OTP reports ourselves with bounded inspect limits. The Logger OTP
  # translator depends on both an exact report shape and private metadata. A
  # structurally valid redacted report can still render as bare `nil` after its
  # metadata is bounded, hiding the failure that operators need. A pre-rendered
  # string preserves the reason without exposing the unredacted state.
  defp redact_otp_report(log_event, %{label: label, report: report}) do
    %{log_event | msg: {:string, otp_report_string(label, report)}}
  end

  # Logger's primary translator filter runs BEFORE this handler filter. When
  # it understands a report it keeps `{:report, report}` but adds the rendered
  # text under `:elixir_translation` and points `meta.report_cb` at a callback
  # that prints only that key. A gen_server/gen_statem terminate report is a
  # FLAT map (`label`, `reason`, `state`, `last_message`, ... — no `report`
  # key), so it used to fall through to the 256-node walk, which dropped
  # `:elixir_translation` and made the report_cb print `nil`. Every
  # supervisor crash, including the 2026-10-09 Trust boot hang, logged as
  # `[error] nil`. Redact the already-rendered translation instead.
  defp redact_report(log_event, report) do
    case report_translation(report) do
      {:ok, translation} ->
        rendered = translation |> IO.chardata_to_string() |> bound_rendered()
        %{log_event | msg: {:string, redact_binary(rendered)}}

      :error ->
        redact_untranslated_report(log_event, report)
    end
  end

  defp report_translation(%{elixir_translation: translation}), do: {:ok, translation}
  defp report_translation([{:elixir_translation, translation} | _rest]), do: {:ok, translation}
  defp report_translation(_report), do: :error

  defp redact_untranslated_report(log_event, %{label: label, report: _} = report)
       when is_tuple(label) do
    redact_otp_report(log_event, report)
  end

  # Untranslated flat OTP report (translator disabled or unknown label). OTP
  # emits these with a handful of atom keys; the size bound keeps an arbitrary
  # caller-built map from being copied wholesale before the walk budget applies.
  defp redact_untranslated_report(log_event, %{label: label} = report)
       when is_tuple(label) and map_size(report) <= @max_flat_otp_report_keys do
    fields = report |> Map.delete(:label) |> Enum.sort()
    %{log_event | msg: {:string, otp_report_string(label, fields)}}
  end

  defp redact_untranslated_report(log_event, report) do
    {redacted, _budget} = walk(report, @max_depth, @max_nodes)
    %{log_event | msg: {:report, redacted}}
  end

  defp bound_rendered(rendered) when byte_size(rendered) <= @max_rendered_bytes, do: rendered

  defp bound_rendered(rendered) do
    head =
      case :unicode.characters_to_binary(binary_part(rendered, 0, @max_rendered_bytes)) do
        valid when is_binary(valid) -> valid
        {:incomplete, valid, _rest} -> valid
        {:error, valid, _rest} -> valid
      end

    head <> "\n... (log message truncated)"
  end

  # Keys of a proper keyword list, or :improper when it is not one (an
  # exhaustion marker in the spine makes the translator raise).
  defp keyword_keys(list), do: keyword_keys(list, [])
  defp keyword_keys([], acc), do: Enum.reverse(acc)
  defp keyword_keys([{k, _v} | rest], acc) when is_atom(k), do: keyword_keys(rest, [k | acc])
  defp keyword_keys(_other, _acc), do: :improper

  @otp_inspect_opts [limit: 100, printable_limit: 4_096, pretty: true, width: 100]
  # `inspect/2`'s :limit is global across the term, so a big `state` would eat
  # the whole budget and turn `reason` — the one field that matters — into
  # "...". Render keyword reports entry by entry, each with its own limit.
  @otp_report_key_order [:reason, :last_message, :name, :client_info, :state]

  defp otp_report_string(label, report) do
    rendered =
      try do
        case keyword_keys(report) do
          :improper ->
            inspect(report, @otp_inspect_opts)

          keys ->
            ordered =
              Enum.filter(@otp_report_key_order, &(&1 in keys)) ++
                (keys -- @otp_report_key_order)

            Enum.map_join(ordered, "\n", fn key ->
              "  #{key}: " <> inspect(Keyword.get(report, key), @otp_inspect_opts)
            end)
        end
      rescue
        _ -> "<report not inspectable>"
      end

    redact_binary("#{inspect(label)} (report exceeded redaction budget)\n" <> rendered)
  end

  # Top-level fail-closed: never rewrite {:report, _} into {:string, _}.
  defp fail_closed(log_event, {:string, _}),
    do: %{log_event | msg: {:string, @redacted_binary}}

  defp fail_closed(log_event, {:report, _}),
    do: %{log_event | msg: {:report, @redacted_marker}}

  defp fail_closed(log_event, {format, args})
       when is_list(args) and (is_binary(format) or is_list(format)),
       do: %{log_event | msg: {:string, @redacted_binary}}

  defp fail_closed(log_event, _), do: log_event

  defp redact_format_message(log_event, format, args) do
    # Redacting a format string and its arguments independently can remove a
    # directive while leaving its argument behind. OTP then emits a formatter
    # error instead of the log message. Render once with a bounded io_lib
    # budget, redact the complete result, and return a valid string message.
    rendered =
      format
      |> :io_lib.format(args, chars_limit: @max_format_chars)
      |> IO.chardata_to_string()
      |> redact_binary()

    %{log_event | msg: {:string, rendered}}
  end

  defp redact_metadata(%{meta: metadata} = log_event) do
    {redacted, _budget} = walk(metadata, @max_depth, @max_nodes)
    %{log_event | meta: redacted}
  end

  defp redact_metadata(log_event), do: log_event

  defp fail_closed_metadata(%{meta: _metadata} = log_event),
    do: %{log_event | meta: @redacted_marker}

  defp fail_closed_metadata(log_event), do: log_event

  # SensitiveData.redact/1 uses Regex/String operations that can raise on
  # invalid UTF-8. Never let that kill the Logger primary filter.
  @doc "Redact secrets and sensitive data from an already-rendered string."
  @spec redact_binary(binary()) :: binary()
  def redact_binary(str) when is_binary(str) do
    try do
      SensitiveData.redact(str)
    rescue
      _ -> @redacted_binary
    catch
      _, _ -> @redacted_binary
    end
  end

  @doc "Redact a term recursively, including values stored under sensitive field names."
  @spec redact_term(term()) :: term()
  def redact_term(term) do
    try do
      {redacted, _budget} = walk(term, @max_depth, @max_nodes)
      redacted
    rescue
      _ -> @redacted_marker
    catch
      _, _ -> @redacted_marker
    end
  end

  @doc "Redact a value using its associated configuration or report key."
  @spec redact_value(term(), term()) :: term()
  def redact_value(key, value) do
    if sensitive_key?(key), do: @redacted_binary, else: redact_term(value)
  rescue
    _ -> @redacted_binary
  catch
    _, _ -> @redacted_binary
  end

  # --- Globally bounded term walk -------------------------------------------
  # Each visited term consumes one node from `budget`. Returns {term, budget_left}.

  defp walk(_term, _depth, budget) when budget <= 0, do: {@redacted_marker, 0}

  defp walk(bin, _depth, budget) when is_binary(bin) do
    {redact_binary(bin), budget - 1}
  end

  # List guard is only for *entering* list mode. Spine continuation never uses
  # is_list/1 — see continue_list_tail/5, which peels cons by pattern match.
  defp walk(list, depth, budget) when is_list(list) do
    if depth <= 0 do
      {@redacted_marker, budget - 1}
    else
      walk_list(list, depth - 1, budget - 1, [])
    end
  end

  defp walk(tuple, depth, budget) when is_tuple(tuple) do
    cond do
      depth <= 0 ->
        {@redacted_marker, budget - 1}

      tuple_size(tuple) == 2 and sensitive_key?(elem(tuple, 0)) ->
        redact_sensitive_pair(tuple, depth, budget)

      true ->
        # Index only; never Tuple.to_list/1 (full attacker-controlled allocation).
        walk_tuple(tuple, 0, tuple_size(tuple), depth - 1, budget - 1, [])
    end
  end

  # Struct-tagged maps (real modules or forged atoms). Never call struct/2 or
  # mod.__struct__/1. Iterate in place — never Map.delete/Map.to_list the whole
  # struct (that would allocate O(size) before the node budget can stop us).
  defp walk(%{__struct__: mod} = map, depth, budget) when is_atom(mod) do
    if depth <= 0 do
      {@redacted_marker, budget - 1}
    else
      case walk_map_iterator(
             :maps.next(:maps.iterator(map)),
             depth - 1,
             budget - 1,
             [],
             _skip_struct? = true
           ) do
        {:complete, pairs, budget_left} ->
          case assemble_pairs(pairs) do
            {:ok, assembled} ->
              {Map.put(assembled, :__struct__, mod), budget_left}

            :collision ->
              {@redacted_marker, budget_left}
          end

        {:incomplete, _pairs, budget_left} ->
          {@redacted_marker, budget_left}
      end
    end
  end

  defp walk(map, depth, budget) when is_map(map) do
    if depth <= 0 do
      {@redacted_marker, budget - 1}
    else
      case walk_map_iterator(
             :maps.next(:maps.iterator(map)),
             depth - 1,
             budget - 1,
             [],
             _skip_struct? = false
           ) do
        {:complete, pairs, budget_left} ->
          case assemble_pairs(pairs) do
            {:ok, assembled} -> {assembled, budget_left}
            :collision -> {@redacted_marker, budget_left}
          end

        {:incomplete, pairs, budget_left} ->
          case assemble_pairs(pairs) do
            {:ok, assembled} -> {Map.put(assembled, :redacted, true), budget_left}
            :collision -> {@redacted_marker, budget_left}
          end
      end
    end
  end

  defp walk(other, _depth, budget), do: {other, budget - 1}

  # --- List: recursive cons peel (no is_list/1 on the remainder) ------------
  #
  # Multi-cons improper lists such as [safe, "secret..." | tail] are stored as
  # [safe | ["secret..." | tail]]. Each cons is peeled by [head | tail] match.
  # Continuation decides by pattern match on the remainder:
  #   []              -> proper terminator
  #   [_ | _] = cons  -> another spine cell (proper or improper)
  #   other           -> true improper non-list tail (must walk as a term)
  #
  # Never pass a multi-cell improper remainder wholesale to walk/3's generic
  # `other` clause — that would preserve secret-bearing list spines unredacted.

  # Empty completion must win before budget exhaustion: when the final element
  # spends the exact remaining budget, [] must reverse without a false marker.
  # Only a non-empty unvisited remainder appends the redaction marker.
  defp walk_list([], _depth, budget, acc), do: {Enum.reverse(acc), budget}

  defp walk_list(_rest, _depth, budget, acc) when budget <= 0 do
    # Drop unvisited remainder (including any improper secret tail).
    {Enum.reverse([@redacted_marker | acc]), 0}
  end

  defp walk_list([head | tail], depth, budget, acc) do
    {head_redacted, budget_left} = walk(head, depth, budget)
    continue_list_tail(tail, depth, budget_left, head_redacted, acc)
  end

  # Proper end of list.
  defp continue_list_tail([], depth, budget, head_redacted, acc) do
    walk_list([], depth, budget, [head_redacted | acc])
  end

  # Another cons cell — covers proper *and* improper multi-cons spines.
  # Pattern `[_ | _]` matches improper lists; does not use is_list/1.
  defp continue_list_tail([_ | _] = next_cons, depth, budget, head_redacted, acc) do
    walk_list(next_cons, depth, budget, [head_redacted | acc])
  end

  # True improper non-list tail (binary, tuple, map, atom, ...). Walk it.
  defp continue_list_tail(non_list_tail, depth, budget, head_redacted, acc) do
    {tail_redacted, budget_final} = walk(non_list_tail, depth, budget)
    {finish_improper(acc, head_redacted, tail_redacted), budget_final}
  end

  defp finish_improper(acc, head, tail) do
    Enum.reduce(acc, [head | tail], fn item, rest -> [item | rest] end)
  end

  # --- Tuple: bounded elem/2 indexing ---------------------------------------

  defp walk_tuple(_tuple, index, size, _depth, budget, acc) when index >= size do
    {List.to_tuple(Enum.reverse(acc)), budget}
  end

  defp walk_tuple(_tuple, _index, _size, _depth, budget, _acc) when budget <= 0 do
    # Cannot emit a partial tuple while later elements remain unwalked.
    {@redacted_marker, 0}
  end

  defp walk_tuple(tuple, index, size, depth, budget, acc) do
    {elem_redacted, budget_left} = walk(elem(tuple, index), depth, budget)
    walk_tuple(tuple, index + 1, size, depth, budget_left, [elem_redacted | acc])
  end

  # --- Map: bounded iterator (no Map.to_list/1) -----------------------------

  defp walk_map_iterator(:none, _depth, budget, acc, _skip_struct?) do
    {:complete, Enum.reverse(acc), budget}
  end

  defp walk_map_iterator(_next, _depth, budget, acc, _skip_struct?) when budget <= 0 do
    {:incomplete, Enum.reverse(acc), 0}
  end

  defp walk_map_iterator({key, value, rest_iterator}, depth, budget, acc, skip_struct?) do
    if skip_struct? and key == :__struct__ do
      # Skip the tag without charging budget; never copy the whole map first.
      walk_map_iterator(:maps.next(rest_iterator), depth, budget, acc, skip_struct?)
    else
      {key_redacted, budget_after_key} = walk(key, depth, budget)

      {value_redacted, budget_left} =
        if sensitive_key?(key) do
          {@redacted_binary, max(budget_after_key - 1, 0)}
        else
          walk(value, depth, budget_after_key)
        end

      walk_map_iterator(
        :maps.next(rest_iterator),
        depth,
        budget_left,
        [{key_redacted, value_redacted} | acc],
        skip_struct?
      )
    end
  end

  # After key redaction, colliding keys must not silently merge secret values.
  defp assemble_pairs(pairs) do
    keys = Enum.map(pairs, fn {key, _value} -> key end)

    if length(keys) == MapSet.size(MapSet.new(keys)) do
      {:ok, Map.new(pairs)}
    else
      :collision
    end
  end

  defp redact_sensitive_pair(tuple, depth, budget) do
    {key_redacted, budget_left} = walk(elem(tuple, 0), depth - 1, budget - 1)

    if budget_left > 0 do
      {{key_redacted, @redacted_binary}, budget_left - 1}
    else
      {@redacted_marker, 0}
    end
  end

  defp sensitive_key?(key) when is_atom(key) do
    key |> Atom.to_string() |> sensitive_key?()
  end

  defp sensitive_key?(key) when is_binary(key) do
    normalized =
      key
      |> String.trim()
      |> String.replace(~r/[^A-Za-z0-9]+/u, "_")

    Regex.match?(@sensitive_key_pattern, normalized)
  end

  defp sensitive_key?(_key), do: false
end
