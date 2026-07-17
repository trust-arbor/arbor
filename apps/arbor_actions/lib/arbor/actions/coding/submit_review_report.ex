defmodule Arbor.Actions.Coding.SubmitReviewReport do
  @moduledoc """
  Side-effect-free terminal tool that accepts a strict code-review report.

  Reviewers call this action exactly once when ready. The result is a
  JSON-clean string-keyed map with exactly `vote`, `finding_updates`, and
  `new_findings`. Ledger-, owner-, cycle-, and delta-aware validation remains
  in `ReviewLedgerCore` / `Consensus.DecideReview` — this action only bounds
  the tool-schema contract and normalizes the three report fields.
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
  @allowed_votes ~w(approve reject abstain)
  @allowed_update_states ~w(fixed open architectural_blocker)
  @allowed_severities ~w(blocking major minor nit)

  @impl true
  @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
  def run(params, _context) when is_map(params) do
    with {:ok, vote} <- fetch_vote(params),
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
      vote when vote in @allowed_votes -> {:ok, vote}
      vote when is_atom(vote) -> fetch_vote(%{"vote" => Atom.to_string(vote)})
      _ -> {:error, :invalid_vote}
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
    with :ok <- ensure_string_keys(update),
         id when is_binary(id) and id != "" <- map_get(update, "id"),
         state when state in @allowed_update_states <- map_get(update, "state") do
      base = %{"id" => id, "state" => state}

      optional =
        Enum.reduce(["title", "required_action", "evidence"], base, fn key, acc ->
          case map_get(update, key) do
            value when is_binary(value) -> Map.put(acc, key, value)
            nil -> acc
            _ -> acc
          end
        end)

      {:ok, optional}
    else
      _ -> {:error, :invalid_finding_update}
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
    with :ok <- ensure_string_keys(finding),
         title when is_binary(title) and title != "" <- map_get(finding, "title"),
         required_action when is_binary(required_action) and required_action != "" <-
           map_get(finding, "required_action"),
         severity when severity in @allowed_severities <- map_get(finding, "severity"),
         {:ok, anchor} <- normalize_anchor(map_get(finding, "anchor")) do
      base = %{
        "title" => title,
        "required_action" => required_action,
        "severity" => severity,
        "anchor" => anchor
      }

      base =
        case map_get(finding, "evidence") do
          evidence when is_binary(evidence) -> Map.put(base, "evidence", evidence)
          _ -> base
        end

      base =
        case map_get(finding, "state") do
          "architectural_blocker" -> Map.put(base, "state", "architectural_blocker")
          nil -> base
          _ -> base
        end

      {:ok, base}
    else
      _ -> {:error, :invalid_new_finding}
    end
  end

  defp normalize_new_finding(_), do: {:error, :invalid_new_finding}

  defp normalize_anchor(anchor) when is_map(anchor) do
    with :ok <- ensure_string_keys(anchor),
         path when is_binary(path) and path != "" <- map_get(anchor, "path"),
         side when side in ["new", "old"] <- map_get(anchor, "side"),
         line when is_integer(line) and line > 0 <- map_get(anchor, "line") do
      {:ok, %{"path" => path, "side" => side, "line" => line}}
    else
      _ -> {:error, :invalid_anchor}
    end
  end

  defp normalize_anchor(_), do: {:error, :invalid_anchor}

  defp param(params, keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(params, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp map_get(map, key) when is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        # Prefer string keys; fall back only for schema-atomized known keys.
        Enum.find_value(Map.keys(map), fn
          atom when is_atom(atom) ->
            if Atom.to_string(atom) == key, do: Map.get(map, atom), else: nil

          _ ->
            nil
        end)
    end
  end

  defp ensure_string_keys(map) when is_map(map) do
    if Enum.all?(Map.keys(map), &(is_binary(&1) or is_atom(&1))), do: :ok, else: :error
  end

  defp reverse_ok({:ok, list}), do: {:ok, Enum.reverse(list)}
  defp reverse_ok(other), do: other
end
