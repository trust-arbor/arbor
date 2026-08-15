defmodule Arbor.Contracts.API.HistorianTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.API.Historian

  @moduletag :fast
  @moduletag spec: "VP-05D2C3I0C4C"

  @expected_proven_progress [
    :durable_and_hot_proven_absent,
    :durable_proven_absent,
    :none_proven_absent
  ]

  @expected_delete_stage [
    :durable_delete,
    :durable_verify,
    :hot_delete,
    :hot_verify
  ]

  @expected_delete_error [
    :absence_not_supported,
    :delete_not_supported,
    :durable_unavailable,
    :hot_unavailable,
    :invalid_precondition,
    :invalid_stream_id,
    :verification_failed
  ]

  @expected_absence_error [
    :absence_not_supported,
    :durable_unavailable,
    :hot_unavailable,
    :invalid_precondition,
    :invalid_stream_id,
    :verification_failed
  ]

  @expected_delete_result [
    :ok,
    {:tuple,
     [
       :error,
       {:tuple,
        [
          :delete_incomplete,
          {:type_ref, :stream_id},
          {:type_ref, :stream_content_delete_stage},
          {:type_ref, :stream_content_proven_progress}
        ]}
     ]},
    {:tuple, [:error, {:type_ref, :stream_content_delete_error}]}
  ]

  @expected_absence_result [
    {:tuple, [:ok, true]},
    {:tuple, [:ok, false]},
    {:tuple, [:error, {:tuple, [:absence_indeterminate, {:type_ref, :stream_id}]}]},
    {:tuple, [:error, {:type_ref, :stream_content_absence_error}]}
  ]

  test "complete history stream content callbacks are optional arity-2 facade callbacks" do
    callbacks = Historian.behaviour_info(:callbacks)
    optional = Historian.behaviour_info(:optional_callbacks)

    expected = [
      delete_complete_history_stream_content: 2,
      check_complete_history_stream_content_absent: 2
    ]

    for callback <- expected do
      assert callback in callbacks
      assert callback in optional
    end
  end

  test "closed C4C types document exact progress and packet error atoms" do
    Code.ensure_loaded!(Historian)
    assert {:ok, types} = Code.Typespec.fetch_types(Historian)

    assert_atom_only_alias!(types, :stream_content_proven_progress, @expected_proven_progress)
    assert_atom_only_alias!(types, :stream_content_delete_stage, @expected_delete_stage)
    assert_atom_only_alias!(types, :stream_content_delete_error, @expected_delete_error)
    assert_atom_only_alias!(types, :stream_content_absence_error, @expected_absence_error)

    assert_exact_variants!(types, :stream_content_delete_result, @expected_delete_result)
    assert_exact_variants!(types, :stream_content_absence_result, @expected_absence_result)

    # Forbidden invented atoms must not appear as public C4C type members.
    for type_name <- [
          :stream_content_proven_progress,
          :stream_content_delete_stage,
          :stream_content_delete_error,
          :stream_content_absence_error,
          :stream_content_delete_result,
          :stream_content_absence_result
        ] do
      body = type_body!(types, type_name)
      refute type_contains_atom?(body, :invalid_options)
      refute type_contains_atom?(body, :backend_unavailable)
    end
  end

  test "existing Historian callbacks are not regressed" do
    callbacks = Historian.behaviour_info(:callbacks)

    required = [
      read_recent_history_entries: 1,
      read_history_entries_for_agent: 2,
      start_link: 1,
      healthy?: 0
    ]

    for callback <- required do
      assert callback in callbacks
    end
  end

  defp type_def!(types, name) when is_list(types) and is_atom(name) do
    case Enum.find(types, fn
           {:type, {^name, _type, _vars}} -> true
           _ -> false
         end) do
      {:type, type_def} -> type_def
      nil -> flunk("missing exported type #{inspect(name)} on Arbor.Contracts.API.Historian")
    end
  end

  defp type_body!(types, name) do
    {:"::", _meta, [_head, body]} = Code.Typespec.type_to_quoted(type_def!(types, name))
    body
  end

  defp assert_atom_only_alias!(types, name, expected_atoms) do
    actual =
      types
      |> type_body!(name)
      |> flatten_union()
      |> Enum.map(fn leaf ->
        case normalize_leaf(leaf) do
          atom when is_atom(atom) ->
            atom

          other ->
            flunk(
              "atom-only alias #{inspect(name)} has non-atom leaf: #{inspect(other)} (raw: #{inspect(leaf)})"
            )
        end
      end)
      |> Enum.sort()

    expected = Enum.sort(expected_atoms)

    unless actual == expected do
      flunk(
        "atom-only alias #{inspect(name)} mismatch\nexpected: #{inspect(expected)}\nactual:   #{inspect(actual)}"
      )
    end
  end

  defp assert_exact_variants!(types, name, expected_variants) do
    actual =
      types
      |> type_body!(name)
      |> flatten_union()
      |> Enum.map(&normalize_leaf/1)
      |> Enum.sort()

    expected = Enum.sort(expected_variants)

    unless actual == expected do
      flunk(
        "result union #{inspect(name)} mismatch\nexpected: #{inspect(expected)}\nactual:   #{inspect(actual)}"
      )
    end
  end

  defp flatten_union({:|, _meta, [left, right]}), do: flatten_union(left) ++ flatten_union(right)
  defp flatten_union(other), do: [other]

  defp normalize_leaf(atom) when is_atom(atom), do: atom

  # Tuple AST MUST precede generic {name, meta, args} local type-reference.
  defp normalize_leaf({left, right}),
    do: {:tuple, [normalize_leaf(left), normalize_leaf(right)]}

  defp normalize_leaf({:{}, _meta, elems}) when is_list(elems),
    do: {:tuple, Enum.map(elems, &normalize_leaf/1)}

  defp normalize_leaf({name, _meta, []}) when is_atom(name), do: {:type_ref, name}

  defp normalize_leaf({name, _meta, args}) when is_atom(name) and is_list(args),
    do: {:type_ref, name, length(args)}

  defp normalize_leaf({{:., _meta, [mod, name]}, _call_meta, []}) when is_atom(name),
    do: {:remote_type_ref, mod, name}

  defp normalize_leaf(value) when is_integer(value) or is_binary(value), do: {:literal, value}

  defp normalize_leaf(other), do: {:unknown, other}

  defp type_contains_atom?(quoted, atom) when is_atom(atom) do
    type_walk?(quoted, fn
      ^atom -> true
      _ -> false
    end)
  end

  defp type_walk?(list, pred) when is_list(list), do: Enum.any?(list, &type_walk?(&1, pred))

  defp type_walk?(tuple, pred) when is_tuple(tuple) do
    pred.(tuple) or
      tuple
      |> Tuple.to_list()
      |> Enum.any?(&type_walk?(&1, pred))
  end

  defp type_walk?(other, pred), do: pred.(other)
end
