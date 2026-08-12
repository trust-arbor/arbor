defmodule Arbor.Commands.SourceCoupling.Baseline do
  @moduledoc """
  Pure baseline admit, compare, and write-plan for source-coupling census.
  """

  alias Arbor.Commands.SourceCoupling.Encode

  @schema "arbor.packaging.source_coupling.baseline.v1"
  @version 1
  @dispositions MapSet.new(["accepted", "tracked", "false_positive"])
  @max_rationale_bytes 500

  @metadata_keys ~w(from_app to_app from_band to_band fate level_direction)

  @doc "Admit a baseline map; verifies entries_digest and unresolved dispositions."
  @spec admit(map()) :: {:ok, map()} | {:error, term()}
  def admit(raw) when is_map(raw) do
    with :ok <- exact_schema(raw),
         :ok <- exact_version(raw),
         {:ok, entries} <- admit_entries(Map.get(raw, "entries")),
         {:ok, unresolved} <- admit_unresolved(Map.get(raw, "unresolved_entries")),
         expected <- Encode.entries_digest(entries),
         :ok <- match_digest(Map.get(raw, "entries_digest"), expected, entries) do
      {:ok,
       %{
         "schema" => @schema,
         "version" => @version,
         "provenance" => Map.get(raw, "provenance") || %{},
         "policy" => Map.get(raw, "policy") || default_policy(),
         "counts" => Map.get(raw, "counts") || %{},
         "entries" => entries,
         "unresolved_entries" => unresolved,
         "entries_digest" => expected
       }}
    end
  end

  def admit(_), do: {:error, :malformed_or_stale_baseline}

  @doc "Compare current gating occurrences + unresolved against admitted baseline."
  @spec compare(map(), [map()], [map()]) :: {:ok, map()} | {:error, term()}
  def compare(baseline, gating_occurrences, unresolved_agg)
      when is_map(baseline) and is_list(gating_occurrences) and is_list(unresolved_agg) do
    base_entries = Map.get(baseline, "entries") || []
    base_unresolved = Map.get(baseline, "unresolved_entries") || []

    base_map = Map.new(base_entries, &{entry_key(&1), &1})
    cur_map = Map.new(gating_occurrences, &{entry_key(&1), &1})

    base_u = Map.new(base_unresolved, &{unresolved_key(&1), &1})
    cur_u = Map.new(unresolved_agg, &{unresolved_key(&1), &1})

    failures =
      []
      |> compare_occurrence_keys(base_map, cur_map)
      |> compare_unresolved_keys(base_u, cur_u)

    status = if failures == [], do: "ok", else: "failed"

    {:ok,
     %{
       "status" => status,
       "failures" => Enum.sort_by(failures, &{&1["reason"], &1["detail"]}),
       "failure_count" => length(failures)
     }}
  end

  def compare(_, _, _), do: {:error, :invalid_compare}

  @doc """
  Build a baseline document from census gating set.

  `prior` optional admitted baseline for preserving unresolved dispositions.
  `review` map of unresolved_key_string => %{disposition, rationale}.
  """
  @spec build(map(), map() | nil, map()) :: {:ok, map()} | {:error, term()}
  def build(census, prior, review \\ %{})

  def build(census, prior, review)
      when is_map(census) and is_map(review) do
    gating = Map.get(census, "gating_occurrences") || []
    unresolved = Map.get(census, "unresolved") || []
    prior_u = if is_map(prior), do: Map.get(prior, "unresolved_entries") || [], else: []
    prior_u_map = Map.new(prior_u, &{unresolved_key(&1), &1})

    with {:ok, unresolved_entries} <- merge_unresolved(unresolved, prior_u_map, review) do
      entries =
        gating
        |> Enum.map(&Encode.order_entry/1)
        |> Enum.sort_by(&entry_sort/1)

      unresolved_entries =
        unresolved_entries
        |> Enum.map(&Encode.order_unresolved_entry/1)
        |> Enum.sort_by(&unresolved_sort/1)

      digest = Encode.entries_digest(entries)

      doc = %{
        "schema" => @schema,
        "version" => @version,
        "provenance" => %{
          "tree_oid" => get_in(census, ["provenance", "tree_oid"]) || "",
          "scan_manifest_digest" => get_in(census, ["provenance", "scan_manifest_digest"]) || ""
        },
        "policy" => default_policy(),
        "counts" => Map.get(census, "counts") || %{},
        "entries" => entries,
        "unresolved_entries" => unresolved_entries,
        "entries_digest" => digest
      }

      {:ok, doc}
    end
  end

  def build(_, _, _), do: {:error, :invalid_build}

  defp default_policy do
    %{
      "removal" => "require_write",
      "typespec_only" => "gate",
      "unresolved" => "require_disposition",
      "metadata_match" => "required"
    }
  end

  defp exact_schema(%{"schema" => @schema}), do: :ok
  defp exact_schema(_), do: {:error, :malformed_or_stale_baseline}

  defp exact_version(%{"version" => @version}), do: :ok
  defp exact_version(_), do: {:error, :malformed_or_stale_baseline}

  defp match_digest(got, expected, _entries) when is_binary(got) and got == expected, do: :ok

  # Bootstrap seed: empty entries may omit digest or use any 64-hex placeholder;
  # admit rebinds to the computed empty-list digest (never skips non-empty sets).
  defp match_digest(got, expected, []) when is_binary(expected) do
    cond do
      got == expected -> :ok
      is_nil(got) -> :ok
      is_binary(got) and Regex.match?(~r/\A[0-9a-f]{64}\z/, got) -> :ok
      true -> {:error, :malformed_or_stale_baseline}
    end
  end

  defp match_digest(_, _, _), do: {:error, :malformed_or_stale_baseline}

  defp admit_entries(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn entry, {:ok, acc} ->
      case admit_entry(entry) do
        {:ok, e} -> {:cont, {:ok, [e | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp admit_entries(_), do: {:error, :malformed_or_stale_baseline}

  defp admit_entry(entry) when is_map(entry) do
    required = ~w(file from_module target kind class from_app to_app from_band to_band fate level_direction occurrence_count)

    if Enum.all?(required, &Map.has_key?(entry, &1)) and is_integer(entry["occurrence_count"]) and
         entry["occurrence_count"] >= 1 do
      {:ok, Encode.order_entry(entry)}
    else
      {:error, :malformed_or_stale_baseline}
    end
  end

  defp admit_entry(_), do: {:error, :malformed_or_stale_baseline}

  defp admit_unresolved(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn entry, {:ok, acc} ->
      case admit_unresolved_entry(entry) do
        {:ok, e} -> {:cont, {:ok, [e | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp admit_unresolved(nil), do: {:ok, []}
  defp admit_unresolved(_), do: {:error, :malformed_or_stale_baseline}

  defp admit_unresolved_entry(entry) when is_map(entry) do
    disp = entry["disposition"]
    rationale = entry["rationale"]
    norm = entry["normalized_expression"] || ""
    digest = entry["expression_digest"]
    expected = Encode.expression_digest(norm)

    cond do
      not MapSet.member?(@dispositions, disp) ->
        {:error, :malformed_or_stale_baseline}

      not is_binary(rationale) or String.trim(rationale) == "" or
          byte_size(rationale) > @max_rationale_bytes ->
        {:error, :malformed_or_stale_baseline}

      not is_binary(digest) or digest != expected ->
        {:error, :malformed_or_stale_baseline}

      true ->
        {:ok, Encode.order_unresolved_entry(entry)}
    end
  end

  defp admit_unresolved_entry(_), do: {:error, :malformed_or_stale_baseline}

  defp compare_occurrence_keys(failures, base_map, cur_map) do
    failures =
      Enum.reduce(cur_map, failures, fn {key, cur}, acc ->
        case Map.fetch(base_map, key) do
          :error ->
            [
              %{
                "reason" => "new_finding",
                "detail" => key_detail(key)
              }
              | acc
            ]

          {:ok, base} ->
            cond do
              cur["occurrence_count"] > base["occurrence_count"] ->
                [
                  %{
                    "reason" => "occurrence_count_increased",
                    "detail" => key_detail(key)
                  }
                  | acc
                ]

              cur["occurrence_count"] < base["occurrence_count"] ->
                [
                  %{
                    "reason" => "occurrence_count_decreased",
                    "detail" => key_detail(key)
                  }
                  | acc
                ]

              metadata_changed?(base, cur) ->
                [
                  %{
                    "reason" => "occurrence_metadata_changed",
                    "detail" => key_detail(key)
                  }
                  | acc
                ]

              true ->
                acc
            end
        end
      end)

    Enum.reduce(base_map, failures, fn {key, _base}, acc ->
      if Map.has_key?(cur_map, key) do
        acc
      else
        [
          %{
            "reason" => "baseline_entry_removed",
            "detail" => key_detail(key)
          }
          | acc
        ]
      end
    end)
  end

  defp compare_unresolved_keys(failures, base_u, cur_u) do
    failures =
      Enum.reduce(cur_u, failures, fn {key, cur}, acc ->
        case Map.fetch(base_u, key) do
          :error ->
            [
              %{
                "reason" => "unexplained_unresolved",
                "detail" => unresolved_detail(key)
              }
              | acc
            ]

          {:ok, base} ->
            cond do
              cur["occurrence_count"] > base["occurrence_count"] ->
                [
                  %{
                    "reason" => "unresolved_count_increased",
                    "detail" => unresolved_detail(key)
                  }
                  | acc
                ]

              cur["occurrence_count"] < base["occurrence_count"] ->
                [
                  %{
                    "reason" => "unresolved_count_decreased",
                    "detail" => unresolved_detail(key)
                  }
                  | acc
                ]

              true ->
                acc
            end
        end
      end)

    Enum.reduce(base_u, failures, fn {key, _}, acc ->
      if Map.has_key?(cur_u, key) do
        acc
      else
        [
          %{
            "reason" => "unresolved_baseline_entry_removed",
            "detail" => unresolved_detail(key)
          }
          | acc
        ]
      end
    end)
  end

  defp metadata_changed?(base, cur) do
    Enum.any?(@metadata_keys, fn k -> base[k] != cur[k] end)
  end

  defp entry_key(entry) do
    {
      entry["file"],
      entry["from_module"],
      entry["target"],
      entry["kind"],
      entry["class"]
    }
  end

  defp unresolved_key(entry) do
    {
      entry["file"],
      entry["from_module"],
      entry["reason"],
      entry["kind"],
      entry["expression_digest"]
    }
  end

  defp key_detail({file, from_module, target, kind, class}) do
    "#{file}|#{from_module}|#{target}|#{kind}|#{class}"
  end

  defp unresolved_detail({file, from_module, reason, kind, digest}) do
    "#{file}|#{from_module}|#{reason}|#{kind}|#{digest}"
  end

  defp entry_sort(e),
    do: {e["file"], e["from_module"], e["target"], e["kind"], e["class"]}

  defp unresolved_sort(e),
    do: {e["file"], e["from_module"], e["reason"], e["kind"], e["expression_digest"]}

  defp merge_unresolved(current, prior_map, review) do
    Enum.reduce_while(current, {:ok, []}, fn item, {:ok, acc} ->
      key = unresolved_key(item)

      case Map.fetch(prior_map, key) do
        {:ok, prior} ->
          merged =
            item
            |> Map.put("disposition", prior["disposition"])
            |> Map.put("rationale", prior["rationale"])

          {:cont, {:ok, [merged | acc]}}

        :error ->
          review_key = key_detail_unresolved(key)

          case Map.get(review, review_key) || Map.get(review, item["expression_digest"]) do
            %{"disposition" => d, "rationale" => r} ->
              if MapSet.member?(@dispositions, d) and is_binary(r) and String.trim(r) != "" do
                merged = item |> Map.put("disposition", d) |> Map.put("rationale", r)
                {:cont, {:ok, [merged | acc]}}
              else
                {:halt, {:error, {:unresolved_review_invalid, review_key}}}
              end

            _ ->
              {:halt, {:error, {:unresolved_review_required, review_key}}}
          end
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp key_detail_unresolved({file, from_module, reason, kind, digest}) do
    "#{file}|#{from_module}|#{reason}|#{kind}|#{digest}"
  end
end
