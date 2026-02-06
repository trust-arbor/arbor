defmodule Arbor.Agent.Verification do
  @moduledoc """
  Verification flow for self-healing remediation.

  After a fix is applied, this module confirms whether the remediation
  actually worked by re-checking the original anomaly condition.

  ## Verification Strategy

  Each anomaly type has a specific verification function:
  - **Message queue flood**: Check if queue length is back to normal
  - **Process leak**: Check if process count is decreasing
  - **Supervisor crash**: Check if supervisor has active children

  ## Usage

      # After applying a fix
      case Verification.verify_fix(anomaly, action, target) do
        {:ok, :verified} ->
          # Fix worked
        {:ok, :unverified} ->
          # Fix didn't work, may need escalation
        {:error, reason} ->
          # Verification failed
      end
  """

  require Logger

  alias Arbor.Monitor.Diagnostics

  @verification_delay_ms 500
  @max_retries 3
  @retry_delay_ms 200

  @doc """
  Verify that a fix was successful.

  Returns:
  - `{:ok, :verified}` — The fix worked
  - `{:ok, :unverified}` — The fix didn't work
  - `{:error, reason}` — Verification failed
  """
  @spec verify_fix(map(), atom(), term()) :: {:ok, :verified | :unverified} | {:error, term()}
  def verify_fix(anomaly, action, target, opts \\ []) do
    delay = Keyword.get(opts, :delay_ms, @verification_delay_ms)
    retries = Keyword.get(opts, :retries, @max_retries)

    # Wait for fix to take effect
    Process.sleep(delay)

    verify_with_retries(anomaly, action, target, retries)
  end

  @doc """
  Quick check if an anomaly condition is still present.

  Does not wait or retry — use for polling scenarios.
  """
  @spec anomaly_still_present?(map()) :: boolean()
  def anomaly_still_present?(anomaly) do
    case verify_condition(anomaly) do
      {:ok, :verified} -> false
      _ -> true
    end
  end

  @doc """
  Create a verification report with before/after metrics.
  """
  @spec create_report(map(), atom(), term(), keyword()) :: map()
  def create_report(anomaly, action, target, opts \\ []) do
    before_metrics = gather_metrics(anomaly, target)

    result = verify_fix(anomaly, action, target, opts)

    after_metrics = gather_metrics(anomaly, target)

    %{
      anomaly_skill: anomaly.skill,
      action: action,
      target: inspect(target),
      result: result,
      before_metrics: before_metrics,
      after_metrics: after_metrics,
      verified_at: DateTime.utc_now()
    }
  end

  # ============================================================================
  # Private — Verification with Retries
  # ============================================================================

  defp verify_with_retries(anomaly, action, target, retries_remaining) do
    case verify_action(anomaly, action, target) do
      {:ok, :verified} = result ->
        result

      {:ok, :unverified} when retries_remaining > 0 ->
        Process.sleep(@retry_delay_ms)
        verify_with_retries(anomaly, action, target, retries_remaining - 1)

      {:ok, :unverified} = result ->
        result

      {:error, _reason} when retries_remaining > 0 ->
        Process.sleep(@retry_delay_ms)
        verify_with_retries(anomaly, action, target, retries_remaining - 1)

      {:error, _reason} = error ->
        error
    end
  end

  # ============================================================================
  # Private — Action-Specific Verification
  # ============================================================================

  defp verify_action(_anomaly, :kill_process, pid) when is_pid(pid) do
    # Process should be dead
    if Process.alive?(pid) do
      {:ok, :unverified}
    else
      {:ok, :verified}
    end
  end

  defp verify_action(_anomaly, :force_gc, pid) when is_pid(pid) do
    # For GC, check if memory decreased or queue length is reasonable
    if Process.alive?(pid) do
      case Diagnostics.inspect_process(pid) do
        %{message_queue_len: len} when len < 1000 ->
          {:ok, :verified}

        %{memory: memory} when memory < 10_000_000 ->
          {:ok, :verified}

        _ ->
          {:ok, :unverified}
      end
    else
      # Process died, which might be OK for GC
      {:ok, :verified}
    end
  rescue
    _ -> {:error, :process_inspection_failed}
  end

  defp verify_action(_anomaly, :stop_supervisor, pid) when is_pid(pid) do
    # Supervisor should be dead
    if Process.alive?(pid) do
      {:ok, :unverified}
    else
      {:ok, :verified}
    end
  end

  defp verify_action(_anomaly, :logged_warning, _target) do
    # Manual intervention logged — consider verified (human will handle)
    {:ok, :verified}
  end

  defp verify_action(anomaly, :none, _target) do
    # No action taken — verify the anomaly condition directly
    verify_condition(anomaly)
  end

  defp verify_action(_anomaly, action, _target) do
    Logger.debug("[Verification] Unknown action #{action}, assuming verified")
    {:ok, :verified}
  end

  # ============================================================================
  # Private — Condition Verification
  # ============================================================================

  defp verify_condition(%{skill: :processes, details: details}) do
    pid = Map.get(details, :pid) || Map.get(details, :process)
    threshold = Map.get(details, :threshold, 1000)

    cond do
      is_nil(pid) ->
        # No specific process, check general queue lengths
        bloated = Diagnostics.find_bloated_queues(threshold)
        if Enum.empty?(bloated), do: {:ok, :verified}, else: {:ok, :unverified}

      not Process.alive?(pid) ->
        {:ok, :verified}

      true ->
        case Diagnostics.inspect_process(pid) do
          %{message_queue_len: len} when len < threshold ->
            {:ok, :verified}

          _ ->
            {:ok, :unverified}
        end
    end
  rescue
    _ -> {:error, :verification_failed}
  end

  defp verify_condition(%{skill: :beam, details: details}) do
    # Check process count if that was the issue
    case details do
      %{process_count: _} ->
        current_count = :erlang.system_info(:process_count)
        max_count = :erlang.system_info(:process_limit)

        if current_count / max_count < 0.7 do
          {:ok, :verified}
        else
          {:ok, :unverified}
        end

      _ ->
        # Generic BEAM issue — assume verified
        {:ok, :verified}
    end
  rescue
    _ -> {:error, :verification_failed}
  end

  defp verify_condition(%{skill: :supervisor, details: details}) do
    pid = Map.get(details, :pid) || Map.get(details, :supervisor)

    cond do
      is_nil(pid) ->
        {:ok, :verified}

      not Process.alive?(pid) ->
        {:ok, :verified}

      true ->
        # Check if supervisor has recovered
        case Diagnostics.inspect_supervisor(pid) do
          %{children: children} when is_list(children) ->
            active_count = Enum.count(children, fn c -> c.alive == true end)
            total_count = length(children)

            if total_count == 0 or active_count / total_count >= 0.8 do
              {:ok, :verified}
            else
              {:ok, :unverified}
            end

          _ ->
            {:ok, :unverified}
        end
    end
  rescue
    _ -> {:error, :verification_failed}
  end

  defp verify_condition(%{skill: skill}) do
    Logger.debug("[Verification] No specific verification for skill #{skill}")
    {:ok, :verified}
  end

  # ============================================================================
  # Private — Metrics Gathering
  # ============================================================================

  defp gather_metrics(%{skill: :processes, details: details}, target) do
    pid = target || Map.get(details, :pid) || Map.get(details, :process)

    if is_pid(pid) and Process.alive?(pid) do
      case safe_call(fn -> Diagnostics.inspect_process(pid) end) do
        nil -> %{process_alive: true}
        info -> Map.take(info, [:message_queue_len, :memory, :reductions, :status])
      end
    else
      %{process_alive: is_pid(pid) and Process.alive?(pid)}
    end
  end

  defp gather_metrics(%{skill: :beam}, _target) do
    %{
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
      memory_total: :erlang.memory(:total)
    }
  end

  defp gather_metrics(%{skill: :supervisor, details: details}, target) do
    pid = target || Map.get(details, :pid) || Map.get(details, :supervisor)

    if is_pid(pid) and Process.alive?(pid) do
      case safe_call(fn -> Diagnostics.inspect_supervisor(pid) end) do
        nil -> %{supervisor_alive: true}
        info -> Map.take(info, [:strategy, :intensity, :period])
      end
    else
      %{supervisor_alive: is_pid(pid) and Process.alive?(pid)}
    end
  end

  defp gather_metrics(_anomaly, _target), do: %{}

  defp safe_call(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end
end
