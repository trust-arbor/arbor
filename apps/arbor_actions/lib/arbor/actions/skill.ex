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

  External/imported skills retain `taint: :untrusted`. Activation and compilation
  require approval of the exact source version. Declared tools still require
  their own capabilities. Import confirmation does not approve execution.

  ## Authorization

  - Search: `arbor://code/read`
  - Activate: `arbor://memory/write` (writes the agent's own working memory)
  - Deactivate: `arbor://memory/write`
  - ListActive: `arbor://code/read`
  - Import: `arbor://code/write`
  - Compile: `arbor://code/compile`
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
    def run(params, context) do
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
            taint: to_string(skill_field(skill, :taint) || "untrusted")
          }
          |> Map.merge(lib.approval_status(skill_field(skill, :name), context[:agent_id]))
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
    Activate an exact operator-approved skill version. Approval never grants its tools.
    Imported provenance remains untrusted, and an active reference is rechecked at each use.
    """
    use Jido.Action,
      name: "skill_activate",
      description: "Activate an exact approved skill version into working memory",
      category: "skill",
      tags: ["skill", "activate", "memory"],
      schema: [skill_name: [type: :string, required: true]]

    alias Arbor.Actions.Config
    alias Arbor.Common.SkillLibrary

    def taint_roles, do: %{skill_name: :control}

    @impl true
    def run(params, context) do
      agent_id = context[:agent_id]
      name = params[:skill_name]

      with {:ok, version} <- SkillLibrary.resolve_approved_version(name, agent_id),
           :ok <- check_tools(version.skill, agent_id) do
        activate(version, agent_id)
      end
    rescue
      _ -> {:error, :skill_activation_unavailable}
    catch
      _, _ -> {:error, :skill_activation_unavailable}
    end

    defp activate(version, agent_id) do
      memory = Config.memory_module()
      wm = memory.get_working_memory(agent_id) || memory.new_working_memory(agent_id)
      existing = Enum.find(Map.get(wm, :active_skills, []), &(Map.get(&1, :name) == version.name))

      if existing do
        with {:ok, exact} <-
               SkillLibrary.resolve_approved_version(version.name, agent_id, existing) do
          {:ok,
           %{
             activated: false,
             name: exact.name,
             version_digest: exact.digest,
             reason: "already active",
             content: Map.get(exact.skill, :body, "")
           }}
        end
      else
        entry =
          Map.merge(
            Map.take(version.skill, [:name, :description, :body, :taint, :provenance]),
            version.approval
          )

        with {:ok, updated} <- memory.activate_working_memory_skill(wm, entry),
             :ok <- memory.save_working_memory(agent_id, updated),
             {:ok, exact} <-
               SkillLibrary.resolve_approved_version(version.name, agent_id, version.approval) do
          body = Map.get(exact.skill, :body, "")
          tokens = div(String.length(body), 4)

          Arbor.Signals.durable_emit(:skill, :skill_activated, %{
            skill_name: exact.name,
            agent_id: agent_id,
            version_digest: exact.digest,
            approval_id: exact.approval.approval_id,
            token_estimate: tokens
          })

          {:ok,
           %{
             activated: true,
             name: exact.name,
             version_digest: exact.digest,
             token_estimate: tokens,
             content: body
           }}
        end
      end
    end

    defp check_tools(skill, agent_id) do
      security = Config.security_module()
      tools = Map.get(skill, :allowed_tools) || []

      unauthorized =
        Enum.reject(tools, fn tool ->
          with {:ok, uri} <- Arbor.Actions.tool_name_to_canonical_uri(tool),
               {:ok, :authorized} <-
                 security.authorize(agent_id, uri, :execute, verify_identity: false) do
            true
          else
            _ -> false
          end
        end)

      if unauthorized == [], do: :ok, else: {:error, {:unauthorized_tools, unauthorized}}
    end
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
    alias Arbor.Common.SkillLibrary

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
        case get_working_memory(agent_id) do
          {:ok, wm} -> wm_mod.list_active_skills(wm)
          _ -> []
        end

      summaries =
        Enum.map(skills, fn skill ->
          %{
            name: skill.name,
            description: skill.description,
            activated_at: DateTime.to_iso8601(skill.activated_at)
          }
          |> Map.merge(SkillLibrary.approval_status(skill.name, agent_id, skill))
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

    def taint_roles, do: %{path: {:control, requires: [:path_traversal]}, approve: :data}

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

    Requires current approval of the exact source snapshot before cache or provider
    effects. Returns generated DOT as untrusted code with input and output hashes;
    ordinary pipeline execution authorization remains required.

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

    alias Arbor.Actions.{Config, File, Skill.CompilationPrompt}
    alias Arbor.Common.SkillLibrary

    def taint_roles, do: %{skill_name: :control, force: :data}

    @impl true
    def run(params, context) do
      with :ok <- public_context(context),
           {:ok, version} <-
             SkillLibrary.resolve_approved_version(params[:skill_name], context[:agent_id]),
           {:ok, path} <- cache_path(version.skill),
           {:ok, path} <- File.authorize_file_op(context, path, :read) do
        compile_or_read(version, path, params[:force] == true, context)
      end
    rescue
      _ -> {:error, :skill_compile_unavailable}
    catch
      _, _ -> {:error, :skill_compile_unavailable}
    end

    defp public_context(%{agent_id: id} = context) when is_binary(id) and byte_size(id) > 0 do
      if is_nil(context[:memory_write_policy]), do: :ok, else: {:error, :memory_write_denied}
    end

    defp public_context(_), do: {:error, :skill_not_approved}

    defp cache_path(%{path: path}) when is_binary(path) and byte_size(path) <= 4096,
      do: {:ok, Path.join(Path.dirname(path), "COMPILED.dot")}

    defp cache_path(_), do: {:error, :skill_cache_path_unavailable}

    defp compile_or_read(version, path, force, context) do
      case if(force, do: {:error, :stale}, else: read_bound(path, version.digest)) do
        {:ok, dot} ->
          finish(version, path, dot, true, context)

        {:error, reason} when reason in [:enoent, :stale] ->
          compile_and_store(version, path, context)

        {:error, _} = error ->
          error
      end
    end

    # This is an integrity receipt for untrusted generated code, not permission
    # to execute it. Consumers still pass the DOT through ordinary Engine gates.
    defp read_bound(path, digest) do
      with {:ok, stat} <- Elixir.File.stat(path),
           true <- stat.size <= 262_400,
           {:ok, bytes} <- Elixir.File.read(path),
           [header, dot] <- String.split(bytes, "\n", parts: 2),
           output_hash <- hash(dot),
           true <- header == "// arbor:skill_version=#{digest} output_sha256=#{output_hash}" do
        {:ok, dot}
      else
        {:error, _} = error -> error
        _ -> {:error, :stale}
      end
    end

    defp compile_and_store(version, path, context) do
      with {:ok, path} <- File.authorize_file_op(context, path, :write),
           {:ok, _} <-
             SkillLibrary.resolve_approved_version(
               version.name,
               context[:agent_id],
               version.approval
             ),
           {:ok, dot} <- compile_skill_to_dot(version.skill),
           {:ok, _} <-
             SkillLibrary.resolve_approved_version(
               version.name,
               context[:agent_id],
               version.approval
             ),
           {:ok, path} <- File.authorize_file_op(context, path, :write),
           :ok <-
             Elixir.File.write(
               path,
               "// arbor:skill_version=#{version.digest} output_sha256=#{hash(dot)}\n" <> dot
             ) do
        finish(version, path, dot, false, context)
      end
    end

    defp finish(version, path, dot, cached, context) do
      with {:ok, _} <-
             SkillLibrary.resolve_approved_version(
               version.name,
               context[:agent_id],
               version.approval
             ) do
        {:ok,
         %{
           compiled: true,
           dot_path: path,
           dot: dot,
           cached: cached,
           input_version_digest: version.digest,
           output_digest: hash(dot),
           taint: :untrusted
         }}
      end
    end

    defp compile_skill_to_dot(skill) do
      user_prompt =
        "Compile this skill to a DOT graph:\n\nSkill name: #{skill.name}\n\n#{skill.body}"

      case Config.ai_module().generate_text(user_prompt,
             model: "fast",
             system_prompt: CompilationPrompt.system_prompt()
           ) do
        {:ok, response} ->
          case extract_dot_from_response(response) do
            dot when is_binary(dot) and byte_size(dot) in 1..262_144 -> {:ok, dot}
            _ -> {:error, :no_dot_in_response}
          end

        {:error, _} = error ->
          error

        _ ->
          {:error, :invalid_compile_response}
      end
    end

    defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

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
  end
end
