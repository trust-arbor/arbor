defmodule Arbor.Commands.SafeRecoveryClosure.MeasureShell do
  @moduledoc false

  # One-build compose-hold: stage source, build arbor_trust, remove COOKIE,
  # pin rel/arbor_trust, probe, then always release the lease. Distinct from
  # the E0B2 two-build composer; does not share its ledger domain.

  alias Arbor.Commands.SafeRecoveryArtifact.SourceStaging
  alias Arbor.Commands.SafeRecoveryClosure.{MeasureCore, PeerRunner}

  @token_bytes 32
  @ledger_key {__MODULE__, :ledger}

  @spec measure(keyword()) :: {:ok, map()} | {:error, term()}
  def measure(opts) when is_list(opts) do
    token = :crypto.strong_rand_bytes(@token_bytes)

    case try_acquire(token) do
      :busy -> {:error, :cleanup_ledger_busy}
      :ok -> opts |> run_measure() |> settle()
    end
  end

  def measure(_opts), do: {:error, :invalid_opts}

  @doc false
  @spec measure_from_facts_for_test(map()) :: {:ok, map()} | {:error, term()}
  def measure_from_facts_for_test(%{replies: replies}) when is_map(replies) do
    token = :crypto.strong_rand_bytes(@token_bytes)

    case try_acquire(token) do
      :busy -> {:error, :cleanup_ledger_busy}
      :ok -> replies |> run_from_facts() |> settle()
    end
  end

  def measure_from_facts_for_test(_), do: {:error, :invalid_opts}

  defp run_measure(opts) do
    run(MeasureCore.init(), {:live, opts})
  catch
    kind, reason -> {:error, {:composer_crashed, kind, reason}}
  end

  defp run_from_facts(replies) do
    run(MeasureCore.init(), {:facts, replies})
  catch
    kind, reason -> {:error, {:composer_crashed, kind, reason}}
  end

  defp run(state, mode) do
    case MeasureCore.next(state) do
      {:done, result} ->
        result

      {:error, _} = error ->
        error

      {:effect, step, next_state} ->
        raw = perform(step, next_state, mode)

        case MeasureCore.step_result(next_state, step, raw) do
          {:ok, state2} -> run(state2, mode)
          {:error, _} = error -> error
        end
    end
  end

  defp perform(step, state, {:live, opts}), do: perform_live(step, state, opts)

  defp perform(step, _state, {:facts, replies}),
    do: Map.get(replies, step, {:error, :missing_fact})

  defp perform_live(:stage_source, _state, opts) do
    case SourceStaging.stage(opts, :production) do
      {:ok, lease} = ok ->
        record(:source, {:live, lease})
        ok

      {:error, {:cleanup_retained, _reason, identity}} = error ->
        record(:source, {:retained, identity})
        error

      {:error, _} = error ->
        error
    end
  end

  defp perform_live(:acquire_build, state, _opts) do
    request = %{
      "schema" => "arbor.shell.trusted_build.request.v1",
      "source" => %{
        "schema" => "arbor.shell.trusted_build.source.v1",
        "identity" => state.source["identity"]
      }
    }

    case Arbor.Shell.acquire_trusted_build_lease(request) do
      {:ok, handle, _view} ->
        record(:build, {:live, handle})
        {:ok, handle}

      {:error, _} = error ->
        error
    end
  end

  defp perform_live({:run_phase, phase}, state, _opts) do
    Arbor.Shell.execute_trusted_build(state.build, phase)
  end

  defp perform_live(:stage_native, state, _opts) do
    Arbor.Shell.stage_trusted_build_native(state.build)
  end

  defp perform_live(:inventory_deps, state, _opts) do
    Arbor.Shell.inventory_trusted_build_deps(state.build)
  end

  defp perform_live(:remove_cookie, state, _opts) do
    Arbor.Shell.remove_trusted_build_release_cookie(state.build)
  end

  defp perform_live(:inventory_release, state, _opts) do
    Arbor.Shell.inventory_trusted_build(state.build)
  end

  defp perform_live(:pin_root, state, _opts) do
    Arbor.Shell.trusted_build_release_root(state.build)
  end

  defp perform_live(:measure, state, _opts) do
    PeerRunner.measure(state.release_root)
  end

  defp settle(outcome) do
    ledger = fetch_ledger()
    result = run_cleanup(ledger)

    case pending(result) do
      [] ->
        Process.delete(@ledger_key)
        outcome

      _pending ->
        put_ledger(result)
        {:error, {:cleanup_retained, :closure_measure}}
    end
  end

  defp run_cleanup(ledger) do
    ledger
    |> cleanup_build()
    |> cleanup_source()
  end

  defp cleanup_build(%{build: {:live, handle}} = ledger) do
    case safe_release_build(handle) do
      :ok -> %{ledger | build: :none}
      _other -> ledger
    end
  end

  defp cleanup_build(ledger), do: ledger

  defp cleanup_source(%{source: {:live, lease}} = ledger) do
    case safe_release_source(lease) do
      :ok -> %{ledger | source: :none}
      _other -> ledger
    end
  end

  defp cleanup_source(%{source: {:retained, _identity}} = ledger), do: ledger
  defp cleanup_source(ledger), do: ledger

  defp safe_release_build(handle) do
    Arbor.Shell.release_trusted_build_lease(handle)
  catch
    _kind, _reason -> {:error, :build_cleanup_failed}
  end

  defp safe_release_source(lease) do
    SourceStaging.release(lease)
  catch
    _kind, _reason -> {:error, :source_cleanup_failed}
  end

  defp pending(ledger) do
    Enum.reject([ledger.build, ledger.source], &(&1 == :none or is_nil(&1)))
  end

  defp try_acquire(token) do
    case Process.get(@ledger_key) do
      nil ->
        put_ledger(%{token: token, source: :none, build: :none})
        :ok

      _existing ->
        :busy
    end
  end

  defp record(kind, value) do
    ledger = fetch_ledger()
    put_ledger(Map.put(ledger, kind, value))
  end

  defp fetch_ledger, do: Process.get(@ledger_key)
  defp put_ledger(ledger), do: Process.put(@ledger_key, ledger)
end
