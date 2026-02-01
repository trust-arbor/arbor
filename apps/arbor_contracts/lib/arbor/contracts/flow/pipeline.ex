defmodule Arbor.Contracts.Flow.Pipeline do
  @moduledoc """
  Behaviour and types for workflow pipelines.

  A pipeline defines the stages items flow through and the valid
  transitions between stages. Implementations can customize stages
  and transition rules.

  ## Default SDLC Pipeline

  The standard SDLC pipeline has these stages:

  ```
  inbox -> brainstorming -> planned -> in_progress -> completed
                                 \\-> discarded
  ```

  ## Custom Pipelines

  Implementations can define custom stages and transitions:

      defmodule MyPipeline do
        @behaviour Arbor.Contracts.Flow.Pipeline

        @impl true
        def stages do
          [:draft, :review, :approved, :published]
        end

        @impl true
        def initial_stage, do: :draft

        @impl true
        def terminal_stages, do: [:published]

        @impl true
        def transition_allowed?(:draft, :review), do: true
        def transition_allowed?(:review, :approved), do: true
        def transition_allowed?(:review, :draft), do: true  # reject
        def transition_allowed?(:approved, :published), do: true
        def transition_allowed?(_, _), do: false

        @impl true
        def stage_directory(:draft), do: "0-drafts"
        def stage_directory(:review), do: "1-review"
        def stage_directory(:approved), do: "2-approved"
        def stage_directory(:published), do: "3-published"
      end

  """

  @type stage :: atom()
  @type transition_result :: :ok | {:error, :invalid_transition | :unknown_stage}

  @doc """
  Returns the ordered list of stages in this pipeline.
  """
  @callback stages() :: [stage()]

  @doc """
  Returns the initial stage for new items.
  """
  @callback initial_stage() :: stage()

  @doc """
  Returns the list of terminal stages (no further transitions).
  """
  @callback terminal_stages() :: [stage()]

  @doc """
  Check if a transition from one stage to another is allowed.

  This defines the valid edges in the pipeline DAG.
  """
  @callback transition_allowed?(from_stage :: stage(), to_stage :: stage()) :: boolean()

  @doc """
  Get the directory name for a stage.

  Returns the subdirectory name used for items in this stage
  (e.g., "0-inbox", "1-brainstorming").
  """
  @callback stage_directory(stage :: stage()) :: String.t()

  @doc """
  Get the stage for a given directory name.

  Inverse of `stage_directory/1`. Returns `{:ok, stage}` or `:error`.
  """
  @callback directory_stage(directory :: String.t()) :: {:ok, stage()} | :error

  @optional_callbacks [directory_stage: 1]

  # Helper functions for working with pipelines

  @doc """
  Check if a stage is valid for the given pipeline module.
  """
  @spec valid_stage?(module(), stage()) :: boolean()
  def valid_stage?(pipeline_module, stage) do
    stage in pipeline_module.stages()
  end

  @doc """
  Check if a stage is a terminal stage.
  """
  @spec terminal?(module(), stage()) :: boolean()
  def terminal?(pipeline_module, stage) do
    stage in pipeline_module.terminal_stages()
  end

  @doc """
  Validate a transition and return :ok or an error.
  """
  @spec validate_transition(module(), stage(), stage()) :: transition_result()
  def validate_transition(pipeline_module, from_stage, to_stage) do
    cond do
      not valid_stage?(pipeline_module, from_stage) ->
        {:error, :unknown_stage}

      not valid_stage?(pipeline_module, to_stage) ->
        {:error, :unknown_stage}

      not pipeline_module.transition_allowed?(from_stage, to_stage) ->
        {:error, :invalid_transition}

      true ->
        :ok
    end
  end

  @doc """
  Get all valid next stages from a given stage.
  """
  @spec valid_next_stages(module(), stage()) :: [stage()]
  def valid_next_stages(pipeline_module, from_stage) do
    pipeline_module.stages()
    |> Enum.filter(fn to_stage ->
      pipeline_module.transition_allowed?(from_stage, to_stage)
    end)
  end
end
