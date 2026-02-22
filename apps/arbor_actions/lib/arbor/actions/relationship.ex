defmodule Arbor.Actions.Relationship do
  @moduledoc """
  Relationship management actions for storing, retrieving, and enriching
  interpersonal relationship memories.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `Get` | Retrieve a relationship summary by person name |
  | `Save` | Create or update a relationship record |
  | `Moment` | Record a key moment in a relationship |
  | `Browse` | List all known relationships |
  | `Summarize` | Get a detailed or brief relationship summary |
  """

  # ============================================================================
  # Get
  # ============================================================================

  defmodule Get do
    @moduledoc """
    Retrieve a relationship by person name.

    Returns a full summary of the relationship including background,
    values, key moments, and dynamics.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `name` | string | yes | The person's name |
    """

    use Jido.Action,
      name: "relationship_get",
      description:
        "Retrieve a relationship by person name. Returns background, values, key moments, and relationship dynamics.",
      category: "relationship",
      tags: ["memory", "relationship", "get", "recall"],
      schema: [
        name: [type: :string, required: true, doc: "The person's name"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Memory, as: MemoryHelpers

    @spec taint_roles() :: %{atom() => :control | :data}
    def taint_roles, do: %{name: :data}

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      with {:ok, agent_id} <- MemoryHelpers.extract_agent_id(context, params),
           :ok <- MemoryHelpers.ensure_memory(agent_id) do
        case Arbor.Memory.get_relationship_by_name(agent_id, params.name) do
          {:ok, relationship} ->
            summary = summarize_relationship(relationship)
            Actions.emit_completed(__MODULE__, %{name: params.name})
            {:ok, %{name: params.name, summary: summary, found: true}}

          {:error, :not_found} ->
            {:ok,
             %{
               name: params.name,
               found: false,
               summary: "No relationship found for #{params.name}"
             }}

          {:error, reason} ->
            Actions.emit_failed(__MODULE__, reason)
            {:error, "Failed to get relationship: #{inspect(reason)}"}
        end
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end

    defp summarize_relationship(relationship) do
      rel_mod = Module.concat([:Arbor, :Memory, :Relationship])

      if Code.ensure_loaded?(rel_mod) and function_exported?(rel_mod, :summarize, 1) do
        apply(rel_mod, :summarize, [relationship])
      else
        inspect(relationship)
      end
    end
  end

  # ============================================================================
  # Save
  # ============================================================================

  defmodule Save do
    @moduledoc """
    Create or update a relationship record.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `name` | string | yes | The person's name |
    | `background` | list(string) | no | Background context items |
    | `values` | list(string) | no | The person's values |
    | `relationship_dynamic` | string | no | Description of the relationship type |
    | `personal_details` | list(string) | no | Personal details |
    | `current_focus` | list(string) | no | Current focus areas |
    | `uncertainties` | list(string) | no | Known uncertainties |
    """

    use Jido.Action,
      name: "relationship_save",
      description:
        "Create or update a relationship. Required: name. Optional: background (list), values (list), relationship_dynamic, personal_details (list), current_focus (list), uncertainties (list).",
      category: "relationship",
      tags: ["memory", "relationship", "save", "store"],
      schema: [
        name: [type: :string, required: true, doc: "The person's name"],
        background: [type: {:list, :string}, default: [], doc: "Background context items"],
        values: [type: {:list, :string}, default: [], doc: "The person's values"],
        relationship_dynamic: [type: :string, doc: "Description of the relationship type"],
        personal_details: [type: {:list, :string}, default: [], doc: "Personal details"],
        current_focus: [type: {:list, :string}, default: [], doc: "Current focus areas"],
        uncertainties: [type: {:list, :string}, default: [], doc: "Known uncertainties"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Memory, as: MemoryHelpers

    @spec taint_roles() :: %{atom() => :control | :data}
    def taint_roles do
      %{
        name: :data,
        background: :data,
        values: :data,
        relationship_dynamic: :data,
        personal_details: :data,
        current_focus: :data,
        uncertainties: :data
      }
    end

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      with {:ok, agent_id} <- MemoryHelpers.extract_agent_id(context, params),
           :ok <- MemoryHelpers.ensure_memory(agent_id) do
        relationship = build_relationship(agent_id, params)

        case Arbor.Memory.save_relationship(agent_id, relationship) do
          {:ok, saved} ->
            Actions.emit_completed(__MODULE__, %{name: params.name})
            {:ok, %{name: params.name, saved: true, id: Map.get(saved, :id)}}

          {:error, reason} ->
            Actions.emit_failed(__MODULE__, reason)
            {:error, "Failed to save relationship: #{inspect(reason)}"}
        end
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end

    defp build_relationship(agent_id, params) do
      rel_mod = Module.concat([:Arbor, :Memory, :Relationship])

      base =
        if Code.ensure_loaded?(rel_mod) and function_exported?(rel_mod, :new, 2) do
          case Arbor.Memory.get_relationship_by_name(agent_id, params.name) do
            {:ok, rel} -> rel
            _ -> apply(rel_mod, :new, [params.name, []])
          end
        else
          %{name: params.name}
        end

      base
      |> maybe_update(:background, params[:background])
      |> maybe_update(:values, params[:values])
      |> maybe_update(:relationship_dynamic, params[:relationship_dynamic])
      |> maybe_update(:personal_details, params[:personal_details])
      |> maybe_update(:current_focus, params[:current_focus])
      |> maybe_update(:uncertainties, params[:uncertainties])
    end

    defp maybe_update(rel, _field, nil), do: rel
    defp maybe_update(rel, _field, []), do: rel

    defp maybe_update(rel, field, value) when is_list(value) do
      existing = Map.get(rel, field, [])
      Map.put(rel, field, Enum.uniq(existing ++ value))
    end

    defp maybe_update(rel, field, value), do: Map.put(rel, field, value)
  end

  # ============================================================================
  # Moment
  # ============================================================================

  defmodule Moment do
    @moduledoc """
    Record a key moment in a relationship.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `name` | string | yes | The person's name |
    | `summary` | string | yes | Description of the moment |
    | `emotional_markers` | list(string) | no | Emotional tags (e.g., trust, joy, insight) |
    | `salience` | float | no | Importance score 0.0-1.0 (default: 0.5) |
    """

    use Jido.Action,
      name: "relationship_moment",
      description:
        "Record a key moment in a relationship. Required: name, summary. Optional: emotional_markers (list of emotions), salience (0.0-1.0).",
      category: "relationship",
      tags: ["memory", "relationship", "moment", "event"],
      schema: [
        name: [type: :string, required: true, doc: "The person's name"],
        summary: [type: :string, required: true, doc: "Description of the moment"],
        emotional_markers: [
          type: {:list, :string},
          default: [],
          doc: "Emotional tags: connection, insight, joy, trust, concern, hope, etc."
        ],
        salience: [type: :float, default: 0.5, doc: "Importance score 0.0-1.0"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Memory, as: MemoryHelpers

    @spec taint_roles() :: %{atom() => :control | :data}
    def taint_roles do
      %{name: :data, summary: :data, emotional_markers: :data, salience: :data}
    end

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      with {:ok, agent_id} <- MemoryHelpers.extract_agent_id(context, params),
           :ok <- MemoryHelpers.ensure_memory(agent_id),
           {:ok, relationship} <- find_relationship(agent_id, params.name) do
        opts = [
          emotional_markers:
            Enum.map(params[:emotional_markers] || [], &MemoryHelpers.safe_to_atom/1),
          salience: params[:salience] || 0.5
        ]

        case Arbor.Memory.add_moment(agent_id, relationship.id, params.summary, opts) do
          {:ok, updated} ->
            Actions.emit_completed(__MODULE__, %{name: params.name})

            {:ok,
             %{
               name: params.name,
               moment_added: true,
               relationship_id: updated.id,
               total_moments: length(Map.get(updated, :key_moments, []))
             }}

          {:error, reason} ->
            Actions.emit_failed(__MODULE__, reason)
            {:error, "Failed to add moment: #{inspect(reason)}"}
        end
      else
        {:error, :not_found} ->
          {:error, "Relationship not found for #{params.name}. Save the relationship first."}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end

    defp find_relationship(agent_id, name) do
      Arbor.Memory.get_relationship_by_name(agent_id, name)
    end
  end

  # ============================================================================
  # Browse
  # ============================================================================

  defmodule Browse do
    @moduledoc """
    List all known relationships for the agent.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `limit` | integer | no | Maximum results (default: 20) |
    | `sort_by` | string | no | Sort field: salience, name, last_interaction (default: salience) |
    """

    use Jido.Action,
      name: "relationship_browse",
      description:
        "List all known relationships. Optional: limit (default 20), sort_by (salience, name, last_interaction).",
      category: "relationship",
      tags: ["memory", "relationship", "list"],
      schema: [
        limit: [type: :non_neg_integer, default: 20, doc: "Maximum results"],
        sort_by: [
          type: :string,
          default: "salience",
          doc: "Sort field: salience, name, last_interaction"
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Memory, as: MemoryHelpers

    @spec taint_roles() :: %{atom() => :control | :data}
    def taint_roles, do: %{limit: :data, sort_by: :control}

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      with {:ok, agent_id} <- MemoryHelpers.extract_agent_id(context, params),
           :ok <- MemoryHelpers.ensure_memory(agent_id) do
        sort_by = MemoryHelpers.safe_to_atom(params[:sort_by] || "salience")
        limit = params[:limit] || 20

        case Arbor.Memory.list_relationships(agent_id, sort_by: sort_by, limit: limit) do
          {:ok, relationships} ->
            summaries =
              Enum.map(relationships, fn rel ->
                %{
                  name: Map.get(rel, :name),
                  relationship_dynamic: Map.get(rel, :relationship_dynamic),
                  salience: Map.get(rel, :salience),
                  moment_count: length(Map.get(rel, :key_moments, [])),
                  last_interaction: Map.get(rel, :last_interaction)
                }
              end)

            Actions.emit_completed(__MODULE__, %{count: length(summaries)})
            {:ok, %{relationships: summaries, count: length(summaries)}}

          {:error, reason} ->
            Actions.emit_failed(__MODULE__, reason)
            {:error, "Failed to list relationships: #{inspect(reason)}"}
        end
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end
  end

  # ============================================================================
  # Summarize
  # ============================================================================

  defmodule Summarize do
    @moduledoc """
    Get a detailed or brief summary of a relationship.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `name` | string | yes | The person's name |
    | `format` | string | no | Summary format: full, brief (default: full) |
    """

    use Jido.Action,
      name: "relationship_summarize",
      description:
        "Get a formatted summary of a relationship. Required: name. Optional: format (full or brief, default full).",
      category: "relationship",
      tags: ["memory", "relationship", "summarize"],
      schema: [
        name: [type: :string, required: true, doc: "The person's name"],
        format: [
          type: :string,
          default: "full",
          doc: "Summary format: full, brief"
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Memory, as: MemoryHelpers

    @spec taint_roles() :: %{atom() => :control | :data}
    def taint_roles, do: %{name: :data, format: :control}

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      with {:ok, agent_id} <- MemoryHelpers.extract_agent_id(context, params),
           :ok <- MemoryHelpers.ensure_memory(agent_id) do
        case Arbor.Memory.get_relationship_by_name(agent_id, params.name) do
          {:ok, relationship} ->
            summary = format_summary(relationship, params[:format] || "full")
            Actions.emit_completed(__MODULE__, %{name: params.name})
            {:ok, %{name: params.name, summary: summary, format: params[:format] || "full"}}

          {:error, :not_found} ->
            {:ok,
             %{
               name: params.name,
               found: false,
               summary: "No relationship found for #{params.name}"
             }}

          {:error, reason} ->
            Actions.emit_failed(__MODULE__, reason)
            {:error, "Failed to summarize relationship: #{inspect(reason)}"}
        end
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end

    defp format_summary(relationship, "brief") do
      rel_mod = Module.concat([:Arbor, :Memory, :Relationship])

      if Code.ensure_loaded?(rel_mod) and function_exported?(rel_mod, :summarize, 2) do
        apply(rel_mod, :summarize, [relationship, :brief])
      else
        "#{Map.get(relationship, :name)}: #{Map.get(relationship, :relationship_dynamic, "unknown dynamic")}"
      end
    end

    defp format_summary(relationship, _full) do
      rel_mod = Module.concat([:Arbor, :Memory, :Relationship])

      if Code.ensure_loaded?(rel_mod) and function_exported?(rel_mod, :summarize, 1) do
        apply(rel_mod, :summarize, [relationship])
      else
        inspect(relationship)
      end
    end
  end
end
