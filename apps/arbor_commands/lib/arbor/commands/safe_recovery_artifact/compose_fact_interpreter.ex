defmodule Arbor.Commands.SafeRecoveryArtifact.ComposeFactInterpreter do
  @moduledoc false

  # Test-only. Runs the identical ComposeCore/CleanupPlan pure logic used in
  # production, but every dispatch site here reads a canned reply out of the
  # caller-supplied `facts` map instead of calling Arbor.Shell or
  # SourceStaging -- this module contains no such call anywhere, in either
  # its :compose or :retry mode.
  #
  # This module owns the :fact ComposeLedger domain and a receipt schema
  # distinct from ComposeShell's -- a receipt minted here can never be
  # accepted by production retry_cleanup/1 (different schema, and even a
  # forged matching schema would still miss under the :production domain
  # key), and a real production receipt can never be replayed here to
  # "resolve" a real pending resource with a synthetic :ok fixture reply.

  alias Arbor.Commands.SafeRecoveryArtifact.{
    CleanupPlan,
    CleanupReceipt,
    ComposeCore,
    ComposeLedger
  }

  @domain :fact
  @receipt_schema "arbor.commands.safe_recovery_artifact.two_build_cleanup_receipt.fact.v1"
  @token_bytes 32

  @doc false
  @spec receipt_schema() :: String.t()
  def receipt_schema, do: @receipt_schema

  @spec compose_from_facts_for_test(term()) ::
          {:ok, map()} | {:error, term()} | {:error, {:cleanup_retained, CleanupReceipt.t()}}
  def compose_from_facts_for_test(%{mode: :compose, facts: facts}) when is_map(facts) do
    token = :crypto.strong_rand_bytes(@token_bytes)

    case ComposeLedger.try_acquire(@domain, token) do
      :busy -> {:error, :cleanup_ledger_busy}
      :ok -> run_compose(facts)
    end
  end

  def compose_from_facts_for_test(%{mode: :retry, receipt: receipt, facts: facts})
      when is_map(facts) do
    with %CleanupReceipt{schema: @receipt_schema, owner: owner, token: token} <- receipt,
         true <- is_binary(token) do
      if owner == self() do
        case ComposeLedger.fetch(@domain) do
          {:ok, %{token: ^token} = ledger} -> resettle(ledger, facts)
          _other -> {:error, :invalid_cleanup_receipt}
        end
      else
        {:error, :foreign_receipt}
      end
    else
      _other -> {:error, :invalid_cleanup_receipt}
    end
  end

  def compose_from_facts_for_test(_other), do: {:error, :invalid_opts}

  # -- main pipeline -----------------------------------------------------

  defp run_compose(facts) do
    settle(run_or_catch(facts), facts)
  end

  defp run_or_catch(facts) do
    run(ComposeCore.init(), facts)
  catch
    kind, reason -> {:threw, kind, reason}
  end

  defp run(state, facts) do
    case ComposeCore.next(state) do
      {:done, result} ->
        result

      {:error, _reason} = error ->
        error

      {:effect, step, next_state} ->
        trace(facts, {:composer_step, step})
        raw_result = Map.get(facts.replies, step, {:error, :fixture_missing})
        ledger_effect(step, raw_result)

        case ComposeCore.step_result(next_state, step, raw_result) do
          {:ok, state2} -> run(state2, facts)
          {:error, _reason} = error -> error
        end
    end
  end

  # Mirrors ComposeShell's acquisition-site ledgering exactly (same rule: a
  # C1 cleanup-retained identity is recorded immediately, unconditionally,
  # before any shape check) so the fact interpreter exercises the same
  # ledger/receipt/retry state machine without ever calling Shell.
  defp ledger_effect({:stage_source, slot}, {:ok, lease}) do
    ComposeLedger.record_source(@domain, slot, {:live, lease})
  end

  defp ledger_effect({:stage_source, slot}, {:error, {:cleanup_retained, _reason, identity}}) do
    ComposeLedger.record_source(@domain, slot, {:retained, identity})
  end

  defp ledger_effect({:acquire_build, slot}, {:ok, handle}) do
    ComposeLedger.record_build(@domain, slot, {:live, handle})
  end

  defp ledger_effect(_step, _raw_result), do: :ok

  # -- retained-cleanup ledger / receipt / retry --------------------------

  defp settle(outcome, facts) do
    outcome = normalize_outcome(outcome)
    {:ok, ledger} = ComposeLedger.fetch(@domain)
    ledger = ComposeLedger.set_preserved_outcome_once(ledger, outcome)

    finish_sweep(ledger, outcome, facts)
  end

  defp resettle(ledger, facts), do: finish_sweep(ledger, ledger.preserved_outcome, facts)

  defp finish_sweep(ledger, outcome, facts) do
    swept = run_cleanup_plan(ledger, facts)

    case CleanupPlan.pending(swept) do
      [] ->
        ComposeLedger.delete(@domain)
        outcome

      _pending ->
        ComposeLedger.persist(@domain, swept)
        {:error, {:cleanup_retained, receipt_from(swept)}}
    end
  end

  defp receipt_from(ledger) do
    %CleanupReceipt{schema: @receipt_schema, owner: self(), token: ledger.token}
  end

  defp normalize_outcome({:threw, kind, reason}), do: {:error, {:composer_crashed, kind, reason}}
  defp normalize_outcome(outcome), do: outcome

  defp run_cleanup_plan(ledger, facts), do: run_cleanup_plan(ledger, CleanupPlan.init(), facts)

  defp run_cleanup_plan(ledger, cursor, facts) do
    case CleanupPlan.next(ledger, cursor) do
      :done ->
        ledger

      {:cleanup, tag, cursor2} ->
        result = dispatch_cleanup(tag, facts)
        {ledger2, cursor3} = CleanupPlan.record(ledger, cursor2, tag, result)
        run_cleanup_plan(ledger2, cursor3, facts)
    end
  end

  defp dispatch_cleanup(tag, facts) do
    trace(facts, {:cleanup_attempt, tag})

    facts
    |> Map.get(:cleanup_replies, %{})
    |> Map.get(tag, :ok)
  end

  # Test-only instrumentation: when `facts` carries a :trace_pid, every step
  # dispatch and every cleanup attempt is reported to it so tests can assert
  # the exact operation trace and the exact cleanup call log, rather than
  # inferring them from side effects.
  defp trace(%{trace_pid: pid}, message) when is_pid(pid), do: send(pid, message)
  defp trace(_facts, _message), do: :ok
end
