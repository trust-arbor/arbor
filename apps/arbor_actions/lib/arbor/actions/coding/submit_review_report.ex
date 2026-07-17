defmodule Arbor.Actions.Coding.SubmitReviewReport do
  @moduledoc """
  Side-effect-free terminal tool that accepts a strict code-review report.

  Reviewers call this action exactly once when ready. The result is a
  JSON-clean string-keyed map with exactly `vote`, `finding_updates`, and
  `new_findings`. Ledger-, owner-, cycle-, and delta-aware validation remains
  in `ReviewLedgerCore` / `Consensus.DecideReview` — this action only bounds
  the tool-schema contract and normalizes the three report fields.

  Fail-closed: unknown keys and malformed optional values are rejected, never
  silently dropped.
  """

  use Jido.Action,
    name: "coding_submit_review_report",
    description:
      "Submit the final binding code-review report (vote, finding_updates, new_findings). Call exactly once when ready; do not emit free-form JSON text.",
    category: "coding",
    tags: ["coding", "review", "report", "terminal"],
    schema:
      Zoi.object(%{
        vote:
          Zoi.enum(["approve", "reject", "abstain"],
            description: "Perspective vote: approve, reject, or abstain"
          ),
        finding_updates:
          Zoi.array(
            Zoi.object(%{
              id: Zoi.string() |> Zoi.min(1) |> Zoi.max(256),
              state: Zoi.enum(["fixed", "open", "architectural_blocker"]),
              title: Zoi.string() |> Zoi.max(512) |> Zoi.optional(),
              required_action: Zoi.string() |> Zoi.max(1024) |> Zoi.optional(),
              evidence: Zoi.string() |> Zoi.max(2048) |> Zoi.optional()
            }),
            description: "Updates to same-owner ledger findings (max 8 with new_findings)"
          )
          |> Zoi.max(8)
          |> Zoi.optional(),
        new_findings:
          Zoi.array(
            Zoi.object(%{
              title: Zoi.string() |> Zoi.min(1) |> Zoi.max(512),
              required_action: Zoi.string() |> Zoi.min(1) |> Zoi.max(1024),
              severity: Zoi.enum(["blocking", "major", "minor", "nit"]),
              anchor:
                Zoi.object(%{
                  path: Zoi.string() |> Zoi.min(1) |> Zoi.max(1024),
                  side: Zoi.enum(["new", "old"]),
                  line: Zoi.integer() |> Zoi.min(1)
                }),
              evidence: Zoi.string() |> Zoi.max(2048) |> Zoi.optional(),
              state: Zoi.enum(["architectural_blocker"]) |> Zoi.optional()
            }),
            description: "New findings for this perspective (max 8 with finding_updates)"
          )
          |> Zoi.max(8)
          |> Zoi.optional()
      })

  # Nested maps are dynamic JSON; keep the tool schema closed at the root.
  defoverridable to_tool: 0

  def to_tool do
    tool = Jido.Action.Tool.to_tool(__MODULE__)
    Map.update!(tool, :parameters_schema, &Map.put(&1, :additionalProperties, false))
  end

  def taint_roles do
    %{
      vote: :data,
      finding_updates: :data,
      new_findings: :data
    }
  end

  def effect_class, do: :read

  @max_entries 8
  @max_id_bytes 256
  @max_title_bytes 512
  @max_required_action_bytes 1_024
  @max_evidence_bytes 2_048
  @max_path_bytes 1_024
  @allowed_votes ~w(approve reject abstain)
  @allowed_update_states ~w(fixed open architectural_blocker)
  @allowed_severities ~w(blocking major minor nit)
  @root_keys MapSet.new(["vote", "finding_updates", "new_findings"])
  @update_keys MapSet.new(["id", "state", "title", "required_action", "evidence"])
  @new_finding_keys MapSet.new([
                      "title",
                      "required_action",
                      "severity",
                      "anchor",
                      "evidence",
                      "state"
                    ])
  @anchor_keys MapSet.new(["path", "side", "line"])

  @impl true
  @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
  def run(params, _context) when is_map(params) do
    with :ok <- ensure_only_keys(params, @root_keys, :invalid_report_field),
         {:ok, vote} <- fetch_vote(params),
         {:ok, updates} <- fetch_list(params, ["finding_updates", :finding_updates], []),
         {:ok, findings} <- fetch_list(params, ["new_findings", :new_findings], []),
         :ok <- bound_entry_count(updates, findings),
         {:ok, normalized_updates} <- normalize_updates(updates),
         {:ok, normalized_findings} <- normalize_new_findings(findings) do
      {:ok,
       %{
         "vote" => vote,
         "finding_updates" => normalized_updates,
         "new_findings" => normalized_findings
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def run(_params, _context), do: {:error, :invalid_params}

  defp fetch_vote(params) do
    case param(params, ["vote", :vote]) do
      vote when vote in @allowed_votes ->
        {:ok, vote}

      vote when is_atom(vote) and vote in [:approve, :reject, :abstain] ->
        {:ok, Atom.to_string(vote)}

      _ ->
        {:error, :invalid_vote}
    end
  end

  defp fetch_list(params, keys, default) do
    case param(params, keys) do
      nil -> {:ok, default}
      list when is_list(list) -> {:ok, list}
      _ -> {:error, :invalid_report_field}
    end
  end

  defp bound_entry_count(updates, findings) do
    if length(updates) + length(findings) <= @max_entries,
      do: :ok,
      else: {:error, :too_many_findings}
  end

  defp normalize_updates(updates) do
    Enum.reduce_while(updates, {:ok, []}, fn update, {:ok, acc} ->
      case normalize_update(update) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_ok()
  end

  defp normalize_update(update) when is_map(update) do
    with :ok <- ensure_only_keys(update, @update_keys, :invalid_finding_update),
         {:ok, id} <- required_binary(update, "id", @max_id_bytes),
         {:ok, state} <- required_enum(update, "state", @allowed_update_states),
         {:ok, title} <- optional_binary(update, "title", @max_title_bytes),
         {:ok, required_action} <-
           optional_binary(update, "required_action", @max_required_action_bytes),
         {:ok, evidence} <- optional_binary(update, "evidence", @max_evidence_bytes) do
      base = %{"id" => id, "state" => state}
      base = put_optional(base, "title", title)
      base = put_optional(base, "required_action", required_action)
      base = put_optional(base, "evidence", evidence)
      {:ok, base}
    end
  end

  defp normalize_update(_), do: {:error, :invalid_finding_update}

  defp normalize_new_findings(findings) do
    Enum.reduce_while(findings, {:ok, []}, fn finding, {:ok, acc} ->
      case normalize_new_finding(finding) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_ok()
  end

  defp normalize_new_finding(finding) when is_map(finding) do
    with :ok <- ensure_only_keys(finding, @new_finding_keys, :invalid_new_finding),
         {:ok, title} <- required_binary(finding, "title", @max_title_bytes),
         {:ok, required_action} <-
           required_binary(finding, "required_action", @max_required_action_bytes),
         {:ok, severity} <- required_enum(finding, "severity", @allowed_severities),
         {:ok, anchor} <- normalize_anchor(map_get(finding, "anchor")),
         {:ok, evidence} <- optional_binary(finding, "evidence", @max_evidence_bytes),
         {:ok, state} <- optional_enum(finding, "state", ["architectural_blocker"]) do
      base = %{
        "title" => title,
        "required_action" => required_action,
        "severity" => severity,
        "anchor" => anchor
      }

      base = put_optional(base, "evidence", evidence)
      base = put_optional(base, "state", state)
      {:ok, base}
    end
  end

  defp normalize_new_finding(_), do: {:error, :invalid_new_finding}

  defp normalize_anchor(anchor) when is_map(anchor) do
    with :ok <- ensure_only_keys(anchor, @anchor_keys, :invalid_anchor),
         {:ok, path} <- required_binary(anchor, "path", @max_path_bytes),
         {:ok, side} <- required_enum(anchor, "side", ["new", "old"]),
         line when is_integer(line) and line > 0 <- map_get(anchor, "line") do
      {:ok, %{"path" => path, "side" => side, "line" => line}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_anchor}
    end
  end

  defp normalize_anchor(_), do: {:error, :invalid_anchor}

  defp ensure_only_keys(map, allowed, error_reason) when is_map(map) do
    keys =
      map
      |> Map.keys()
      |> Enum.map(fn
        key when is_atom(key) -> Atom.to_string(key)
        key when is_binary(key) -> key
        _ -> :invalid
      end)

    duplicate_key? = length(keys) != MapSet.size(MapSet.new(keys))

    if Enum.any?(keys, &(&1 == :invalid)) or duplicate_key? do
      {:error, error_reason}
    else
      unknown = Enum.reject(keys, &MapSet.member?(allowed, &1))
      if unknown == [], do: :ok, else: {:error, error_reason}
    end
  end

  defp required_binary(map, key, max_bytes) do
    case map_get(map, key) do
      value when is_binary(value) ->
        if value != "" and bounded_utf8?(value, max_bytes),
          do: {:ok, value},
          else: {:error, :invalid_report_field}

      _ ->
        {:error, :invalid_report_field}
    end
  end

  defp optional_binary(map, key, max_bytes) do
    case map_has_key?(map, key) do
      false ->
        {:ok, :absent}

      true ->
        case map_get(map, key) do
          value when is_binary(value) ->
            if bounded_utf8?(value, max_bytes),
              do: {:ok, value},
              else: {:error, :invalid_report_field}

          _ ->
            {:error, :invalid_report_field}
        end
    end
  end

  defp bounded_utf8?(value, max_bytes) do
    String.valid?(value) and byte_size(value) <= max_bytes
  end

  defp required_enum(map, key, allowed) do
    case map_get(map, key) do
      value when is_binary(value) ->
        if value in allowed, do: {:ok, value}, else: {:error, :invalid_report_field}

      value when is_atom(value) ->
        string = Atom.to_string(value)
        if string in allowed, do: {:ok, string}, else: {:error, :invalid_report_field}

      _ ->
        {:error, :invalid_report_field}
    end
  end

  defp optional_enum(map, key, allowed) do
    case map_has_key?(map, key) do
      false ->
        {:ok, :absent}

      true ->
        case map_get(map, key) do
          value when is_binary(value) ->
            if value in allowed, do: {:ok, value}, else: {:error, :invalid_report_field}

          value when is_atom(value) ->
            string = Atom.to_string(value)
            if string in allowed, do: {:ok, string}, else: {:error, :invalid_report_field}

          _ ->
            {:error, :invalid_report_field}
        end
    end
  end

  defp put_optional(map, _key, :absent), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp param(params, keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(params, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp map_has_key?(map, key) when is_binary(key) do
    Map.has_key?(map, key) or
      Enum.any?(Map.keys(map), fn
        atom when is_atom(atom) -> Atom.to_string(atom) == key
        _ -> false
      end)
  end

  defp map_get(map, key) when is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(Map.keys(map), fn
          atom when is_atom(atom) ->
            if Atom.to_string(atom) == key, do: Map.get(map, atom), else: nil

          _ ->
            nil
        end)
    end
  end

  defp reverse_ok({:ok, list}), do: {:ok, Enum.reverse(list)}
  defp reverse_ok(other), do: other
end
