defmodule Arbor.SDLC.TestHelpers do
  @moduledoc """
  Test helpers for arbor_sdlc tests.
  """

  alias Arbor.Consensus.{Coordinator, EvaluatorAgent, EventStore, TopicRegistry}
  alias Arbor.Persistence.Store.ETS, as: ETSStore
  alias Arbor.SDLC.{Config, PersistentFileTracker, Pipeline}

  @doc """
  Creates a temporary directory structure for testing.

  Returns the path to the temporary roadmap root.
  """
  def setup_test_roadmap(context \\ %{}) do
    # Create a unique temp directory
    test_id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    temp_root = Path.join(System.tmp_dir!(), "arbor_sdlc_test_#{test_id}")

    # Create all stage directories
    Pipeline.ensure_directories!(temp_root)

    # Store in context for cleanup
    Map.put(context, :temp_roadmap_root, temp_root)
  end

  @doc """
  Cleans up the temporary test directory.
  """
  def cleanup_test_roadmap(%{temp_roadmap_root: root}) do
    File.rm_rf!(root)
    :ok
  end

  def cleanup_test_roadmap(_), do: :ok

  @doc """
  Creates a test item file in the specified stage.
  """
  def create_test_item(roadmap_root, stage, filename, content) do
    dir = Pipeline.stage_path(stage, roadmap_root)
    path = Path.join(dir, filename)
    File.write!(path, content)
    path
  end

  @doc """
  Returns sample markdown content for a simple item.
  """
  def simple_item_content(title \\ "Test Item") do
    """
    # #{title}

    **Created:** 2026-02-01
    **Priority:** medium
    **Category:** feature

    ## Summary

    A test item for testing purposes.
    """
  end

  @doc """
  Returns sample markdown content for a fully expanded item.
  """
  def expanded_item_content(title \\ "Expanded Test Item") do
    """
    # #{title}

    **Created:** 2026-02-01
    **Priority:** high
    **Category:** feature

    ## Summary

    A fully expanded test item.

    ## Why It Matters

    Testing is important for quality.

    ## Acceptance Criteria

    - [ ] First criterion
    - [ ] Second criterion

    ## Definition of Done

    - [ ] Tests pass
    - [ ] Code reviewed
    """
  end

  @doc """
  Ensures the consensus infrastructure is running for Deliberator tests.

  Starts a uniquely-named EventStore and Coordinator with SDLC-specific
  perspectives/quorum config. Uses unique names to avoid conflicts with
  the global processes started by the consensus app's test_helper.

  Also sets the SDLC AI module and consensus_server in app config so
  `Config.new()` picks them up. Returns the previous AI module value
  for restoration.
  """
  def ensure_consensus_started do
    stop_consensus_children()
    start_consensus_services()

    # Disable LLM topic classification for tests (avoid CLI calls)
    Application.put_env(:arbor_consensus, :llm_topic_classification_enabled, false)

    prev_ai = Application.get_env(:arbor_sdlc, :ai_module)
    Application.put_env(:arbor_sdlc, :ai_module, EvaluatorMockAI.StandardApprove)
    prev_ai
  end

  defp stop_consensus_children do
    supervisor = Arbor.Consensus.Supervisor

    # Remove existing supervised children so we can restart with SDLC config.
    # The consensus test_helper.exs adds these as supervisor children, so
    # GenServer.stop would trigger a supervisor restart with default config.
    children_to_stop = [
      Coordinator,
      EventStore,
      EvaluatorAgent.Supervisor,
      TopicRegistry
    ]

    for child_id <- children_to_stop do
      case Supervisor.terminate_child(supervisor, child_id) do
        :ok -> Supervisor.delete_child(supervisor, child_id)
        {:error, :not_found} -> :ok
      end
    end

    # Also stop any non-supervised instances (e.g. from a previous test run)
    stop_if_alive(Coordinator)
    stop_if_alive(EventStore)
    stop_if_alive(EvaluatorAgent.Supervisor)
    stop_if_alive(TopicRegistry)
  end

  defp start_consensus_services do
    # Start fresh with SDLC-specific config
    {:ok, _} = EventStore.start_link([])

    # Start TopicRegistry (required by Coordinator)
    case TopicRegistry.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # Start EvaluatorAgent.Supervisor (required by Coordinator)
    case EvaluatorAgent.Supervisor.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # Ensure Shell.ExecutionRegistry is available for TopicMatcher LLM classification
    case Supervisor.start_child(
           Arbor.Shell.Supervisor,
           {Arbor.Shell.ExecutionRegistry, []}
         ) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, _} -> :ok
    end

    {:ok, _} = Coordinator.start_link([])
  end

  defp stop_if_alive(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 5000)
    end
  catch
    :exit, _ -> :ok
  end

  @doc """
  Restores the SDLC AI module to its previous value.
  """
  def restore_ai_module(nil), do: Application.delete_env(:arbor_sdlc, :ai_module)
  def restore_ai_module(prev), do: Application.put_env(:arbor_sdlc, :ai_module, prev)

  @doc """
  Starts a test file tracker with ETS backend.

  Uses fixed atom names to avoid atom exhaustion in tests.
  """
  def start_test_tracker(name \\ :test_sdlc_tracker) do
    config = %Config{
      persistence_backend: ETSStore,
      persistence_name: name
    }

    # Start the ETS store first
    {:ok, _store} = ETSStore.start_link(name: name)

    # Use fixed atom name for tracker
    tracker_name = :test_sdlc_tracker_tracker

    # Start the tracker
    {:ok, tracker} =
      PersistentFileTracker.start_link(
        name: tracker_name,
        config: config
      )

    {tracker, name}
  end

  @doc """
  Stops test processes.
  """
  def stop_test_processes({tracker, store_name}) do
    if Process.alive?(tracker), do: GenServer.stop(tracker)

    case Process.whereis(store_name) do
      pid when is_pid(pid) -> GenServer.stop(pid)
      _ -> :ok
    end

    :ok
  end
end
