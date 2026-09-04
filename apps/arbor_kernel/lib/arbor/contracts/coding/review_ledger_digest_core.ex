defmodule Arbor.Contracts.Coding.ReviewLedgerDigestCore do
  @moduledoc """
  Pure digest of the review ledger subset carried on a coding terminal result.

  Input is the adapted terminal map produced by `Arbor.Orchestrator.CodingTaskExecutor`
  (string-keyed JSON-clean map with a `"review"` object and a payload `"commit"`).

  ## Digested subset

  Only the following keys participate, nested under `"review"` unless noted:

  * `"review_cycle"` — non-negative integer
  * `"review_disposition"` — non-blank string
  * `"blocking_ids"` — list of delimiter-safe id strings (nonblank, no whitespace/control)
  * `"reviewer_outcomes"` — map of perspective name to
    `%{"perspective" => ..., "status" => ..., "provider" => ..., "model" => ...}` only
  * `"consolidated_findings"` — list of maps with `"id"` or `"issue_key"`, `"severity"`,
    `"state"` (defaults to `"open"` when absent), and `"owner"` (or first of `"owners"`)

  Plus top-level `"reviewed_commit"` taken **only** from `"commit"` (40 lowercase hex).
  `"commit_hash"` is never accepted.

  Titles, evidence, required_action, and other review fields are excluded.

  ## Canonicalization

  The subset map is recursively key-sorted (UTF-8 byte order) and encoded with
  `Jason.encode!/1` (compact, no whitespace). The digest is
  `"sha256:" <> lowercase_hex(SHA256(canonical_json))`.

  A verifier can recompute the digest from archived `coding-terminal-evidence.json`
  by projecting the same subset and applying the same canonicalization.
  """

  @type digest :: String.t()

  @doc """
  Compute the review-ledger digest for an adapted terminal map.
  """
  @spec digest(map()) :: {:ok, digest()} | {:error, :projection_invalid}
  def digest(terminal) when is_map(terminal) and not is_struct(terminal) do
    with {:ok, subset} <- project_subset(terminal),
         {:ok, canonical} <- canonical_json(subset),
         digest <- sha256_prefixed(canonical) do
      {:ok, digest}
    else
      {:error, :projection_invalid} -> {:error, :projection_invalid}
      _ -> {:error, :projection_invalid}
    end
  end

  def digest(_), do: {:error, :projection_invalid}

  defp project_subset(terminal) do
    with {:ok, review} <- fetch_review_map(terminal),
         {:ok, reviewed_commit} <- fetch_reviewed_commit(terminal),
         {:ok, review_cycle} <- fetch_non_neg_int(review, "review_cycle"),
         {:ok, review_disposition} <- fetch_nonblank_string(review, "review_disposition"),
         {:ok, blocking_ids} <- project_blocking_ids(review),
         {:ok, reviewer_outcomes} <- project_reviewer_outcomes(review),
         {:ok, consolidated_findings} <- project_consolidated_findings(review) do
      {:ok,
       %{
         "review" => %{
           "review_cycle" => review_cycle,
           "review_disposition" => review_disposition,
           "blocking_ids" => blocking_ids,
           "reviewer_outcomes" => reviewer_outcomes,
           "consolidated_findings" => consolidated_findings
         },
         "reviewed_commit" => reviewed_commit
       }}
    end
  end

  defp fetch_review_map(terminal) do
    case Map.get(terminal, "review") do
      review when is_map(review) and not is_struct(review) -> {:ok, review}
      _ -> {:error, :projection_invalid}
    end
  end

  defp fetch_reviewed_commit(terminal) do
    if Map.has_key?(terminal, "commit_hash") and not Map.has_key?(terminal, "commit") do
      {:error, :projection_invalid}
    else
      case Map.get(terminal, "commit") do
        commit when is_binary(commit) ->
          if valid_commit_oid?(commit), do: {:ok, commit}, else: {:error, :projection_invalid}

        _ ->
          {:error, :projection_invalid}
      end
    end
  end

  defp valid_commit_oid?(commit) do
    Regex.match?(~r/^[0-9a-f]{40}$/, commit)
  end

  defp fetch_non_neg_int(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> {:error, :projection_invalid}
    end
  end

  defp fetch_nonblank_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        if String.valid?(value) and String.trim(value) != "" do
          {:ok, value}
        else
          {:error, :projection_invalid}
        end

      _ ->
        {:error, :projection_invalid}
    end
  end

  defp project_blocking_ids(review) do
    case Map.get(review, "blocking_ids") do
      ids when is_list(ids) ->
        ids
        |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
          case validate_delimiter_safe_id(id) do
            :ok -> {:cont, {:ok, [id | acc]}}
            {:error, _} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, ids} -> {:ok, Enum.reverse(ids)}
          error -> error
        end

      _ ->
        {:error, :projection_invalid}
    end
  end

  defp validate_delimiter_safe_id(id) when is_binary(id) do
    cond do
      not String.valid?(id) -> {:error, :projection_invalid}
      String.trim(id) == "" -> {:error, :projection_invalid}
      String.match?(id, ~r/[\s\x00-\x1F\x7F=]/) -> {:error, :projection_invalid}
      true -> :ok
    end
  end

  defp validate_delimiter_safe_id(_), do: {:error, :projection_invalid}

  defp project_reviewer_outcomes(review) do
    case Map.get(review, "reviewer_outcomes") do
      outcomes when is_map(outcomes) and not is_struct(outcomes) ->
        outcomes
        |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
          with :ok <- validate_delimiter_safe_id(key),
               {:ok, projected} <- project_reviewer_outcome(key, value) do
            {:cont, {:ok, Map.put(acc, key, projected)}}
          else
            {:error, _} = error -> {:halt, error}
          end
        end)

      _ ->
        {:error, :projection_invalid}
    end
  end

  defp project_reviewer_outcome(key, value) when is_map(value) and not is_struct(value) do
    with {:ok, perspective} <- fetch_nonblank_string(value, "perspective"),
         :ok <- ensure_perspective_key_match(key, perspective),
         {:ok, status} <- fetch_nonblank_string(value, "status"),
         {:ok, provider} <- fetch_nonblank_string(value, "provider"),
         {:ok, model} <- fetch_nonblank_string(value, "model") do
      {:ok,
       %{
         "perspective" => perspective,
         "status" => status,
         "provider" => provider,
         "model" => model
       }}
    end
  end

  defp project_reviewer_outcome(_key, _value), do: {:error, :projection_invalid}

  defp ensure_perspective_key_match(key, perspective) do
    if key == perspective, do: :ok, else: {:error, :projection_invalid}
  end

  defp project_consolidated_findings(review) do
    case Map.get(review, "consolidated_findings") do
      findings when is_list(findings) ->
        findings
        |> Enum.reduce_while({:ok, []}, fn finding, {:ok, acc} ->
          case project_consolidated_finding(finding) do
            {:ok, projected} -> {:cont, {:ok, [projected | acc]}}
            {:error, _} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, findings} -> {:ok, Enum.reverse(findings)}
          error -> error
        end

      _ ->
        {:error, :projection_invalid}
    end
  end

  defp project_consolidated_finding(finding) when is_map(finding) and not is_struct(finding) do
    with {:ok, id_fields} <- project_finding_id(finding),
         {:ok, severity} <- fetch_nonblank_string(finding, "severity"),
         {:ok, state} <- project_finding_state(finding),
         {:ok, owner} <- project_finding_owner(finding) do
      {:ok, Map.merge(id_fields, %{"severity" => severity, "state" => state, "owner" => owner})}
    end
  end

  defp project_consolidated_finding(_), do: {:error, :projection_invalid}

  defp project_finding_id(finding) do
    cond do
      Map.has_key?(finding, "id") ->
        case fetch_nonblank_string(finding, "id") do
          {:ok, id} -> {:ok, %{"id" => id}}
          error -> error
        end

      Map.has_key?(finding, "issue_key") ->
        case fetch_nonblank_string(finding, "issue_key") do
          {:ok, issue_key} -> {:ok, %{"issue_key" => issue_key}}
          error -> error
        end

      true ->
        {:error, :projection_invalid}
    end
  end

  defp project_finding_state(finding) do
    case Map.fetch(finding, "state") do
      :error -> {:ok, "open"}
      {:ok, value} -> fetch_nonblank_string(%{"state" => value}, "state")
    end
  end

  defp project_finding_owner(finding) do
    cond do
      Map.has_key?(finding, "owner") ->
        fetch_nonblank_string(finding, "owner")

      is_list(Map.get(finding, "owners")) ->
        case Map.get(finding, "owners") do
          [owner | _] -> fetch_nonblank_string(%{"owner" => owner}, "owner")
          _ -> {:error, :projection_invalid}
        end

      true ->
        {:error, :projection_invalid}
    end
  end

  defp canonical_json(value) do
    {:ok, value |> canonicalize() |> Jason.encode!()}
  rescue
    _ -> {:error, :projection_invalid}
  end

  defp canonicalize(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {key, value} -> {key, canonicalize(value)} end)
    |> Map.new()
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(value), do: value

  defp sha256_prefixed(data) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, data), case: :lower)
  end
end
