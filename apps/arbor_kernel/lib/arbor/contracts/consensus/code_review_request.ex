defmodule Arbor.Contracts.Consensus.CodeReviewRequest do
  @moduledoc """
  Input contract for code-review council pipelines.

  The review loop hands a completed coding-agent branch to a council as a
  JSON-clean payload: the branch diff, touched files, exact candidate/base
  commits, an opaque commit-tree snapshot id, the agent intent, and the
  originating agent id. This struct is the typed boundary before that payload
  enters a DOT pipeline.
  """

  use TypedStruct

  @max_delta_files 128
  @max_delta_file_bytes 1_024
  @max_delta_ranges_per_file 128
  @max_delta_ranges_total 1_024
  @max_delta_line_number 10_000_000
  @max_delta_ranges_bytes 131_072
  @max_finding_ledger_bytes 131_072
  @max_prompt_ledger_bytes 32_768
  @max_prompt_delta_bytes 32_768
  @max_prompt_revision_bytes 256

  typedstruct enforce: true do
    @typedoc "A code-review request for a completed coding-agent branch"

    field(:diff, String.t())
    field(:files, [String.t()])
    field(:branch, String.t())
    field(:base_ref, String.t() | nil, enforce: false, default: nil)
    field(:candidate_commit, String.t() | nil, enforce: false, default: nil)
    field(:review_snapshot_id, String.t() | nil, enforce: false, default: nil)
    field(:intent, String.t(), enforce: false, default: "")
    field(:agent_id, String.t() | nil, enforce: false, default: nil)
    field(:review_cycle, pos_integer(), enforce: false, default: 1)
    field(:prior_candidate_commit, String.t() | nil, enforce: false, default: nil)
    field(:delta_diff, String.t(), enforce: false, default: "")
    field(:delta_files, [String.t()], enforce: false, default: [])
    field(:delta_ranges, map(), enforce: false, default: %{})
    field(:finding_ledger, map(), enforce: false, default: %{})
  end

  @doc """
  Build a review request from atom-keyed, string-keyed, or keyword attrs.

  Required fields:

    * `:diff` - a non-empty git diff
    * `:files` - a non-empty list of touched file paths
    * `:branch` - the review branch name
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs) do
    attrs
    |> Map.new()
    |> new()
  end

  def new(attrs) when is_map(attrs) do
    with {:ok, diff} <- required_string(attrs, :diff),
         {:ok, files} <- required_files(attrs),
         {:ok, branch} <- required_string(attrs, :branch),
         {:ok, base_ref} <- optional_string(attrs, :base_ref, nil),
         {:ok, candidate_commit} <- optional_string(attrs, :candidate_commit, nil),
         {:ok, review_snapshot_id} <- optional_string(attrs, :review_snapshot_id, nil),
         {:ok, intent} <- optional_string(attrs, :intent, ""),
         {:ok, agent_id} <- optional_string(attrs, :agent_id, nil),
         {:ok, review_cycle} <- optional_positive_integer(attrs, :review_cycle, 1),
         {:ok, prior_candidate_commit} <-
           optional_utf8_string(attrs, :prior_candidate_commit, nil),
         {:ok, delta_diff} <- optional_utf8_string(attrs, :delta_diff, ""),
         {:ok, delta_files} <- optional_delta_files(attrs),
         {:ok, delta_ranges} <- optional_delta_ranges(attrs),
         {:ok, finding_ledger} <- optional_finding_ledger(attrs) do
      {:ok,
       %__MODULE__{
         diff: diff,
         files: files,
         branch: branch,
         base_ref: base_ref,
         candidate_commit: candidate_commit,
         review_snapshot_id: review_snapshot_id,
         intent: intent,
         agent_id: agent_id,
         review_cycle: review_cycle,
         prior_candidate_commit: prior_candidate_commit,
         delta_diff: delta_diff,
         delta_files: delta_files,
         delta_ranges: delta_ranges,
         finding_ledger: finding_ledger
       }}
    end
  end

  @doc "Bind an authorized commit-tree snapshot to a review request."
  @spec bind_review_snapshot(t(), map()) :: {:ok, t()} | {:error, term()}
  def bind_review_snapshot(%__MODULE__{} = request, snapshot) when is_map(snapshot) do
    with {:ok, snapshot_id} <- required_snapshot_string(snapshot, :review_snapshot_id),
         {:ok, snapshot_candidate} <- required_snapshot_string(snapshot, :candidate_commit),
         {:ok, snapshot_base} <- required_snapshot_string(snapshot, :base_commit),
         :ok <- require_equal_revision(:candidate, request.candidate_commit, snapshot_candidate),
         :ok <- require_equal_revision(:base, request.base_ref, snapshot_base) do
      new(%{
        diff: request.diff,
        files: request.files,
        branch: request.branch,
        base_ref: snapshot_base,
        candidate_commit: snapshot_candidate,
        review_snapshot_id: snapshot_id,
        intent: request.intent,
        agent_id: request.agent_id,
        review_cycle: request.review_cycle,
        prior_candidate_commit: request.prior_candidate_commit,
        delta_diff: request.delta_diff,
        delta_files: request.delta_files,
        delta_ranges: request.delta_ranges,
        finding_ledger: request.finding_ledger
      })
    end
  end

  def bind_review_snapshot(%__MODULE__{}, _snapshot), do: {:error, :invalid_review_snapshot}

  @doc "Return the complete canonical string-keyed JSON representation."
  @spec to_map(t()) :: %{required(String.t()) => term()}
  def to_map(%__MODULE__{} = request) do
    %{
      "diff" => request.diff,
      "files" => request.files,
      "branch" => request.branch,
      "base_ref" => request.base_ref,
      "candidate_commit" => request.candidate_commit,
      "review_snapshot_id" => request.review_snapshot_id,
      "intent" => request.intent,
      "agent_id" => request.agent_id,
      "review_cycle" => request.review_cycle,
      "prior_candidate_commit" => request.prior_candidate_commit,
      "delta_diff" => request.delta_diff,
      "delta_files" => request.delta_files,
      "delta_ranges" => request.delta_ranges,
      "finding_ledger" => request.finding_ledger
    }
  end

  @doc """
  Convert the request to Engine context values.

  The returned map is JSON-clean and intentionally includes both flat keys
  (`diff` / `review.diff`) and a nested `review.request` map. Flat keys are
  convenient for `context_keys` and debugging; the nested map is convenient for
  future handlers that want the request as one value. `review.prompt` is the
  string fed to LLM reviewer nodes through `prompt_context_key`.
  """
  @spec to_context(t()) :: map()
  def to_context(%__MODULE__{} = request) do
    request_map = to_map(request)

    question = "Should branch #{request.branch} be accepted for human review?"

    %{
      "review.request" => request_map,
      "diff" => request.diff,
      "files" => request.files,
      "branch" => request.branch,
      "base_ref" => request.base_ref,
      "candidate_commit" => request.candidate_commit,
      "review_snapshot_id" => request.review_snapshot_id,
      "intent" => request.intent,
      "agent_id" => request.agent_id,
      "review_cycle" => request.review_cycle,
      "prior_candidate_commit" => request.prior_candidate_commit,
      "delta_diff" => request.delta_diff,
      "delta_files" => request.delta_files,
      "finding_ledger" => request.finding_ledger,
      "review.diff" => request.diff,
      "review.files" => request.files,
      "review.branch" => request.branch,
      "review.base_ref" => request.base_ref,
      "review.candidate_commit" => request.candidate_commit,
      "review.snapshot_id" => request.review_snapshot_id,
      "review.intent" => request.intent,
      "review.agent_id" => request.agent_id,
      "review.cycle" => request.review_cycle,
      # Production council DOT context_keys use the review.* namespace form
      # (review.review_cycle), matching review.finding_ledger / review.delta_ranges.
      "review.review_cycle" => request.review_cycle,
      "review.prior_candidate_commit" => request.prior_candidate_commit,
      "review.delta_diff" => request.delta_diff,
      "review.delta_files" => request.delta_files,
      "review.delta_ranges" => request.delta_ranges,
      "review.finding_ledger" => request.finding_ledger,
      "review.prompt" => prompt_text(request),
      "council.question" => question
    }
  end

  @doc """
  Render a stable prompt body for the reviewer LLM nodes.
  """
  @spec prompt_text(t()) :: String.t()
  def prompt_text(%__MODULE__{} = request) do
    ledger_json = bounded_json(request.finding_ledger, @max_prompt_ledger_bytes)

    """
    Branch: #{request.branch}
    Candidate commit: #{request.candidate_commit || "unknown"}
    Base commit: #{request.base_ref || "unknown"}
    Review snapshot id: #{request.review_snapshot_id || "unavailable"}
    Agent id: #{request.agent_id || "unknown"}

    Review cycle: #{request.review_cycle}
    Recheck: #{recheck_summary(request)}
    Prior candidate commit: #{bounded_text(request.prior_candidate_commit || "none", @max_prompt_revision_bytes)}
    Delta files:
    #{format_delta_files(request.delta_files)}
    Delta diff (bounded):
    ```diff
    #{bounded_text(request.delta_diff, @max_prompt_delta_bytes)}
    ```

    Review charter:
    #{review_charter(request)}

    Finding ledger (bounded JSON):
    ```json
    #{ledger_json}
    ```

    Intent:
    #{blank_to_none(request.intent)}

    Files:
    #{format_files(request.files)}

    Diff:
    ```diff
    #{request.diff}
    ```
    """
    |> String.trim()
  end

  defp required_string(attrs, key) do
    with {:ok, value} <- fetch_attr(attrs, key),
         :ok <- validate_non_empty_string(key, value) do
      {:ok, value}
    end
  end

  defp optional_string(attrs, key, default) do
    case fetch_attr(attrs, key) do
      {:ok, nil} ->
        {:ok, default}

      {:ok, value} when is_binary(value) ->
        {:ok, value}

      {:ok, value} ->
        {:error, {:invalid_field, key, {:expected_string_or_nil, value}}}

      {:error, {:missing_required_field, ^key}} ->
        {:ok, default}
    end
  end

  defp optional_positive_integer(attrs, key, default) do
    case fetch_attr(attrs, key) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_field, key, {:expected_positive_integer, value}}}
      {:error, {:missing_required_field, ^key}} -> {:ok, default}
    end
  end

  defp optional_utf8_string(attrs, key, default) do
    case optional_string(attrs, key, default) do
      {:ok, value} when is_binary(value) ->
        if String.valid?(value),
          do: {:ok, value},
          else: {:error, {:invalid_field, key, :invalid_utf8}}

      other ->
        other
    end
  end

  defp optional_delta_files(attrs) do
    case fetch_attr(attrs, :delta_files) do
      {:ok, files} -> validate_delta_files(files)
      {:error, {:missing_required_field, :delta_files}} -> {:ok, []}
    end
  end

  defp optional_finding_ledger(attrs) do
    case fetch_attr(attrs, :finding_ledger) do
      {:ok, ledger} -> validate_finding_ledger(ledger)
      {:error, {:missing_required_field, :finding_ledger}} -> {:ok, %{}}
    end
  end

  defp optional_delta_ranges(attrs) do
    case fetch_attr(attrs, :delta_ranges) do
      {:ok, ranges} -> validate_delta_ranges(ranges)
      {:error, {:missing_required_field, :delta_ranges}} -> {:ok, %{}}
    end
  end

  defp validate_delta_files(files) when is_list(files) do
    cond do
      length(files) > @max_delta_files ->
        {:error, {:invalid_field, :delta_files, :too_many}}

      Enum.any?(files, &(not valid_repo_relative_file?(&1))) ->
        invalid = Enum.find(files, &(not valid_repo_relative_file?(&1)))
        {:error, {:invalid_field, :delta_files, {:invalid_path, invalid}}}

      length(files) != length(Enum.uniq(files)) ->
        {:error, {:invalid_field, :delta_files, :duplicate}}

      true ->
        {:ok, Enum.sort(files)}
    end
  end

  defp validate_delta_files(value),
    do: {:error, {:invalid_field, :delta_files, {:expected_list, value}}}

  defp valid_repo_relative_file?(file) when is_binary(file) do
    file != "" and byte_size(file) <= @max_delta_file_bytes and
      String.trim(file) == file and String.valid?(file) and
      not String.contains?(file, <<0>>) and not String.starts_with?(file, ["/", "\\"]) and
      not String.contains?(file, "\\") and
      Enum.all?(String.split(file, "/"), &(&1 not in ["", ".", ".."]))
  end

  defp valid_repo_relative_file?(_file), do: false

  defp validate_delta_ranges(ranges) when is_map(ranges) do
    cond do
      is_struct(ranges) -> invalid_delta_ranges(:invalid_json)
      map_size(ranges) > @max_delta_files -> invalid_delta_ranges(:too_many_files)
      true -> validate_delta_range_entries(ranges)
    end
  end

  defp validate_delta_ranges(value), do: invalid_delta_ranges({:expected_map, value})

  defp validate_delta_range_entries(ranges) do
    case Enum.find(Map.to_list(ranges), fn {path, _path_ranges} ->
           not valid_delta_range_path?(path)
         end) do
      {path, _path_ranges} -> invalid_delta_ranges({:invalid_path, path})
      nil -> validate_delta_range_values(ranges)
    end
  end

  defp validate_delta_range_values(ranges) do
    ranges
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, [], 0}, fn {path, path_ranges}, {:ok, acc, total} ->
      case validate_delta_ranges_for_file(path_ranges) do
        {:ok, normalized, count} when total + count <= @max_delta_ranges_total ->
          {:cont, {:ok, [{path, normalized} | acc], total + count}}

        {:ok, _normalized, _count} ->
          {:halt, invalid_delta_ranges(:too_many_total)}

        {:error, reason} ->
          {:halt, invalid_delta_ranges({:invalid_ranges, path, reason})}
      end
    end)
    |> case do
      {:ok, entries, _total} ->
        normalized = Map.new(Enum.reverse(entries))

        case Jason.encode(normalized) do
          {:ok, encoded} when byte_size(encoded) <= @max_delta_ranges_bytes ->
            {:ok, normalized}

          {:ok, _encoded} ->
            invalid_delta_ranges(:too_large)

          {:error, _reason} ->
            invalid_delta_ranges(:invalid_json)
        end

      error ->
        error
    end
  end

  defp validate_delta_ranges_for_file(path_ranges) when is_list(path_ranges) do
    if length(path_ranges) > @max_delta_ranges_per_file do
      {:error, :too_many_per_file}
    else
      Enum.reduce_while(path_ranges, {:ok, [], nil}, fn range, {:ok, normalized, previous_end} ->
        case range do
          [start_line, end_line]
          when is_integer(start_line) and start_line > 0 and
                 is_integer(end_line) and end_line >= start_line and
                 end_line <= @max_delta_line_number and
                 (is_nil(previous_end) or start_line > previous_end + 1) ->
            {:cont, {:ok, [[start_line, end_line] | normalized], end_line}}

          _ ->
            {:halt, {:error, :invalid_range}}
        end
      end)
      |> case do
        {:ok, normalized, _previous_end} ->
          {:ok, Enum.reverse(normalized), length(path_ranges)}

        error ->
          error
      end
    end
  end

  defp validate_delta_ranges_for_file(_path_ranges), do: {:error, :expected_list}

  defp valid_delta_range_path?(path) when is_binary(path) do
    valid_repo_relative_file?(path) and not windows_absolute_path?(path)
  end

  defp valid_delta_range_path?(_path), do: false

  defp windows_absolute_path?(<<drive, ":", rest::binary>>)
       when drive in ?A..?Z or drive in ?a..?z do
    String.starts_with?(rest, "/")
  end

  defp windows_absolute_path?(_path), do: false

  defp invalid_delta_ranges(reason),
    do: {:error, {:invalid_field, :delta_ranges, reason}}

  defp validate_finding_ledger(ledger) when is_map(ledger) do
    with true <- not is_struct(ledger),
         true <- json_clean?(ledger),
         {:ok, encoded} <- Jason.encode(ledger),
         true <- byte_size(encoded) <= @max_finding_ledger_bytes do
      {:ok, ledger}
    else
      _ -> {:error, {:invalid_field, :finding_ledger, :invalid_json_or_size}}
    end
  end

  defp validate_finding_ledger(value),
    do: {:error, {:invalid_field, :finding_ledger, {:expected_map, value}}}

  defp json_clean?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn {key, nested} -> is_binary(key) and json_clean?(nested) end)
  end

  defp json_clean?(value) when is_list(value), do: Enum.all?(value, &json_clean?/1)
  defp json_clean?(value) when is_binary(value), do: String.valid?(value)
  defp json_clean?(value) when is_boolean(value) or is_nil(value) or is_integer(value), do: true

  defp json_clean?(value) when is_float(value),
    do: value == value and value not in [:infinity, :neg_infinity]

  defp json_clean?(_value), do: false

  defp required_snapshot_string(snapshot, key) do
    case snapshot_value(snapshot, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_review_snapshot, key}}
    end
  end

  defp require_equal_revision(kind, nil, _snapshot_commit),
    do: {:error, {:missing_review_commit, kind}}

  defp require_equal_revision(_kind, commit, commit), do: :ok

  defp require_equal_revision(kind, _request_commit, _snapshot_commit),
    do: {:error, {:review_commit_mismatch, kind}}

  defp snapshot_value(snapshot, key) do
    Map.get(snapshot, key) || Map.get(snapshot, Atom.to_string(key))
  end

  defp required_files(attrs) do
    with {:ok, files} <- fetch_attr(attrs, :files),
         :ok <- validate_files(files) do
      {:ok, files}
    end
  end

  defp fetch_attr(attrs, key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(attrs, key) -> {:ok, Map.get(attrs, key)}
      Map.has_key?(attrs, string_key) -> {:ok, Map.get(attrs, string_key)}
      true -> {:error, {:missing_required_field, key}}
    end
  end

  defp validate_non_empty_string(key, value)
       when is_binary(value) do
    if String.trim(value) == "" do
      {:error, {:invalid_field, key, :empty}}
    else
      :ok
    end
  end

  defp validate_non_empty_string(key, value),
    do: {:error, {:invalid_field, key, {:expected_string, value}}}

  defp validate_files(files) when is_list(files) and files != [] do
    case Enum.find(files, fn file -> not valid_file?(file) end) do
      nil -> :ok
      invalid -> {:error, {:invalid_field, :files, {:invalid_path, invalid}}}
    end
  end

  defp validate_files([]), do: {:error, {:invalid_field, :files, :empty}}
  defp validate_files(value), do: {:error, {:invalid_field, :files, {:expected_list, value}}}

  defp valid_file?(file) when is_binary(file), do: String.trim(file) != ""
  defp valid_file?(_), do: false

  defp blank_to_none(value) when is_binary(value) do
    if String.trim(value) == "", do: "none provided", else: value
  end

  defp format_files(files), do: Enum.map_join(files, "\n", &"- #{&1}")

  defp recheck_summary(%__MODULE__{review_cycle: 1}), do: "initial review"
  defp recheck_summary(%__MODULE__{}), do: "recheck against the supplied delta"

  defp review_charter(%__MODULE__{review_cycle: 1}) do
    "Cycle 1: review the stated intent and full diff."
  end

  defp review_charter(%__MODULE__{}) do
    "Cycle >1: verify owned open findings, inspect only the supplied delta for regressions, " <>
      "and report pre-existing or out-of-delta issues as nonblocking/out-of-scope."
  end

  defp format_delta_files([]), do: "- none supplied"
  defp format_delta_files(files), do: Enum.map_join(files, "\n", &"- #{&1}")

  defp bounded_text(value, limit) when byte_size(value) <= limit, do: value

  defp bounded_text(value, limit) do
    marker = "\n[truncated]"
    prefix_limit = max(limit - byte_size(marker), 0)
    utf8_prefix(value, prefix_limit) <> marker
  end

  defp utf8_prefix(_value, 0), do: ""

  defp utf8_prefix(value, limit) do
    prefix = binary_part(value, 0, min(byte_size(value), limit))
    if String.valid?(prefix), do: prefix, else: utf8_prefix(value, limit - 1)
  end

  defp bounded_json(value, limit) do
    encoded = Jason.encode!(value)

    if byte_size(encoded) <= limit do
      encoded
    else
      envelope = %{
        "truncated" => true,
        "original_bytes" => byte_size(encoded),
        "preview" => ""
      }

      empty = Jason.encode!(envelope)
      fit_json_preview(encoded, envelope, limit, 0, min(byte_size(encoded), limit), empty)
    end
  end

  defp fit_json_preview(_encoded, _envelope, _limit, low, high, best) when low > high,
    do: best

  defp fit_json_preview(encoded, envelope, limit, low, high, best) do
    midpoint = div(low + high, 2)
    preview = utf8_prefix(encoded, midpoint)
    candidate = envelope |> Map.put("preview", preview) |> Jason.encode!()

    if byte_size(candidate) <= limit do
      fit_json_preview(encoded, envelope, limit, midpoint + 1, high, candidate)
    else
      fit_json_preview(encoded, envelope, limit, low, midpoint - 1, best)
    end
  end
end
