defmodule Arbor.Orchestrator.CodingPlan.OutcomeMapper do
  @moduledoc """
  Pure, closed mapping from coding pipeline evidence to `TaskOutcome` maps.

  This is the owner of the compatibility terminal vocabulary. It accepts only
  structured evidence and never uses response or failure prose to classify an
  outcome.
  """

  alias Arbor.Contracts.Coding.TaskOutcome

  @terminal_statuses ~w(
    approval_denied
    change_committed
    declined
    human_review_required
    no_changes
    pr_created
    pr_failed
    review_failed
    review_rejected
    review_requires_rework
    rework_exhausted
    validation_capacity_exceeded
    validation_failed
  )

  @terminal_registry %{
    "approval_denied" => %{
      disposition: "rejected",
      phase: "commit",
      origin: "operator",
      retry: "none"
    },
    "change_committed" => %{
      disposition: "succeeded",
      phase: "commit",
      origin: "arbor",
      retry: "none"
    },
    "declined" => %{disposition: "rejected", phase: "control", origin: "operator", retry: "none"},
    "human_review_required" => %{
      disposition: "requires_input",
      phase: "review",
      origin: "reviewer",
      retry: "none"
    },
    "no_changes" => %{
      disposition: "succeeded",
      phase: "worker_turn",
      origin: "worker",
      retry: "none"
    },
    "pr_created" => %{disposition: "succeeded", phase: "adoption", origin: "arbor", retry: "none"},
    "pr_failed" => %{
      disposition: "failed",
      phase: "adoption",
      origin: "arbor",
      retry: "after_external_change"
    },
    "review_failed" => %{
      disposition: "failed",
      phase: "review",
      origin: "reviewer",
      retry: "after_external_change"
    },
    "review_rejected" => %{
      disposition: "rejected",
      phase: "review",
      origin: "reviewer",
      retry: "none"
    },
    "review_requires_rework" => %{
      disposition: "requires_input",
      phase: "review",
      origin: "reviewer",
      retry: "same_session"
    },
    "rework_exhausted" => %{
      disposition: "failed",
      phase: "review",
      origin: "runtime",
      retry: "new_session"
    },
    "validation_capacity_exceeded" => %{
      disposition: "requires_input",
      phase: "validation",
      origin: "validator",
      retry: "after_external_change"
    },
    "validation_failed" => %{
      disposition: "failed",
      phase: "validation",
      origin: "validator",
      retry: "same_session"
    }
  }

  @pipeline_error_codes ~w(
    pipeline_error
    committed_change_materialization_failed
    council_review_failed
    draft_pr_failed
    review_tier_invalid_or_missing
    worker_provider_account_exhausted
    worker_provider_session_id_missing
    worker_recovery_continuity_invalid
    worker_recovery_reopen_failed
    worker_recovery_send_failed
    worker_recovery_summary_failed
    worker_send_recovery_exhausted
    worker_stale_close_failed
    worker_stop_reason_not_end_turn
    worker_turn_no_progress
    workspace_missing
  )

  @pipeline_registry %{
    "pipeline_error" => %{
      disposition: "failed",
      phase: "control",
      origin: "runtime",
      retry: "new_session"
    },
    "committed_change_materialization_failed" => %{
      disposition: "failed",
      phase: "review",
      origin: "arbor",
      retry: "after_external_change"
    },
    "council_review_failed" => %{
      disposition: "failed",
      phase: "review",
      origin: "reviewer",
      retry: "after_external_change"
    },
    "draft_pr_failed" => %{
      disposition: "failed",
      phase: "adoption",
      origin: "arbor",
      retry: "after_external_change"
    },
    "review_tier_invalid_or_missing" => %{
      disposition: "failed",
      phase: "review",
      origin: "reviewer",
      retry: "after_external_change"
    },
    "worker_provider_account_exhausted" => %{
      disposition: "failed",
      phase: "worker_turn",
      origin: "provider",
      retry: "new_session"
    },
    "worker_provider_session_id_missing" => %{
      disposition: "failed",
      phase: "worker_start",
      origin: "acp_transport",
      retry: "new_session"
    },
    "worker_recovery_continuity_invalid" => %{
      disposition: "failed",
      phase: "worker_turn",
      origin: "runtime",
      retry: "new_session"
    },
    "worker_recovery_reopen_failed" => %{
      disposition: "failed",
      phase: "worker_start",
      origin: "acp_transport",
      retry: "new_session"
    },
    "worker_recovery_send_failed" => %{
      disposition: "failed",
      phase: "worker_turn",
      origin: "acp_transport",
      retry: "new_session"
    },
    "worker_recovery_summary_failed" => %{
      disposition: "failed",
      phase: "worker_turn",
      origin: "worker",
      retry: "new_session"
    },
    "worker_send_recovery_exhausted" => %{
      disposition: "failed",
      phase: "worker_turn",
      origin: "runtime",
      retry: "new_session"
    },
    "worker_stale_close_failed" => %{
      disposition: "failed",
      phase: "cleanup",
      origin: "acp_transport",
      retry: "new_session"
    },
    "worker_stop_reason_not_end_turn" => %{
      disposition: "failed",
      phase: "worker_turn",
      origin: "acp_transport",
      retry: "new_session"
    },
    "worker_turn_no_progress" => %{
      disposition: "failed",
      phase: "worker_turn",
      origin: "worker",
      retry: "same_session"
    },
    "workspace_missing" => %{
      disposition: "failed",
      phase: "workspace",
      origin: "arbor",
      retry: "after_external_change"
    }
  }

  @special_registry %{
    "invalid_terminal_evidence" => %{
      disposition: "failed",
      phase: "control",
      origin: "runtime",
      retry: "none"
    },
    "worker_model_mismatch" => %{
      disposition: "failed",
      phase: "worker_start",
      origin: "provider",
      retry: "new_session"
    }
  }

  @registered_codes Map.keys(
                      Map.merge(
                        Map.merge(@terminal_registry, @pipeline_registry),
                        @special_registry
                      )
                    )

  @doc "Return the compatibility terminal statuses in registry order."
  @spec terminal_statuses() :: [String.t()]
  def terminal_statuses, do: @terminal_statuses

  @doc "Return all stable pipeline-error codes emitted by the coding graph."
  @spec pipeline_error_codes() :: [String.t()]
  def pipeline_error_codes, do: @pipeline_error_codes

  @doc "Return the closed stable code registry."
  @spec registered_codes() :: [String.t()]
  def registered_codes, do: Enum.sort(@registered_codes)

  @spec terminal_status?(term()) :: boolean()
  def terminal_status?(status), do: is_binary(status) and status in @terminal_statuses

  @spec pipeline_error_code?(term()) :: boolean()
  def pipeline_error_code?(code), do: is_binary(code) and code in @pipeline_error_codes

  @doc "Map a compatibility terminal using trusted structured ACP evidence."
  @spec map_terminal(term(), map(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def map_terminal(status, evidence, opts \\ []) do
    with {:ok, spec} <- fetch_spec(@terminal_registry, status),
         {:ok, facts} <- trusted_facts(evidence, opts) do
      case reject_provider_exhaustion(facts) do
        {:error, :provider_account_exhausted} ->
          map_pipeline_error("worker_provider_account_exhausted", evidence, opts)

        :ok ->
          with :ok <- completed_turn?(facts) do
            spec
            |> maybe_model_mismatch(facts)
            |> outcome(facts)
          else
            _ -> {:error, invalid_terminal_evidence(evidence, opts)}
          end
      end
    else
      {:error, _reason} -> {:error, invalid_terminal_evidence(evidence, opts)}
      _ -> {:error, invalid_terminal_evidence(evidence, opts)}
    end
  end

  @doc "Map a registered pipeline error; unknown codes fail closed."
  @spec map_pipeline_error(term(), map(), keyword() | map()) :: {:ok, map()}
  def map_pipeline_error(error_code, evidence, opts \\ []) do
    code = structured_error_code(error_code, evidence)

    with {:ok, facts} <- trusted_facts(evidence, opts),
         {:ok, spec} <- Map.fetch(@pipeline_registry, code) do
      outcome(Map.put(spec, :code, code), facts)
    else
      _ -> {:ok, invalid_terminal_evidence(evidence, opts)}
    end
  end

  @doc "Validate the exact canonical TaskOutcome map."
  @spec normalize(term()) :: {:ok, map()} | {:error, term()}
  def normalize(outcome) when is_map(outcome) and not is_struct(outcome) do
    with true <- Enum.all?(Map.keys(outcome), &is_binary/1),
         {:ok, typed} <- TaskOutcome.new(outcome),
         true <- typed.code in @registered_codes,
         canonical = TaskOutcome.to_map(typed),
         true <- canonical == outcome do
      {:ok, canonical}
    else
      _ -> {:error, :invalid_terminal_evidence}
    end
  end

  def normalize(_outcome), do: {:error, :invalid_terminal_evidence}

  @spec valid?(term()) :: boolean()
  def valid?(outcome), do: match?({:ok, _}, normalize(outcome))

  @doc "Validate that an outcome is compatible with the canonical terminal status."
  @spec compatible_with_status?(term(), term()) :: boolean()
  def compatible_with_status?(outcome, status) do
    with {:ok, normalized} <- normalize(outcome),
         true <- terminal_status?(status),
         :ok <- compatible_fields(normalized, status) do
      true
    else
      _ -> false
    end
  end

  @doc "Build the bounded fail-closed outcome used when evidence is unusable."
  @spec invalid_terminal_evidence(map(), keyword() | map()) :: map()
  def invalid_terminal_evidence(evidence, opts \\ []) do
    facts = trusted_facts_or_empty(evidence, opts)

    {:ok, mapped} = outcome(Map.fetch!(@special_registry, "invalid_terminal_evidence"), facts)
    mapped
  end

  defp fetch_spec(registry, status) when is_binary(status) do
    case Map.fetch(registry, status) do
      {:ok, spec} -> {:ok, Map.put(spec, :code, status)}
      :error -> {:error, :unknown_terminal}
    end
  end

  defp fetch_spec(_registry, _status), do: {:error, :unknown_terminal}

  defp outcome(spec, facts) do
    attrs = %{
      version: TaskOutcome.schema_version(),
      disposition: spec.disposition,
      code: Map.get(spec, :code, "invalid_terminal_evidence"),
      phase: spec.phase,
      origin: spec.origin,
      retry: spec.retry
    }

    attrs
    |> Map.merge(facts)
    |> TaskOutcome.new()
    |> case do
      {:ok, typed} -> {:ok, TaskOutcome.to_map(typed)}
      _ -> {:ok, TaskOutcome.to_map(invalid_typed_outcome())}
    end
  end

  defp invalid_typed_outcome do
    {:ok, typed} =
      TaskOutcome.new(%{
        version: TaskOutcome.schema_version(),
        disposition: "failed",
        code: "invalid_terminal_evidence",
        phase: "control",
        origin: "runtime",
        retry: "none"
      })

    typed
  end

  defp maybe_model_mismatch(spec, facts) do
    if is_binary(facts[:requested_model]) and is_binary(facts[:confirmed_model]) and
         facts.requested_model != facts.confirmed_model do
      Map.fetch!(@special_registry, "worker_model_mismatch")
      |> Map.put(:code, "worker_model_mismatch")
    else
      spec
    end
  end

  defp completed_turn?(facts) do
    if facts[:delivery_state] == "delivered" and facts[:completion_state] == "end_turn",
      do: :ok,
      else: {:error, :incomplete_turn}
  end

  defp reject_provider_exhaustion(%{delivery_state: "provider_account_exhausted"}),
    do: {:error, :provider_account_exhausted}

  defp reject_provider_exhaustion(_facts), do: :ok

  defp trusted_facts_or_empty(evidence, opts) do
    case trusted_facts(evidence, opts) do
      {:ok, facts} -> facts
      _ -> %{}
    end
  end

  defp trusted_facts(evidence, opts) when is_map(evidence) do
    with {:ok, delivery_state} <- optional_delivery_state(evidence),
         {:ok, completion_state} <- optional_completion_state(evidence),
         {:ok, worker_session_id} <-
           optional_string(evidence, [
             "worker_session_id",
             "worker.worker_session_id",
             "worker_status.worker_session_id"
           ]),
         {:ok, provider_session_id} <-
           optional_string(evidence, [
             "worker_provider_session_id",
             "worker_msg.session_id",
             "worker.session_id",
             "worker_status.session_id"
           ]),
         {:ok, provider} <-
           optional_string(evidence, ["worker.provider", "worker_status.provider"]),
         {:ok, confirmed_model} <-
           optional_string(evidence, ["worker_status.model", "worker.model"]),
         {:ok, requested_model} <- optional_option(opts, :requested_model),
         {:ok, configured_provider} <- optional_option(opts, :worker_provider) do
      {:ok,
       %{}
       |> maybe_put_fact(:delivery_state, delivery_state)
       |> maybe_put_fact(:completion_state, completion_state)
       |> maybe_put_fact(:worker_session_id, worker_session_id)
       |> maybe_put_fact(:provider_session_id, provider_session_id)
       |> maybe_put_fact(:provider, configured_provider || provider)
       |> maybe_put_fact(:requested_model, requested_model)
       |> maybe_put_fact(:confirmed_model, confirmed_model)}
    end
  end

  defp trusted_facts(_evidence, _opts), do: {:error, :malformed_evidence}

  defp optional_option(opts, key) do
    value = option_get(opts, key)

    cond do
      is_nil(value) -> {:ok, nil}
      is_binary(value) and String.trim(value) != "" -> {:ok, value}
      true -> {:error, :malformed_option}
    end
  end

  defp optional_string(map, keys) do
    case Enum.find_value(keys, fn key -> lookup(map, key) end) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, blank_to_nil(value)}
      _ -> {:error, :malformed_evidence}
    end
  end

  defp optional_delivery_state(evidence) do
    with {:ok, value} <- optional_string(evidence, ["worker_msg.delivery_status"]),
         true <- is_nil(value) or value in TaskOutcome.delivery_states() do
      {:ok, value}
    else
      _ -> {:error, :malformed_evidence}
    end
  end

  defp optional_completion_state(evidence) do
    with {:ok, value} <- optional_string(evidence, ["worker_msg.stop_reason"]) do
      if value in TaskOutcome.completion_states(), do: {:ok, value}, else: {:ok, nil}
    end
  end

  defp blank_to_nil(value), do: if(String.trim(value) == "", do: nil, else: value)

  defp maybe_put_fact(map, _key, nil), do: map
  defp maybe_put_fact(map, key, value), do: Map.put(map, key, value)

  defp option_get(opts, key) when is_list(opts), do: Keyword.get(opts, key)

  defp option_get(opts, key) when is_map(opts),
    do: Map.get(opts, key) || Map.get(opts, Atom.to_string(key))

  defp option_get(_opts, _key), do: nil

  defp structured_error_code(error_code, evidence) when is_binary(error_code) do
    if error_code in @pipeline_error_codes,
      do: error_code,
      else: structured_error_code(nil, evidence)
  end

  defp structured_error_code(_error_code, evidence) when is_map(evidence) do
    case lookup(evidence, "worker_msg.delivery_status") do
      "provider_account_exhausted" -> "worker_provider_account_exhausted"
      _ -> nil
    end
  end

  defp structured_error_code(_error_code, _evidence), do: nil

  defp lookup(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        case String.split(key, ".") do
          [_] -> atom_key_value(map, key)
          parts -> nested_lookup(map, parts)
        end
    end
  end

  defp lookup(_map, _key), do: nil

  defp nested_lookup(map, [part | rest]) do
    case lookup(map, part) do
      nil -> nil
      value when rest == [] -> value
      value when is_map(value) -> nested_lookup(value, rest)
      _ -> nil
    end
  end

  defp nested_lookup(_map, _parts), do: nil

  defp atom_key_value(map, key) do
    Enum.find_value(map, fn
      {atom, value} when is_atom(atom) ->
        if Atom.to_string(atom) == key, do: value

      _ ->
        nil
    end)
  end

  defp compatible_fields(%{"code" => "worker_model_mismatch"} = outcome, _status) do
    if outcome["disposition"] == "failed" and outcome["phase"] == "worker_start" and
         outcome["origin"] == "provider" and outcome["retry"] == "new_session" and
         is_binary(outcome["requested_model"]) and is_binary(outcome["confirmed_model"]) and
         outcome["requested_model"] != outcome["confirmed_model"],
       do: :ok,
       else: {:error, :inconsistent_outcome}
  end

  defp compatible_fields(%{"code" => code} = outcome, status) when code == status do
    spec = Map.fetch!(@terminal_registry, status)

    if outcome["disposition"] == spec.disposition and outcome["phase"] == spec.phase and
         outcome["origin"] == spec.origin and outcome["retry"] == spec.retry,
       do: :ok,
       else: {:error, :inconsistent_outcome}
  end

  defp compatible_fields(_outcome, _status), do: {:error, :inconsistent_outcome}
end
