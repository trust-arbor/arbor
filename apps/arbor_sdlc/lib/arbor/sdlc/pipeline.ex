defmodule Arbor.SDLC.Pipeline do
  @moduledoc """
  SDLC-specific pipeline configuration.

  Implements the `Arbor.Contracts.Flow.Pipeline` behaviour with the standard
  SDLC stages and transition rules. This pipeline models the flow of work
  items from idea to completion:

  ```
  inbox -> brainstorming -> planned -> in_progress -> completed
                                  \\-> discarded
  ```

  ## Stages

  - `:inbox` - Raw ideas, bugs, features waiting to be expanded
  - `:brainstorming` - Expanded items being analyzed and decided on
  - `:planned` - Items approved and ready for implementation
  - `:in_progress` - Items currently being worked on
  - `:completed` - Finished items
  - `:discarded` - Items rejected by the council

  ## Usage

      # Check if a transition is valid
      true = Arbor.SDLC.Pipeline.transition_allowed?(:inbox, :brainstorming)
      false = Arbor.SDLC.Pipeline.transition_allowed?(:completed, :inbox)

      # Get directory for a stage
      "0-inbox" = Arbor.SDLC.Pipeline.stage_directory(:inbox)

      # Get stage from directory
      {:ok, :inbox} = Arbor.SDLC.Pipeline.directory_stage("0-inbox")
  """

  @behaviour Arbor.Contracts.Flow.Pipeline

  @stages [
    :inbox,
    :brainstorming,
    :planned,
    :in_progress,
    :completed,
    :discarded
  ]

  @directory_mapping %{
    inbox: "0-inbox",
    brainstorming: "1-brainstorming",
    planned: "2-planned",
    in_progress: "3-in-progress",
    completed: "5-completed",
    discarded: "8-discarded"
  }

  # Build reverse mapping at compile time
  @stage_mapping @directory_mapping
                 |> Enum.map(fn {stage, dir} -> {dir, stage} end)
                 |> Map.new()

  # Allowed transitions: {from, to}
  @transitions MapSet.new([
                 {:inbox, :brainstorming},
                 {:brainstorming, :planned},
                 {:brainstorming, :discarded},
                 {:planned, :in_progress},
                 {:planned, :discarded},
                 {:in_progress, :completed},
                 {:in_progress, :planned}
               ])

  # =============================================================================
  # Pipeline Behaviour Implementation
  # =============================================================================

  @impl Arbor.Contracts.Flow.Pipeline
  def stages, do: @stages

  @impl Arbor.Contracts.Flow.Pipeline
  def initial_stage, do: :inbox

  @impl Arbor.Contracts.Flow.Pipeline
  def terminal_stages, do: [:completed, :discarded]

  @impl Arbor.Contracts.Flow.Pipeline
  def transition_allowed?(from_stage, to_stage) do
    MapSet.member?(@transitions, {from_stage, to_stage})
  end

  @impl Arbor.Contracts.Flow.Pipeline
  def stage_directory(stage) when is_atom(stage) do
    Map.fetch!(@directory_mapping, stage)
  end

  @impl Arbor.Contracts.Flow.Pipeline
  def directory_stage(directory) when is_binary(directory) do
    case Map.fetch(@stage_mapping, directory) do
      {:ok, stage} -> {:ok, stage}
      :error -> :error
    end
  end

  # =============================================================================
  # SDLC-Specific Helpers
  # =============================================================================

  @doc """
  Get the full path for a stage within a roadmap root.

  ## Examples

      "/path/to/roadmap/0-inbox" = Pipeline.stage_path(:inbox, "/path/to/roadmap")
  """
  @spec stage_path(atom(), String.t()) :: String.t()
  def stage_path(stage, roadmap_root) when is_atom(stage) and is_binary(roadmap_root) do
    Path.join(roadmap_root, stage_directory(stage))
  end

  @doc """
  Get the directories that should be watched for the SDLC workflow.

  Returns directories for stages that have processors watching them:
  - inbox (Expander watches for new items)
  - brainstorming (Deliberator watches for items to analyze)

  ## Examples

      directories = Pipeline.watched_directories("/path/to/roadmap")
      ["/path/to/roadmap/0-inbox", "/path/to/roadmap/1-brainstorming"]
  """
  @spec watched_directories(String.t()) :: [String.t()]
  def watched_directories(roadmap_root) when is_binary(roadmap_root) do
    # Watch inbox and brainstorming - where processors operate
    [:inbox, :brainstorming]
    |> Enum.map(&stage_path(&1, roadmap_root))
  end

  @doc """
  Get all directory paths for all stages.

  ## Examples

      paths = Pipeline.all_stage_paths("/path/to/roadmap")
  """
  @spec all_stage_paths(String.t()) :: [String.t()]
  def all_stage_paths(roadmap_root) when is_binary(roadmap_root) do
    @stages
    |> Enum.map(&stage_path(&1, roadmap_root))
  end

  @doc """
  Determine the stage of an item from its file path.

  ## Examples

      {:ok, :inbox} = Pipeline.stage_from_path("/roadmap/0-inbox/feature.md")
      :error = Pipeline.stage_from_path("/some/other/path.md")
  """
  @spec stage_from_path(String.t()) :: {:ok, atom()} | :error
  def stage_from_path(path) when is_binary(path) do
    # Extract the directory name from the path
    path
    |> Path.dirname()
    |> Path.basename()
    |> directory_stage()
  end

  @doc """
  Get the next stage for automatic progression.

  Returns the next stage in the standard flow, if any.
  Terminal stages return nil.

  ## Examples

      {:ok, :brainstorming} = Pipeline.next_stage(:inbox)
      nil = Pipeline.next_stage(:completed)
  """
  @spec next_stage(atom()) :: {:ok, atom()} | nil
  def next_stage(:inbox), do: {:ok, :brainstorming}
  def next_stage(:brainstorming), do: {:ok, :planned}
  def next_stage(:planned), do: {:ok, :in_progress}
  def next_stage(:in_progress), do: {:ok, :completed}
  def next_stage(:completed), do: nil
  def next_stage(:discarded), do: nil
  def next_stage(_), do: nil

  @doc """
  Check if a stage is a processing stage (has a processor watching it).
  """
  @spec processing_stage?(atom()) :: boolean()
  def processing_stage?(:inbox), do: true
  def processing_stage?(:brainstorming), do: true
  def processing_stage?(_), do: false

  @doc """
  Get the directory mapping for all stages.

  Useful for initialization and validation.
  """
  @spec directory_mapping() :: map()
  def directory_mapping, do: @directory_mapping

  @doc """
  Ensure all stage directories exist under the given root.

  Creates missing directories.
  """
  @spec ensure_directories!(String.t()) :: :ok
  def ensure_directories!(roadmap_root) when is_binary(roadmap_root) do
    @stages
    |> Enum.each(fn stage ->
      path = stage_path(stage, roadmap_root)
      File.mkdir_p!(path)
    end)

    :ok
  end
end
