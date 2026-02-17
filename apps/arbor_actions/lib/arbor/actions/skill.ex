defmodule Arbor.Actions.Skill do
  @moduledoc """
  Skill management operations as Jido actions.

  Provides actions for agents to discover, activate, deactivate, and manage
  skills from the skill library. Skills are reusable prompt templates that
  agents can load into their working memory for contextual guidance.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `Search` | Search the skill library by keyword or semantic query |
  | `Activate` | Load a skill into agent working memory |
  | `Deactivate` | Remove a skill from agent working memory |
  | `ListActive` | List currently active skills |
  | `Import` | Import external skills from a directory |
  | `Compile` | JIT-compile a skill to a DOT graph |

  ## Progressive Disclosure

  Search returns name + description only (not body) to keep results compact.
  Activate loads the full body into working memory.

  ## Security

  External/imported skills are tagged `taint: :untrusted`. Activating an
  untrusted skill with `allowed_tools` requires the agent to hold matching
  capabilities. Import requires `arbor://skills/import` capability.

  ## Authorization

  - Search: `arbor://actions/execute/skill.search`
  - Activate: `arbor://actions/execute/skill.activate`
  - Deactivate: `arbor://actions/execute/skill.deactivate`
  - ListActive: `arbor://actions/execute/skill.list_active`
  - Import: `arbor://actions/execute/skill.import`
  - Compile: `arbor://actions/execute/skill.compile`
  """

  # -- Search ----------------------------------------------------------------

  defmodule Search do
    @moduledoc """
    Search the skill library for matching skills.

    Returns name, description, tags, category, and taint level for each
    result. Does not return the full skill body (use Activate for that).

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `query` | string | yes | Search query |
    | `limit` | integer | no | Max results (default: 5) |
    | `category` | string | no | Filter by category |
    | `hybrid` | boolean | no | Force hybrid search (default: true) |
    """

    use Jido.Action,
      name: "skill_search",
      description: "Search the skill library for skills matching a query",
      category: "skill",
      tags: ["skill", "search", "discovery"],
      schema: [
        query: [type: :string, required: true, doc: "Search query"],
        limit: [type: :integer, default: 5, doc: "Max results"],
        category: [type: :string, doc: "Filter by category"],
        hybrid: [type: :boolean, default: true, doc: "Use hybrid search when available"]
      ]

    alias Arbor.Actions

    def taint_roles, do: %{query: :control, limit: :data, category: :data, hybrid: :data}

    @impl true
    def run(params, _context) do
      query = params[:query]
      limit = params[:limit] || 5
      opts = [limit: limit, hybrid: params[:hybrid] != false]
      opts = if params[:category], do: Keyword.put(opts, :category, params[:category]), else: opts

      Actions.emit_started(__MODULE__, %{query: query, limit: limit})

      lib = skill_library_module()

      results =
        if Code.ensure_loaded?(lib) and function_exported?(lib, :search, 2) do
          # credo:disable-for-next-line Credo.Check.Refactor.Apply
          apply(lib, :search, [query, opts])
        else
          []
        end

      # Progressive disclosure: name + description only, not body
      summaries =
        Enum.map(results, fn skill ->
          %{
            name: skill_field(skill, :name),
            description: skill_field(skill, :description),
            tags: skill_field(skill, :tags) || [],
            category: skill_field(skill, :category),
            taint: to_string(skill_field(skill, :taint) || "trusted")
          }
        end)

      Actions.emit_completed(__MODULE__, %{count: length(summaries)})
      {:ok, %{results: summaries, count: length(summaries)}}
    end

    defp skill_field(%{} = skill, field), do: Map.get(skill, field)
    defp skill_library_module, do: Arbor.Common.SkillLibrary
  end

  # -- Activate ---------------------------------------------------------------

  defmodule Activate do
    @moduledoc """
    Activate a skill by loading it into agent working memory.

    Fetches the full skill from the library and adds it to the agent's
    `active_skills` list. The skill body becomes part of the agent's
    system prompt context.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `skill_name` | string | yes | Name of the skill to activate |

    ## Security

    Untrusted skills with `allowed_tools` require the agent to hold matching
    capabilities. Activation of untrusted skills is logged via signal emission.
    """

    use Jido.Action,
      name: "skill_activate",
      description: "Activate a skill and load it into working memory",
      category: "skill",
      tags: ["skill", "activate", "memory"],
      schema: [
        skill_name: [type: :string, required: true, doc: "Name of the skill to activate"]
      ]

    alias Arbor.Actions
    alias Arbor.Memory.WorkingMemory

    require Logger

    def taint_roles, do: %{skill_name: :control}

    @impl true
    def run(params, context) do
      skill_name = params[:skill_name]
      agent_id = context[:agent_id] || "unknown"

      Actions.emit_started(__MODULE__, %{skill_name: skill_name, agent_id: agent_id})

      lib = Arbor.Common.SkillLibrary

      with {:lib, true} <- {:lib, Code.ensure_loaded?(lib)},
           # credo:disable-for-next-line Credo.Check.Refactor.Apply
           {:ok, skill} <- apply(lib, :get, [skill_name]),
           :ok <- check_untrusted_activation(skill, agent_id),
           {:ok, wm} <- get_working_memory(agent_id),
           wm_mod = WorkingMemory,
           {:ok, updated_wm} <- apply(wm_mod, :activate_skill, [wm, skill]) do
        save_working_memory(agent_id, updated_wm)

        token_estimate = estimate_tokens(skill)

        if skill_field(skill, :taint) == :untrusted do
          emit_untrusted_activation(skill_name, agent_id)
        end

        Actions.emit_completed(__MODULE__, %{skill_name: skill_name, agent_id: agent_id})
        {:ok, %{activated: true, name: skill_name, token_estimate: token_estimate}}
      else
        {:lib, false} ->
          {:error, :skill_library_unavailable}

        {:error, :not_found} ->
          Actions.emit_failed(__MODULE__, %{skill_name: skill_name, reason: :not_found})
          {:error, :skill_not_found}

        {:error, :already_active} ->
          {:ok, %{activated: false, name: skill_name, reason: "already active"}}

        {:error, :max_skills_reached} ->
          Actions.emit_failed(__MODULE__, %{skill_name: skill_name, reason: :max_skills_reached})
          {:error, :max_skills_reached}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, %{skill_name: skill_name, reason: inspect(reason)})
          {:error, reason}
      end
    end

    defp check_untrusted_activation(skill, agent_id) do
      taint = skill_field(skill, :taint)
      allowed_tools = skill_field(skill, :allowed_tools) || []

      if taint == :untrusted and allowed_tools != [] do
        check_tool_capabilities(allowed_tools, agent_id)
      else
        :ok
      end
    end

    defp check_tool_capabilities(tools, agent_id) do
      security_mod = Arbor.Security

      if Code.ensure_loaded?(security_mod) and function_exported?(security_mod, :authorize, 4) do
        unauthorized =
          Enum.reject(tools, fn tool ->
            resource = "arbor://actions/execute/#{tool}"
            # credo:disable-for-next-line Credo.Check.Refactor.Apply
            case apply(security_mod, :authorize, [agent_id, resource, :execute, []]) do
              {:ok, :authorized} -> true
              _ -> false
            end
          end)

        if unauthorized == [] do
          :ok
        else
          {:error, {:unauthorized_tools, unauthorized}}
        end
      else
        # No security module — allow activation
        :ok
      end
    end

    defp emit_untrusted_activation(skill_name, agent_id) do
      if Code.ensure_loaded?(Arbor.Signals) do
        Arbor.Signals.emit(:skill, :untrusted_activated, %{
          skill_name: skill_name,
          agent_id: agent_id
        })
      end
    end

    defp get_working_memory(agent_id) do
      mem_mod = Arbor.Memory

      if Code.ensure_loaded?(mem_mod) and function_exported?(mem_mod, :get_working_memory, 1) do
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        case apply(mem_mod, :get_working_memory, [agent_id]) do
          nil -> {:ok, WorkingMemory.new(agent_id)}
          wm -> {:ok, wm}
        end
      else
        {:ok, WorkingMemory.new(agent_id, rebuild_from_signals: false)}
      end
    rescue
      _ -> {:ok, WorkingMemory.new(agent_id, rebuild_from_signals: false)}
    catch
      :exit, _ -> {:ok, WorkingMemory.new(agent_id, rebuild_from_signals: false)}
    end

    defp save_working_memory(agent_id, wm) do
      mem_mod = Arbor.Memory

      if Code.ensure_loaded?(mem_mod) and function_exported?(mem_mod, :save_working_memory, 2) do
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(mem_mod, :save_working_memory, [agent_id, wm])
      end
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    defp estimate_tokens(skill) do
      body = skill_field(skill, :body) || ""
      # Rough estimate: 1 token ≈ 4 chars
      div(String.length(body), 4)
    end

    defp skill_field(%{} = skill, field), do: Map.get(skill, field)
  end

  # -- Deactivate -------------------------------------------------------------

  defmodule Deactivate do
    @moduledoc """
    Deactivate a skill and remove it from working memory.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `skill_name` | string | yes | Name of the skill to deactivate |
    """

    use Jido.Action,
      name: "skill_deactivate",
      description: "Deactivate a skill and remove it from working memory",
      category: "skill",
      tags: ["skill", "deactivate", "memory"],
      schema: [
        skill_name: [type: :string, required: true, doc: "Name of the skill to deactivate"]
      ]

    alias Arbor.Actions
    alias Arbor.Memory.WorkingMemory

    def taint_roles, do: %{skill_name: :control}

    @impl true
    def run(params, context) do
      skill_name = params[:skill_name]
      agent_id = context[:agent_id] || "unknown"

      Actions.emit_started(__MODULE__, %{skill_name: skill_name, agent_id: agent_id})

      wm_mod = WorkingMemory

      with {:ok, wm} <- get_working_memory(agent_id) do
        updated_wm = wm_mod.deactivate_skill(wm, skill_name)
        save_working_memory(agent_id, updated_wm)

        Actions.emit_completed(__MODULE__, %{skill_name: skill_name, agent_id: agent_id})
        {:ok, %{deactivated: true, name: skill_name}}
      end
    end

    defp get_working_memory(agent_id) do
      mem_mod = Arbor.Memory

      if Code.ensure_loaded?(mem_mod) and function_exported?(mem_mod, :get_working_memory, 1) do
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        case apply(mem_mod, :get_working_memory, [agent_id]) do
          nil -> {:ok, WorkingMemory.new(agent_id, rebuild_from_signals: false)}
          wm -> {:ok, wm}
        end
      else
        {:ok, WorkingMemory.new(agent_id, rebuild_from_signals: false)}
      end
    rescue
      _ -> {:ok, WorkingMemory.new(agent_id, rebuild_from_signals: false)}
    catch
      :exit, _ -> {:ok, WorkingMemory.new(agent_id, rebuild_from_signals: false)}
    end

    defp save_working_memory(agent_id, wm) do
      mem_mod = Arbor.Memory

      if Code.ensure_loaded?(mem_mod) and function_exported?(mem_mod, :save_working_memory, 2) do
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(mem_mod, :save_working_memory, [agent_id, wm])
      end
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  # -- ListActive -------------------------------------------------------------

  defmodule ListActive do
    @moduledoc """
    List currently active skills in agent working memory.

    Returns the name, description, and activation time for each active skill.
    """

    use Jido.Action,
      name: "skill_list_active",
      description: "List currently active skills in working memory",
      category: "skill",
      tags: ["skill", "list", "active", "memory"],
      schema: []

    alias Arbor.Actions
    alias Arbor.Memory.WorkingMemory

    def taint_roles, do: %{}

    @impl true
    def run(_params, context) do
      agent_id = context[:agent_id] || "unknown"

      Actions.emit_started(__MODULE__, %{agent_id: agent_id})

      wm_mod = WorkingMemory

      skills =
        with {:ok, wm} <- get_working_memory(agent_id) do
          wm_mod.list_active_skills(wm)
        else
          _ -> []
        end

      summaries =
        Enum.map(skills, fn skill ->
          %{
            name: skill.name,
            description: skill.description,
            activated_at: DateTime.to_iso8601(skill.activated_at)
          }
        end)

      Actions.emit_completed(__MODULE__, %{count: length(summaries), agent_id: agent_id})
      {:ok, %{skills: summaries, count: length(summaries)}}
    end

    defp get_working_memory(agent_id) do
      mem_mod = Arbor.Memory

      if Code.ensure_loaded?(mem_mod) and function_exported?(mem_mod, :get_working_memory, 1) do
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        case apply(mem_mod, :get_working_memory, [agent_id]) do
          nil -> {:ok, WorkingMemory.new(agent_id, rebuild_from_signals: false)}
          wm -> {:ok, wm}
        end
      else
        {:ok, WorkingMemory.new(agent_id, rebuild_from_signals: false)}
      end
    rescue
      _ -> {:ok, WorkingMemory.new(agent_id, rebuild_from_signals: false)}
    catch
      :exit, _ -> {:ok, WorkingMemory.new(agent_id, rebuild_from_signals: false)}
    end
  end

  # -- Import (Phase 4) ------------------------------------------------------

  defmodule Import do
    @moduledoc """
    Import external skills from a directory.

    Scans a directory for SKILL.md files, validates format per Agent Skills
    spec, and registers them in the skill library with `taint: :untrusted`.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `path` | string | yes | Directory path to scan for skills |
    | `approve` | boolean | no | Preview when false, import when true (default: false) |

    ## Security

    - Requires `arbor://skills/import` capability
    - All imported skills are tagged `taint: :untrusted`
    - Paths are validated via SafePath
    - Reflex checks run on skill names and bodies
    """

    use Jido.Action,
      name: "skill_import",
      description: "Import external skills from a directory",
      category: "skill",
      tags: ["skill", "import", "external", "security"],
      schema: [
        path: [type: :string, required: true, doc: "Directory path to scan"],
        approve: [type: :boolean, default: false, doc: "Preview (false) or import (true)"]
      ]

    alias Arbor.Actions

    def taint_roles, do: %{path: :control, approve: :data}

    @impl true
    def run(params, _context) do
      path = params[:path]
      approve = params[:approve] || false

      Actions.emit_started(__MODULE__, %{path: path, approve: approve})

      importer = Arbor.Common.SkillImporter

      if Code.ensure_loaded?(importer) and function_exported?(importer, :import_from_directory, 2) do
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        case apply(importer, :import_from_directory, [path, [approve: approve]]) do
          {:ok, result} ->
            Actions.emit_completed(__MODULE__, %{path: path, count: result[:count] || 0})
            {:ok, result}

          {:error, reason} = error ->
            Actions.emit_failed(__MODULE__, %{path: path, reason: inspect(reason)})
            error
        end
      else
        {:error, :importer_unavailable}
      end
    end
  end

  # -- Compile (Phase 5) -----------------------------------------------------

  defmodule Compile do
    @moduledoc """
    JIT-compile a skill to a DOT graph for orchestrator execution.

    Checks content hash against cached DOT file. On cache miss (or force),
    uses an LLM call to generate a DOT graph from the skill body.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `skill_name` | string | yes | Name of the skill to compile |
    | `force` | boolean | no | Force recompilation (default: false) |
    """

    use Jido.Action,
      name: "skill_compile",
      description: "JIT-compile a skill to a DOT graph for orchestrator execution",
      category: "skill",
      tags: ["skill", "compile", "dot", "orchestrator"],
      schema: [
        skill_name: [type: :string, required: true, doc: "Name of the skill to compile"],
        force: [type: :boolean, default: false, doc: "Force recompilation"]
      ]

    alias Arbor.Actions

    require Logger

    def taint_roles, do: %{skill_name: :control, force: :data}

    @impl true
    def run(params, _context) do
      skill_name = params[:skill_name]
      force = params[:force] || false

      Actions.emit_started(__MODULE__, %{skill_name: skill_name, force: force})

      lib = Arbor.Common.SkillLibrary
      cache_mod = Arbor.Common.SkillLibrary.DotCache

      with {:lib, true} <- {:lib, Code.ensure_loaded?(lib)},
           # credo:disable-for-next-line Credo.Check.Refactor.Apply
           {:ok, skill} <- apply(lib, :get, [skill_name]),
           {:cache, true} <- {:cache, Code.ensure_loaded?(cache_mod)} do
        content_hash = Map.get(skill, :content_hash) || compute_hash(skill)

        if not force and not apply(cache_mod, :stale?, [skill_name, content_hash]) do
          {:ok, dot_path} = apply(cache_mod, :get, [skill_name, content_hash])

          Actions.emit_completed(__MODULE__, %{skill_name: skill_name, cached: true})
          {:ok, %{compiled: true, dot_path: dot_path, cached: true}}
        else
          case compile_skill_to_dot(skill) do
            {:ok, dot_content} ->
              {:ok, dot_path} = apply(cache_mod, :put, [skill_name, content_hash, dot_content])
              maybe_validate_dot(dot_content)

              Actions.emit_completed(__MODULE__, %{skill_name: skill_name, cached: false})
              {:ok, %{compiled: true, dot_path: dot_path, cached: false}}

            {:error, reason} = error ->
              Actions.emit_failed(__MODULE__, %{
                skill_name: skill_name,
                reason: inspect(reason)
              })

              error
          end
        end
      else
        {:lib, false} -> {:error, :skill_library_unavailable}
        {:error, :not_found} -> {:error, :skill_not_found}
        {:cache, false} -> {:error, :dot_cache_unavailable}
      end
    end

    defp compile_skill_to_dot(skill) do
      body = Map.get(skill, :body) || ""
      name = Map.get(skill, :name) || "unnamed"

      prompt = """
      Convert this skill into a DOT graph for orchestrator execution.
      The graph should use Arbor handler types (codergen, shell, consensus, etc.)
      and follow the node attribute format: [type="handler_type" attr="value"].

      Skill name: #{name}
      Skill body:
      #{body}

      Output ONLY the DOT graph, starting with `digraph` and ending with `}`.
      """

      ai_mod = Arbor.AI

      if Code.ensure_loaded?(ai_mod) and function_exported?(ai_mod, :generate_text_via_api, 2) do
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        case apply(ai_mod, :generate_text_via_api, [prompt, [model: "fast"]]) do
          {:ok, response} ->
            dot = extract_dot_from_response(response)
            if dot, do: {:ok, dot}, else: {:error, :no_dot_in_response}

          {:error, _} = error ->
            error
        end
      else
        {:error, :ai_unavailable}
      end
    rescue
      e -> {:error, {:compile_failed, inspect(e)}}
    catch
      :exit, reason -> {:error, {:compile_failed, inspect(reason)}}
    end

    defp extract_dot_from_response(response) when is_binary(response) do
      # Extract DOT graph from markdown fence or raw response
      case Regex.run(~r/```(?:dot|graphviz)?\s*\n(digraph[\s\S]*?)\n```/m, response) do
        [_, dot] ->
          String.trim(dot)

        nil ->
          if String.starts_with?(String.trim(response), "digraph") do
            String.trim(response)
          end
      end
    end

    defp extract_dot_from_response(%{text: text}), do: extract_dot_from_response(text)
    defp extract_dot_from_response(%{"text" => text}), do: extract_dot_from_response(text)
    defp extract_dot_from_response(_), do: nil

    defp maybe_validate_dot(dot_content) do
      validator = Arbor.Orchestrator

      if Code.ensure_loaded?(validator) and function_exported?(validator, :validate, 1) do
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        case apply(validator, :validate, [dot_content]) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning("[SkillCompile] DOT validation failed: #{inspect(reason)}")
        end
      end
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    defp compute_hash(skill) do
      body = Map.get(skill, :body) || ""
      :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    end
  end
end
