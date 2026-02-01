defmodule Arbor.SDLC.TestHelpers do
  @moduledoc """
  Test helpers for arbor_sdlc tests.
  """

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
