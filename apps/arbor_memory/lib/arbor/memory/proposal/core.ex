defmodule Arbor.Memory.Proposal.Core do
  @moduledoc false

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Memory.MutationAdmission.Lease
  alias Arbor.Memory.SelfKnowledge

  @max_pending 20
  @content_similarity_threshold 0.6
  @acceptance_boost 0.2
  @max_identifier_bytes 256
  @max_content_bytes 65_536
  @max_evidence_items 256
  @max_evidence_item_bytes 4_096
  @max_metadata_entries 256
  @max_metadata_bytes 65_536
  @max_source_bytes 256
  @max_reject_reason_bytes 1_024
  @max_reject_opts 4
  @max_list_limit 10_000
  @max_list_opts 8
  @max_agent_entries 512
  @max_total_entries 10_000
  @max_total_bytes 4_000_000
  @lease_token_bytes 32
  @allowed_list_opt_keys [:type, :limit, :sort_by]
  @allowed_reject_opt_keys [:reason]
  @allowed_sort_by [:created_at, :confidence]

  @allowed_types [
    :fact,
    :insight,
    :learning,
    :pattern,
    :preconscious,
    :goal,
    :goal_update,
    :thought,
    :concern,
    :curiosity,
    :identity,
    :intent,
    :cognitive_mode
  ]

  @type provenance_status :: :verified | :legacy_unlabeled | :invalid_durable_provenance

  @spec allowed_types() :: [atom()]
  def allowed_types, do: @allowed_types

  @spec max_pending() :: pos_integer()
  def max_pending, do: @max_pending

  @spec limits() :: map()
  def limits do
    %{
      max_pending: @max_pending,
      max_identifier_bytes: @max_identifier_bytes,
      max_content_bytes: @max_content_bytes,
      max_evidence_items: @max_evidence_items,
      max_evidence_item_bytes: @max_evidence_item_bytes,
      max_metadata_entries: @max_metadata_entries,
      max_metadata_bytes: @max_metadata_bytes,
      max_reject_reason_bytes: @max_reject_reason_bytes,
      max_reject_opts: @max_reject_opts,
      max_list_limit: @max_list_limit,
      max_agent_entries: @max_agent_entries,
      max_total_entries: @max_total_entries,
      max_total_bytes: @max_total_bytes
    }
  end

  @spec valid_identifier?(term()) :: boolean()
  def valid_identifier?(id) when is_binary(id) do
    byte_size(id) > 0 and byte_size(id) <= @max_identifier_bytes
  end

  def valid_identifier?(_), do: false

  @spec valid_owner_lease?(term(), term()) :: boolean()
  def valid_owner_lease?(
        %Lease{token: token, agent_id: agent_id, admitted_gate_gen: generation},
        expected_agent_id
      )
      when is_binary(token) and byte_size(token) == @lease_token_bytes and
             is_integer(generation) and generation > 0 and agent_id == expected_agent_id do
    valid_identifier?(agent_id) and String.valid?(agent_id) and String.trim(agent_id) == agent_id
  end

  def valid_owner_lease?(_lease, _expected_agent_id), do: false

  @spec validate_create(String.t(), atom(), map()) ::
          {:ok, map()} | {:error, atom() | {atom(), term()}}
  def validate_create(agent_id, type, data)
      when is_binary(agent_id) and is_atom(type) and is_map(data) do
    with true <- valid_identifier?(agent_id),
         true <- type in @allowed_types,
         {:ok, content} <- validate_content(data),
         {:ok, confidence} <- validate_confidence(Map.get(data, :confidence, 0.5)),
         {:ok, source} <- validate_source(Map.get(data, :source)),
         {:ok, evidence} <- validate_evidence(Map.get(data, :evidence, [])),
         {:ok, metadata} <- validate_metadata(Map.get(data, :metadata, %{})) do
      {:ok,
       %{
         content: content,
         confidence: confidence,
         source: source,
         evidence: evidence,
         metadata: metadata
       }}
    else
      false when type not in @allowed_types ->
        {:error, {:invalid_type, type, @allowed_types}}

      false ->
        {:error, :invalid_request}

      {:error, _} = error ->
        error
    end
  end

  def validate_create(_agent_id, type, _data) when is_atom(type) and type not in @allowed_types do
    {:error, {:invalid_type, type, @allowed_types}}
  end

  def validate_create(_agent_id, _type, _data), do: {:error, :invalid_request}

  @doc "Validate list_pending opts before any owner traversal."
  @spec validate_list_opts(term()) ::
          {:ok, keyword()} | {:error, :invalid_request | :limit_exceeded}
  def validate_list_opts(opts) when is_list(opts) do
    with :ok <- bounded_keyword_opts(opts, 0),
         :ok <- validate_list_opt_keys(opts),
         {:ok, type} <- validate_list_type(Keyword.get(opts, :type)),
         {:ok, limit} <- validate_list_limit(Keyword.get(opts, :limit)),
         {:ok, sort_by} <- validate_list_sort_by(Keyword.get(opts, :sort_by, :created_at)) do
      cleaned =
        []
        |> then(fn acc -> if type, do: [{:type, type} | acc], else: acc end)
        |> then(fn acc -> if limit != nil, do: [{:limit, limit} | acc], else: acc end)
        |> then(fn acc -> [{:sort_by, sort_by} | acc] end)
        |> Enum.reverse()

      {:ok, cleaned}
    end
  end

  def validate_list_opts(_), do: {:error, :invalid_request}

  @doc """
  Validate reject opts as a bounded atom-key keyword list allowing only `:reason`.

  Never call `Keyword` APIs on untrusted/mixed-key lists — validate shape first.
  """
  @spec validate_reject_opts(term()) ::
          {:ok, String.t() | nil} | {:error, :invalid_request | :limit_exceeded}
  def validate_reject_opts(opts) when is_list(opts) do
    with :ok <- bound_reject_keyword_length(opts, 0),
         {:ok, reason} <- extract_reject_reason(opts, :absent) do
      validate_reject_reason(reason)
    end
  end

  def validate_reject_opts(_), do: {:error, :invalid_request}

  @doc "Validate optional reject reason before review mutation."
  @spec validate_reject_reason(term()) :: {:ok, String.t() | nil} | {:error, atom()}
  def validate_reject_reason(nil), do: {:ok, nil}

  def validate_reject_reason(reason) when is_binary(reason) do
    if byte_size(reason) <= @max_reject_reason_bytes,
      do: {:ok, reason},
      else: {:error, :limit_exceeded}
  end

  def validate_reject_reason(_), do: {:error, :invalid_request}

  # Length bound first so attacker-sized keyword lists fail closed without full walks.
  defp bound_reject_keyword_length([], n) when n <= @max_reject_opts, do: :ok

  defp bound_reject_keyword_length([{key, _value} | rest], n)
       when is_atom(key) and n < @max_reject_opts do
    bound_reject_keyword_length(rest, n + 1)
  end

  defp bound_reject_keyword_length([{key, _value} | _rest], n)
       when is_atom(key) and n >= @max_reject_opts,
       do: {:error, :limit_exceeded}

  defp bound_reject_keyword_length(_malformed, _n), do: {:error, :invalid_request}

  # Only :reason is admitted; walk is already length-bounded above.
  defp extract_reject_reason([], :absent), do: {:ok, nil}
  defp extract_reject_reason([], {:present, reason}), do: {:ok, reason}

  defp extract_reject_reason([{key, value} | rest], seen) when is_atom(key) do
    cond do
      key not in @allowed_reject_opt_keys ->
        {:error, :invalid_request}

      key == :reason and seen == :absent ->
        extract_reject_reason(rest, {:present, value})

      key == :reason ->
        {:error, :invalid_request}

      true ->
        extract_reject_reason(rest, seen)
    end
  end

  defp extract_reject_reason(_malformed, _seen), do: {:error, :invalid_request}

  @spec build_proposal(String.t(), atom(), map(), String.t(), DateTime.t()) :: map()
  def build_proposal(agent_id, type, fields, id, %DateTime{} = created_at) do
    %{
      id: id,
      agent_id: agent_id,
      type: type,
      content: fields.content,
      confidence: fields.confidence,
      source: fields.source,
      evidence: fields.evidence,
      metadata: fields.metadata,
      created_at: created_at,
      status: :pending
    }
  end

  @spec canonicalize_payload(map()) :: map()
  def canonicalize_payload(proposal) when is_map(proposal) do
    %{
      "id" => Map.fetch!(proposal, :id),
      "agent_id" => Map.fetch!(proposal, :agent_id),
      "type" => Atom.to_string(Map.fetch!(proposal, :type)),
      "content" => Map.fetch!(proposal, :content),
      "confidence" => Map.fetch!(proposal, :confidence),
      "source" => Map.get(proposal, :source),
      "evidence" => Map.get(proposal, :evidence, []),
      "metadata" => stringify_keys(Map.get(proposal, :metadata, %{})),
      "created_at" => datetime_to_iso(Map.get(proposal, :created_at)),
      "status" => Atom.to_string(Map.fetch!(proposal, :status))
    }
  end

  @spec worst_status(provenance_status(), provenance_status()) :: provenance_status()
  def worst_status(left, right) do
    if status_rank(left) >= status_rank(right), do: left, else: right
  end

  @spec join_taint(term(), term()) :: {:ok, Taint.t()} | {:error, atom()}
  def join_taint(left, right), do: Taint.join(left, right)

  @spec find_duplicate([map()], atom(), String.t()) ::
          {:duplicate, map()} | :no_duplicate
  def find_duplicate(candidates, type, content) when is_list(candidates) do
    same_type =
      Enum.filter(candidates, fn p ->
        Map.get(p, :type) == type and Map.get(p, :status) in [:pending, :deferred]
      end)

    content_lower = String.downcase(content)

    case Enum.find(same_type, fn p -> String.downcase(p.content) == content_lower end) do
      nil -> fuzzy_match(content, same_type)
      match -> {:duplicate, match}
    end
  end

  @spec boost_confidence(map()) :: map()
  def boost_confidence(proposal) when is_map(proposal) do
    Map.update!(proposal, :confidence, fn c -> min(1.0, c + 0.05) end)
  end

  @spec select_prune_ids([map()], non_neg_integer()) :: [String.t()]
  def select_prune_ids(pending, max_pending \\ @max_pending) do
    overflow = length(pending) - max_pending + 1

    if overflow > 0 do
      pending
      |> Enum.sort_by(fn p -> {p.confidence, p.created_at} end, :asc)
      |> Enum.take(overflow)
      |> Enum.map(& &1.id)
    else
      []
    end
  end

  @spec sort_and_filter([map()], keyword()) :: [map()]
  def sort_and_filter(proposals, opts) when is_list(proposals) and is_list(opts) do
    case validate_list_opts(opts) do
      {:ok, clean} -> do_sort_and_filter(proposals, clean)
      {:error, _} -> []
    end
  end

  defp do_sort_and_filter(proposals, opts) do
    type_filter = Keyword.get(opts, :type)
    limit = Keyword.get(opts, :limit)
    sort_by = Keyword.get(opts, :sort_by, :created_at)

    proposals
    |> Enum.filter(&(&1.status == :pending))
    |> then(fn list ->
      if type_filter, do: Enum.filter(list, &(&1.type == type_filter)), else: list
    end)
    |> sort_proposals(sort_by)
    |> then(fn list ->
      if is_integer(limit) and limit >= 0, do: Enum.take(list, limit), else: list
    end)
  end

  @spec validate_transition(map(), atom()) :: :ok | {:error, {atom(), atom(), atom()}}
  def validate_transition(%{status: status}, expected) when status == expected, do: :ok

  def validate_transition(%{status: status}, expected),
    do: {:error, {:invalid_status, status, expected}}

  @spec apply_reject(map(), term()) :: map()
  def apply_reject(proposal, reason) do
    metadata =
      if reason == nil,
        do: proposal.metadata,
        else: Map.put(proposal.metadata, :rejection_reason, reason)

    %{proposal | status: :rejected, metadata: metadata}
  end

  @spec apply_defer(map(), DateTime.t()) :: map()
  def apply_defer(proposal, %DateTime{} = now) do
    count = Map.get(proposal.metadata, :deferred_count, 0) + 1

    %{
      proposal
      | status: :deferred,
        metadata:
          Map.merge(proposal.metadata, %{
            deferred_at: now,
            deferred_count: count
          })
    }
  end

  @spec apply_undefer(map()) :: map()
  def apply_undefer(proposal), do: %{proposal | status: :pending}

  @spec apply_accept(map()) :: map()
  def apply_accept(proposal), do: %{proposal | status: :accepted}

  @spec transfer_plan(map()) ::
          {:goal, map()}
          | {:goal_update, map()}
          | {:intent, map()}
          | {:knowledge, map()}
  def transfer_plan(%{type: :goal} = proposal) do
    goal_data = Map.get(proposal.metadata, :goal_data, %{})
    priority = Map.get(goal_data, "priority") || Map.get(goal_data, :priority) || :medium

    {:goal,
     %{
       description: proposal.content,
       priority: priority,
       goal_data: goal_data
     }}
  end

  def transfer_plan(%{type: :goal_update} = proposal) do
    update_data = Map.get(proposal.metadata, :update_data, %{})
    goal_id = Map.get(update_data, "id") || Map.get(update_data, :id)
    progress = Map.get(update_data, "progress") || Map.get(update_data, :progress)

    {:goal_update, %{goal_id: goal_id, progress: progress}}
  end

  def transfer_plan(%{type: :intent} = proposal) do
    decomp = Map.get(proposal.metadata, :decomposition, %{})

    {:intent,
     %{
       capability: Map.get(decomp, "capability") || Map.get(decomp, :capability) || "unknown",
       op: Map.get(decomp, "op") || Map.get(decomp, :op) || "unknown",
       target: Map.get(decomp, "target") || Map.get(decomp, :target),
       description: proposal.content
     }}
  end

  def transfer_plan(proposal) do
    boosted = min(1.0, proposal.confidence + @acceptance_boost)

    {:knowledge,
     %{
       type: node_type_for(proposal.type),
       content: proposal.content,
       relevance: boosted,
       metadata: %{
         "proposal_id" => proposal.id,
         "original_confidence" => proposal.confidence
       },
       skip_dedup: true
     }}
  end

  @spec fence_ids(map()) :: %{operation_id: String.t(), domain_id: String.t()}
  def fence_ids(%{id: proposal_id, type: type}) do
    compact = compact_id(proposal_id)

    domain_id =
      case type do
        :goal -> "goal_prop_" <> compact
        :goal_update -> compact
        :intent -> "int_prop_" <> compact
        _ -> "prop_xfer_" <> proposal_id
      end

    %{
      operation_id: "prop_xfer_" <> proposal_id,
      domain_id: domain_id
    }
  end

  @spec validate_transfer_plan(term()) :: {:ok, {atom(), map()}} | {:error, atom()}
  def validate_transfer_plan(proposal) when is_map(proposal) and not is_struct(proposal) do
    with {:ok, type} <- bounded_proposal_type(Map.get(proposal, :type)),
         {:ok, id} <- bounded_identifier(Map.get(proposal, :id)),
         {:ok, content} <- bounded_binary(Map.get(proposal, :content), @max_content_bytes),
         {:ok, confidence} <- bounded_confidence(Map.get(proposal, :confidence, 0.5)),
         {:ok, metadata} <- bounded_metadata(Map.get(proposal, :metadata, %{})) do
      case type do
        :goal ->
          bounded_goal_plan(content, metadata)

        :goal_update ->
          bounded_goal_update_plan(metadata)

        :intent ->
          bounded_intent_plan(content, metadata)

        _ ->
          bounded_knowledge_plan(type, content, confidence, id)
      end
    end
  end

  def validate_transfer_plan(_), do: {:error, :invalid_request}

  @spec validate_owner_transfer_request(atom(), term()) ::
          {:ok, map()} | {:error, atom()}
  def validate_owner_transfer_request(kind, request)
      when is_atom(kind) and is_map(request) and not is_struct(request) do
    with true <- request[:kind] == kind,
         {:ok, agent_id} <- bounded_identifier(request[:agent_id]),
         {:ok, _proposal_id} <- bounded_identifier(request[:proposal_id]),
         {:ok, _operation_id} <- bounded_identifier(request[:operation_id]),
         true <- is_reference(request[:operation_ref]),
         :ok <- mailbox_taint(request[:joined_taint]),
         :ok <- bounded_deadline(request[:deadline_ms]),
         :ok <- matching_lease(request[:lease], agent_id),
         {:ok, plan} <- validate_owner_plan(kind, request[:plan]) do
      {:ok, Map.put(request, :plan, plan)}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_request}
    end
  end

  def validate_owner_transfer_request(_kind, _request), do: {:error, :invalid_request}

  @spec validate_create_mailbox(term(), term(), term(), term(), term()) ::
          {:ok, map()} | {:error, atom() | {atom(), term()}}
  def validate_create_mailbox(agent_id, type, fields, taint, status) do
    with {:ok, normalized} <- validate_create(agent_id, type, mailbox_create_data(fields)),
         :ok <- require_normalized_create_fields(normalized),
         :ok <- mailbox_status(status),
         :ok <- mailbox_taint(taint) do
      {:ok, normalized}
    end
  end

  @spec validate_review_mailbox(term(), term(), term(), term(), term(), term()) ::
          {:ok, term()} | {:error, :invalid_request | :invalid_provenance | :limit_exceeded}
  def validate_review_mailbox(agent_id, proposal_id, expected, taint, status, review_op) do
    with true <- valid_identifier?(agent_id) and valid_identifier?(proposal_id),
         true <- expected in [:pending, :deferred],
         :ok <- mailbox_status(status),
         :ok <- mailbox_taint(taint),
         {:ok, review_op} <- mailbox_review_op(review_op) do
      {:ok, review_op}
    else
      {:error, _} = error -> error
      false -> {:error, :invalid_request}
      _ -> {:error, :invalid_request}
    end
  end

  @spec validate_delete_mailbox(term(), term()) :: :ok | {:error, :invalid_request}
  def validate_delete_mailbox(agent_id, proposal_id) do
    if valid_identifier?(agent_id) and valid_identifier?(proposal_id),
      do: :ok,
      else: {:error, :invalid_request}
  end

  @spec classify_handoff_ownership(term(), term()) ::
          :release_store_owned_unknown
          | :handed_activate
          | :release_store_owned_pre_handoff
          | :uncertain_unknown
  def classify_handoff_ownership({:ok, _lease}, :ok), do: :release_store_owned_unknown
  def classify_handoff_ownership(:ok, :ok), do: :release_store_owned_unknown
  def classify_handoff_ownership({:ok, _lease}, :not_owner), do: :handed_activate
  def classify_handoff_ownership({:ok, _lease}, {:error, :not_owner}), do: :handed_activate
  def classify_handoff_ownership(:ok, :not_owner), do: :handed_activate
  def classify_handoff_ownership(:ok, {:error, :not_owner}), do: :handed_activate
  def classify_handoff_ownership({:error, _reason}, :ok), do: :release_store_owned_pre_handoff
  def classify_handoff_ownership({:error, _reason}, _assert), do: :uncertain_unknown
  def classify_handoff_ownership(_handoff, :ok), do: :release_store_owned_pre_handoff
  def classify_handoff_ownership(_handoff, _assert), do: :uncertain_unknown

  @spec classify_store_interrupt(atom(), atom()) ::
          :pre_handoff_rollback
          | :pre_handoff_keep_unknown
          | :uncertain_keep_unknown
          | :post_handoff_unknown
  def classify_store_interrupt(:reserving, :new), do: :pre_handoff_rollback
  def classify_store_interrupt(:reserving, :preexisting), do: :pre_handoff_keep_unknown
  def classify_store_interrupt(:handing_off, _origin), do: :uncertain_keep_unknown
  def classify_store_interrupt(:awaiting_result, _origin), do: :post_handoff_unknown
  def classify_store_interrupt(_phase, :preexisting), do: :pre_handoff_keep_unknown
  def classify_store_interrupt(_phase, _origin), do: :uncertain_keep_unknown

  @spec classify_attempt_failure(atom(), atom()) :: :complete | :unknown_keep | :abort
  def classify_attempt_failure(_origin, :receipt), do: :complete
  def classify_attempt_failure(:preexisting, _kind), do: :unknown_keep
  def classify_attempt_failure(:new, :determinate), do: :abort
  def classify_attempt_failure(_origin, _kind), do: :unknown_keep

  @spec failure_kind(term()) :: :unknown | :determinate
  def failure_kind(reason)
      when reason in [:transfer_outcome_unknown, :outcome_unknown, :commit_outcome_unknown],
      do: :unknown

  def failure_kind({:unknown, _reason}), do: :unknown
  def failure_kind(_reason), do: :determinate

  @absent_root_errors [:not_owner, :invalid_lease, :stale_lease, :destroyed]

  @spec classify_root_settle(term()) :: :released | :absent | :transient
  def classify_root_settle(:ok), do: :released
  def classify_root_settle(reason) when reason in @absent_root_errors, do: :absent
  def classify_root_settle({:error, reason}) when reason in @absent_root_errors, do: :absent
  def classify_root_settle({:error, _reason}), do: :transient
  def classify_root_settle(_reason), do: :transient

  @spec unresolved_rearm(term(), integer()) :: :retain | {:rearm, pos_integer()}
  def unresolved_rearm(deadline_ms, now_ms \\ System.monotonic_time(:millisecond))

  def unresolved_rearm(deadline_ms, now_ms)
      when is_integer(deadline_ms) and is_integer(now_ms) do
    remaining = deadline_ms - now_ms
    if remaining > 0, do: {:rearm, remaining}, else: :retain
  end

  def unresolved_rearm(_deadline_ms, _now_ms), do: :retain

  @unresolved_backoffs_ms [50, 150, 400]

  @spec unresolved_backoff(term()) :: {:retry, pos_integer()} | :terminal
  def unresolved_backoff(attempts) when is_integer(attempts) and attempts >= 0 do
    case Enum.at(@unresolved_backoffs_ms, attempts) do
      delay when is_integer(delay) and delay > 0 -> {:retry, delay}
      _ -> :terminal
    end
  end

  def unresolved_backoff(_attempts), do: :terminal

  @spec remember_unresolved_leases(term(), Lease.t()) :: [Lease.t()]
  def remember_unresolved_leases(held, %Lease{} = lease) when is_list(held) do
    if Enum.any?(held, &(&1 == lease)), do: held, else: held ++ [lease]
  end

  def remember_unresolved_leases(_held, %Lease{} = lease), do: [lease]

  @spec valid_owner_plan?(atom(), term()) :: boolean()
  def valid_owner_plan?(kind, plan), do: match?({:ok, _}, validate_owner_plan(kind, plan))

  @spec canonicalize_owner_plan(atom(), term()) :: {:ok, map()} | {:error, atom()}
  def canonicalize_owner_plan(kind, plan), do: validate_owner_plan(kind, plan)

  defp mailbox_status(status)
       when status in [:verified, :legacy_unlabeled, :invalid_durable_provenance],
       do: :ok

  defp mailbox_status(_), do: {:error, :invalid_request}

  defp mailbox_taint(%Taint{}), do: :ok
  defp mailbox_taint(_), do: {:error, :invalid_provenance}

  defp mailbox_review_op({:reject, reason}) do
    case validate_reject_reason(reason) do
      {:ok, cleaned} -> {:ok, {:reject, cleaned}}
      {:error, _} = error -> error
    end
  end

  defp mailbox_review_op(op) when op in [:defer, :undefer], do: {:ok, op}
  defp mailbox_review_op(_), do: {:error, :invalid_request}

  defp mailbox_create_data(fields) when is_map(fields) and not is_struct(fields), do: fields
  defp mailbox_create_data(_fields), do: %{}

  defp require_normalized_create_fields(%{
         content: content,
         confidence: confidence,
         evidence: evidence,
         metadata: metadata
       })
       when is_binary(content) and is_number(confidence) and is_list(evidence) and
              is_map(metadata) do
    :ok
  end

  defp require_normalized_create_fields(_), do: {:error, :invalid_request}

  defp bounded_proposal_type(type) when type in @allowed_types, do: {:ok, type}
  defp bounded_proposal_type(_), do: {:error, :invalid_request}

  defp bounded_identifier(id) do
    if valid_identifier?(id), do: {:ok, id}, else: {:error, :invalid_request}
  end

  defp bounded_binary(value, max_bytes) when is_binary(value) and is_integer(max_bytes) do
    size = byte_size(value)

    cond do
      size == 0 -> {:error, :invalid_request}
      size > max_bytes -> {:error, :limit_exceeded}
      not String.valid?(value) -> {:error, :invalid_request}
      true -> {:ok, value}
    end
  end

  defp bounded_binary(_value, _max_bytes), do: {:error, :invalid_request}

  defp bounded_optional_binary(nil, _max_bytes), do: {:ok, nil}

  defp bounded_optional_binary(value, max_bytes)
       when is_binary(value) and is_integer(max_bytes) do
    cond do
      byte_size(value) > max_bytes -> {:error, :limit_exceeded}
      not String.valid?(value) -> {:error, :invalid_request}
      true -> {:ok, value}
    end
  end

  defp bounded_optional_binary(_value, _max_bytes), do: {:error, :invalid_request}

  defp bounded_confidence(c) when is_float(c) and c >= 0.0 and c <= 1.0, do: {:ok, c}
  defp bounded_confidence(c) when is_integer(c) and c >= 0 and c <= 1, do: {:ok, c * 1.0}
  defp bounded_confidence(_), do: {:error, :invalid_request}

  defp bounded_metadata(metadata) when is_map(metadata) and not is_struct(metadata) do
    case validate_metadata(metadata) do
      {:ok, _} -> {:ok, metadata}
      {:error, _} = error -> error
    end
  end

  defp bounded_metadata(_), do: {:error, :invalid_request}

  defp bounded_goal_plan(content, metadata) do
    description = String.trim(content)
    goal_data = metadata_entry(metadata, :goal_data)
    priority = if is_map(goal_data), do: metadata_entry(goal_data, :priority), else: nil

    cond do
      description == "" ->
        {:error, :empty_description}

      byte_size(description) > @max_content_bytes ->
        {:error, :limit_exceeded}

      true ->
        case bounded_priority(priority || :medium) do
          {:ok, priority} ->
            {:ok, {:goal, %{description: description, priority: priority}}}

          {:error, _} = error ->
            error
        end
    end
  end

  defp bounded_goal_update_plan(metadata) do
    update_data = metadata_entry(metadata, :update_data)

    with true <- is_map(update_data) and not is_struct(update_data),
         {:ok, goal_id} <- bounded_identifier(metadata_entry(update_data, :id)),
         {:ok, progress} <- bounded_progress(metadata_entry(update_data, :progress)) do
      {:ok, {:goal_update, %{goal_id: goal_id, progress: progress}}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_request}
    end
  end

  defp bounded_intent_plan(content, metadata) do
    decomp = metadata_entry(metadata, :decomposition)
    decomp = if is_map(decomp) and not is_struct(decomp), do: decomp, else: %{}

    with {:ok, capability} <-
           bounded_named_or_default(
             metadata_entry(decomp, :capability),
             @max_source_bytes,
             "unknown"
           ),
         {:ok, op} <- bounded_intent_op(metadata_entry(decomp, :op)),
         {:ok, target} <-
           bounded_optional_binary(metadata_entry(decomp, :target), @max_identifier_bytes) do
      {:ok, {:intent, %{capability: capability, op: op, target: target, description: content}}}
    end
  end

  defp bounded_knowledge_plan(type, content, confidence, id) do
    with {:ok, node_type} <- bounded_knowledge_type(node_type_for(type)),
         {:ok, relevance} <- bounded_progress(min(1.0, confidence + @acceptance_boost)) do
      {:ok,
       {:knowledge,
        %{
          type: node_type,
          content: content,
          relevance: relevance,
          metadata: %{"proposal_id" => id, "original_confidence" => confidence},
          skip_dedup: true
        }}}
    end
  end

  @intent_ops [:read, :write, :exec, :search, :file, :unknown]
  @knowledge_types [:fact, :insight, :skill, :experience, :observation, :trait, :intention, :goal]

  defp bounded_intent_op(nil), do: {:ok, :unknown}
  defp bounded_intent_op(op) when op in @intent_ops, do: {:ok, op}

  defp bounded_intent_op(op) when is_binary(op) do
    case op do
      "read" -> {:ok, :read}
      "write" -> {:ok, :write}
      "exec" -> {:ok, :exec}
      "search" -> {:ok, :search}
      "file" -> {:ok, :file}
      "unknown" -> {:ok, :unknown}
      _ -> {:error, :invalid_request}
    end
  end

  defp bounded_intent_op(_), do: {:error, :invalid_request}

  defp bounded_progress(p) when is_float(p) and p >= 0.0 and p <= 1.0, do: {:ok, p}
  defp bounded_progress(p) when is_integer(p) and p >= 0 and p <= 1, do: {:ok, p * 1.0}
  defp bounded_progress(_), do: {:error, :invalid_request}

  defp bounded_knowledge_type(type) when type in @knowledge_types, do: {:ok, type}
  defp bounded_knowledge_type(_), do: {:error, :invalid_request}

  defp bounded_named_or_default(nil, _max_bytes, default), do: {:ok, default}
  defp bounded_named_or_default(value, max_bytes, _default), do: bounded_binary(value, max_bytes)

  defp bounded_deadline(ms) when is_integer(ms), do: :ok
  defp bounded_deadline(_), do: {:error, :invalid_request}

  defp bounded_priority(p) when p in [:low, :medium, :high, :critical], do: {:ok, p}
  defp bounded_priority("low"), do: {:ok, :low}
  defp bounded_priority("medium"), do: {:ok, :medium}
  defp bounded_priority("high"), do: {:ok, :high}
  defp bounded_priority("critical"), do: {:ok, :critical}
  defp bounded_priority(nil), do: {:ok, :medium}
  defp bounded_priority(_), do: {:error, :invalid_request}

  defp bounded_skip_dedup(true), do: {:ok, true}
  defp bounded_skip_dedup(false), do: {:ok, false}
  defp bounded_skip_dedup(nil), do: {:ok, true}
  defp bounded_skip_dedup(_), do: {:error, :invalid_request}

  defp matching_lease(lease, agent_id) do
    if valid_owner_lease?(lease, agent_id), do: :ok, else: {:error, :invalid_lease}
  end

  defp validate_owner_plan(:create_goal, plan) when is_map(plan) and not is_struct(plan) do
    with {:ok, description} <- bounded_binary(plan[:description], @max_content_bytes),
         description = String.trim(description),
         true <- description != "",
         {:ok, domain_id} <- bounded_identifier(plan[:domain_id]),
         {:ok, priority} <- bounded_priority(Map.get(plan, :priority, :medium)) do
      {:ok,
       %{
         description: description,
         domain_id: domain_id,
         priority: priority
       }}
    else
      false -> {:error, :empty_description}
      {:error, _} = error -> error
      _ -> {:error, :invalid_request}
    end
  end

  defp validate_owner_plan(:update_goal, plan) when is_map(plan) and not is_struct(plan) do
    with {:ok, goal_id} <- bounded_identifier(plan[:goal_id]),
         {:ok, progress} <- bounded_progress(plan[:progress]) do
      {:ok, %{goal_id: goal_id, progress: progress}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_request}
    end
  end

  defp validate_owner_plan(:record_intent, plan) when is_map(plan) and not is_struct(plan) do
    with {:ok, capability} <-
           bounded_named_or_default(plan[:capability], @max_source_bytes, "unknown"),
         {:ok, op} <- bounded_intent_op(plan[:op]),
         {:ok, target} <- bounded_optional_binary(plan[:target], @max_identifier_bytes),
         {:ok, description} <- bounded_binary(plan[:description], @max_content_bytes),
         {:ok, domain_id} <- bounded_identifier(plan[:domain_id]) do
      {:ok,
       %{
         capability: capability,
         op: op,
         target: target,
         description: description,
         domain_id: domain_id
       }}
    end
  end

  defp validate_owner_plan(:create_knowledge, plan) when is_map(plan) and not is_struct(plan) do
    with {:ok, content} <- bounded_binary(plan[:content], @max_content_bytes),
         {:ok, type} <- bounded_knowledge_type(plan[:type]),
         {:ok, relevance} <- bounded_progress(plan[:relevance]),
         {:ok, metadata} <- bounded_metadata(Map.get(plan, :metadata, %{})),
         {:ok, skip_dedup} <- bounded_skip_dedup(Map.get(plan, :skip_dedup, true)) do
      {:ok,
       %{
         type: type,
         content: content,
         relevance: relevance,
         metadata: metadata,
         skip_dedup: skip_dedup
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_request}
    end
  end

  defp validate_owner_plan(_kind, _plan), do: {:error, :invalid_request}

  defp metadata_entry(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp metadata_entry(_map, _key), do: nil

  @spec reinforce_op_id(String.t(), atom(), String.t()) :: String.t()
  def reinforce_op_id(agent_id, type, content) do
    digest =
      :crypto.hash(:sha256, [agent_id, Atom.to_string(type), content])
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "prop_rein_" <> digest
  end

  @spec find_similar_node(map() | nil, atom(), String.t()) ::
          {:duplicate, String.t()} | :new
  def find_similar_node(nil, _type, _content), do: :new

  def find_similar_node(graph, type, content) when is_map(graph) do
    node_type = node_type_for(type)
    nodes = Map.get(graph, :nodes) || %{}

    similar =
      nodes
      |> Map.values()
      |> Enum.find(fn node ->
        Map.get(node, :type) == node_type and
          SelfKnowledge.text_similarity(content, Map.get(node, :content, "")) >=
            @content_similarity_threshold
      end)

    case similar do
      nil -> :new
      node -> {:duplicate, Map.get(node, :id)}
    end
  end

  @spec node_type_for(atom()) :: atom()
  def node_type_for(:fact), do: :fact
  def node_type_for(:insight), do: :insight
  def node_type_for(:learning), do: :skill
  def node_type_for(:pattern), do: :experience
  def node_type_for(:preconscious), do: :experience
  def node_type_for(:goal), do: :goal
  def node_type_for(:goal_update), do: :goal
  def node_type_for(:thought), do: :observation
  def node_type_for(:concern), do: :observation
  def node_type_for(:curiosity), do: :observation
  def node_type_for(:identity), do: :trait
  def node_type_for(:intent), do: :intention
  def node_type_for(:cognitive_mode), do: :observation
  def node_type_for(_), do: :observation

  @spec estimate_bytes(map()) :: non_neg_integer()
  def estimate_bytes(proposal) when is_map(proposal) do
    proposal
    |> canonicalize_payload()
    |> :erlang.term_to_binary()
    |> byte_size()
  end

  @spec within_total_bounds?(non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          boolean()
  def within_total_bounds?(entries, bytes, additional_bytes) do
    entries + 1 <= @max_total_entries and bytes + additional_bytes <= @max_total_bytes
  end

  @spec within_agent_bounds?(non_neg_integer()) :: boolean()
  def within_agent_bounds?(count), do: count < @max_agent_entries

  @spec stats([map()]) :: map()
  def stats(proposals) when is_list(proposals) do
    by_status = Enum.group_by(proposals, & &1.status)
    by_type = Enum.group_by(proposals, & &1.type)

    %{
      total: length(proposals),
      pending: length(Map.get(by_status, :pending, [])),
      accepted: length(Map.get(by_status, :accepted, [])),
      rejected: length(Map.get(by_status, :rejected, [])),
      deferred: length(Map.get(by_status, :deferred, [])),
      by_type: Map.new(by_type, fn {type, list} -> {type, length(list)} end),
      avg_confidence: avg_confidence(proposals)
    }
  end

  defp validate_content(%{content: content}) when is_binary(content) and content != "" do
    if byte_size(content) <= @max_content_bytes,
      do: {:ok, content},
      else: {:error, :limit_exceeded}
  end

  defp validate_content(%{"content" => content}) when is_binary(content) and content != "" do
    if byte_size(content) <= @max_content_bytes,
      do: {:ok, content},
      else: {:error, :limit_exceeded}
  end

  defp validate_content(_), do: {:error, :missing_content}

  defp validate_confidence(c) when is_float(c) and c >= 0.0 and c <= 1.0, do: {:ok, c}
  defp validate_confidence(c) when is_integer(c) and c >= 0 and c <= 1, do: {:ok, c * 1.0}
  defp validate_confidence(_), do: {:error, :invalid_request}

  defp validate_source(nil), do: {:ok, nil}

  defp validate_source(source) when is_binary(source) do
    if byte_size(source) <= @max_source_bytes, do: {:ok, source}, else: {:error, :limit_exceeded}
  end

  defp validate_source(_), do: {:error, :invalid_request}

  # Bounded traversal — never length/1 on attacker-sized lists.
  defp validate_evidence(list) when is_list(list) do
    validate_evidence_items(list, 0, [])
  end

  defp validate_evidence(_), do: {:error, :invalid_request}

  defp validate_evidence_items([], _count, acc), do: {:ok, Enum.reverse(acc)}

  defp validate_evidence_items([item | rest], count, acc)
       when count < @max_evidence_items and is_binary(item) do
    if byte_size(item) <= @max_evidence_item_bytes do
      validate_evidence_items(rest, count + 1, [item | acc])
    else
      {:error, :limit_exceeded}
    end
  end

  defp validate_evidence_items([_item | _rest], count, _acc)
       when count >= @max_evidence_items,
       do: {:error, :limit_exceeded}

  defp validate_evidence_items([_item | _rest], _count, _acc), do: {:error, :invalid_request}
  defp validate_evidence_items(_improper, _count, _acc), do: {:error, :invalid_request}

  defp validate_metadata(map) when is_map(map) do
    size = map_size(map)

    cond do
      size > @max_metadata_entries ->
        {:error, :limit_exceeded}

      estimate_metadata_bytes(map) > @max_metadata_bytes ->
        {:error, :limit_exceeded}

      true ->
        {:ok, map}
    end
  end

  defp validate_metadata(_), do: {:error, :invalid_request}

  defp estimate_metadata_bytes(map) when is_map(map) do
    map
    |> :erlang.term_to_binary()
    |> byte_size()
  rescue
    _ -> @max_metadata_bytes + 1
  end

  defp bounded_keyword_opts([], _n), do: :ok

  defp bounded_keyword_opts([{key, _value} | rest], n)
       when is_atom(key) and n < @max_list_opts do
    bounded_keyword_opts(rest, n + 1)
  end

  defp bounded_keyword_opts([{_key, _value} | _rest], n) when n >= @max_list_opts,
    do: {:error, :limit_exceeded}

  defp bounded_keyword_opts(_other, _n), do: {:error, :invalid_request}

  defp validate_list_opt_keys(opts) do
    if Enum.all?(opts, fn {k, _} -> k in @allowed_list_opt_keys end),
      do: :ok,
      else: {:error, :invalid_request}
  end

  defp validate_list_type(nil), do: {:ok, nil}
  defp validate_list_type(type) when type in @allowed_types, do: {:ok, type}
  defp validate_list_type(_), do: {:error, :invalid_request}

  defp validate_list_limit(nil), do: {:ok, nil}

  defp validate_list_limit(limit)
       when is_integer(limit) and limit >= 0 and limit <= @max_list_limit,
       do: {:ok, limit}

  defp validate_list_limit(limit) when is_integer(limit) and limit > @max_list_limit,
    do: {:error, :limit_exceeded}

  defp validate_list_limit(_), do: {:error, :invalid_request}

  defp validate_list_sort_by(sort_by) when sort_by in @allowed_sort_by, do: {:ok, sort_by}
  defp validate_list_sort_by(_), do: {:error, :invalid_request}

  defp fuzzy_match(content, candidates) do
    case Enum.find(candidates, fn p ->
           SelfKnowledge.text_similarity(content, p.content) >= @content_similarity_threshold
         end) do
      nil -> :no_duplicate
      match -> {:duplicate, match}
    end
  end

  defp sort_proposals(proposals, :confidence), do: Enum.sort_by(proposals, & &1.confidence, :desc)

  defp sort_proposals(proposals, _) do
    Enum.sort_by(proposals, & &1.created_at, {:desc, DateTime})
  end

  defp status_rank(:invalid_durable_provenance), do: 2
  defp status_rank(:legacy_unlabeled), do: 1
  defp status_rank(:verified), do: 0
  defp status_rank(_), do: 2

  defp compact_id(proposal_id) when is_binary(proposal_id) do
    proposal_id
    |> String.replace_prefix("prop_", "")
    |> then(fn s -> if byte_size(s) > 32, do: binary_part(s, 0, 32), else: s end)
  end

  defp datetime_to_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp datetime_to_iso(_), do: nil

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_value(v)}
      {k, v} when is_binary(k) -> {k, stringify_value(v)}
      {k, v} -> {inspect(k), stringify_value(v)}
    end)
  end

  defp stringify_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp stringify_value(list) when is_list(list), do: Enum.map(list, &stringify_value/1)
  defp stringify_value(map) when is_map(map) and not is_struct(map), do: stringify_keys(map)
  defp stringify_value(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp stringify_value(other), do: other

  defp avg_confidence([]), do: 0.0

  defp avg_confidence(proposals) do
    total = Enum.sum(Enum.map(proposals, & &1.confidence))
    Float.round(total / length(proposals), 3)
  end
end
