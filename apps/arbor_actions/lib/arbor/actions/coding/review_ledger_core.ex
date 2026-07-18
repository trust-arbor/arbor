defmodule Arbor.Actions.Coding.ReviewLedgerCore do
  @moduledoc """
  Pure review-ledger state and decision logic.

  The core accepts and returns string-keyed JSON-clean maps. It has no knowledge
  of commits, diffs, processes, or clocks; a caller supplies the trusted
  perspective names and the explicit changed-line ranges.
  """

  @version "review-ledger-v1"
  @max_perspectives 10
  @max_findings_per_perspective 8
  @max_findings 128
  @max_encoded_bytes 131_072
  @max_out_of_scope 128
  @max_title_bytes 512
  @max_required_action_bytes 1_024
  @max_evidence_bytes 2_048
  @max_path_bytes 1_024

  @default_perspectives [
    "correctness",
    "security",
    "regression_test_coverage",
    "edge_cases_error_handling",
    "simplicity_yagni_scope",
    "readability_maintainability",
    "contract_api_compat",
    "architecture_grain_fit",
    "performance_resource",
    "docs_naming"
  ]

  @votes ["approve", "reject", "abstain"]
  @severities ["blocking", "major", "minor", "nit"]
  @active_states ["open", "new_regression", "architectural_blocker"]
  @update_states ["fixed", "open", "architectural_blocker"]

  @doc "Create an empty ledger, or validate a JSON ledger/configuration map."
  @spec new(map()) :: {:ok, map()} | {:error, term()}
  def new(opts) when is_map(opts) do
    with :ok <- ensure_string_keyed_json(opts),
         {:ok, perspectives, initial} <- initial_config(opts),
         {:ok, ledger} <- initial_ledger(initial, perspectives),
         :ok <- bounded?(ledger) do
      {:ok, ledger}
    end
  end

  def new(_opts), do: {:error, :invalid_ledger_options}

  @doc "Apply one complete review cycle and recompute all derived gates."
  @spec apply_cycle(map(), pos_integer(), map()) :: {:ok, map()} | {:error, term()}
  def apply_cycle(ledger, review_cycle, reports_or_opts)
      when is_map(ledger) and is_integer(review_cycle) and review_cycle > 0 and
             is_map(reports_or_opts) do
    with {:ok, ledger} <- normalize_ledger(ledger),
         :ok <- expected_cycle(ledger, review_cycle),
         {:ok, reports, delta_ranges} <- split_cycle_input(reports_or_opts),
         :ok <- validate_delta_ranges(delta_ranges),
         {:ok, normalized_reports} <- validate_reports(ledger, reports),
         {:ok, ledger} <- apply_updates(ledger, review_cycle, normalized_reports),
         {:ok, ledger} <- add_new_findings(ledger, review_cycle, normalized_reports, delta_ranges),
         ledger <- recompute_derived(ledger),
         ledger <- put_cycle(ledger, review_cycle, normalized_reports),
         :ok <- bounded?(ledger) do
      {:ok, ledger}
    end
  end

  def apply_cycle(_ledger, _review_cycle, _reports), do: {:error, :invalid_cycle_input}

  @doc """
  Project a perspective report to its authority before strict ledger application.

  Drops only `finding_updates` whose ids resolve to **known** findings owned by
  another perspective. Those entries must never mutate foreign findings and must
  not invalidate otherwise complete same-owner evidence.

  Unknown ids and malformed same-owner updates are preserved so strict validation
  still fails closed. Direct `apply_cycle/3` calls that retain cross-owner updates
  continue to reject them.
  """
  @spec project_report_to_authority(String.t(), map(), map()) :: map()
  def project_report_to_authority(owner, report, ledger)
      when is_binary(owner) and is_map(report) and is_map(ledger) do
    case normalize_ledger(ledger) do
      {:ok, normalized} ->
        case Map.fetch(report, "finding_updates") do
          {:ok, updates} when is_list(updates) ->
            projected =
              Enum.reject(updates, &foreign_owned_finding_update?(owner, &1, normalized))

            Map.put(report, "finding_updates", projected)

          _ ->
            report
        end

      {:error, _reason} ->
        report
    end
  end

  def project_report_to_authority(_owner, report, _ledger) when is_map(report), do: report
  def project_report_to_authority(_owner, report, _ledger), do: report

  @doc "Return the review-specific disposition and deterministic reasons."
  @spec decision(map()) :: map()
  def decision(ledger) when is_map(ledger) do
    case normalize_ledger(ledger) do
      {:ok, normalized} -> build_decision(normalized)
      {:error, _reason} -> fail_closed_decision()
    end
  end

  def decision(_ledger), do: fail_closed_decision()

  @doc "Convert a ledger and its current decision into JSON-clean context values."
  @spec to_context(map()) :: map()
  def to_context(ledger) when is_map(ledger) do
    case normalize_ledger(ledger) do
      {:ok, normalized} ->
        findings = normalized["findings"] |> map_values_sorted()
        decision = build_decision(normalized)

        %{
          "review.finding_ledger" => normalized,
          "review.findings" => findings,
          "review.out_of_scope" => normalized["out_of_scope"],
          "review.decision" => decision,
          "review.perspective_votes" => effective_perspective_votes(normalized),
          "finding_ledger" => normalized
        }

      {:error, _reason} ->
        %{
          "review.finding_ledger" => %{},
          "review.findings" => [],
          "review.out_of_scope" => [],
          "review.decision" => fail_closed_decision(),
          "review.perspective_votes" => %{},
          "finding_ledger" => %{}
        }
    end
  end

  def to_context(_ledger), do: to_context(%{})

  defp initial_config(opts) do
    direct_ledger? = Map.has_key?(opts, "version") or Map.has_key?(opts, "findings")
    perspectives = Map.get(opts, "perspectives", @default_perspectives)
    initial = if direct_ledger?, do: opts, else: Map.get(opts, "finding_ledger", %{})

    with {:ok, perspectives} <- validate_perspectives(perspectives),
         :ok <- ensure_string_keyed_json(initial) do
      {:ok, perspectives, initial}
    end
  end

  defp initial_ledger(initial, perspectives) when initial == %{},
    do: {:ok, empty_ledger(perspectives)}

  defp initial_ledger(initial, perspectives) when is_map(initial) do
    with {:ok, normalized} <- normalize_ledger(initial),
         true <- normalized["perspectives"] == perspectives do
      {:ok, normalized}
    else
      false -> {:error, :ledger_perspectives_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp initial_ledger(_initial, _perspectives), do: {:error, :invalid_finding_ledger}

  defp empty_ledger(perspectives) do
    %{
      "version" => @version,
      "perspectives" => perspectives,
      "review_cycle" => 0,
      "findings" => %{},
      "cycles" => %{},
      "out_of_scope" => []
    }
  end

  defp normalize_ledger(ledger) when is_map(ledger) and map_size(ledger) == 0,
    do: {:ok, empty_ledger(@default_perspectives)}

  defp normalize_ledger(ledger) when is_map(ledger) do
    with :ok <- bounded?(ledger),
         :ok <- ensure_string_keyed_json(ledger),
         true <- Map.get(ledger, "version") == @version,
         {:ok, perspectives} <- validate_perspectives(Map.get(ledger, "perspectives")),
         review_cycle when is_integer(review_cycle) and review_cycle >= 0 <-
           Map.get(ledger, "review_cycle"),
         {:ok, findings} <-
           validate_findings(Map.get(ledger, "findings"), perspectives, review_cycle),
         {:ok, cycles} <-
           validate_cycles(Map.get(ledger, "cycles"), perspectives, review_cycle),
         {:ok, out_of_scope} <-
           validate_out_of_scope(Map.get(ledger, "out_of_scope"), perspectives, review_cycle) do
      normalized = %{
        "version" => @version,
        "perspectives" => perspectives,
        "review_cycle" => review_cycle,
        "findings" => findings,
        "cycles" => cycles,
        "out_of_scope" => out_of_scope
      }

      normalized = recompute_derived(normalized)

      case bounded?(normalized) do
        :ok -> {:ok, normalized}
        {:error, reason} -> {:error, reason}
      end
    else
      false -> {:error, :invalid_ledger}
      nil -> {:error, :invalid_ledger}
      _ -> {:error, :invalid_ledger}
    end
  end

  defp normalize_ledger(_ledger), do: {:error, :invalid_ledger}

  defp validate_perspectives(perspectives)
       when is_list(perspectives) and length(perspectives) > 0 and
              length(perspectives) <= @max_perspectives do
    if Enum.all?(perspectives, &valid_owner?/1) and Enum.uniq(perspectives) == perspectives do
      {:ok, Enum.sort(perspectives)}
    else
      {:error, :invalid_perspectives}
    end
  end

  defp validate_perspectives(_perspectives), do: {:error, :invalid_perspectives}

  defp valid_owner?(owner) when is_binary(owner) do
    String.valid?(owner) and byte_size(owner) > 0 and byte_size(owner) <= 128 and
      String.trim(owner) == owner
  end

  defp valid_owner?(_owner), do: false

  defp expected_cycle(ledger, review_cycle) do
    if review_cycle == ledger["review_cycle"] + 1,
      do: :ok,
      else: {:error, :unexpected_review_cycle}
  end

  defp split_cycle_input(input) do
    with :ok <- ensure_string_keyed_json(input) do
      if Map.has_key?(input, "reports") do
        reports = Map.get(input, "reports")
        delta_ranges = Map.get(input, "delta_ranges", %{})

        if is_map(reports) and is_map(delta_ranges),
          do: {:ok, reports, delta_ranges},
          else: {:error, :invalid_cycle_options}
      else
        {:ok, input, %{}}
      end
    end
  end

  defp validate_reports(ledger, reports) when is_map(reports) do
    owners = Map.keys(reports)

    with true <- Enum.all?(owners, &(&1 in ledger["perspectives"])),
         {:ok, normalized} <-
           Enum.reduce_while(Enum.sort(owners), {:ok, %{}}, fn owner, {:ok, acc} ->
             case validate_report(owner, Map.fetch!(reports, owner), ledger) do
               {:ok, report} -> {:cont, {:ok, Map.put(acc, owner, report)}}
               {:error, reason} -> {:halt, {:error, reason}}
             end
           end) do
      {:ok, normalized}
    else
      false -> {:error, :unknown_perspective}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_reports}
    end
  end

  defp validate_reports(_ledger, _reports), do: {:error, :invalid_reports}

  defp validate_report(owner, report, ledger) when is_map(report) do
    allowed = ["vote", "finding_updates", "new_findings"]

    with :ok <- ensure_string_keyed_json(report),
         true <- Enum.all?(Map.keys(report), &(&1 in allowed)),
         {:ok, vote} <- validate_vote(Map.get(report, "vote")),
         {:ok, updates} <- validate_updates(owner, Map.get(report, "finding_updates", []), ledger),
         :ok <- require_owned_active_updates(owner, updates, ledger),
         {:ok, new_findings} <- validate_new_findings(owner, Map.get(report, "new_findings", [])),
         true <- length(updates) + length(new_findings) <= @max_findings_per_perspective do
      {:ok, %{"vote" => vote, "finding_updates" => updates, "new_findings" => new_findings}}
    else
      false -> {:error, {:too_many_findings, owner}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, {:invalid_report, owner}}
    end
  end

  defp validate_report(owner, _report, _ledger), do: {:error, {:invalid_report, owner}}

  # Recheck cycles require explicit owner disposition for every active finding the
  # perspective owns. Omitting an owned active finding is not silent "still open"
  # evidence — the report is invalid and the consumer boundary abstains.
  defp require_owned_active_updates(_owner, _updates, %{"review_cycle" => 0}), do: :ok

  defp require_owned_active_updates(owner, updates, ledger) when is_list(updates) do
    active_ids =
      ledger["findings"]
      |> Map.values()
      |> Enum.filter(&(&1["owner"] == owner and active?(&1)))
      |> Enum.map(& &1["id"])
      |> Enum.sort()

    active_id_set = MapSet.new(active_ids)

    active_update_ids =
      updates
      |> Enum.map(& &1["id"])
      |> Enum.filter(&MapSet.member?(active_id_set, &1))

    cond do
      length(active_update_ids) != length(Enum.uniq(active_update_ids)) ->
        {:error, {:duplicate_owned_finding_update, owner}}

      Enum.sort(active_update_ids) != active_ids ->
        {:error, {:incomplete_owned_finding_updates, owner}}

      true ->
        :ok
    end
  end

  defp require_owned_active_updates(owner, _updates, _ledger),
    do: {:error, {:incomplete_owned_finding_updates, owner}}

  defp foreign_owned_finding_update?(owner, update, ledger) when is_map(update) do
    case Map.get(update, "id") do
      id when is_binary(id) ->
        case Map.get(ledger["findings"], id) do
          %{"owner" => finding_owner} when is_binary(finding_owner) ->
            finding_owner != owner

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp foreign_owned_finding_update?(_owner, _update, _ledger), do: false

  defp validate_vote(vote) when vote in @votes, do: {:ok, vote}
  defp validate_vote(_vote), do: {:error, :invalid_vote}

  defp validate_updates(owner, updates, ledger) when is_list(updates) do
    if length(updates) > @max_findings_per_perspective do
      {:error, {:too_many_updates, owner}}
    else
      Enum.reduce_while(updates, {:ok, []}, fn update, {:ok, acc} ->
        case validate_update(owner, update, ledger) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> reverse_ok()
    end
  end

  defp validate_updates(_owner, _updates, _ledger), do: {:error, :invalid_finding_updates}

  defp validate_update(owner, update, ledger) when is_map(update) do
    with :ok <- ensure_string_keyed_json(update),
         true <- Map.has_key?(update, "id"),
         id when is_binary(id) <- Map.get(update, "id"),
         finding when is_map(finding) <- Map.get(ledger["findings"], id),
         true <- finding["owner"] == owner,
         true <-
           Enum.all?(
             Map.keys(update),
             &(&1 in [
                 "id",
                 "state",
                 "title",
                 "required_action",
                 "evidence",
                 "issue_key",
                 "owner",
                 "origin_cycle",
                 "severity",
                 "anchor"
               ])
           ),
         :ok <- immutable_update_fields(update, finding),
         {:ok, state} <- validate_update_state(Map.get(update, "state")),
         :ok <- fixed_transition_allowed(finding, state),
         :ok <- validate_optional_text_fields(update) do
      {:ok, Map.put(update, "state", state)}
    else
      false -> {:error, {:cross_owner_update, owner}}
      nil -> {:error, :unknown_finding}
      {:error, reason} -> {:error, reason}
      _ -> {:error, {:invalid_update, owner}}
    end
  end

  defp validate_update(_owner, _update, _ledger), do: {:error, :invalid_finding_update}

  defp immutable_update_fields(update, finding) do
    immutable = ["issue_key", "owner", "origin_cycle", "severity", "anchor", "title"]

    if Enum.all?(immutable, fn key ->
         not Map.has_key?(update, key) or Map.get(update, key) == finding[key]
       end),
       do: :ok,
       else: {:error, :immutable_finding_field}
  end

  defp validate_update_state(state) when state in @update_states, do: {:ok, state}
  defp validate_update_state(_state), do: {:error, :invalid_finding_state}

  defp fixed_transition_allowed(%{"state" => "fixed"}, "fixed"), do: :ok

  defp fixed_transition_allowed(%{"state" => "fixed"}, _state),
    do: {:error, :fixed_finding_cannot_reopen}

  defp fixed_transition_allowed(_finding, _state), do: :ok

  defp validate_optional_text_fields(update) do
    with :ok <- optional_bounded_text(update, "title", @max_title_bytes),
         :ok <- optional_bounded_text(update, "required_action", @max_required_action_bytes),
         :ok <- optional_bounded_text(update, "evidence", @max_evidence_bytes) do
      :ok
    end
  end

  defp optional_bounded_text(map, key, max) do
    case Map.fetch(map, key) do
      :error ->
        :ok

      {:ok, value} when is_binary(value) and byte_size(value) <= max ->
        if String.valid?(value), do: :ok, else: {:error, {:invalid_field, key}}

      {:ok, nil} when key == "evidence" ->
        :ok

      _ ->
        {:error, {:invalid_field, key}}
    end
  end

  defp validate_new_findings(owner, findings) when is_list(findings) do
    if length(findings) > @max_findings_per_perspective do
      {:error, {:too_many_new_findings, owner}}
    else
      Enum.reduce_while(findings, {:ok, []}, fn finding, {:ok, acc} ->
        case validate_new_finding(owner, finding) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> reverse_ok()
    end
  end

  defp validate_new_findings(_owner, _findings), do: {:error, :invalid_new_findings}

  defp validate_new_finding(owner, finding) when is_map(finding) do
    allowed = ["title", "required_action", "severity", "anchor", "evidence", "owner", "state"]

    with :ok <- ensure_string_keyed_json(finding),
         true <- Enum.all?(Map.keys(finding), &(&1 in allowed)),
         true <- not Map.has_key?(finding, "id"),
         true <- not Map.has_key?(finding, "issue_key"),
         true <- not Map.has_key?(finding, "blocks_merge"),
         true <- not Map.has_key?(finding, "perspective"),
         :ok <- embedded_owner_matches(finding, owner),
         {:ok, title} <- required_bounded_text(finding, "title", @max_title_bytes),
         {:ok, required_action} <-
           required_bounded_text(finding, "required_action", @max_required_action_bytes),
         {:ok, severity} <- validate_severity(Map.get(finding, "severity")),
         {:ok, anchor} <- validate_anchor(Map.get(finding, "anchor")),
         {:ok, evidence} <- optional_evidence(finding),
         {:ok, state} <- validate_new_state(finding) do
      issue_key = issue_key(anchor, title)
      id = finding_id(owner, issue_key)

      normalized = %{
        "id" => id,
        "issue_key" => issue_key,
        "owner" => owner,
        "severity" => severity,
        "title" => title,
        "required_action" => required_action,
        "anchor" => anchor
      }

      normalized =
        if evidence == nil, do: normalized, else: Map.put(normalized, "evidence", evidence)

      normalized = if state == nil, do: normalized, else: Map.put(normalized, "state", state)

      {:ok, normalized}
    else
      false -> {:error, :invalid_new_finding}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_new_finding}
    end
  end

  defp validate_new_finding(_owner, _finding), do: {:error, :invalid_new_finding}

  defp validate_new_state(finding) do
    case Map.fetch(finding, "state") do
      :error -> {:ok, nil}
      {:ok, "architectural_blocker"} -> {:ok, "architectural_blocker"}
      {:ok, _state} -> {:error, :invalid_new_finding_state}
    end
  end

  defp embedded_owner_matches(finding, owner) do
    case Map.fetch(finding, "owner") do
      :error -> :ok
      {:ok, ^owner} -> :ok
      {:ok, _other} -> {:error, :embedded_owner_mismatch}
    end
  end

  defp required_bounded_text(map, key, max) do
    case Map.get(map, key) do
      value when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= max ->
        if String.valid?(value) do
          normalized = String.normalize(value, :nfc) |> String.trim()
          if normalized == "", do: {:error, {:invalid_field, key}}, else: {:ok, normalized}
        else
          {:error, {:invalid_field, key}}
        end

      _ ->
        {:error, {:invalid_field, key}}
    end
  end

  defp validate_severity(severity) when severity in @severities, do: {:ok, severity}
  defp validate_severity(_severity), do: {:error, :invalid_severity}

  defp validate_anchor(anchor) when is_map(anchor) do
    with :ok <- ensure_string_keyed_json(anchor),
         true <- Enum.sort(Map.keys(anchor)) == ["line", "path", "side"],
         {:ok, path} <- validate_repo_path(Map.get(anchor, "path")),
         side when side in ["old", "new"] <- Map.get(anchor, "side"),
         line when is_integer(line) and line > 0 <- Map.get(anchor, "line") do
      {:ok, %{"path" => path, "side" => side, "line" => line}}
    else
      _ -> {:error, :invalid_anchor}
    end
  end

  defp validate_anchor(_anchor), do: {:error, :invalid_anchor}

  defp optional_evidence(finding) do
    case Map.fetch(finding, "evidence") do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, evidence} when is_binary(evidence) and byte_size(evidence) <= @max_evidence_bytes ->
        if String.valid?(evidence), do: {:ok, evidence}, else: {:error, :invalid_evidence}

      _ ->
        {:error, :invalid_evidence}
    end
  end

  defp validate_repo_path(path)
       when is_binary(path) and byte_size(path) > 0 and byte_size(path) <= @max_path_bytes do
    if valid_repo_path?(path), do: {:ok, path}, else: {:error, :invalid_repo_path}
  end

  defp validate_repo_path(_path), do: {:error, :invalid_repo_path}

  defp valid_repo_path?(path) do
    String.valid?(path) and String.trim(path) == path and not String.contains?(path, <<0>>) and
      not String.starts_with?(path, ["/", "\\"]) and not String.contains?(path, "\\") and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
  end

  defp validate_delta_ranges(ranges) when is_map(ranges) do
    with :ok <- ensure_string_keyed_json(ranges),
         {:ok, _} <-
           Enum.reduce_while(Enum.sort(Map.to_list(ranges)), {:ok, nil}, fn {path, path_ranges},
                                                                            {:ok, previous_path} ->
             with {:ok, path} <- validate_repo_path(path),
                  {:ok, _normalized} <- validate_ranges(path_ranges) do
               if previous_path == nil or path > previous_path,
                 do: {:cont, {:ok, path}},
                 else: {:halt, {:error, :invalid_delta_ranges}}
             else
               _ -> {:halt, {:error, :invalid_delta_ranges}}
             end
           end) do
      :ok
    else
      _ -> {:error, :invalid_delta_ranges}
    end
  end

  defp validate_delta_ranges(_ranges), do: {:error, :invalid_delta_ranges}

  defp validate_ranges(ranges) when is_list(ranges) do
    Enum.reduce_while(ranges, {:ok, nil}, fn range, {:ok, previous_end} ->
      case range do
        [start_line, end_line]
        when is_integer(start_line) and start_line > 0 and is_integer(end_line) and
               end_line >= start_line and (is_nil(previous_end) or start_line > previous_end + 1) ->
          {:cont, {:ok, end_line}}

        _ ->
          {:halt, {:error, :invalid_delta_ranges}}
      end
    end)
  end

  defp validate_ranges(_ranges), do: {:error, :invalid_delta_ranges}

  defp apply_updates(ledger, review_cycle, reports) do
    updates =
      reports
      |> Map.values()
      |> Enum.flat_map(& &1["finding_updates"])

    ids = Enum.map(updates, & &1["id"])

    if length(ids) != length(Enum.uniq(ids)) do
      {:error, :duplicate_finding_update}
    else
      findings =
        Enum.reduce(updates, ledger["findings"], fn update, findings ->
          finding = Map.fetch!(findings, update["id"])
          updated = apply_finding_update(finding, update, review_cycle)
          Map.put(findings, update["id"], updated)
        end)

      {:ok, Map.put(ledger, "findings", findings)}
    end
  end

  defp apply_finding_update(finding, update, _review_cycle) do
    state = update["state"]

    if finding["state"] == "fixed" and state != "fixed" do
      finding
    else
      finding
      |> Map.put("state", state)
      |> maybe_update(update, "title")
      |> maybe_update(update, "required_action")
      |> maybe_update(update, "evidence")
    end
  end

  defp maybe_update(finding, update, key) do
    if Map.has_key?(update, key), do: Map.put(finding, key, Map.get(update, key)), else: finding
  end

  defp add_new_findings(ledger, review_cycle, reports, delta_ranges) do
    candidates =
      reports
      |> Enum.sort_by(fn {owner, _report} -> owner end)
      |> Enum.flat_map(fn {owner, report} -> Enum.map(report["new_findings"], &{owner, &1}) end)

    ids = Enum.map(candidates, fn {_owner, finding} -> finding["id"] end)

    cond do
      length(ids) != length(Enum.uniq(ids)) ->
        {:error, :duplicate_new_finding}

      Enum.any?(ids, &Map.has_key?(ledger["findings"], &1)) ->
        {:error, :duplicate_new_finding}

      Enum.any?(ids, &out_of_scope_id?(ledger["out_of_scope"], &1)) ->
        {:error, :duplicate_new_finding}

      map_size(ledger["findings"]) +
        length(Enum.filter(candidates, &in_delta?(&1, review_cycle, delta_ranges))) >
          @max_findings ->
        {:error, :too_many_findings}

      length(ledger["out_of_scope"]) +
        length(Enum.reject(candidates, &in_delta?(&1, review_cycle, delta_ranges))) >
          @max_out_of_scope ->
        {:error, :too_many_out_of_scope_findings}

      true ->
        {in_scope, out_of_scope} =
          Enum.split_with(candidates, &in_delta?(&1, review_cycle, delta_ranges))

        findings =
          Enum.reduce(in_scope, ledger["findings"], fn {_owner, finding}, acc ->
            state =
              cond do
                finding["state"] == "architectural_blocker" -> "architectural_blocker"
                review_cycle == 1 -> "open"
                true -> "new_regression"
              end

            finding =
              finding
              |> Map.put("origin_cycle", review_cycle)
              |> Map.put("state", state)

            Map.put(acc, finding["id"], finding)
          end)

        out_of_scope =
          Enum.map(out_of_scope, fn {_owner, finding} ->
            finding
            |> Map.put("origin_cycle", review_cycle)
            |> Map.put("state", "out_of_scope")
            |> Map.put("reason", "outside_delta")
          end)

        {:ok,
         ledger
         |> Map.put("findings", findings)
         |> Map.update!("out_of_scope", fn existing ->
           Enum.sort_by(existing ++ out_of_scope, & &1["id"])
         end)}
    end
  end

  defp in_delta?({_owner, _finding}, 1, _ranges), do: true

  defp in_delta?({_owner, finding}, _review_cycle, ranges) do
    anchor = finding["anchor"]

    anchor["side"] == "new" and
      Enum.any?(Map.get(ranges, anchor["path"], []), fn [start_line, end_line] ->
        anchor["line"] >= start_line and anchor["line"] <= end_line
      end)
  end

  defp out_of_scope_id?(out_of_scope, id),
    do: Enum.any?(out_of_scope, &(is_map(&1) and Map.get(&1, "id") == id))

  defp recompute_derived(ledger) do
    major_owner_counts = major_issue_owner_counts(ledger)
    independent_major_quorum? = independent_major_quorum?(ledger)

    findings =
      Enum.reduce(ledger["findings"], %{}, fn {id, finding}, acc ->
        blocks_merge =
          active?(finding) and
            (finding["severity"] == "blocking" or
               (finding["severity"] == "major" and
                  (Map.get(major_owner_counts, finding["issue_key"], 0) >= 2 or
                     independent_major_quorum?)))

        Map.put(acc, id, Map.put(finding, "blocks_merge", blocks_merge))
      end)

    Map.put(ledger, "findings", findings)
  end

  # Active majors grouped by exact issue_key to distinct owner count.
  # Same path/side/line/title from 2 or more owners is corroborated_major.
  defp major_issue_owner_counts(ledger) do
    ledger
    |> active_major_findings()
    |> Enum.group_by(& &1["issue_key"], & &1["owner"])
    |> Map.new(fn {issue_key, owners} -> {issue_key, MapSet.size(MapSet.new(owners))} end)
  end

  # Two distinct owners with any active majors form an independent-major quorum,
  # even when their exact issue_key values differ.
  defp independent_major_quorum?(ledger) do
    ledger
    |> active_major_findings()
    |> Enum.map(& &1["owner"])
    |> MapSet.new()
    |> MapSet.size()
    |> Kernel.>=(2)
  end

  defp active_major_findings(ledger) do
    ledger["findings"]
    |> Map.values()
    |> Enum.filter(&(&1["severity"] == "major" and active?(&1)))
  end

  defp active?(finding), do: finding["state"] in @active_states

  defp put_cycle(ledger, review_cycle, reports) do
    votes =
      ledger["perspectives"]
      |> Enum.map(fn owner -> {owner, get_in(reports, [owner, "vote"]) || "abstain"} end)
      |> Map.new()

    cycle = %{
      "review_cycle" => review_cycle,
      "votes" => votes,
      "reported_owners" => reports |> Map.keys() |> Enum.sort()
    }

    ledger
    |> Map.put("review_cycle", review_cycle)
    |> Map.put("cycles", Map.put(ledger["cycles"], Integer.to_string(review_cycle), cycle))
  end

  defp validate_findings(findings, perspectives, review_cycle)
       when is_map(findings) and map_size(findings) <= @max_findings do
    Enum.reduce_while(findings, {:ok, %{}}, fn {id, finding}, {:ok, acc} ->
      case validate_stored_finding(id, finding, perspectives, review_cycle) do
        {:ok, normalized} -> {:cont, {:ok, Map.put(acc, id, normalized)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_findings(_findings, _perspectives, _review_cycle), do: {:error, :invalid_findings}

  defp validate_stored_finding(id, finding, perspectives, review_cycle)
       when is_binary(id) and is_map(finding) do
    required = [
      "id",
      "issue_key",
      "owner",
      "origin_cycle",
      "severity",
      "state",
      "blocks_merge",
      "title",
      "required_action",
      "anchor"
    ]

    with true <- Enum.all?(required, &Map.has_key?(finding, &1)),
         true <- Enum.all?(Map.keys(finding), &(&1 in (required ++ ["evidence"]))),
         :ok <- ensure_string_keyed_json(finding),
         true <- finding["id"] == id,
         true <- is_boolean(finding["blocks_merge"]),
         true <- is_integer(finding["origin_cycle"]),
         true <- finding["origin_cycle"] > 0 and finding["origin_cycle"] <= review_cycle,
         true <- finding["state"] in ["fixed" | @active_states],
         true <- finding["severity"] in @severities,
         true <- finding["owner"] in perspectives,
         {:ok, title} <- required_bounded_text(finding, "title", @max_title_bytes),
         {:ok, required_action} <-
           required_bounded_text(finding, "required_action", @max_required_action_bytes),
         {:ok, anchor} <- validate_anchor(finding["anchor"]),
         {:ok, evidence} <- optional_evidence(finding),
         issue_key = issue_key(anchor, title),
         true <- finding["issue_key"] == issue_key,
         true <- finding["id"] == finding_id(finding["owner"], issue_key) do
      normalized = %{
        "id" => finding_id(finding["owner"], issue_key),
        "issue_key" => issue_key,
        "owner" => finding["owner"],
        "origin_cycle" => finding["origin_cycle"],
        "severity" => finding["severity"],
        "state" => finding["state"],
        "blocks_merge" => false,
        "title" => title,
        "required_action" => required_action,
        "anchor" => anchor
      }

      normalized =
        if evidence == nil, do: normalized, else: Map.put(normalized, "evidence", evidence)

      {:ok, normalized}
    else
      _ -> {:error, :invalid_stored_finding}
    end
  end

  defp validate_stored_finding(_id, _finding, _perspectives, _review_cycle),
    do: {:error, :invalid_stored_finding}

  defp validate_cycles(cycles, perspectives, review_cycle) when is_map(cycles) do
    expected_keys =
      if review_cycle == 0, do: [], else: Enum.map(1..review_cycle, &Integer.to_string/1)

    if Enum.sort(Map.keys(cycles)) != Enum.sort(expected_keys) do
      {:error, :invalid_cycles}
    else
      Enum.reduce_while(cycles, {:ok, %{}}, fn {cycle, value}, {:ok, acc} ->
        with {number, ""} <- Integer.parse(cycle),
             true <- number > 0,
             true <- number <= review_cycle,
             true <- is_map(value),
             true <- Enum.sort(Map.keys(value)) == ["reported_owners", "review_cycle", "votes"],
             true <- value["review_cycle"] == number,
             true <- is_map(value["votes"]),
             true <- Enum.sort(Map.keys(value["votes"])) == perspectives,
             true <- is_list(value["reported_owners"]),
             true <- Enum.uniq(value["reported_owners"]) == value["reported_owners"],
             true <- Enum.sort(value["reported_owners"]) == value["reported_owners"],
             true <- Enum.all?(value["reported_owners"], &(&1 in perspectives)),
             true <-
               Enum.all?(perspectives, fn owner ->
                 vote = Map.get(value["votes"], owner)
                 owner in value["reported_owners"] or vote == "abstain"
               end),
             true <-
               Enum.all?(value["votes"], fn {owner, vote} ->
                 owner in perspectives and vote in @votes
               end) do
          {:cont, {:ok, Map.put(acc, cycle, value)}}
        else
          _ -> {:halt, {:error, :invalid_cycles}}
        end
      end)
    end
  end

  defp validate_cycles(_cycles, _perspectives, _review_cycle), do: {:error, :invalid_cycles}

  defp validate_out_of_scope(out_of_scope, perspectives, review_cycle)
       when is_list(out_of_scope) and length(out_of_scope) <= @max_out_of_scope do
    result =
      Enum.reduce_while(out_of_scope, {:ok, []}, fn record, {:ok, acc} ->
        case validate_out_of_scope_record(record, perspectives, review_cycle) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with {:ok, records} <- result,
         records <- Enum.sort_by(records, & &1["id"]),
         ids = Enum.map(records, & &1["id"]),
         true <- ids == Enum.uniq(ids) do
      {:ok, records}
    else
      _ -> {:error, :invalid_out_of_scope}
    end
  end

  defp validate_out_of_scope(_out_of_scope, _perspectives, _review_cycle),
    do: {:error, :invalid_out_of_scope}

  defp validate_out_of_scope_record(record, perspectives, review_cycle) when is_map(record) do
    required = [
      "id",
      "issue_key",
      "owner",
      "origin_cycle",
      "severity",
      "state",
      "title",
      "required_action",
      "anchor",
      "reason"
    ]

    with true <- Enum.all?(required, &Map.has_key?(record, &1)),
         true <- Enum.all?(Map.keys(record), &(&1 in (required ++ ["evidence"]))),
         :ok <- ensure_string_keyed_json(record),
         true <- record["state"] == "out_of_scope",
         true <- record["reason"] == "outside_delta",
         true <- record["owner"] in perspectives,
         true <- record["severity"] in @severities,
         true <- is_integer(record["origin_cycle"]),
         true <- record["origin_cycle"] > 0 and record["origin_cycle"] <= review_cycle,
         {:ok, title} <- required_bounded_text(record, "title", @max_title_bytes),
         {:ok, required_action} <-
           required_bounded_text(record, "required_action", @max_required_action_bytes),
         {:ok, anchor} <- validate_anchor(record["anchor"]),
         {:ok, evidence} <- optional_evidence(record),
         issue_key = issue_key(anchor, title),
         true <- record["issue_key"] == issue_key,
         id = finding_id(record["owner"], issue_key),
         true <- record["id"] == id do
      normalized = %{
        "id" => id,
        "issue_key" => issue_key,
        "owner" => record["owner"],
        "origin_cycle" => record["origin_cycle"],
        "severity" => record["severity"],
        "state" => "out_of_scope",
        "title" => title,
        "required_action" => required_action,
        "anchor" => anchor,
        "reason" => "outside_delta"
      }

      normalized =
        if evidence == nil, do: normalized, else: Map.put(normalized, "evidence", evidence)

      {:ok, normalized}
    else
      _ -> {:error, :invalid_out_of_scope}
    end
  end

  defp validate_out_of_scope_record(_record, _perspectives, _review_cycle),
    do: {:error, :invalid_out_of_scope}

  defp build_decision(ledger) do
    votes = effective_perspective_votes(ledger)
    vote_counts = Enum.frequencies(Map.values(votes))
    vote_counts = Map.merge(%{"approve" => 0, "reject" => 0, "abstain" => 0}, vote_counts)

    active_findings = ledger["findings"] |> Map.values() |> Enum.filter(&active?/1)
    architectural = Enum.filter(active_findings, &(&1["state"] == "architectural_blocker"))

    blocking =
      Enum.filter(
        active_findings,
        &(&1["blocks_merge"] == true or &1["state"] == "architectural_blocker")
      )

    reported_owners = reported_owners_this_cycle(ledger)

    {confirmed_blocking, unconfirmed_blocking} =
      blocking
      |> Enum.reject(&(&1["state"] == "architectural_blocker"))
      |> Enum.split_with(&MapSet.member?(reported_owners, &1["owner"]))

    security_veto = Map.get(votes, "security") == "reject"
    major_owner_counts = major_issue_owner_counts(ledger)

    reasons =
      blocking
      |> Enum.sort_by(& &1["id"])
      |> Enum.map(fn finding ->
        reason =
          cond do
            finding["state"] == "architectural_blocker" ->
              "architectural_blocker"

            not MapSet.member?(reported_owners, finding["owner"]) ->
              "unconfirmed_blocker"

            true ->
              blocker_reason(finding, major_owner_counts)
          end

        %{"id" => finding["id"], "reason" => reason}
      end)

    reasons =
      if security_veto,
        do: [%{"id" => "security", "reason" => "security_veto"} | reasons],
        else: reasons

    disposition =
      cond do
        security_veto or architectural != [] ->
          "human_review"

        # Owner never reconfirmed this cycle — do not spend another worker rework turn.
        unconfirmed_blocking != [] ->
          "human_review"

        # Explicitly reopened/reconfirmed merge blockers still require worker rework.
        confirmed_blocking != [] ->
          "rework"

        vote_counts["approve"] > vote_counts["reject"] and vote_counts["approve"] > 0 ->
          "accept"

        # True all-abstain / no actionable finding — escalate, do not rework.
        vote_counts["approve"] == 0 and vote_counts["reject"] == 0 ->
          "human_review"

        true ->
          "rework"
      end

    reasons =
      if disposition == "human_review" and reasons == [] do
        [%{"id" => "council", "reason" => "all_abstain"}]
      else
        reasons
      end

    %{
      "disposition" => disposition,
      "security_veto" => security_veto,
      "blocking_ids" => Enum.map(blocking, & &1["id"]) |> Enum.sort(),
      "blocking_reasons" => reasons,
      "vote_counts" => vote_counts
    }
  end

  defp blocker_reason(finding, major_owner_counts) do
    cond do
      finding["severity"] != "major" ->
        "active_blocking"

      Map.get(major_owner_counts, finding["issue_key"], 0) >= 2 ->
        "corroborated_major"

      true ->
        "independent_major_quorum"
    end
  end

  defp reported_owners_this_cycle(ledger) do
    case ledger["review_cycle"] do
      cycle when is_integer(cycle) and cycle > 0 ->
        owners =
          get_in(ledger, ["cycles", Integer.to_string(cycle), "reported_owners"]) || []

        if is_list(owners), do: MapSet.new(owners), else: MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  defp latest_votes(ledger) do
    case ledger["review_cycle"] do
      0 -> Map.new(ledger["perspectives"], &{&1, "abstain"})
      cycle -> Map.get(ledger["cycles"], Integer.to_string(cycle), %{})["votes"] || %{}
    end
  end

  defp effective_perspective_votes(ledger) do
    blocking_owners =
      ledger["findings"]
      |> Map.values()
      |> Enum.filter(&merge_blocking_finding?/1)
      |> Enum.map(& &1["owner"])
      |> MapSet.new()

    latest_votes(ledger)
    |> Map.new(fn {owner, vote} ->
      effective_vote =
        if vote == "reject" and owner != "security" and
             not MapSet.member?(blocking_owners, owner),
           do: "abstain",
           else: vote

      {owner, effective_vote}
    end)
  end

  defp merge_blocking_finding?(finding) do
    active?(finding) and
      (finding["severity"] == "blocking" or
         finding["state"] == "architectural_blocker" or
         finding["blocks_merge"] == true)
  end

  defp fail_closed_decision do
    %{
      "disposition" => "human_review",
      "security_veto" => true,
      "blocking_ids" => [],
      "blocking_reasons" => [%{"id" => "ledger", "reason" => "invalid_ledger"}],
      "vote_counts" => %{"approve" => 0, "reject" => 0, "abstain" => 0}
    }
  end

  defp issue_key(anchor, title) do
    hash_parts([
      @version,
      anchor["path"],
      anchor["side"],
      Integer.to_string(anchor["line"]),
      normalize_title(title)
    ])
  end

  defp finding_id(owner, issue_key), do: hash_parts([@version, owner, issue_key])

  defp hash_parts(parts) do
    parts
    |> Enum.map(fn part -> <<byte_size(part)::32, part::binary>> end)
    |> :erlang.iolist_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp normalize_title(title), do: title |> String.normalize(:nfc) |> String.trim()

  defp ensure_string_keyed_json(value) when is_map(value) and not is_struct(value) do
    if Enum.all?(value, fn {key, nested} -> is_binary(key) and json_clean?(nested) end),
      do: :ok,
      else: {:error, :non_json_clean}
  end

  defp ensure_string_keyed_json(_value), do: {:error, :non_json_clean}

  defp json_clean?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn {key, nested} -> is_binary(key) and json_clean?(nested) end)
  end

  defp json_clean?(value) when is_list(value), do: Enum.all?(value, &json_clean?/1)
  defp json_clean?(value) when is_binary(value), do: String.valid?(value)
  defp json_clean?(value) when is_boolean(value) or is_nil(value) or is_integer(value), do: true

  defp json_clean?(value) when is_float(value),
    do: value == value and value not in [:infinity, :neg_infinity]

  defp json_clean?(_value), do: false

  defp bounded?(value) do
    case Jason.encode(value) do
      {:ok, encoded} when byte_size(encoded) <= @max_encoded_bytes -> :ok
      {:ok, _encoded} -> {:error, :ledger_too_large}
      {:error, _reason} -> {:error, :non_json_clean}
    end
  end

  defp reverse_ok({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_ok(error), do: error

  defp map_values_sorted(map) do
    map
    |> Enum.sort_by(fn {id, _finding} -> id end)
    |> Enum.map(fn {_id, finding} -> finding end)
  end
end
