defmodule Arbor.SDLC.Events do
  @moduledoc """
  Signal emission for SDLC activity.

  Emits signals for all SDLC pipeline events, enabling observability
  and integration with other Arbor systems. All signals are emitted
  under the `:sdlc` category.

  ## Signal Types

  ### Item Lifecycle
  - `:item_detected` - New item file detected
  - `:item_changed` - Previously processed item file changed
  - `:item_parsed` - Item parsed from markdown
  - `:item_expanded` - Item expanded by Expander processor
  - `:item_deliberated` - Item analyzed by Deliberator
  - `:item_moved` - Item moved to a new stage
  - `:item_completed` - Item reached terminal stage

  ### Processing
  - `:processing_started` - Processor began working on item
  - `:processing_completed` - Processor finished item
  - `:processing_failed` - Processor encountered error

  ### Consensus
  - `:decision_requested` - Deliberator requested council decision
  - `:decision_rendered` - Council made a decision
  - `:decision_documented` - Decision written to .arbor/decisions/

  ### Session Lifecycle
  - `:session_spawned` - Auto session spawned for work item
  - `:session_completed` - Session finished successfully
  - `:session_failed` - Session failed or tests didn't pass
  - `:session_blocked` - Session hit max turns and was blocked
  - `:session_interrupted` - Session was interrupted by user

  ### System
  - `:watcher_started` - File watcher initialized
  - `:watcher_scan_completed` - Periodic scan finished
  - `:consistency_check_completed` - Consistency checker finished

  ## Usage

      # Emit item detected
      Events.emit_item_detected(path, content_hash)

      # Emit processing started
      Events.emit_processing_started(item, :expander)

      # Emit with correlation
      Events.emit_item_moved(item, :inbox, :brainstorming, correlation_id: trace_id)
  """

  require Logger

  @category :sdlc

  # =============================================================================
  # Item Lifecycle Events
  # =============================================================================

  @doc """
  Emit when a new item file is detected.
  """
  @spec emit_item_detected(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def emit_item_detected(path, content_hash, opts \\ []) do
    emit(
      :item_detected,
      %{
        path: path,
        content_hash: content_hash
      },
      opts
    )
  end

  @doc """
  Emit when a previously processed item file is changed.
  """
  @spec emit_item_changed(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def emit_item_changed(path, content_hash, opts \\ []) do
    emit(
      :item_changed,
      %{
        path: path,
        content_hash: content_hash
      },
      opts
    )
  end

  @doc """
  Emit when an item is successfully parsed from markdown.
  """
  @spec emit_item_parsed(map() | struct(), keyword()) :: :ok | {:error, term()}
  def emit_item_parsed(item, opts \\ []) do
    emit(
      :item_parsed,
      %{
        item_id: get_item_id(item),
        title: Map.get(item, :title),
        path: Map.get(item, :path),
        category: Map.get(item, :category),
        priority: Map.get(item, :priority)
      },
      opts
    )
  end

  @doc """
  Emit when an item is expanded by the Expander processor.
  """
  @spec emit_item_expanded(map() | struct(), keyword()) :: :ok | {:error, term()}
  def emit_item_expanded(item, opts \\ []) do
    emit(
      :item_expanded,
      %{
        item_id: get_item_id(item),
        title: Map.get(item, :title),
        category: Map.get(item, :category),
        priority: Map.get(item, :priority),
        has_acceptance_criteria: Map.get(item, :acceptance_criteria, []) != [],
        has_definition_of_done: Map.get(item, :definition_of_done, []) != []
      },
      opts
    )
  end

  @doc """
  Emit when an item is analyzed by the Deliberator.
  """
  @spec emit_item_deliberated(map() | struct(), atom(), keyword()) :: :ok | {:error, term()}
  def emit_item_deliberated(item, outcome, opts \\ []) do
    emit(
      :item_deliberated,
      %{
        item_id: get_item_id(item),
        title: Map.get(item, :title),
        outcome: outcome,
        decision_id: Keyword.get(opts, :decision_id)
      },
      opts
    )
  end

  @doc """
  Emit when an item is moved to a new stage.
  """
  @spec emit_item_moved(map() | struct(), atom(), atom(), keyword()) :: :ok | {:error, term()}
  def emit_item_moved(item, from_stage, to_stage, opts \\ []) do
    emit(
      :item_moved,
      %{
        item_id: get_item_id(item),
        title: Map.get(item, :title),
        from_stage: from_stage,
        to_stage: to_stage,
        old_path: Keyword.get(opts, :old_path),
        new_path: Keyword.get(opts, :new_path)
      },
      opts
    )
  end

  @doc """
  Emit when an item reaches a terminal stage.
  """
  @spec emit_item_completed(map() | struct(), atom(), keyword()) :: :ok | {:error, term()}
  def emit_item_completed(item, terminal_stage, opts \\ []) do
    emit(
      :item_completed,
      %{
        item_id: get_item_id(item),
        title: Map.get(item, :title),
        terminal_stage: terminal_stage,
        duration_ms: Keyword.get(opts, :duration_ms)
      },
      opts
    )
  end

  # =============================================================================
  # Processing Events
  # =============================================================================

  @doc """
  Emit when a processor starts working on an item.
  """
  @spec emit_processing_started(map() | struct(), atom(), keyword()) :: :ok | {:error, term()}
  def emit_processing_started(item, processor, opts \\ []) do
    emit(
      :processing_started,
      %{
        item_id: get_item_id(item),
        title: Map.get(item, :title),
        processor: processor,
        complexity_tier: Keyword.get(opts, :complexity_tier)
      },
      opts
    )
  end

  @doc """
  Emit when a processor completes an item.
  """
  @spec emit_processing_completed(map() | struct(), atom(), term(), keyword()) ::
          :ok | {:error, term()}
  def emit_processing_completed(item, processor, result, opts \\ []) do
    emit(
      :processing_completed,
      %{
        item_id: get_item_id(item),
        title: Map.get(item, :title),
        processor: processor,
        result: summarize_result(result),
        duration_ms: Keyword.get(opts, :duration_ms)
      },
      opts
    )
  end

  @doc """
  Emit when a processor fails on an item.
  """
  @spec emit_processing_failed(map() | struct(), atom(), term(), keyword()) ::
          :ok | {:error, term()}
  def emit_processing_failed(item, processor, error, opts \\ []) do
    emit(
      :processing_failed,
      %{
        item_id: get_item_id(item),
        title: Map.get(item, :title),
        processor: processor,
        error: inspect(error),
        retryable: Keyword.get(opts, :retryable, true)
      },
      opts
    )
  end

  # =============================================================================
  # Consensus Events
  # =============================================================================

  @doc """
  Emit when the Deliberator requests a council decision.
  """
  @spec emit_decision_requested(map() | struct(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def emit_decision_requested(item, proposal_id, opts \\ []) do
    emit(
      :decision_requested,
      %{
        item_id: get_item_id(item),
        title: Map.get(item, :title),
        proposal_id: proposal_id,
        attempt: Keyword.get(opts, :attempt, 1)
      },
      opts
    )
  end

  @doc """
  Emit when the council renders a decision.
  """
  @spec emit_decision_rendered(String.t(), atom(), map(), keyword()) :: :ok | {:error, term()}
  def emit_decision_rendered(proposal_id, verdict, decision_summary, opts \\ []) do
    emit(
      :decision_rendered,
      %{
        proposal_id: proposal_id,
        verdict: verdict,
        approval_count: Map.get(decision_summary, :approval_count),
        rejection_count: Map.get(decision_summary, :rejection_count),
        abstain_count: Map.get(decision_summary, :abstain_count)
      },
      opts
    )
  end

  @doc """
  Emit when a decision is documented to .arbor/decisions/.
  """
  @spec emit_decision_documented(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def emit_decision_documented(proposal_id, decision_path, opts \\ []) do
    emit(
      :decision_documented,
      %{
        proposal_id: proposal_id,
        decision_path: decision_path
      },
      opts
    )
  end

  # =============================================================================
  # Session Lifecycle Events
  # =============================================================================

  @doc """
  Emit when an auto session is spawned for a work item.
  """
  @spec emit_session_spawned(map() | struct(), String.t(), atom(), keyword()) ::
          :ok | {:error, term()}
  def emit_session_spawned(item, session_id, execution_mode, opts \\ []) do
    emit(
      :session_spawned,
      %{
        item_id: get_item_id(item),
        title: Map.get(item, :title),
        path: Map.get(item, :path),
        session_id: session_id,
        execution_mode: execution_mode
      },
      opts
    )
  end

  @doc """
  Emit when a session completes successfully.
  """
  @spec emit_session_completed(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def emit_session_completed(item_path, session_id, opts \\ []) do
    emit(
      :session_completed,
      %{
        item_path: item_path,
        session_id: session_id
      },
      opts
    )
  end

  @doc """
  Emit when a session fails (tests didn't pass, errors, etc.).
  """
  @spec emit_session_failed(String.t(), String.t(), atom(), keyword()) :: :ok | {:error, term()}
  def emit_session_failed(item_path, session_id, reason, opts \\ []) do
    emit(
      :session_failed,
      %{
        item_path: item_path,
        session_id: session_id,
        reason: reason
      },
      opts
    )
  end

  @doc """
  Emit when a session is blocked (hit max_turns).
  """
  @spec emit_session_blocked(String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def emit_session_blocked(item_path, session_id, reason, opts \\ []) do
    emit(
      :session_blocked,
      %{
        item_path: item_path,
        session_id: session_id,
        reason: reason
      },
      opts
    )
  end

  @doc """
  Emit when a session is interrupted by user.
  """
  @spec emit_session_interrupted(String.t(), String.t(), map(), keyword()) ::
          :ok | {:error, term()}
  def emit_session_interrupted(item_path, session_id, metadata, opts \\ []) do
    emit(
      :session_interrupted,
      %{
        item_path: item_path,
        session_id: session_id,
        metadata: metadata
      },
      opts
    )
  end

  # =============================================================================
  # System Events
  # =============================================================================

  @doc """
  Emit when the file watcher starts.
  """
  @spec emit_watcher_started([String.t()], keyword()) :: :ok | {:error, term()}
  def emit_watcher_started(directories, opts \\ []) do
    emit(
      :watcher_started,
      %{
        directories: directories,
        poll_interval: Keyword.get(opts, :poll_interval)
      },
      opts
    )
  end

  @doc """
  Emit when a periodic scan completes.
  """
  @spec emit_watcher_scan_completed(map(), keyword()) :: :ok | {:error, term()}
  def emit_watcher_scan_completed(stats, opts \\ []) do
    emit(
      :watcher_scan_completed,
      %{
        files_scanned: Map.get(stats, :files_scanned, 0),
        new_files: Map.get(stats, :new_files, 0),
        changed_files: Map.get(stats, :changed_files, 0),
        deleted_files: Map.get(stats, :deleted_files, 0)
      },
      opts
    )
  end

  @doc """
  Emit when the consistency checker completes.
  """
  @spec emit_consistency_check_completed(map(), keyword()) :: :ok | {:error, term()}
  def emit_consistency_check_completed(results, opts \\ []) do
    emit(
      :consistency_check_completed,
      %{
        checks_run: Map.get(results, :checks_run, []),
        issues_found: Map.get(results, :issues_found, 0),
        items_flagged: Map.get(results, :items_flagged, [])
      },
      opts
    )
  end

  # =============================================================================
  # Private Helpers
  # =============================================================================

  defp emit(type, data, opts) do
    if signals_available?() do
      Arbor.Signals.emit(@category, type, data, opts)
    else
      Logger.debug("SDLC signal (signals not available)",
        type: type,
        data: data
      )

      :ok
    end
  end

  defp signals_available? do
    Code.ensure_loaded?(Arbor.Signals) and
      function_exported?(Arbor.Signals, :healthy?, 0) and
      Arbor.Signals.healthy?()
  end

  defp get_item_id(%{id: id}) when is_binary(id), do: id
  defp get_item_id(%{path: path}) when is_binary(path), do: path
  defp get_item_id(_), do: nil

  defp summarize_result({:ok, :no_action}), do: "no_action"
  defp summarize_result({:ok, {:moved, stage}}), do: "moved_to_#{stage}"
  defp summarize_result({:ok, {:updated, _}}), do: "updated"

  defp summarize_result({:ok, {:moved_and_updated, stage, _}}),
    do: "moved_and_updated_to_#{stage}"

  defp summarize_result({:error, reason}), do: "error: #{inspect(reason)}"
  defp summarize_result(other), do: inspect(other)
end
