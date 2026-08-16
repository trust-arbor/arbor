defmodule Arbor.Commands.SafeRecoveryArtifact.ComposeShell do
  @moduledoc false

  # Imperative shell for the E0B2C3b two-build composer. The only PRODUCTION
  # module allowed to call Arbor.Shell.*/SourceStaging.* -- perform_effect/3
  # maps each ComposeCore step to exactly one hardcoded call and ledgers the
  # result the instant it returns. Owns its own hardcoded cleanup-plan loop
  # (no shared callback crosses to ComposeFactInterpreter).
  #
  # This module owns the :production ComposeLedger domain exclusively.
  # ComposeFactInterpreter owns a disjoint :fact domain under its own receipt
  # schema -- neither module's ledger storage or receipt shape is reachable
  # from the other, so a fixture-mode retry can never resolve (and silently
  # "launder" as cleaned) a real pending Shell/SourceStaging resource, and a
  # real receipt can never be replayed against fixture-only cleanup logic.

  alias Arbor.Commands.SafeRecoveryArtifact.{
    CleanupPlan,
    CleanupReceipt,
    ComposeCore,
    ComposeLedger,
    SourceStaging,
    TrustedInventory
  }

  @domain :production
  @receipt_schema "arbor.commands.safe_recovery_artifact.two_build_cleanup_receipt.v1"
  @cleanup_opts [max_entries: 1_000_000, timeout_ms: 10_000]
  @token_bytes 32

  @doc false
  @spec receipt_schema() :: String.t()
  def receipt_schema, do: @receipt_schema

  @spec compose(keyword()) ::
          {:ok, map()} | {:error, term()} | {:error, {:cleanup_retained, CleanupReceipt.t()}}
  def compose(opts) when is_list(opts) do
    token = :crypto.strong_rand_bytes(@token_bytes)

    case ComposeLedger.try_acquire(@domain, token) do
      :busy -> {:error, :cleanup_ledger_busy}
      :ok -> opts |> run_compose() |> settle()
    end
  end

  def compose(_opts), do: {:error, :invalid_opts}

  @spec retry_cleanup(term()) ::
          {:ok, map()} | {:error, term()} | {:error, {:cleanup_retained, CleanupReceipt.t()}}
  def retry_cleanup(%CleanupReceipt{schema: @receipt_schema, owner: owner, token: token})
      when is_binary(token) do
    if owner == self() do
      case ComposeLedger.fetch(@domain) do
        {:ok, %{token: ^token} = ledger} -> resettle(ledger)
        _other -> {:error, :invalid_cleanup_receipt}
      end
    else
      {:error, :foreign_receipt}
    end
  end

  def retry_cleanup(_receipt), do: {:error, :invalid_cleanup_receipt}

  # -- main pipeline -----------------------------------------------------

  defp run_compose(opts) do
    run(ComposeCore.init(), opts)
  catch
    kind, reason -> {:threw, kind, reason}
  end

  defp run(state, opts) do
    case ComposeCore.next(state) do
      {:done, result} ->
        result

      {:error, _reason} = error ->
        error

      {:effect, step, next_state} ->
        raw_result = perform_effect(step, next_state, opts)

        case ComposeCore.step_result(next_state, step, raw_result) do
          {:ok, state2} -> run(state2, opts)
          {:error, _reason} = error -> error
        end
    end
  end

  defp perform_effect({:stage_source, slot}, _state, opts) do
    case SourceStaging.stage(opts, :production) do
      {:ok, lease} = ok ->
        ComposeLedger.record_source(@domain, slot, {:live, lease})
        ok

      {:error, {:cleanup_retained, _reason, identity}} = error ->
        ComposeLedger.record_source(@domain, slot, {:retained, identity})
        error

      {:error, _reason} = error ->
        error
    end
  end

  defp perform_effect({:acquire_build, slot}, state, _opts) do
    lease = state.source[slot]

    request = %{
      "schema" => "arbor.shell.trusted_build.request.v1",
      "source" => %{
        "schema" => "arbor.shell.trusted_build.source.v1",
        "identity" => lease["identity"]
      }
    }

    case Arbor.Shell.acquire_trusted_build_lease(request) do
      {:ok, handle, _view} ->
        ComposeLedger.record_build(@domain, slot, {:live, handle})
        {:ok, handle}

      {:error, _reason} = error ->
        error
    end
  end

  defp perform_effect({:run_phase, slot, phase}, state, _opts) do
    Arbor.Shell.execute_trusted_build(state.build[slot], phase)
  end

  defp perform_effect({:stage_native, slot}, state, _opts) do
    Arbor.Shell.stage_trusted_build_native(state.build[slot])
  end

  defp perform_effect({:inventory_deps, slot}, state, _opts) do
    Arbor.Shell.inventory_trusted_build_deps(state.build[slot])
  end

  defp perform_effect({:remove_cookie, slot}, state, _opts) do
    Arbor.Shell.remove_trusted_build_release_cookie(state.build[slot])
  end

  defp perform_effect({:inventory_release, slot}, state, _opts) do
    Arbor.Shell.inventory_trusted_build(state.build[slot])
  end

  defp perform_effect({:read_descriptors, slot}, state, _opts) do
    selectors = TrustedInventory.descriptor_selectors(state.release_raw[slot])

    selectors
    |> Enum.reduce_while({:ok, []}, fn {selector, _rebased}, {:ok, acc} ->
      case Arbor.Shell.read_trusted_build_descriptor(state.build[slot], selector) do
        {:ok, %{"path" => ^selector} = descriptor} -> {:cont, {:ok, [descriptor | acc]}}
        {:ok, _mismatched} -> {:halt, {:error, :descriptor_selector_mismatch}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  # -- retained-cleanup ledger / receipt / retry --------------------------

  defp settle(outcome) do
    outcome = normalize_outcome(outcome)
    {:ok, ledger} = ComposeLedger.fetch(@domain)
    ledger = ComposeLedger.set_preserved_outcome_once(ledger, outcome)

    finish_sweep(ledger, outcome)
  end

  defp resettle(ledger), do: finish_sweep(ledger, ledger.preserved_outcome)

  defp finish_sweep(ledger, outcome) do
    swept = run_cleanup_plan(ledger)

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

  defp run_cleanup_plan(ledger), do: run_cleanup_plan(ledger, CleanupPlan.init())

  defp run_cleanup_plan(ledger, cursor) do
    case CleanupPlan.next(ledger, cursor) do
      :done ->
        ledger

      {:cleanup, tag, cursor2} ->
        result = dispatch_cleanup(ledger, tag)
        {ledger2, cursor3} = CleanupPlan.record(ledger, cursor2, tag, result)
        run_cleanup_plan(ledger2, cursor3)
    end
  end

  # Direct per-clause catch -- no `fun` parameter anywhere in the cleanup
  # dispatch path.
  defp dispatch_cleanup(ledger, {:build, slot}) do
    {:live, handle} = ledger.build[slot]
    Arbor.Shell.release_trusted_build_lease(handle)
  catch
    kind, reason -> {:threw, kind, reason}
  end

  defp dispatch_cleanup(ledger, {:source, slot}) do
    case ledger.source[slot] do
      {:live, lease} -> SourceStaging.release(lease)
      {:retained, identity} -> Arbor.Shell.remove_owned_tree(identity, @cleanup_opts)
    end
  catch
    kind, reason -> {:threw, kind, reason}
  end
end
