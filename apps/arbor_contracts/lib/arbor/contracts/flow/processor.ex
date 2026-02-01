defmodule Arbor.Contracts.Flow.Processor do
  @moduledoc """
  Behaviour for flow item processors.

  Processors are responsible for transforming items as they move through
  pipeline stages. Examples include expanders (inbox -> brainstorming),
  interviewers (brainstorming -> planned), and consistency checkers.

  ## Implementing a Processor

      defmodule MyProcessor do
        @behaviour Arbor.Contracts.Flow.Processor

        @impl true
        def processor_id, do: "my_processor"

        @impl true
        def can_handle?(%{category: :feature}), do: true
        def can_handle?(_item), do: false

        @impl true
        def process_item(item, opts) do
          # Process the item and return result
          {:ok, :no_action}
        end
      end

  ## Processing Results

  The `process_item/2` callback must return one of:

  - `{:ok, :no_action}` - Item processed but no stage transition
  - `{:ok, {:moved, new_stage}}` - Item should move to new_stage
  - `{:ok, {:updated, updated_item}}` - Item was modified in place
  - `{:ok, {:moved_and_updated, new_stage, updated_item}}` - Both moved and modified
  - `{:error, reason}` - Processing failed

  ## Options

  Processors receive options that may include:

  - `:dry_run` - If true, don't perform actual changes
  - `:context` - Map with additional context (e.g., session info)
  - Processor-specific options
  """

  alias Arbor.Contracts.Flow.Item

  @type processor_id :: String.t()
  @type stage :: atom()
  @type process_result ::
          {:ok, :no_action}
          | {:ok, {:moved, stage()}}
          | {:ok, {:updated, Item.t()}}
          | {:ok, {:moved_and_updated, stage(), Item.t()}}
          | {:error, term()}

  @type process_opts :: [
          dry_run: boolean(),
          context: map()
        ]

  @doc """
  Returns a unique identifier for this processor.

  This ID is used for tracking which processor has handled which items.
  """
  @callback processor_id() :: processor_id()

  @doc """
  Check if this processor can handle the given item.

  Implementations should check the item's stage, category, or other
  attributes to determine if they should process it.
  """
  @callback can_handle?(item :: Item.t() | map()) :: boolean()

  @doc """
  Process an item and return the result.

  The item passed may be an `Item.t()` struct or a plain map (for processors
  operating at the arbor_flow level before struct conversion).

  ## Return Values

  - `{:ok, :no_action}` - Processing complete, no stage change needed
  - `{:ok, {:moved, stage}}` - Item should be moved to the specified stage
  - `{:ok, {:updated, item}}` - Item was updated in place
  - `{:ok, {:moved_and_updated, stage, item}}` - Item updated and should move
  - `{:error, reason}` - Processing failed
  """
  @callback process_item(item :: Item.t() | map(), opts :: process_opts()) :: process_result()
end
