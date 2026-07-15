defmodule Arbor.Orchestrator.Engine.EffectOwner do
  @moduledoc false

  # Pure same-library helpers for Engine effect-owner ordering.
  # No side effects, no IO, no process/global state, no wall clock or RNG.
  # Callers inject random bytes and ISO8601 timestamps.

  alias Arbor.Orchestrator.Engine.Outcome

  @journaled_classes MapSet.new([:idempotent_with_key, :side_effecting])
  # Bounded opaque execution id: "exec_" + 32 lower-hex chars (16 random bytes).
  @execution_id_bytes 16
  @outcome_status_atoms MapSet.new([
                          :success,
                          :partial_success,
                          :retry,
                          :fail,
                          :skipped
                        ])

  @type receipt_error ::
          :invalid_outcome_status
          | :invalid_completed_at

  @doc "True when the handler idempotency class must use the effect owner protocol."
  @spec journaled?(atom()) :: boolean()
  def journaled?(class) when is_atom(class), do: MapSet.member?(@journaled_classes, class)
  def journaled?(_), do: false

  @doc """
  Build a bounded execution_id from caller-supplied random bytes.

  Expects exactly 16 bytes; returns `"exec_"` plus 32 lowercase hex characters.
  """
  @spec fresh_execution_id(binary()) :: String.t()
  def fresh_execution_id(random_bytes)
      when is_binary(random_bytes) and byte_size(random_bytes) == @execution_id_bytes do
    "exec_" <> Base.encode16(random_bytes, case: :lower)
  end

  @doc "Stable string identity for a handler module (no Elixir. prefix)."
  @spec handler_identity(module() | term()) :: String.t()
  def handler_identity(handler) when is_atom(handler) do
    handler
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
  end

  def handler_identity(handler), do: inspect(handler)

  @doc """
  Closed string-keyed prepare attrs for `PipelineStatus.prepare_effect/3`.

  Owner fields (`generation`, `status`, `schema_version`) are assigned by the
  journal; callers must not include them. `started_at` is a caller-supplied
  ISO8601 timestamp string.
  """
  @spec prepare_attrs(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          atom(),
          String.t(),
          String.t()
        ) :: map()
  def prepare_attrs(
        run_id,
        node_id,
        execution_id,
        handler_id,
        idempotency_class,
        input_hash,
        started_at
      )
      when is_binary(run_id) and is_binary(node_id) and is_binary(execution_id) and
             is_binary(handler_id) and is_atom(idempotency_class) and is_binary(input_hash) and
             is_binary(started_at) do
    %{
      "run_id" => run_id,
      "node_id" => node_id,
      "execution_id" => execution_id,
      "handler" => handler_id,
      "input_hash" => input_hash,
      "idempotency_class" => Atom.to_string(idempotency_class),
      "started_at" => started_at
    }
  end

  @doc """
  Closed string-keyed receipt attrs for `PipelineStatus.record_effect_receipt/5`.

  Fails closed on invalid outcome status (does not rewrite to `"fail"`).
  Persists only a digest of the Outcome — never the Outcome, context, or output.
  `completed_at` is a caller-supplied ISO8601 timestamp string.
  """
  @spec receipt_attrs(Outcome.t(), String.t()) :: {:ok, map()} | {:error, receipt_error()}
  def receipt_attrs(%Outcome{} = outcome, completed_at) when is_binary(completed_at) do
    with {:ok, status} <- closed_outcome_status(outcome.status) do
      {:ok,
       %{
         "completed_at" => completed_at,
         "outcome_status" => status,
         "result_digest" => outcome_result_digest(outcome)
       }}
    end
  end

  def receipt_attrs(%Outcome{}, _), do: {:error, :invalid_completed_at}
  def receipt_attrs(_, _), do: {:error, :invalid_outcome_status}

  @doc """
  Deterministic lowercase SHA-256 of the complete `%Outcome{}`.

  Uses Erlang external term format with `[:deterministic]` so equal maps with
  different insertion order hash equally, while type-distinct values differ.
  Only the digest is persisted in the effect envelope.
  """
  @spec outcome_result_digest(Outcome.t()) :: String.t()
  def outcome_result_digest(%Outcome{} = outcome) do
    payload = :erlang.term_to_binary(outcome, [:deterministic])
    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end

  defp closed_outcome_status(status) when is_atom(status) do
    if MapSet.member?(@outcome_status_atoms, status) do
      {:ok, Atom.to_string(status)}
    else
      {:error, :invalid_outcome_status}
    end
  end

  defp closed_outcome_status(_), do: {:error, :invalid_outcome_status}
end
