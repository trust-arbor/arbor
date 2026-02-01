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

  ## Runtime Configuration

  Pipeline stages, directories, and transitions can be configured at runtime
  via application environment:

      config :arbor_sdlc,
        pipeline: %{
          stages: [:inbox, :brainstorming, :planned, :in_progress, :completed, :discarded],
          directories: %{
            inbox: "0-inbox",
            brainstorming: "1-brainstorming",
            # ... other mappings
          },
          transitions: [
            {:inbox, :brainstorming},
            {:brainstorming, :planned},
            # ... other transitions
          ],
          processing_stages: [:inbox, :brainstorming]
        }

  If no configuration is provided, the standard SDLC pipeline is used.

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

  # Default compile-time values (used when no runtime config provided)
  @default_stages [
    :inbox,
    :brainstorming,
    :planned,
    :in_progress,
    :completed,
    :discarded
  ]

  @default_directory_mapping %{
    inbox: "0-inbox",
    brainstorming: "1-brainstorming",
    planned: "2-planned",
    in_progress: "3-in-progress",
    completed: "5-completed",
    discarded: "8-discarded"
  }

  @default_transitions [
    {:inbox, :brainstorming},
    {:brainstorming, :planned},
    {:brainstorming, :discarded},
    {:planned, :in_progress},
    {:planned, :discarded},
    {:in_progress, :completed},
    {:in_progress, :planned}
  ]

  @default_processing_stages [:inbox, :brainstorming]

  # =============================================================================
  # Runtime Configuration Accessors
  # =============================================================================

  @doc """
  Get the pipeline configuration.

  Returns a map with :stages, :directories, :transitions, and :processing_stages.
  If runtime configuration is not set, returns the default values.
  """
  @spec config() :: map()
  def config do
    case Application.get_env(:arbor_sdlc, :pipeline) do
      nil ->
        %{
          stages: @default_stages,
          directories: @default_directory_mapping,
          transitions: MapSet.new(@default_transitions),
          processing_stages: @default_processing_stages
        }

      pipeline_config when is_map(pipeline_config) ->
        %{
          stages: Map.get(pipeline_config, :stages, @default_stages),
          directories: Map.get(pipeline_config, :directories, @default_directory_mapping),
          transitions:
            pipeline_config
            |> Map.get(:transitions, @default_transitions)
            |> MapSet.new(),
          processing_stages:
            Map.get(pipeline_config, :processing_stages, @default_processing_stages)
        }
    end
  end

  @doc """
  Reset the pipeline configuration to defaults.

  Useful for testing.
  """
  @spec reset_config() :: :ok
  def reset_config do
    Application.delete_env(:arbor_sdlc, :pipeline)
    :ok
  end

  @doc """
  Update the pipeline configuration at runtime.

  Accepts a map with any of:
  - `:stages` - List of stage atoms in order
  - `:directories` - Map of stage atoms to directory strings
  - `:transitions` - List of {from, to} tuples
  - `:processing_stages` - List of stages that have processors

  ## Examples

      Pipeline.configure(%{
        stages: [:draft, :review, :published],
        directories: %{draft: "drafts", review: "review", published: "published"},
        transitions: [{:draft, :review}, {:review, :published}],
        processing_stages: [:draft, :review]
      })
  """
  @spec configure(map()) :: :ok
  def configure(new_config) when is_map(new_config) do
    current = Application.get_env(:arbor_sdlc, :pipeline, %{})
    merged = Map.merge(current, new_config)
    Application.put_env(:arbor_sdlc, :pipeline, merged)
    :ok
  end

  # =============================================================================
  # Pipeline Behaviour Implementation
  # =============================================================================

  @impl Arbor.Contracts.Flow.Pipeline
  def stages do
    config().stages
  end

  @impl Arbor.Contracts.Flow.Pipeline
  def initial_stage do
    List.first(stages())
  end

  @impl Arbor.Contracts.Flow.Pipeline
  def terminal_stages do
    # By convention, :completed and :discarded are terminal
    # This can be overridden in config if needed
    case Application.get_env(:arbor_sdlc, :pipeline) do
      %{terminal_stages: terminals} -> terminals
      _ -> [:completed, :discarded]
    end
  end

  @impl Arbor.Contracts.Flow.Pipeline
  def transition_allowed?(from_stage, to_stage) do
    MapSet.member?(config().transitions, {from_stage, to_stage})
  end

  @impl Arbor.Contracts.Flow.Pipeline
  def stage_directory(stage) when is_atom(stage) do
    case Map.fetch(config().directories, stage) do
      {:ok, directory} -> directory
      :error -> raise KeyError, key: stage, term: config().directories
    end
  end

  @impl Arbor.Contracts.Flow.Pipeline
  def directory_stage(directory) when is_binary(directory) do
    directories = config().directories

    # Build reverse mapping dynamically
    stage_mapping =
      directories
      |> Enum.map(fn {stage, dir} -> {dir, stage} end)
      |> Map.new()

    case Map.fetch(stage_mapping, directory) do
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

  Returns directories for stages that have processors watching them.
  By default, this is :inbox and :brainstorming.

  ## Examples

      directories = Pipeline.watched_directories("/path/to/roadmap")
      ["/path/to/roadmap/0-inbox", "/path/to/roadmap/1-brainstorming"]
  """
  @spec watched_directories(String.t()) :: [String.t()]
  def watched_directories(roadmap_root) when is_binary(roadmap_root) do
    config().processing_stages
    |> Enum.map(&stage_path(&1, roadmap_root))
  end

  @doc """
  Get all directory paths for all stages.

  ## Examples

      paths = Pipeline.all_stage_paths("/path/to/roadmap")
  """
  @spec all_stage_paths(String.t()) :: [String.t()]
  def all_stage_paths(roadmap_root) when is_binary(roadmap_root) do
    stages()
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
  def next_stage(stage) do
    if stage in terminal_stages() do
      nil
    else
      find_next_stage(stage, stages())
    end
  end

  defp find_next_stage(stage, all_stages) do
    stage_index = Enum.find_index(all_stages, &(&1 == stage))

    case get_next_non_terminal(stage_index, all_stages) do
      nil -> nil
      next -> {:ok, next}
    end
  end

  defp get_next_non_terminal(nil, _stages), do: nil

  defp get_next_non_terminal(index, stages) when index < length(stages) - 1 do
    next = Enum.at(stages, index + 1)
    # Skip :discarded if present (it's a branch, not part of the linear flow)
    # But :completed is valid as the normal end of the pipeline
    if next == :discarded, do: nil, else: next
  end

  defp get_next_non_terminal(_index, _stages), do: nil

  @doc """
  Check if a stage is a processing stage (has a processor watching it).
  """
  @spec processing_stage?(atom()) :: boolean()
  def processing_stage?(stage) do
    stage in config().processing_stages
  end

  @doc """
  Get the directory mapping for all stages.

  Useful for initialization and validation.
  """
  @spec directory_mapping() :: map()
  def directory_mapping, do: config().directories

  @doc """
  Ensure all stage directories exist under the given root.

  Creates missing directories.
  """
  @spec ensure_directories!(String.t()) :: :ok
  def ensure_directories!(roadmap_root) when is_binary(roadmap_root) do
    stages()
    |> Enum.each(fn stage ->
      path = stage_path(stage, roadmap_root)
      File.mkdir_p!(path)
    end)

    :ok
  end
end
