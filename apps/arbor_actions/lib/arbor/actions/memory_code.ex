defmodule Arbor.Actions.MemoryCode do
  @moduledoc """
  Code management actions for storing and retrieving learned code patterns.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `StoreCode` | Store a code pattern with language and purpose |
  | `ListCode` | List stored code patterns |
  | `DeleteCode` | Delete a code pattern |
  | `ViewCode` | View a specific code pattern by ID or search by purpose |
  """

  # ============================================================================
  # StoreCode
  # ============================================================================

  defmodule StoreCode do
    @moduledoc """
    Store a code pattern for later use.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `code` | string | yes | The code text |
    | `language` | string | yes | Programming language |
    | `purpose` | string | yes | Description of what the code does |
    """

    use Jido.Action,
      name: "memory_store_code",
      description:
        "Store a code pattern. Required: code, language, purpose.",
      category: "memory_code",
      tags: ["memory", "code", "store"],
      schema: [
        code: [type: :string, required: true, doc: "The code text"],
        language: [type: :string, required: true, doc: "Programming language"],
        purpose: [type: :string, required: true, doc: "Description of what the code does"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Memory, as: MemoryHelpers

    @spec taint_roles() :: %{atom() => :control | :data}
    def taint_roles do
      %{code: :data, language: :control, purpose: :data}
    end

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      with {:ok, agent_id} <- MemoryHelpers.extract_agent_id(context, params),
           :ok <- MemoryHelpers.ensure_memory(agent_id),
           {:ok, entry} <-
             Arbor.Memory.store_code(agent_id, %{
               code: params.code,
               language: params.language,
               purpose: params.purpose
             }) do
        Actions.emit_completed(__MODULE__, %{entry_id: entry.id})
        {:ok, %{entry_id: entry.id, language: params.language, stored: true}}
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end
  end

  # ============================================================================
  # ListCode
  # ============================================================================

  defmodule ListCode do
    @moduledoc """
    List stored code patterns.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `language` | string | no | Filter by programming language |
    | `limit` | integer | no | Maximum results |
    """

    use Jido.Action,
      name: "memory_list_code",
      description:
        "List stored code patterns. Optional: language filter, limit.",
      category: "memory_code",
      tags: ["memory", "code", "list"],
      schema: [
        language: [type: :string, doc: "Filter by programming language"],
        limit: [type: :non_neg_integer, doc: "Maximum results"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Memory, as: MemoryHelpers

    @spec taint_roles() :: %{atom() => :control | :data}
    def taint_roles do
      %{language: :data, limit: :data}
    end

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      with {:ok, agent_id} <- MemoryHelpers.extract_agent_id(context, params),
           :ok <- MemoryHelpers.ensure_memory(agent_id) do
        opts =
          []
          |> maybe_add(:language, params[:language])
          |> maybe_add(:limit, params[:limit])

        entries = Arbor.Memory.list_code(agent_id, opts)

        formatted =
          Enum.map(entries, fn e ->
            %{
              id: e.id,
              language: e.language,
              purpose: e.purpose,
              created_at: e.created_at
            }
          end)

        Actions.emit_completed(__MODULE__, %{count: length(formatted)})
        {:ok, %{entries: formatted, count: length(formatted)}}
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end

    defp maybe_add(opts, _key, nil), do: opts
    defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)
  end

  # ============================================================================
  # DeleteCode
  # ============================================================================

  defmodule DeleteCode do
    @moduledoc """
    Delete a stored code pattern.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `entry_id` | string | yes | Code entry ID to delete |
    """

    use Jido.Action,
      name: "memory_delete_code",
      description: "Delete a code pattern from storage. Required: entry_id.",
      category: "memory_code",
      tags: ["memory", "code", "delete"],
      schema: [
        entry_id: [type: :string, required: true, doc: "Code entry ID to delete"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Memory, as: MemoryHelpers

    @spec taint_roles() :: %{atom() => :control | :data}
    def taint_roles do
      %{entry_id: :data}
    end

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      with {:ok, agent_id} <- MemoryHelpers.extract_agent_id(context, params),
           :ok <- MemoryHelpers.ensure_memory(agent_id) do
        :ok = Arbor.Memory.delete_code(agent_id, params.entry_id)

        Actions.emit_completed(__MODULE__, %{entry_id: params.entry_id})
        {:ok, %{entry_id: params.entry_id, deleted: true}}
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end
  end

  # ============================================================================
  # ViewCode
  # ============================================================================

  defmodule ViewCode do
    @moduledoc """
    View a specific code pattern.

    Can look up by entry ID or search by purpose keyword.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `entry_id` | string | no | Code entry ID (exact lookup) |
    | `query` | string | no | Search by purpose keyword |
    """

    use Jido.Action,
      name: "memory_view_code",
      description:
        "View a code pattern. Provide entry_id for exact lookup or query for purpose search.",
      category: "memory_code",
      tags: ["memory", "code", "view", "search"],
      schema: [
        entry_id: [type: :string, doc: "Code entry ID for exact lookup"],
        query: [type: :string, doc: "Search by purpose keyword"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Memory, as: MemoryHelpers

    @spec taint_roles() :: %{atom() => :control | :data}
    def taint_roles do
      %{entry_id: :data, query: :data}
    end

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      with {:ok, agent_id} <- MemoryHelpers.extract_agent_id(context, params),
           :ok <- MemoryHelpers.ensure_memory(agent_id) do
        cond do
          params[:entry_id] ->
            view_by_id(agent_id, params.entry_id)

          params[:query] ->
            search_by_purpose(agent_id, params.query)

          true ->
            Actions.emit_failed(__MODULE__, :entry_id_or_query_required)
            {:error, :entry_id_or_query_required}
        end
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end

    defp view_by_id(agent_id, entry_id) do
      case Arbor.Memory.get_code(agent_id, entry_id) do
        {:ok, entry} ->
          Actions.emit_completed(__MODULE__, %{entry_id: entry_id})
          {:ok, format_entry(entry)}

        {:error, :not_found} = error ->
          Actions.emit_failed(__MODULE__, :not_found)
          error
      end
    end

    defp search_by_purpose(agent_id, query) do
      entries = Arbor.Memory.find_code_by_purpose(agent_id, query)

      formatted = Enum.map(entries, &format_entry/1)
      Actions.emit_completed(__MODULE__, %{count: length(formatted)})
      {:ok, %{results: formatted, count: length(formatted), query: query}}
    end

    defp format_entry(entry) do
      %{
        id: entry.id,
        code: entry.code,
        language: entry.language,
        purpose: entry.purpose,
        created_at: entry.created_at
      }
    end
  end
end
