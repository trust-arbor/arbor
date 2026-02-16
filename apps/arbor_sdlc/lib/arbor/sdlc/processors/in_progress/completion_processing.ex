defmodule Arbor.SDLC.Processors.InProgress.CompletionProcessing do
  @moduledoc """
  Handles completion detection, test/quality verification, and result
  processing for in-progress work items.

  Extracted from `Arbor.SDLC.Processors.InProgress` to reduce module size.
  All functions were previously private in the parent module and are now
  public here for delegation.
  """

  require Logger

  alias Arbor.Contracts.Flow.Item
  alias Arbor.Flow.ItemParser
  alias Arbor.SDLC.{Config, Events, Pipeline, SessionRunner}
  alias Mix.Tasks.Arbor.HandsHelpers, as: Hands

  # =============================================================================
  # Completion Processing
  # =============================================================================

  def check_and_process_completion(item, config, _opts) do
    metadata = Map.get(item, :metadata, %{}) || %{}
    session_id = Map.get(metadata, :session_id, Map.get(metadata, "session_id"))

    cond do
      session_id == nil ->
        # No session, nothing to check
        {:ok, :no_session}

      hand_session?(session_id) ->
        # Check for Hand completion via summary.md
        check_hand_completion(item, session_id, config)

      true ->
        # Auto session - rely on signals
        {:ok, :awaiting_signal}
    end
  end

  def hand_session?(session_id) do
    String.starts_with?(session_id, "hand-")
  end

  def check_hand_completion(item, session_id, config) do
    # Extract hand name from session_id
    hand_name = String.replace_prefix(session_id, "hand-", "")

    if Hands.summary_exists?(hand_name) do
      Logger.info("Hand summary found, processing completion",
        hand_name: hand_name,
        item_path: item.path
      )

      case Hands.read_summary(hand_name) do
        {:ok, summary} ->
          do_process_completion(item.path, session_id, summary, config)

        {:error, reason} ->
          {:error, {:summary_read_failed, reason}}
      end
    else
      # Check if hand is still running
      case Hands.find_hand(hand_name) do
        :not_found ->
          # Hand stopped without summary
          Logger.warning("Hand stopped without summary", hand_name: hand_name)
          handle_session_error(item.path, :no_summary, config)

        _ ->
          # Hand still running
          {:ok, :still_running}
      end
    end
  end

  def do_process_completion(item_path, session_id, output, config) do
    Logger.info("Processing session completion",
      item_path: item_path,
      session_id: session_id
    )

    # Load the current item
    case File.read(item_path) do
      {:ok, content} ->
        item_map = ItemParser.parse(content)
        process_completed_item(item_map, item_path, session_id, output, config)

      {:error, :enoent} ->
        # Item may have been moved already
        Logger.warning("Item file not found", item_path: item_path)
        {:error, :item_not_found}

      {:error, reason} ->
        {:error, {:file_read_failed, reason}}
    end
  end

  def process_completed_item(item_map, item_path, session_id, output, config) do
    Events.emit_session_completed(item_path, session_id)

    # Run tests and quality checks
    test_result = run_tests(config)
    quality_result = run_quality_checks(config)

    case {test_result, quality_result} do
      {:ok, :ok} ->
        # Success! Move to completed
        move_to_completed(item_map, item_path, session_id, output, config)

      {test_result, quality_result} ->
        # Failure - move back to planned
        handle_test_failure(item_map, item_path, session_id, test_result, quality_result, config)
    end
  end

  def run_tests(config) do
    Logger.info("Running tests")

    timeout = Config.session_test_timeout()

    case Arbor.Shell.execute("mix test",
           cwd: config.roadmap_root,
           sandbox: :none,
           timeout: timeout
         ) do
      {:ok, %{exit_code: 0}} ->
        Logger.info("Tests passed")
        :ok

      {:ok, %{exit_code: code, stdout: output}} ->
        Logger.warning("Tests failed", exit_code: code)
        {:error, {:test_failed, code, String.slice(output, 0, 2000)}}

      {:error, reason} ->
        Logger.error("Test execution failed", error: inspect(reason))
        {:error, {:test_exception, inspect(reason)}}
    end
  end

  def run_quality_checks(config) do
    Logger.info("Running quality checks")

    case Arbor.Shell.execute("mix quality",
           cwd: config.roadmap_root,
           sandbox: :none,
           timeout: 120_000
         ) do
      {:ok, %{exit_code: 0}} ->
        Logger.info("Quality checks passed")
        :ok

      {:ok, %{exit_code: code, stdout: output}} ->
        Logger.warning("Quality checks failed", exit_code: code)
        {:error, {:quality_failed, code, String.slice(output, 0, 2000)}}

      {:error, reason} ->
        Logger.error("Quality check execution failed", error: inspect(reason))
        {:error, {:quality_exception, inspect(reason)}}
    end
  end

  def move_to_completed(item_map, item_path, _session_id, output, config) do
    Logger.info("Moving item to completed", item_path: item_path)

    # Update metadata
    metadata = Map.get(item_map, :metadata, %{}) || %{}

    updated_metadata =
      metadata
      |> Map.put("completed_at", DateTime.utc_now() |> DateTime.to_iso8601())
      |> Map.put("session_output_summary", String.slice(output, 0, 500))
      |> Map.delete("session_id")
      |> Map.delete("session_started_at")

    updated_item = Map.put(item_map, :metadata, updated_metadata)

    # Serialize and move
    content = ItemParser.serialize(updated_item)
    filename = Path.basename(item_path)
    dest_dir = Pipeline.stage_path(:completed, config.roadmap_root)
    dest_path = Path.join(dest_dir, filename)

    File.mkdir_p!(dest_dir)

    case File.write(dest_path, content) do
      :ok ->
        if item_path != dest_path and File.exists?(item_path) do
          File.rm(item_path)
        end

        Events.emit_item_moved(updated_item, :in_progress, :completed,
          old_path: item_path,
          new_path: dest_path
        )

        Events.emit_item_completed(updated_item, :completed)

        Logger.info("Item completed successfully",
          title: Map.get(item_map, :title),
          new_path: dest_path
        )

        {:ok, {:completed, dest_path}}

      {:error, reason} ->
        {:error, {:move_failed, reason}}
    end
  end

  def handle_test_failure(item_map, item_path, session_id, test_result, quality_result, config) do
    Logger.warning("Session completed but checks failed",
      item_path: item_path,
      test_result: inspect(test_result),
      quality_result: inspect(quality_result)
    )

    # Update metadata with failure info
    metadata = Map.get(item_map, :metadata, %{}) || %{}
    attempt = Map.get(metadata, :attempt, Map.get(metadata, "attempt", 1)) || 1

    failure_notes = build_failure_notes(test_result, quality_result)

    updated_metadata =
      metadata
      |> Map.put("last_failure", failure_notes)
      |> Map.put("last_failure_at", DateTime.utc_now() |> DateTime.to_iso8601())
      |> Map.delete("session_id")
      |> Map.delete("session_started_at")

    updated_item = Map.put(item_map, :metadata, updated_metadata)

    # Move back to planned
    content = ItemParser.serialize(updated_item)
    filename = Path.basename(item_path)
    dest_dir = Pipeline.stage_path(:planned, config.roadmap_root)
    dest_path = Path.join(dest_dir, filename)

    File.mkdir_p!(dest_dir)

    case File.write(dest_path, content) do
      :ok ->
        if item_path != dest_path and File.exists?(item_path) do
          File.rm(item_path)
        end

        Events.emit_item_moved(updated_item, :in_progress, :planned,
          old_path: item_path,
          new_path: dest_path
        )

        Events.emit_session_failed(item_path, session_id, :checks_failed)

        Logger.info("Item moved back to planned for retry",
          title: Map.get(item_map, :title),
          attempt: attempt
        )

        {:ok, {:retry, dest_path}}

      {:error, reason} ->
        {:error, {:move_failed, reason}}
    end
  end

  def build_failure_notes(test_result, quality_result) do
    parts = []

    parts =
      case test_result do
        {:error, {:test_failed, code, output}} ->
          ["Tests failed (exit #{code}): #{String.slice(output, 0, 500)}" | parts]

        {:error, reason} ->
          ["Tests error: #{inspect(reason)}" | parts]

        _ ->
          parts
      end

    parts =
      case quality_result do
        {:error, {:quality_failed, code, output}} ->
          ["Quality failed (exit #{code}): #{String.slice(output, 0, 500)}" | parts]

        {:error, reason} ->
          ["Quality error: #{inspect(reason)}" | parts]

        _ ->
          parts
      end

    Enum.join(parts, "\n")
  end

  # =============================================================================
  # Error and Special Case Handling
  # =============================================================================

  def handle_session_error(item_path, reason, _config) do
    Logger.warning("Handling session error",
      item_path: item_path,
      reason: inspect(reason)
    )

    case File.read(item_path) do
      {:ok, content} ->
        item_map = ItemParser.parse(content)
        metadata = Map.get(item_map, :metadata, %{}) || %{}

        updated_metadata =
          metadata
          |> Map.put("last_error", inspect(reason))
          |> Map.put("last_error_at", DateTime.utc_now() |> DateTime.to_iso8601())
          |> Map.delete("session_id")
          |> Map.delete("session_started_at")

        updated_item = Map.put(item_map, :metadata, updated_metadata)

        # Stay in place but update file
        content = ItemParser.serialize(updated_item)
        File.write!(item_path, content)

        {:ok, :error_recorded}

      {:error, _} ->
        {:error, :item_not_found}
    end
  end

  def handle_blocked_session(item_path, session_id, _config) do
    Logger.warning("Session blocked (max_turns reached)",
      item_path: item_path,
      session_id: session_id
    )

    case File.read(item_path) do
      {:ok, content} ->
        item_map = ItemParser.parse(content)
        metadata = Map.get(item_map, :metadata, %{}) || %{}

        updated_metadata =
          metadata
          |> Map.put("blocked", true)
          |> Map.put("blocked_at", DateTime.utc_now() |> DateTime.to_iso8601())
          |> Map.put("blocked_reason", "max_turns_reached")

        updated_item = Map.put(item_map, :metadata, updated_metadata)

        # Write updated item (stays in in_progress)
        content = ItemParser.serialize(updated_item)
        File.write!(item_path, content)

        Events.emit_session_blocked(item_path, session_id, "max_turns")

        {:ok, :blocked}

      {:error, _} ->
        {:error, :item_not_found}
    end
  end

  def handle_interrupted_session(item_path, session_id, metadata, config) do
    Logger.info("Session interrupted",
      item_path: item_path,
      session_id: session_id
    )

    # Emit the interrupted event
    Events.emit_session_interrupted(item_path, session_id, metadata)

    # Route to comms for human input
    route_to_comms(item_path, session_id, config)

    {:ok, :interrupted}
  end

  def route_to_comms(item_path, session_id, _config) do
    # Generate a correlation ID for tracking the response
    correlation_id = "sdlc-resume-#{session_id}-#{System.system_time(:millisecond)}"

    item_name = Path.basename(item_path, ".md")
    message = build_interrupt_message(item_name, session_id, item_path)
    recipient = Application.get_env(:arbor_sdlc, :comms_recipient, nil)

    do_route_to_comms(recipient, message, session_id, correlation_id, item_path)
  end

  def build_interrupt_message(item_name, session_id, item_path) do
    """
    SDLC session interrupted for work item: #{item_name}

    Session ID: #{session_id}
    Item path: #{item_path}

    The session was interrupted and may need your input to continue.
    Reply to this message to resume the session with your guidance.
    """
  end

  def do_route_to_comms(nil, _message, _session_id, _correlation_id, _item_path) do
    Logger.debug("No comms recipient configured, skipping comms routing")
  end

  def do_route_to_comms(recipient, message, session_id, correlation_id, item_path) do
    comms_available? =
      Code.ensure_loaded?(Arbor.Comms) and
        function_exported?(Arbor.Comms, :send_signal, 2)

    if comms_available? do
      send_via_comms(recipient, message, session_id, correlation_id, item_path)
    else
      Logger.debug("Comms not available, skipping comms routing")
    end
  end

  def send_via_comms(recipient, message, session_id, correlation_id, item_path) do
    # Use Kernel.apply to explicitly indicate dynamic call
    case Kernel.apply(Arbor.Comms, :send_signal, [recipient, message]) do
      :ok ->
        Logger.info("Routed interrupted session to comms",
          session_id: session_id,
          correlation_id: correlation_id
        )

        GenServer.cast(self(), {:await_comms_response, correlation_id, item_path, session_id})

      {:error, reason} ->
        Logger.warning("Failed to route to comms",
          session_id: session_id,
          reason: inspect(reason)
        )
    end
  end

  def resume_session(item_path, session_id, response, config) do
    Logger.info("Resuming session with human input",
      item_path: item_path,
      session_id: session_id
    )

    # Build resume prompt with the human's response
    prompt = """
    Previous session was interrupted. Human provided the following guidance:

    #{response}

    Please continue working on the task.
    """

    # Resume using SessionRunner
    runner_opts = [
      item_path: item_path,
      prompt: prompt,
      parent: self(),
      execution_mode: :auto,
      config: config,
      working_dir: config.roadmap_root,
      resume_session_id: session_id
    ]

    case SessionRunner.start_link(runner_opts) do
      {:ok, _runner_pid} ->
        Logger.info("Session resume initiated", session_id: session_id)

      {:error, reason} ->
        Logger.error("Failed to resume session",
          session_id: session_id,
          reason: inspect(reason)
        )
    end
  end

  @doc """
  Serialize an item back to markdown.
  """
  @spec serialize_item(Item.t()) :: String.t()
  def serialize_item(%Item{} = item) do
    item
    |> Map.from_struct()
    |> ItemParser.serialize()
  end
end
