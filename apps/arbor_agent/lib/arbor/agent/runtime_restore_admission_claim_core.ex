defmodule Arbor.Agent.RuntimeRestoreAdmissionClaimCore do
  @moduledoc """
  Pure CRC core for durable runtime-restore admission claims (Phase 4C C3C1a1).

  No IO, no GenServer, no Process, no time, no randomness. Store shells gather
  facts (including already-minted tokens and wall-clock `at`) and apply CAS.
  Deterministic `:crypto.hash/2` fingerprinting is permitted; CSPRNG is not.

  Settlement authority is derived only from durable claim phase:
  - `not_applied` only from `minted` (durable pre-effect proof)
  - `applied` only with exact bound identity (`intent_id` + `fp_<64hex>`)
  - never caller-selectable handoff flags
  """

  @claim_v 1
  @claim_kind "runtime_restore_admission"

  @claim_keys MapSet.new([
                "v",
                "kind",
                "operation_id",
                "target_agent_id",
                "fence_operation_id",
                "token",
                "intent_id",
                "fingerprint",
                "claim_phase",
                "settlement",
                "created_at_unix_ms",
                "updated_at_unix_ms"
              ])

  @settlement_keys MapSet.new(["outcome", "reason_code", "at_unix_ms"])
  @phases ["minted", "bound", "outcome_unknown", "settled"]
  @outcomes ["applied", "not_applied", "failed", "conflict"]

  @max_operation_id_bytes 128
  @max_agent_id_bytes 256
  @max_reason_bytes 64
  @token_bytes 26
  @intent_id_bytes 26
  @fingerprint_bytes 67
  @max_json_safe_integer 9_007_199_254_740_991

  @operation_id_re ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @agent_id_re ~r/\Aagent_[A-Za-z0-9_-]+\z/
  @token_re ~r/\Arrt_[A-Za-z0-9_-]{22}\z/
  @intent_id_re ~r/\Arai_[A-Za-z0-9_-]{22}\z/
  @fingerprint_re ~r/\Afp_[0-9a-f]{64}\z/
  @reason_code_re ~r/\A[a-z][a-z0-9_]*\z/

  @type claim :: %{optional(String.t()) => term()}
  @type settlement :: %{optional(String.t()) => term()}

  @doc "True when a non-null claim map is present."
  @spec claim_present?(term()) :: boolean()
  def claim_present?(claim) when is_map(claim) and not is_struct(claim), do: true
  def claim_present?(_), do: false

  @doc "Admit a claim map or null. Unknown versions/keys/shapes fail closed."
  @spec admit_claim(term()) :: {:ok, nil | claim()} | {:error, :invalid_claim}
  def admit_claim(nil), do: {:ok, nil}

  def admit_claim(claim) when is_map(claim) and not is_struct(claim) do
    with {:ok, claim} <- normalize_string_keys(claim),
         :ok <- exact_keyset(claim, @claim_keys),
         :ok <- require_version_kind(claim),
         :ok <- validate_ids(claim),
         :ok <- validate_phase_shape(claim),
         :ok <- validate_times(claim) do
      {:ok, claim}
    else
      _ -> {:error, :invalid_claim}
    end
  end

  def admit_claim(_), do: {:error, :invalid_claim}

  @doc "Mint a fresh minted claim bound to operation identity."
  @spec mint(map(), String.t()) :: {:ok, claim()} | {:error, atom()}
  def mint(facts, token)
      when is_map(facts) and is_binary(token) do
    with {:ok, operation_id} <-
           require_id(facts, "operation_id", @max_operation_id_bytes, @operation_id_re),
         {:ok, target} <- require_id(facts, "target_agent_id", @max_agent_id_bytes, @agent_id_re),
         :ok <- valid_token(token),
         {:ok, at} <- require_time(facts, "at_unix_ms") do
      {:ok,
       %{
         "v" => @claim_v,
         "kind" => @claim_kind,
         "operation_id" => operation_id,
         "target_agent_id" => target,
         "fence_operation_id" => operation_id,
         "token" => token,
         "intent_id" => nil,
         "fingerprint" => nil,
         "claim_phase" => "minted",
         "settlement" => nil,
         "created_at_unix_ms" => at,
         "updated_at_unix_ms" => at
       }}
    else
      {:error, _} = err -> err
      _ -> {:error, :invalid_claim}
    end
  end

  def mint(_, _), do: {:error, :invalid_claim}

  @doc "Store-owned fingerprint for a bound claim identity."
  @spec fingerprint(String.t(), String.t(), String.t(), String.t(), String.t()) :: String.t()
  def fingerprint(operation_id, target, fence_operation_id, token, intent_id)
      when is_binary(operation_id) and is_binary(target) and is_binary(fence_operation_id) and
             is_binary(token) and is_binary(intent_id) do
    material =
      :erlang.term_to_binary(
        {
          "guarded_restore",
          1,
          operation_id,
          target,
          fence_operation_id,
          token,
          intent_id
        },
        [:deterministic]
      )

    "fp_" <> Base.encode16(:crypto.hash(:sha256, material), case: :lower)
  end

  @doc """
  Bind intent_id + fingerprint onto a minted claim (or idempotent exact bound).

  Transition table: bind accepts **minted** or exact already-**bound** only.
  `outcome_unknown` is never bind-success (not release permission); returns
  `{:error, :restore_phase_illegal}` without mutation.
  """
  @spec bind_intent(claim(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, claim()} | {:error, atom()}
  def bind_intent(claim, intent_id, fingerprint, at)
      when is_map(claim) and is_binary(intent_id) and is_binary(fingerprint) and is_integer(at) do
    with :ok <- valid_intent_id(intent_id),
         :ok <- valid_fingerprint(fingerprint),
         true <- at >= 0 and at <= @max_json_safe_integer do
      case claim do
        %{
          "claim_phase" => "minted",
          "intent_id" => nil,
          "fingerprint" => nil,
          "settlement" => nil,
          "token" => token
        } = c
        when is_binary(token) ->
          expected =
            fingerprint(
              c["operation_id"],
              c["target_agent_id"],
              c["fence_operation_id"],
              token,
              intent_id
            )

          if fingerprint == expected do
            {:ok,
             c
             |> Map.put("intent_id", intent_id)
             |> Map.put("fingerprint", fingerprint)
             |> Map.put("claim_phase", "bound")
             |> Map.put("updated_at_unix_ms", at)}
          else
            {:error, :stale_claim}
          end

        # Exact already-bound only — never outcome_unknown (not a bind successor).
        %{
          "claim_phase" => "bound",
          "intent_id" => ^intent_id,
          "fingerprint" => ^fingerprint,
          "settlement" => nil
        } = c ->
          {:ok, c}

        %{"claim_phase" => "outcome_unknown"} ->
          {:error, :restore_phase_illegal}

        %{"claim_phase" => "settled"} ->
          {:error, :claim_settled}

        _ ->
          {:error, :stale_claim}
      end
    else
      _ -> {:error, :invalid_claim}
    end
  end

  def bind_intent(_, _, _, _), do: {:error, :invalid_claim}

  @doc "Mark bound claim outcome_unknown (idempotent)."
  @spec mark_outcome_unknown(claim(), non_neg_integer()) ::
          {:ok, claim()} | {:error, atom()}
  def mark_outcome_unknown(
        %{"claim_phase" => "bound", "intent_id" => id, "fingerprint" => fp, "settlement" => nil} =
          claim,
        at
      )
      when is_binary(id) and is_binary(fp) and is_integer(at) and at >= 0 and
             at <= @max_json_safe_integer do
    with :ok <- valid_intent_id(id),
         :ok <- valid_fingerprint(fp) do
      {:ok,
       claim
       |> Map.put("claim_phase", "outcome_unknown")
       |> Map.put("updated_at_unix_ms", at)}
    else
      _ -> {:error, :invalid_claim}
    end
  end

  def mark_outcome_unknown(
        %{
          "claim_phase" => "outcome_unknown",
          "settlement" => nil,
          "intent_id" => id,
          "fingerprint" => fp
        } =
          claim,
        _at
      )
      when is_binary(id) and is_binary(fp) do
    with :ok <- valid_intent_id(id),
         :ok <- valid_fingerprint(fp) do
      {:ok, claim}
    else
      _ -> {:error, :invalid_claim}
    end
  end

  def mark_outcome_unknown(%{"claim_phase" => "minted"}, _), do: {:error, :restore_phase_illegal}
  def mark_outcome_unknown(%{"claim_phase" => "settled"}, _), do: {:error, :claim_settled}
  def mark_outcome_unknown(_, _), do: {:error, :stale_claim}

  @doc """
  Settle a claim. First settlement wins.

  Authority is derived only from durable claim phase (no caller handoff flags):
  - `applied` requires exact bound identity (never from `minted`)
  - `not_applied` only from `minted` (durable pre-effect proof)
  - `failed`/`conflict` allowed from minted (nil identity) or bound identity
  - `not_applied` illegal from `bound` / `outcome_unknown`

  Settlement admission order (load-bearing):
  1. Fully admit the **requested** settlement (exact keyset, no atom/string
     duplicate aliases, closed outcome/reason/at grammar).
  2. Already-settled claims: re-admit existing settled shape, then compare the
     fully admitted requested settlement's `outcome`+`reason_code` to the
     existing terminal. Same terminal preserves the first record/`at_unix_ms`;
     different terminal is `:already_settled`. Transition legality is **not**
     applied to phase `"settled"`.
  3. Non-settled phases only: apply `settlement_allowed?/2` transition legality,
     then CAS the new settled shape.

  Idempotency (accepted table): retrying the **same** `outcome` + `reason_code`
  accepts the first settlement record (including its `at_unix_ms`) as the exact
  logical successor. A different terminal is `:already_settled`.
  """
  @spec settle(claim(), settlement()) :: {:ok, claim()} | {:error, atom()}
  def settle(claim, settlement)
      when is_map(claim) and is_map(settlement) do
    # Always admit the request first — rejects malformed/extra/duplicate keys
    # before any phase branching (including already-settled retries).
    case admit_settlement(settlement) do
      {:ok, admitted_settlement} ->
        settle_admitted(claim, admitted_settlement)

      {:error, _} = err ->
        err
    end
  end

  def settle(_, _), do: {:error, :invalid_claim}

  # Already-settled: re-admit the **full claim** + compare admitted terminals.
  # Transition legality (`settlement_allowed?/2`) applies only to non-settled.
  defp settle_admitted(
         %{"claim_phase" => "settled", "settlement" => existing} = claim,
         admitted_settlement
       )
       when is_map(existing) do
    # Full claim admit (keys/version/ids/times/phase shape) — not phase-shape only.
    # Malformed settled rows (including invalid UTF-8 identity) → :invalid_claim,
    # never raise.
    case admit_claim(claim) do
      {:ok, admitted_claim} when is_map(admitted_claim) ->
        existing_terminal = admitted_claim["settlement"]

        if is_map(existing_terminal) and
             settlement_same_terminal?(existing_terminal, admitted_settlement) do
          # Keep first timestamp/record — retry is exact logical successor.
          {:ok, admitted_claim}
        else
          {:error, :already_settled}
        end

      {:ok, nil} ->
        {:error, :invalid_claim}

      {:error, _} ->
        {:error, :invalid_claim}
    end
  end

  defp settle_admitted(
         %{"claim_phase" => phase, "settlement" => nil} = claim,
         admitted_settlement
       )
       when phase in ["minted", "bound", "outcome_unknown"] do
    case settlement_allowed?(claim, admitted_settlement) do
      :ok ->
        at = admitted_settlement["at_unix_ms"]

        next =
          claim
          |> Map.put("claim_phase", "settled")
          |> Map.put("settlement", admitted_settlement)
          |> Map.put("updated_at_unix_ms", at)

        # Fail closed if the resulting settled shape is incomplete/illegal.
        case admit_claim(next) do
          {:ok, admitted} -> {:ok, admitted}
          {:error, _} -> {:error, :invalid_claim}
        end

      {:error, _} = err ->
        err
    end
  end

  defp settle_admitted(_, _), do: {:error, :stale_claim}

  @doc """
  True when two settlements are the same logical terminal (`outcome`+`reason_code`).

  Timestamps are ignored so retries with a later `at_unix_ms` remain idempotent.
  """
  @spec settlement_same_terminal?(term(), term()) :: boolean()
  def settlement_same_terminal?(a, b) when is_map(a) and is_map(b) do
    a_out = Map.get(a, "outcome") || Map.get(a, :outcome)
    b_out = Map.get(b, "outcome") || Map.get(b, :outcome)
    a_reason = Map.get(a, "reason_code") || Map.get(a, :reason_code)
    b_reason = Map.get(b, "reason_code") || Map.get(b, :reason_code)

    is_binary(a_out) and a_out == b_out and is_binary(a_reason) and a_reason == b_reason
  end

  def settlement_same_terminal?(_, _), do: false

  @doc "True when claim may be cleared (settled only)."
  @spec clear_precondition?(claim() | nil) :: boolean()
  def clear_precondition?(%{"claim_phase" => "settled", "settlement" => s}) when is_map(s),
    do: true

  def clear_precondition?(_), do: false

  # Token minting is an imperative-shell fact (randomness). The store/shell
  # generates tokens and injects them into `mint/2`. This core stays pure:
  # deterministic admit/bind/settle/fingerprint only (no CSPRNG calls here).

  # ---------------------------------------------------------------------------
  # Internal validation
  # ---------------------------------------------------------------------------

  defp settlement_allowed?(
         %{"claim_phase" => phase, "intent_id" => intent_id, "fingerprint" => fingerprint},
         %{"outcome" => outcome}
       ) do
    cond do
      # applied never from minted; requires exact bound identity on the claim.
      outcome == "applied" and phase == "minted" ->
        {:error, :restore_phase_illegal}

      outcome == "applied" and phase in ["bound", "outcome_unknown"] ->
        case {valid_intent_id(intent_id), valid_fingerprint(fingerprint)} do
          {:ok, :ok} -> :ok
          _ -> {:error, :restore_phase_illegal}
        end

      outcome == "applied" ->
        {:error, :restore_phase_illegal}

      # Durable pre-effect proof only: minted (no intent bind). Bound cannot
      # prove pre-handoff; outcome_unknown is post-handoff indeterminate.
      outcome == "not_applied" and phase == "minted" and is_nil(intent_id) and
          is_nil(fingerprint) ->
        :ok

      outcome == "not_applied" ->
        {:error, :restore_phase_illegal}

      # failed/conflict: minted (nil identity) or exact bound identity.
      outcome in ["failed", "conflict"] and phase == "minted" and is_nil(intent_id) and
          is_nil(fingerprint) ->
        :ok

      outcome in ["failed", "conflict"] and phase in ["bound", "outcome_unknown"] ->
        case {valid_intent_id(intent_id), valid_fingerprint(fingerprint)} do
          {:ok, :ok} -> :ok
          _ -> {:error, :invalid_claim}
        end

      true ->
        {:error, :restore_phase_illegal}
    end
  end

  defp settlement_allowed?(_, _), do: {:error, :invalid_claim}

  defp admit_settlement(settlement) when is_map(settlement) do
    with {:ok, settlement} <- normalize_string_keys(settlement),
         :ok <- exact_keyset(settlement, @settlement_keys),
         outcome when is_binary(outcome) <- Map.get(settlement, "outcome"),
         true <- outcome in @outcomes,
         reason when is_binary(reason) <- Map.get(settlement, "reason_code"),
         # UTF-8 + byte bounds before Regex (invalid binary must not raise).
         true <- String.valid?(reason),
         true <- byte_size(reason) > 0 and byte_size(reason) <= @max_reason_bytes,
         true <- Regex.match?(@reason_code_re, reason),
         at when is_integer(at) <- Map.get(settlement, "at_unix_ms"),
         true <- at >= 0 and at <= @max_json_safe_integer do
      {:ok, settlement}
    else
      _ -> {:error, :invalid_claim}
    end
  end

  defp admit_settlement(_), do: {:error, :invalid_claim}

  defp require_version_kind(%{"v" => @claim_v, "kind" => @claim_kind}), do: :ok
  defp require_version_kind(_), do: :error

  defp validate_ids(claim) do
    with true <- valid_id?(claim["operation_id"], @max_operation_id_bytes, @operation_id_re),
         true <- valid_id?(claim["target_agent_id"], @max_agent_id_bytes, @agent_id_re),
         true <- claim["fence_operation_id"] == claim["operation_id"],
         :ok <- valid_token(claim["token"]) do
      :ok
    else
      _ -> :error
    end
  end

  # minted: identity fields must be present keys with nil values; no settlement.
  defp validate_phase_shape(%{
         "claim_phase" => "minted",
         "intent_id" => nil,
         "fingerprint" => nil,
         "settlement" => nil
       }),
       do: :ok

  # bound / outcome_unknown: exact intent + fp_<64hex>; no settlement.
  defp validate_phase_shape(%{
         "claim_phase" => phase,
         "intent_id" => intent_id,
         "fingerprint" => fingerprint,
         "settlement" => nil
       })
       when phase in ["bound", "outcome_unknown"] do
    with :ok <- valid_intent_id(intent_id),
         :ok <- valid_fingerprint(fingerprint) do
      :ok
    else
      _ -> :error
    end
  end

  # settled: settlement required; intent/fingerprint shape depends on outcome.
  defp validate_phase_shape(%{
         "claim_phase" => "settled",
         "intent_id" => intent_id,
         "fingerprint" => fingerprint,
         "settlement" => settlement
       })
       when is_map(settlement) do
    with {:ok, settlement} <- admit_settlement(settlement),
         :ok <- settled_identity_shape(settlement["outcome"], intent_id, fingerprint) do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_phase_shape(%{"claim_phase" => phase}) when phase in @phases, do: :error
  defp validate_phase_shape(_), do: :error

  # applied: exact bound identity required (never nil).
  defp settled_identity_shape("applied", intent_id, fingerprint) do
    with :ok <- valid_intent_id(intent_id),
         :ok <- valid_fingerprint(fingerprint) do
      :ok
    else
      _ -> :error
    end
  end

  # not_applied: only pre-effect mint origin (both nil).
  defp settled_identity_shape("not_applied", nil, nil), do: :ok
  defp settled_identity_shape("not_applied", _, _), do: :error

  # failed/conflict: either mint origin (nil/nil) or exact bound identity.
  defp settled_identity_shape(outcome, nil, nil) when outcome in ["failed", "conflict"], do: :ok

  defp settled_identity_shape(outcome, intent_id, fingerprint)
       when outcome in ["failed", "conflict"] do
    with :ok <- valid_intent_id(intent_id),
         :ok <- valid_fingerprint(fingerprint) do
      :ok
    else
      _ -> :error
    end
  end

  defp settled_identity_shape(_, _, _), do: :error

  defp validate_times(%{"created_at_unix_ms" => c, "updated_at_unix_ms" => u})
       when is_integer(c) and is_integer(u) and c >= 0 and u >= 0 and c <= @max_json_safe_integer and
              u <= @max_json_safe_integer and u >= c,
       do: :ok

  defp validate_times(_), do: :error

  defp require_id(map, key, max, re) do
    case Map.get(map, key) do
      id when is_binary(id) ->
        if valid_id?(id, max, re), do: {:ok, id}, else: {:error, :invalid_claim}

      _ ->
        {:error, :invalid_claim}
    end
  end

  defp require_time(map, key) do
    case Map.get(map, key) do
      t when is_integer(t) and t >= 0 and t <= @max_json_safe_integer -> {:ok, t}
      _ -> {:error, :invalid_claim}
    end
  end

  # UTF-8 + byte bounds before Regex — invalid binaries (e.g. <<255>>) must
  # return false / :error, never raise.
  defp valid_id?(id, max, re)
       when is_binary(id) and is_integer(max) and is_struct(re, Regex) do
    byte_size(id) > 0 and byte_size(id) <= max and String.valid?(id) and Regex.match?(re, id)
  end

  defp valid_id?(_, _, _), do: false

  defp valid_token(token) when is_binary(token) do
    if byte_size(token) == @token_bytes and String.valid?(token) and
         Regex.match?(@token_re, token) do
      :ok
    else
      :error
    end
  end

  defp valid_token(_), do: :error

  defp valid_intent_id(id) when is_binary(id) do
    if byte_size(id) == @intent_id_bytes and String.valid?(id) and Regex.match?(@intent_id_re, id) do
      :ok
    else
      :error
    end
  end

  defp valid_intent_id(_), do: :error

  defp valid_fingerprint(fp) when is_binary(fp) do
    if byte_size(fp) == @fingerprint_bytes and String.valid?(fp) and
         Regex.match?(@fingerprint_re, fp) do
      :ok
    else
      :error
    end
  end

  defp valid_fingerprint(_), do: :error

  # Exact closed keyset: every required key present, no extras.
  defp exact_keyset(map, allowed) when is_map(map) do
    keys = map |> Map.keys() |> MapSet.new()
    if MapSet.equal?(keys, allowed), do: :ok, else: :error
  end

  defp normalize_string_keys(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn
      {k, v}, {:ok, acc} when is_binary(k) ->
        if Map.has_key?(acc, k) do
          {:halt, :error}
        else
          {:cont, {:ok, Map.put(acc, k, v)}}
        end

      {k, v}, {:ok, acc} when is_atom(k) and not is_nil(k) ->
        sk = Atom.to_string(k)

        if Map.has_key?(acc, sk) do
          {:halt, :error}
        else
          {:cont, {:ok, Map.put(acc, sk, v)}}
        end

      _, _ ->
        {:halt, :error}
    end)
  end
end
