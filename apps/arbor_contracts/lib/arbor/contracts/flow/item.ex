defmodule Arbor.Contracts.Flow.Item do
  @moduledoc """
  Shared data type for workflow items.

  This struct represents a work item that flows through pipeline stages.
  It is the canonical representation used across libraries that process
  workflow items (arbor_flow, arbor_sdlc, etc.).

  ## Fields

  - `:id` - Unique identifier for the item (auto-generated if not provided)
  - `:title` - Human-readable title (required)
  - `:priority` - Item priority (:critical, :high, :medium, :low, :someday)
  - `:category` - Item category (:feature, :bug, :refactor, etc.)
  - `:summary` - Brief description of the item
  - `:why_it_matters` - Explanation of importance
  - `:acceptance_criteria` - List of criteria that must be met
  - `:definition_of_done` - List of completion checklist items
  - `:depends_on` - List of item IDs this item depends on (DAG support)
  - `:blocks` - List of item IDs blocked by this item (inverse of depends_on)
  - `:related_files` - List of related file paths
  - `:content_hash` - Hash of the raw content for change detection
  - `:created_at` - When the item was created
  - `:path` - File path if loaded from filesystem
  - `:raw_content` - Original markdown content
  - `:notes` - Free-form notes section
  - `:metadata` - Additional metadata map

  ## Usage

      {:ok, item} = Item.new(title: "Implement feature X")

  """

  use TypedStruct

  @type priority :: :critical | :high | :medium | :low | :someday
  @type category ::
          :feature
          | :refactor
          | :bug
          | :infrastructure
          | :idea
          | :research
          | :documentation
          | :content
  @type effort :: :small | :medium | :large | :ongoing
  @type criterion :: %{text: String.t(), completed: boolean()}

  @derive Jason.Encoder
  typedstruct enforce: true do
    @typedoc "A workflow item that flows through pipeline stages"

    field(:id, String.t())
    field(:title, String.t())
    field(:priority, priority(), enforce: false)
    field(:category, category(), enforce: false)
    field(:type, String.t(), enforce: false)
    field(:effort, effort(), enforce: false)
    field(:summary, String.t(), enforce: false)
    field(:why_it_matters, String.t(), enforce: false)
    field(:acceptance_criteria, [criterion()], default: [])
    field(:definition_of_done, [criterion()], default: [])
    field(:depends_on, [String.t()], default: [])
    field(:blocks, [String.t()], default: [])
    field(:related_files, [String.t()], default: [])
    field(:content_hash, String.t(), enforce: false)
    field(:created_at, Date.t(), enforce: false)
    field(:path, String.t(), enforce: false)
    field(:raw_content, String.t(), enforce: false)
    field(:notes, String.t(), enforce: false)
    field(:metadata, map(), default: %{})
  end

  @valid_priorities [:critical, :high, :medium, :low, :someday]
  @valid_categories [
    :feature,
    :refactor,
    :bug,
    :infrastructure,
    :idea,
    :research,
    :documentation,
    :content
  ]

  @valid_efforts [:small, :medium, :large, :ongoing]

  @doc """
  Create a new Item with validation.

  ## Options

  - `:title` (required) - Human-readable title
  - `:id` - Unique identifier (auto-generated if not provided)
  - `:priority` - One of #{inspect(@valid_priorities)}
  - `:category` - One of #{inspect(@valid_categories)}
  - `:summary` - Brief description
  - `:why_it_matters` - Explanation of importance
  - `:acceptance_criteria` - List of criteria maps with :text and :completed keys
  - `:definition_of_done` - List of done criteria maps
  - `:depends_on` - List of item IDs this depends on
  - `:blocks` - List of item IDs blocked by this item
  - `:related_files` - List of related file paths
  - `:content_hash` - Hash of raw content
  - `:created_at` - Date created
  - `:path` - File path
  - `:raw_content` - Original markdown
  - `:notes` - Free-form notes
  - `:metadata` - Additional metadata

  ## Examples

      {:ok, item} = Item.new(title: "Implement user auth")

      {:ok, item} = Item.new(
        title: "Fix login bug",
        priority: :high,
        category: :bug,
        acceptance_criteria: [%{text: "Login works", completed: false}]
      )
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    item = build_struct(attrs)

    case validate(item) do
      :ok -> {:ok, item}
      {:error, _} = error -> error
    end
  end

  @doc """
  Create a new Item, raising on validation errors.
  """
  @spec new!(keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, item} -> item
      {:error, reason} -> raise ArgumentError, "Invalid item: #{inspect(reason)}"
    end
  end

  @doc """
  Compute the content hash for a string.

  Uses SHA-256 truncated to 16 hex characters for change detection.
  """
  @spec compute_hash(String.t()) :: String.t()
  def compute_hash(content) when is_binary(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  @doc """
  Check if the content has changed by comparing hashes.
  """
  @spec content_changed?(t(), String.t()) :: boolean()
  def content_changed?(%__MODULE__{content_hash: nil}, _content), do: true
  def content_changed?(%__MODULE__{content_hash: ""}, _content), do: true

  def content_changed?(%__MODULE__{content_hash: stored_hash}, content) do
    compute_hash(content) != stored_hash
  end

  @doc """
  Check if all acceptance criteria are completed.
  """
  @spec all_criteria_completed?(t()) :: boolean()
  def all_criteria_completed?(%__MODULE__{acceptance_criteria: []}) do
    true
  end

  def all_criteria_completed?(%__MODULE__{acceptance_criteria: criteria}) do
    Enum.all?(criteria, &Map.get(&1, :completed, false))
  end

  @doc """
  Check if all definition of done items are completed.
  """
  @spec all_done_completed?(t()) :: boolean()
  def all_done_completed?(%__MODULE__{definition_of_done: []}) do
    true
  end

  def all_done_completed?(%__MODULE__{definition_of_done: items}) do
    Enum.all?(items, &Map.get(&1, :completed, false))
  end

  @doc """
  Get the valid priority values.
  """
  @spec valid_priorities() :: [priority()]
  def valid_priorities, do: @valid_priorities

  @doc """
  Get the valid category values.
  """
  @spec valid_categories() :: [category()]
  def valid_categories, do: @valid_categories

  @doc """
  Check if a priority value is valid.
  """
  @spec valid_priority?(term()) :: boolean()
  def valid_priority?(priority) when priority in @valid_priorities, do: true
  def valid_priority?(_), do: false

  @doc """
  Check if a category value is valid.
  """
  @spec valid_category?(term()) :: boolean()
  def valid_category?(category) when category in @valid_categories, do: true
  def valid_category?(_), do: false

  # Private functions

  defp build_struct(attrs) do
    %__MODULE__{
      id: attrs[:id] || generate_id(),
      title: Keyword.fetch!(attrs, :title),
      priority: attrs[:priority],
      category: attrs[:category],
      type: attrs[:type],
      effort: attrs[:effort],
      summary: attrs[:summary],
      why_it_matters: attrs[:why_it_matters],
      acceptance_criteria: attrs[:acceptance_criteria] || [],
      definition_of_done: attrs[:definition_of_done] || [],
      depends_on: attrs[:depends_on] || [],
      blocks: attrs[:blocks] || [],
      related_files: attrs[:related_files] || [],
      content_hash: attrs[:content_hash],
      created_at: attrs[:created_at],
      path: attrs[:path],
      raw_content: attrs[:raw_content],
      notes: attrs[:notes],
      metadata: attrs[:metadata] || %{}
    }
  end

  defp generate_id do
    "item_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp validate(%__MODULE__{} = item) do
    validators = [
      &validate_title/1,
      &validate_priority/1,
      &validate_category/1,
      &validate_effort/1,
      &validate_criteria/1
    ]

    Enum.reduce_while(validators, :ok, fn validator, :ok ->
      case validator.(item) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_title(%{title: title}) when is_binary(title) and byte_size(title) > 0 do
    :ok
  end

  defp validate_title(%{title: title}) do
    {:error, {:invalid_title, title}}
  end

  defp validate_priority(%{priority: nil}), do: :ok

  defp validate_priority(%{priority: priority}) when priority in @valid_priorities do
    :ok
  end

  defp validate_priority(%{priority: priority}) do
    {:error, {:invalid_priority, priority}}
  end

  defp validate_category(%{category: nil}), do: :ok

  defp validate_category(%{category: category}) when category in @valid_categories do
    :ok
  end

  defp validate_category(%{category: category}) do
    {:error, {:invalid_category, category}}
  end

  defp validate_effort(%{effort: nil}), do: :ok

  defp validate_effort(%{effort: effort}) when effort in @valid_efforts do
    :ok
  end

  defp validate_effort(%{effort: effort}) do
    {:error, {:invalid_effort, effort}}
  end

  defp validate_criteria(%{acceptance_criteria: criteria, definition_of_done: done}) do
    case validate_criterion_list(criteria) do
      :ok -> validate_criterion_list(done)
      error -> error
    end
  end

  defp validate_criterion_list(criteria) when is_list(criteria) do
    if Enum.all?(criteria, &valid_criterion?/1) do
      :ok
    else
      {:error, {:invalid_criteria_format, criteria}}
    end
  end

  defp validate_criterion_list(criteria) do
    {:error, {:invalid_criteria_format, criteria}}
  end

  defp valid_criterion?(%{text: text, completed: completed})
       when is_binary(text) and is_boolean(completed) do
    true
  end

  defp valid_criterion?(_), do: false
end
