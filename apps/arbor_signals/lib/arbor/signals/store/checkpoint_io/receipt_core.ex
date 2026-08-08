defmodule Arbor.Signals.Store.CheckpointIO.ReceiptCore do
  @moduledoc false

  # Pure receipt state machine for CheckpointIO Store-side convergence.
  # No Process, IO, or Application calls — unit-tested directly.

  @type phase :: :arming | :running | :settling | :closed

  @type receipt :: %{
          phase: phase(),
          op_ref: reference(),
          d_work: integer(),
          d_outer: integer(),
          coordinator: pid(),
          coord_mon: reference(),
          worker: pid() | nil,
          worker_mon: reference() | nil,
          result: :none | {:some, term()},
          worker_down: boolean(),
          coord_down: boolean(),
          outcome: :pending | {:done, term()}
        }

  @type decision ::
          :continue
          | :ignore
          | {:arm_worker, pid()}
          | {:reject_pre_arm_result, :dispatch_failed}
          | :settle_kill_both
          | {:fail_closed_no_result, :exit}
          | :timeout_teardown
          | {:done, term()}

  @type event ::
          {:owner_ready, pid()}
          | {:result, term()}
          | {:worker_down, reference()}
          | {:coord_down, reference()}
          | :work_timeout
          | :quiescence_failed
          | :timeout_teardown_complete

  @doc """
  Split remaining outer budget into work + cleanup reserve.

  Returns `{:error, :timeout}` when remaining <= 1 (work cannot start).
  For remaining > 1: reserve = min(250, max(1, div(remaining, 5)), remaining - 1).
  """
  @spec split_remaining(integer()) ::
          {:ok, %{reserve: pos_integer(), work_budget: pos_integer()}} | {:error, :timeout}
  def split_remaining(remaining0) when is_integer(remaining0) do
    cond do
      remaining0 <= 1 ->
        {:error, :timeout}

      true ->
        reserve =
          [250, max(1, div(remaining0, 5)), remaining0 - 1]
          |> Enum.min()

        work_budget = remaining0 - reserve
        {:ok, %{reserve: reserve, work_budget: work_budget}}
    end
  end

  @doc """
  Compute fixed D_work once from absolute outer deadline and a now timestamp.
  Never recompute after entry — callers thread the returned d_work unchanged.
  """
  @spec split_deadlines(integer(), integer()) ::
          {:ok, d_work :: integer(), d_outer :: integer()} | {:error, :timeout}
  def split_deadlines(d_outer, now)
      when is_integer(d_outer) and is_integer(now) do
    remaining0 = d_outer - now

    case split_remaining(remaining0) do
      {:error, :timeout} ->
        {:error, :timeout}

      {:ok, %{reserve: reserve}} ->
        {:ok, d_outer - reserve, d_outer}
    end
  end

  @spec new(reference(), integer(), integer(), pid(), reference()) :: receipt()
  def new(op_ref, d_work, d_outer, coordinator, coord_mon)
      when is_reference(op_ref) and is_integer(d_work) and is_integer(d_outer) and
             is_pid(coordinator) and is_reference(coord_mon) do
    %{
      phase: :arming,
      op_ref: op_ref,
      d_work: d_work,
      d_outer: d_outer,
      coordinator: coordinator,
      coord_mon: coord_mon,
      worker: nil,
      worker_mon: nil,
      result: :none,
      worker_down: false,
      coord_down: false,
      outcome: :pending
    }
  end

  @doc """
  After shell creates Store-owned worker monitor, mark armed and enter :running.
  """
  @spec arm_worker(receipt(), pid(), reference()) :: receipt()
  def arm_worker(%{phase: :arming} = receipt, worker, worker_mon)
      when is_pid(worker) and is_reference(worker_mon) do
    %{receipt | worker: worker, worker_mon: worker_mon, phase: :running}
  end

  @spec apply_event(receipt(), event()) :: {receipt(), decision()}
  def apply_event(%{outcome: {:done, _} = done} = receipt, _event) do
    {receipt, done}
  end

  def apply_event(receipt, {:owner_ready, worker})
      when is_pid(worker) and receipt.phase == :arming and is_nil(receipt.worker) do
    {receipt, {:arm_worker, worker}}
  end

  def apply_event(receipt, {:owner_ready, _}) do
    {receipt, :ignore}
  end

  def apply_event(%{phase: :arming} = receipt, {:result, _term}) do
    # Pre-arm result cannot be admitted — dual-DOWN proof is impossible.
    {receipt, {:reject_pre_arm_result, :dispatch_failed}}
  end

  def apply_event(%{phase: :running, result: :none} = receipt, {:result, term}) do
    receipt = %{receipt | result: {:some, term}, phase: :settling}
    {receipt, :settle_kill_both}
  end

  def apply_event(%{phase: :settling, result: {:some, _}} = receipt, {:result, _}) do
    # Already holding a result; ignore late duplicate.
    {receipt, :ignore}
  end

  def apply_event(receipt, {:result, _}) do
    {receipt, :ignore}
  end

  def apply_event(receipt, {:worker_down, mon}) do
    cond do
      receipt.worker_mon != mon ->
        {receipt, :ignore}

      receipt.worker_down ->
        # One-shot: already consumed.
        {receipt, :ignore}

      true ->
        receipt = %{receipt | worker_down: true}
        maybe_after_down(receipt)
    end
  end

  def apply_event(receipt, {:coord_down, mon}) do
    cond do
      receipt.coord_mon != mon ->
        {receipt, :ignore}

      receipt.coord_down ->
        {receipt, :ignore}

      true ->
        receipt = %{receipt | coord_down: true}
        maybe_after_coord_down(receipt)
    end
  end

  def apply_event(%{phase: phase} = receipt, :work_timeout)
      when phase in [:arming, :running] do
    {receipt, :timeout_teardown}
  end

  def apply_event(%{phase: :settling} = receipt, :work_timeout) do
    # Settle uses outer cleanup budget, not work timeout.
    {receipt, :ignore}
  end

  def apply_event(receipt, :work_timeout) do
    {receipt, :ignore}
  end

  def apply_event(%{phase: :settling, result: {:some, _}} = receipt, :quiescence_failed) do
    close(receipt, {:error, :exit})
  end

  def apply_event(receipt, :quiescence_failed) do
    close(receipt, {:error, :exit})
  end

  def apply_event(receipt, :timeout_teardown_complete) do
    close(receipt, {:error, :timeout})
  end

  def apply_event(receipt, _unknown) do
    {receipt, :ignore}
  end

  @doc """
  Mark fail-closed outcome after shell finished worker teardown for no-result coord death.
  """
  @spec complete_fail_closed(receipt(), :exit | :dispatch_failed) :: {receipt(), decision()}
  def complete_fail_closed(receipt, reason) when reason in [:exit, :dispatch_failed] do
    close(receipt, {:error, reason})
  end

  @doc """
  Mark pre-arm reject outcome after shell finished coord cleanup.
  """
  @spec complete_pre_arm_reject(receipt(), :dispatch_failed | :exit) :: {receipt(), decision()}
  def complete_pre_arm_reject(receipt, reason) when reason in [:dispatch_failed, :exit] do
    close(receipt, {:error, reason})
  end

  @spec both_down?(receipt()) :: boolean()
  def both_down?(%{worker_down: w, coord_down: c, worker_mon: wm}) do
    # Dual-DOWN proof requires an armed Store-owned worker mon plus both receipts.
    # Pre-arm (worker_mon nil) is never "both down" — use needs_* for coord-only cleanup.
    is_reference(wm) and w and c
  end

  @spec needs_worker_down?(receipt()) :: boolean()
  def needs_worker_down?(%{worker_mon: nil}), do: false
  def needs_worker_down?(%{worker_down: true}), do: false
  def needs_worker_down?(%{worker_mon: mon}) when is_reference(mon), do: true

  @spec needs_coord_down?(receipt()) :: boolean()
  def needs_coord_down?(%{coord_down: true}), do: false
  def needs_coord_down?(%{coord_mon: mon}) when is_reference(mon), do: true

  @spec normalize_final(term()) :: {:ok, term()} | {:error, term()}
  def normalize_final({:ok, value}), do: {:ok, value}
  def normalize_final({:error, reason}), do: {:error, reason}
  def normalize_final(_), do: {:error, :malformed}

  # --- private ---

  defp maybe_after_coord_down(%{phase: :arming} = receipt) do
    close(receipt, {:error, :dispatch_failed})
  end

  defp maybe_after_coord_down(%{phase: :running, result: :none} = receipt) do
    {receipt, {:fail_closed_no_result, :exit}}
  end

  defp maybe_after_coord_down(%{phase: :settling} = receipt) do
    maybe_after_down(receipt)
  end

  defp maybe_after_coord_down(%{phase: :running, result: {:some, _}} = receipt) do
    # Should not happen (result moves to settling), but complete if both down.
    maybe_after_down(%{receipt | phase: :settling})
  end

  defp maybe_after_coord_down(receipt) do
    {receipt, :continue}
  end

  defp maybe_after_down(%{phase: :settling, result: {:some, term}} = receipt) do
    if receipt.worker_down and receipt.coord_down do
      close(receipt, normalize_final(term))
    else
      {receipt, :continue}
    end
  end

  defp maybe_after_down(%{phase: :running} = receipt) do
    # Worker down before result — keep waiting for result under work budget.
    {receipt, :continue}
  end

  defp maybe_after_down(receipt) do
    {receipt, :continue}
  end

  defp close(receipt, outcome_term) do
    receipt = %{receipt | phase: :closed, outcome: {:done, outcome_term}}
    {receipt, {:done, outcome_term}}
  end
end
