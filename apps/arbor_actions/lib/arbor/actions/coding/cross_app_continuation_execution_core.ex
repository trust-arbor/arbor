defmodule Arbor.Actions.Coding.CrossApp.ContinuationExecutionCore do
  @moduledoc """
  Pure, token-free execution envelopes for CrossApp continuation.

  Static receipts are produced before a continuation exists. Claimed windows
  project a fully rehydrated `ContinuationCore` state plus the admitted static
  receipt. Progress construction and admission replay the existing continuation
  transitions with private local fencing, then discard all states and effects.

  All returned values are closed, string-keyed JSON maps. No envelope is an
  authorization credential. This core performs no filesystem, process, clock,
  randomness, Application, Registry, GenServer, or IO operations.
  """

  alias Arbor.Actions.Coding.CrossApp.ContinuationCore

  @schema_version 1
  @max_excerpt_raw_bytes 2_000
  @max_reason_raw_bytes 256
  @max_identifier_raw_bytes 256
  @max_continuation_id_raw_bytes 71
  @max_identities_json_bytes 4_096
  @max_plan_json_bytes 256_000
  @max_receipts_json_bytes 256_000
  @max_handoff_json_bytes 256_000
  @max_window_json_bytes 778_240

  # A JSON string can encode one input byte as six bytes (`\uXXXX`), plus
  # quotes. Envelope ceilings below measure exact fixed syntax and add the
  # already encoded maxima for each variable constituent.
  @max_excerpt_json_bytes 2 + 6 * @max_excerpt_raw_bytes
  @max_reason_json_bytes 2 + 6 * @max_reason_raw_bytes
  @max_identifier_json_bytes 2 + 6 * @max_identifier_raw_bytes
  @max_continuation_id_json_bytes 2 + @max_continuation_id_raw_bytes

  @empty_object_json_bytes byte_size(Jason.encode!(%{}))
  @empty_list_json_bytes byte_size(Jason.encode!([]))
  @empty_string_json_bytes byte_size(Jason.encode!(""))

  @max_check_fixture %{
    "status" => "completed",
    "passed" => true,
    "exit_code" => 0,
    "reason" => nil,
    "stdout_excerpt" => String.duplicate(<<0>>, @max_excerpt_raw_bytes),
    "stderr_excerpt" => String.duplicate(<<0>>, @max_excerpt_raw_bytes),
    "stdout_truncated" => false,
    "stderr_truncated" => false,
    "stdout_sha256" => String.duplicate("0", 64),
    "stderr_sha256" => String.duplicate("0", 64)
  }
  @max_check_json_bytes byte_size(Jason.encode!(@max_check_fixture))

  @static_receipt_fixture %{
    "schema_version" => @schema_version,
    "continuation_id" => "",
    "identities" => %{},
    "checks" => %{"compile" => %{}, "xref" => %{}, "test_compile" => %{}}
  }
  @static_receipt_fixed_json_bytes byte_size(Jason.encode!(@static_receipt_fixture)) -
                                     4 * @empty_object_json_bytes -
                                     @empty_string_json_bytes
  @max_static_receipt_json_bytes @max_identities_json_bytes +
                                   3 * @max_check_json_bytes +
                                   @max_continuation_id_json_bytes +
                                   @static_receipt_fixed_json_bytes

  @capacity_disposition_fixture %{
    "type" => "capacity_handoff",
    "capacity_handoff" => %{}
  }
  @capacity_disposition_fixed_json_bytes byte_size(Jason.encode!(@capacity_disposition_fixture)) -
                                           @empty_object_json_bytes
  @max_capacity_disposition_json_bytes @max_handoff_json_bytes +
                                         @capacity_disposition_fixed_json_bytes

  @failure_disposition_fixture %{"type" => "failed", "reason" => ""}
  @failure_disposition_fixed_json_bytes byte_size(Jason.encode!(@failure_disposition_fixture)) -
                                          @empty_string_json_bytes
  @max_failure_disposition_json_bytes @max_reason_json_bytes +
                                        @failure_disposition_fixed_json_bytes
  @max_completed_disposition_json_bytes byte_size(Jason.encode!(%{"type" => "completed"}))
  @max_disposition_json_bytes max(
                                @max_capacity_disposition_json_bytes,
                                max(
                                  @max_failure_disposition_json_bytes,
                                  @max_completed_disposition_json_bytes
                                )
                              )
  @progress_fixture %{
    "schema_version" => @schema_version,
    "continuation_id" => "xappc_" <> String.duplicate("0", 64),
    "owner_id" => "",
    "fence_generation" => 1_000_000,
    "static_stage_receipt_digest" => String.duplicate("0", 64),
    "new_receipts" => [],
    "disposition" => %{}
  }
  @progress_fixed_json_bytes byte_size(Jason.encode!(@progress_fixture)) -
                               @empty_string_json_bytes - @empty_list_json_bytes -
                               @empty_object_json_bytes
  @max_progress_json_bytes @progress_fixed_json_bytes + @max_identifier_json_bytes +
                             @max_receipts_json_bytes + @max_disposition_json_bytes

  @digest_regex ~r/\A[0-9a-f]{64}\z/
  @continuation_id_regex ~r/\Axappc_[0-9a-f]{64}\z/
  @synthetic_token "local-execution-validation"

  @receipt_keys Enum.sort(~w(schema_version continuation_id identities checks))
  @check_names Enum.sort(~w(compile test_compile xref))
  @check_keys Enum.sort(~w(
    exit_code
    passed
    reason
    status
    stderr_excerpt
    stderr_sha256
    stderr_truncated
    stdout_excerpt
    stdout_sha256
    stdout_truncated
  ))
  @window_keys Enum.sort(~w(
    accepted_receipts
    capacity_handoff
    claimed_at
    continuation_id
    expires_at
    fence_generation
    identities
    owner_id
    per_batch_budget_ms
    planned_batches
    schema_version
    static_stage_receipt_digest
  ))
  @progress_keys Enum.sort(~w(
    continuation_id
    disposition
    fence_generation
    new_receipts
    owner_id
    schema_version
    static_stage_receipt_digest
  ))
  @observation_keys Enum.sort(~w(disposition new_receipts))
  @forbidden_keys MapSet.new(
                    ~w(authority authorization capability credential fence_token secret token)
                  )

  @type envelope :: %{required(String.t()) => term()}
  @type error :: atom()

  @doc "Execution-envelope schema version."
  @spec schema_version() :: 1
  def schema_version, do: @schema_version

  @doc "Raw and encoded constituent ceilings for execution envelopes."
  @spec limits() :: %{required(String.t()) => pos_integer()}
  def limits do
    %{
      "max_excerpt_raw_bytes" => @max_excerpt_raw_bytes,
      "max_excerpt_json_bytes" => @max_excerpt_json_bytes,
      "max_reason_raw_bytes" => @max_reason_raw_bytes,
      "max_reason_json_bytes" => @max_reason_json_bytes,
      "max_identifier_raw_bytes" => @max_identifier_raw_bytes,
      "max_identifier_json_bytes" => @max_identifier_json_bytes,
      "max_continuation_id_raw_bytes" => @max_continuation_id_raw_bytes,
      "max_continuation_id_json_bytes" => @max_continuation_id_json_bytes,
      "max_identities_json_bytes" => @max_identities_json_bytes,
      "max_plan_json_bytes" => @max_plan_json_bytes,
      "max_receipts_json_bytes" => @max_receipts_json_bytes,
      "max_handoff_json_bytes" => @max_handoff_json_bytes,
      "max_check_json_bytes" => @max_check_json_bytes,
      "max_static_receipt_json_bytes" => @max_static_receipt_json_bytes,
      "max_window_json_bytes" => @max_window_json_bytes,
      "max_progress_json_bytes" => @max_progress_json_bytes
    }
  end

  @doc "Construct and digest a static receipt before its continuation exists."
  @spec new_static_stage_receipt(term(), term()) ::
          {:ok, envelope(), String.t()} | {:error, error()}
  def new_static_stage_receipt(identities, checks) do
    with {:ok, identities} <- ContinuationCore.admit_identities(identities),
         {:ok, continuation_id} <- ContinuationCore.lineage_key_for_identities(identities),
         {:ok, checks} <- admit_successful_checks(checks),
         receipt <- build_static_receipt(identities, continuation_id, checks),
         :ok <- reject_forbidden_keys(receipt),
         :ok <-
           bound_json(receipt, @max_static_receipt_json_bytes, :oversized_static_receipt),
         {:ok, digest} <- ContinuationCore.digest(receipt) do
      {:ok, receipt, digest}
    end
  rescue
    _ -> {:error, :malformed_envelope}
  catch
    _, _ -> {:error, :malformed_envelope}
  end

  @doc "Admit an arbitrary static receipt and return its canonical form."
  @spec admit_static_stage_receipt(term()) :: {:ok, envelope()} | {:error, error()}
  def admit_static_stage_receipt(receipt) do
    with :ok <- require_json_object(receipt),
         :ok <- require_exact_keys(receipt, @receipt_keys),
         :ok <- require_schema(receipt["schema_version"]),
         :ok <- reject_forbidden_keys(receipt),
         {:ok, identities} <- ContinuationCore.admit_identities(receipt["identities"]),
         {:ok, continuation_id} <- ContinuationCore.lineage_key_for_identities(identities),
         :ok <- match(receipt["continuation_id"], continuation_id, :lineage_drift),
         {:ok, checks} <- admit_successful_checks(receipt["checks"]),
         canonical <- build_static_receipt(identities, continuation_id, checks),
         :ok <-
           bound_json(canonical, @max_static_receipt_json_bytes, :oversized_static_receipt) do
      {:ok, canonical}
    end
  rescue
    _ -> {:error, :malformed_envelope}
  catch
    _, _ -> {:error, :malformed_envelope}
  end

  @doc "Canonical SHA-256 digest of an admitted static receipt."
  @spec static_receipt_digest(term()) :: {:ok, String.t()} | {:error, error()}
  def static_receipt_digest(receipt) do
    with {:ok, admitted} <- admit_static_stage_receipt(receipt) do
      ContinuationCore.digest(admitted)
    end
  rescue
    _ -> {:error, :malformed_envelope}
  catch
    _, _ -> {:error, :malformed_envelope}
  end

  @doc "Project a token-free execution window from claimed state and static receipt."
  @spec prepare_execution_window(term(), term()) :: {:ok, envelope()} | {:error, error()}
  def prepare_execution_window(state, receipt) do
    with {:ok, admitted_state} <- ContinuationCore.new(state),
         :ok <- require_claimed(admitted_state),
         {:ok, admitted_receipt} <- admit_static_stage_receipt(receipt),
         {:ok, digest} <- ContinuationCore.digest(admitted_receipt),
         :ok <- bind_state_and_receipt(admitted_state, admitted_receipt, digest),
         window <- project_window(admitted_state, admitted_receipt["continuation_id"]),
         :ok <- reject_forbidden_keys(window),
         :ok <- bound_window_constituents(window),
         :ok <- bound_json(window, @max_window_json_bytes, :oversized_execution_window) do
      {:ok, window}
    end
  rescue
    _ -> {:error, :malformed_envelope}
  catch
    _, _ -> {:error, :malformed_envelope}
  end

  @doc "Admit an arbitrary token-free execution window with its static receipt."
  @spec admit_execution_window(term(), term()) :: {:ok, envelope()} | {:error, error()}
  def admit_execution_window(window, receipt) do
    with :ok <- require_json_object(window),
         :ok <- require_exact_keys(window, @window_keys),
         :ok <- require_schema(window["schema_version"]),
         :ok <- reject_forbidden_keys(window),
         :ok <- bound_window_constituents(window),
         :ok <- bound_json(window, @max_window_json_bytes, :oversized_execution_window),
         {:ok, admitted_receipt} <- admit_static_stage_receipt(receipt),
         {:ok, digest} <- ContinuationCore.digest(admitted_receipt),
         :ok <- bind_window_and_receipt(window, admitted_receipt, digest),
         {:ok, state} <- state_from_window(window),
         {:ok, continuation_id} <- ContinuationCore.lineage_key(state),
         :ok <- match(window["continuation_id"], continuation_id, :lineage_drift),
         canonical <- project_window(state, continuation_id),
         :ok <- match(window, canonical, :malformed_envelope) do
      {:ok, canonical}
    end
  rescue
    _ -> {:error, :malformed_envelope}
  catch
    _, _ -> {:error, :malformed_envelope}
  end

  @doc "Construct canonical progress from trusted local observations."
  @spec new_progress(term(), term(), term()) :: {:ok, envelope()} | {:error, error()}
  def new_progress(window, receipt, observations) do
    with {:ok, admitted_window} <- admit_execution_window(window, receipt),
         {:ok, observation} <- admit_observation(observations),
         progress <- build_progress(admitted_window, observation),
         {:ok, canonical} <- do_admit_progress(admitted_window, progress) do
      {:ok, canonical}
    end
  rescue
    _ -> {:error, :malformed_envelope}
  catch
    _, _ -> {:error, :malformed_envelope}
  end

  @doc "Admit arbitrary progress against an admitted window and static receipt."
  @spec admit_progress(term(), term(), term()) :: {:ok, envelope()} | {:error, error()}
  def admit_progress(window, receipt, progress) do
    with {:ok, admitted_window} <- admit_execution_window(window, receipt) do
      do_admit_progress(admitted_window, progress)
    end
  rescue
    _ -> {:error, :malformed_envelope}
  catch
    _, _ -> {:error, :malformed_envelope}
  end

  defp do_admit_progress(window, progress) do
    with :ok <- require_json_object(progress),
         :ok <- require_exact_keys(progress, @progress_keys),
         :ok <- require_schema(progress["schema_version"]),
         :ok <- reject_forbidden_keys(progress),
         :ok <- require_progress_binding(progress, window),
         {:ok, observation} <-
           admit_observation(%{
             "new_receipts" => progress["new_receipts"],
             "disposition" => progress["disposition"]
           }),
         {:ok, canonical_observation} <- replay(window, observation),
         canonical <- build_progress(window, canonical_observation),
         :ok <- bound_json(canonical, @max_progress_json_bytes, :oversized_progress),
         :ok <- reject_forbidden_keys(canonical) do
      {:ok, canonical}
    end
  end

  defp bind_state_and_receipt(state, receipt, digest) do
    with :ok <- match(state["identities"], receipt["identities"], :static_receipt_drift),
         {:ok, continuation_id} <- ContinuationCore.lineage_key(state),
         :ok <- match(continuation_id, receipt["continuation_id"], :lineage_drift),
         :ok <-
           match(state["static_stage_receipt_digest"], digest, :static_receipt_drift) do
      :ok
    end
  end

  defp bind_window_and_receipt(window, receipt, digest) do
    with :ok <- match(window["identities"], receipt["identities"], :static_receipt_drift),
         :ok <- match(window["continuation_id"], receipt["continuation_id"], :lineage_drift),
         :ok <-
           match(window["static_stage_receipt_digest"], digest, :static_receipt_drift) do
      :ok
    end
  end

  defp project_window(state, continuation_id) do
    claim = state["claim"]

    %{
      "schema_version" => @schema_version,
      "continuation_id" => continuation_id,
      "identities" => state["identities"],
      "planned_batches" => state["planned_batches"],
      "accepted_receipts" => state["accepted_receipts"],
      "capacity_handoff" => state["capacity_handoff"],
      "per_batch_budget_ms" => state["per_batch_budget_ms"],
      "static_stage_receipt_digest" => state["static_stage_receipt_digest"],
      "fence_generation" => state["fence_generation"],
      "owner_id" => claim["owner_id"],
      "claimed_at" => claim["claimed_at"],
      "expires_at" => claim["expires_at"]
    }
  end

  defp state_from_window(window) do
    state = %{
      "schema_version" => ContinuationCore.schema_version(),
      "status" => "claimed",
      "identities" => window["identities"],
      "planned_batches" => window["planned_batches"],
      "accepted_receipts" => window["accepted_receipts"],
      "claim" => %{
        "owner_id" => window["owner_id"],
        "fence_token" => @synthetic_token,
        "fence_generation" => window["fence_generation"],
        "claimed_at" => window["claimed_at"],
        "expires_at" => window["expires_at"]
      },
      "fence_generation" => window["fence_generation"],
      "per_batch_budget_ms" => window["per_batch_budget_ms"],
      "static_stage_receipt_digest" => window["static_stage_receipt_digest"],
      "capacity_handoff" => window["capacity_handoff"],
      "terminal_reason" => nil
    }

    ContinuationCore.new(state)
  end

  defp require_claimed(%{"status" => "claimed", "claim" => claim}) when is_map(claim), do: :ok

  defp require_claimed(%{"status" => status}) when status in ~w(failed cancelled completed),
    do: {:error, :terminal_state}

  defp require_claimed(_state), do: {:error, :claim_required}

  defp admit_successful_checks(checks) do
    with :ok <- require_json_object(checks),
         :ok <- require_exact_keys(checks, @check_names),
         {:ok, compile} <- admit_successful_check(checks["compile"]),
         {:ok, xref} <- admit_successful_check(checks["xref"]),
         {:ok, test_compile} <- admit_successful_check(checks["test_compile"]) do
      {:ok,
       %{
         "compile" => compile,
         "xref" => xref,
         "test_compile" => test_compile
       }}
    end
  end

  defp admit_successful_check(check) do
    with :ok <- require_json_object(check),
         :ok <- require_exact_keys(check, @check_keys),
         :ok <- require_success_fields(check),
         {:ok, stdout} <- admit_excerpt(check["stdout_excerpt"]),
         {:ok, stderr} <- admit_excerpt(check["stderr_excerpt"]),
         :ok <- require_boolean(check["stdout_truncated"]),
         :ok <- require_boolean(check["stderr_truncated"]),
         {:ok, stdout_sha} <- admit_hex(check["stdout_sha256"]),
         {:ok, stderr_sha} <- admit_hex(check["stderr_sha256"]),
         canonical <- %{
           "status" => "completed",
           "passed" => true,
           "exit_code" => 0,
           "reason" => nil,
           "stdout_excerpt" => stdout,
           "stderr_excerpt" => stderr,
           "stdout_truncated" => check["stdout_truncated"],
           "stderr_truncated" => check["stderr_truncated"],
           "stdout_sha256" => stdout_sha,
           "stderr_sha256" => stderr_sha
         },
         :ok <- bound_json(canonical, @max_check_json_bytes, :oversized_static_receipt) do
      {:ok, canonical}
    end
  end

  defp require_success_fields(check) do
    if check["status"] === "completed" and check["passed"] === true and
         check["exit_code"] === 0 and is_nil(check["reason"]),
       do: :ok,
       else: {:error, :malformed_envelope}
  end

  defp admit_excerpt(value) when is_binary(value) do
    if String.valid?(value) and byte_size(value) <= @max_excerpt_raw_bytes,
      do: {:ok, value},
      else: {:error, :malformed_envelope}
  end

  defp admit_excerpt(_value), do: {:error, :malformed_envelope}

  defp admit_observation(observation) do
    with :ok <- require_json_object(observation),
         :ok <- require_exact_keys(observation, @observation_keys),
         :ok <- reject_forbidden_keys(observation),
         {:ok, receipts} <- admit_new_receipts(observation["new_receipts"]),
         {:ok, disposition} <- admit_disposition(observation["disposition"]) do
      {:ok, %{"new_receipts" => receipts, "disposition" => disposition}}
    end
  end

  defp admit_new_receipts(receipts) when is_list(receipts) do
    with :ok <- require_json_clean_list(receipts),
         :ok <- bound_json(receipts, @max_receipts_json_bytes, :oversized_progress) do
      {:ok, receipts}
    end
  end

  defp admit_new_receipts(_receipts), do: {:error, :malformed_envelope}

  defp admit_disposition(%{"type" => "completed"} = disposition) do
    with :ok <- require_json_object(disposition),
         :ok <- require_exact_keys(disposition, ~w(type)) do
      {:ok, %{"type" => "completed"}}
    end
  end

  defp admit_disposition(%{"type" => "failed"} = disposition) do
    with :ok <- require_json_object(disposition),
         :ok <- require_exact_keys(disposition, Enum.sort(~w(reason type))),
         {:ok, reason} <- admit_failure_reason(disposition["reason"]) do
      {:ok, %{"type" => "failed", "reason" => reason}}
    end
  end

  defp admit_disposition(%{"type" => "capacity_handoff"} = disposition) do
    with :ok <- require_json_object(disposition),
         :ok <-
           require_exact_keys(disposition, Enum.sort(~w(capacity_handoff type))),
         :ok <- require_json_object(disposition["capacity_handoff"]),
         :ok <-
           bound_json(
             disposition["capacity_handoff"],
             @max_handoff_json_bytes,
             :oversized_progress
           ) do
      {:ok,
       %{
         "type" => "capacity_handoff",
         "capacity_handoff" => disposition["capacity_handoff"]
       }}
    end
  end

  defp admit_disposition(_disposition), do: {:error, :malformed_envelope}

  defp admit_failure_reason(reason) when is_binary(reason) do
    if valid_failure_reason?(reason),
      do: {:ok, reason},
      else: {:error, :malformed_envelope}
  end

  defp admit_failure_reason(_reason), do: {:error, :malformed_envelope}

  defp valid_failure_reason?(reason) do
    byte_size(reason) > 0 and byte_size(reason) <= @max_reason_raw_bytes and
      String.valid?(reason) and printable?(reason) and not String.contains?(reason, <<0>>)
  end

  defp require_progress_binding(progress, window) do
    with :ok <- match(progress["continuation_id"], window["continuation_id"], :lineage_drift),
         :ok <- match(progress["owner_id"], window["owner_id"], :owner_drift),
         :ok <-
           match(
             progress["fence_generation"],
             window["fence_generation"],
             :generation_drift
           ),
         :ok <-
           match(
             progress["static_stage_receipt_digest"],
             window["static_stage_receipt_digest"],
             :static_receipt_drift
           ) do
      :ok
    end
  end

  defp replay(window, observation) do
    with {:ok, state} <- state_from_window(window),
         {:ok, after_receipts} <-
           replay_receipts(
             state,
             observation["new_receipts"],
             window["claimed_at"],
             window["fence_generation"]
           ),
         {:ok, disposition} <-
           replay_disposition(
             after_receipts,
             observation["disposition"],
             window["claimed_at"],
             window["fence_generation"]
           ) do
      {:ok,
       %{
         "new_receipts" =>
           Enum.drop(after_receipts["accepted_receipts"], length(window["accepted_receipts"])),
         "disposition" => disposition
       }}
    end
  end

  defp replay_receipts(state, receipts, now, generation) do
    Enum.reduce_while(receipts, {:ok, state}, fn receipt, {:ok, current} ->
      case ContinuationCore.accept_passed_receipt(
             current,
             fence_input(generation, now, %{"receipt" => receipt})
           ) do
        {:ok, next, _effects} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp replay_disposition(state, %{"type" => "completed"}, now, generation) do
    with {:ok, _next, _effects} <-
           ContinuationCore.complete(state, fence_input(generation, now)) do
      {:ok, %{"type" => "completed"}}
    end
  end

  defp replay_disposition(
         state,
         %{"type" => "failed", "reason" => reason},
         now,
         generation
       ) do
    with {:ok, next, _effects} <-
           ContinuationCore.fail(
             state,
             fence_input(generation, now, %{"reason" => reason})
           ),
         ^reason <- next["terminal_reason"] do
      {:ok, %{"type" => "failed", "reason" => reason}}
    else
      {:error, replay_reason} -> {:error, replay_reason}
      _other -> {:error, :malformed_envelope}
    end
  end

  defp replay_disposition(
         state,
         %{"type" => "capacity_handoff", "capacity_handoff" => handoff},
         now,
         generation
       ) do
    with {:ok, next, _effects} <-
           ContinuationCore.accept_capacity_handoff(
             state,
             fence_input(generation, now, %{"handoff" => handoff})
           ),
         canonical when is_map(canonical) <- next["capacity_handoff"] do
      {:ok, %{"type" => "capacity_handoff", "capacity_handoff" => canonical}}
    else
      {:error, replay_reason} -> {:error, replay_reason}
      _other -> {:error, :malformed_envelope}
    end
  end

  defp fence_input(generation, now, extra \\ %{}) do
    Map.merge(
      %{
        "fence_token" => @synthetic_token,
        "fence_generation" => generation,
        "now" => now
      },
      extra
    )
  end

  defp build_static_receipt(identities, continuation_id, checks) do
    %{
      "schema_version" => @schema_version,
      "continuation_id" => continuation_id,
      "identities" => identities,
      "checks" => checks
    }
  end

  defp build_progress(window, observation) do
    %{
      "schema_version" => @schema_version,
      "continuation_id" => window["continuation_id"],
      "owner_id" => window["owner_id"],
      "fence_generation" => window["fence_generation"],
      "static_stage_receipt_digest" => window["static_stage_receipt_digest"],
      "new_receipts" => observation["new_receipts"],
      "disposition" => observation["disposition"]
    }
  end

  defp bound_window_constituents(window) do
    with :ok <-
           bound_json(
             window["identities"],
             @max_identities_json_bytes,
             :oversized_execution_window
           ),
         :ok <-
           bound_json(
             window["planned_batches"],
             @max_plan_json_bytes,
             :oversized_execution_window
           ),
         :ok <-
           bound_json(
             window["accepted_receipts"],
             @max_receipts_json_bytes,
             :oversized_execution_window
           ),
         :ok <- bound_optional_handoff(window["capacity_handoff"]),
         :ok <- admit_continuation_id(window["continuation_id"]),
         {:ok, _digest} <- admit_hex(window["static_stage_receipt_digest"]) do
      :ok
    end
  end

  defp bound_optional_handoff(nil), do: :ok

  defp bound_optional_handoff(handoff) do
    bound_json(handoff, @max_handoff_json_bytes, :oversized_execution_window)
  end

  defp admit_continuation_id(value) when is_binary(value) do
    if byte_size(value) <= @max_continuation_id_raw_bytes and
         Regex.match?(@continuation_id_regex, value),
       do: :ok,
       else: {:error, :malformed_envelope}
  end

  defp admit_continuation_id(_value), do: {:error, :malformed_envelope}

  defp admit_hex(value) when is_binary(value) do
    if Regex.match?(@digest_regex, value),
      do: {:ok, value},
      else: {:error, :malformed_envelope}
  end

  defp admit_hex(_value), do: {:error, :malformed_envelope}

  defp require_schema(@schema_version), do: :ok
  defp require_schema(_version), do: {:error, :malformed_envelope}

  defp require_boolean(value) when is_boolean(value), do: :ok
  defp require_boolean(_value), do: {:error, :malformed_envelope}

  defp require_json_object(value) when is_map(value) and not is_struct(value) do
    if json_clean?(value), do: :ok, else: {:error, :malformed_envelope}
  end

  defp require_json_object(_value), do: {:error, :malformed_envelope}

  defp require_json_clean_list(list) when is_list(list) do
    if proper_list?(list) and Enum.all?(list, &json_clean?/1),
      do: :ok,
      else: {:error, :malformed_envelope}
  end

  defp require_json_clean_list(_list), do: {:error, :malformed_envelope}

  defp json_clean?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn
      {key, nested} when is_binary(key) -> String.valid?(key) and json_clean?(nested)
      _ -> false
    end)
  end

  defp json_clean?(value) when is_list(value),
    do: proper_list?(value) and Enum.all?(value, &json_clean?/1)

  defp json_clean?(value) when is_binary(value), do: String.valid?(value)

  defp json_clean?(value)
       when is_integer(value) or is_boolean(value) or is_nil(value),
       do: true

  defp json_clean?(_value), do: false

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_tail), do: false

  defp require_exact_keys(map, keys) do
    if Enum.sort(Map.keys(map)) == keys, do: :ok, else: {:error, :malformed_envelope}
  end

  defp reject_forbidden_keys(value) do
    if contains_forbidden_key?(value),
      do: {:error, :malformed_envelope},
      else: :ok
  end

  defp contains_forbidden_key?(value) when is_map(value) and not is_struct(value) do
    Enum.any?(value, fn {key, nested} ->
      forbidden_key?(key) or contains_forbidden_key?(nested)
    end)
  end

  defp contains_forbidden_key?(value) when is_list(value),
    do: Enum.any?(value, &contains_forbidden_key?/1)

  defp contains_forbidden_key?(_value), do: false

  defp forbidden_key?(key) when is_binary(key), do: MapSet.member?(@forbidden_keys, key)
  defp forbidden_key?(_key), do: true

  defp printable?(value) do
    value
    |> String.to_charlist()
    |> Enum.all?(&(&1 >= 0x20 and &1 != 0x7F))
  end

  defp match(left, right, _error) when left === right, do: :ok
  defp match(_left, _right, error), do: {:error, error}

  defp bound_json(value, max, error) do
    case Jason.encode(value) do
      {:ok, encoded} when byte_size(encoded) <= max -> :ok
      {:ok, _encoded} -> {:error, error}
      {:error, _reason} -> {:error, :malformed_envelope}
    end
  end
end
