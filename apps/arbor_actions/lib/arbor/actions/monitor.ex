defmodule Arbor.Actions.Monitor do
  @moduledoc """
  Monitor read operations as Jido actions.

  Exposes Arbor.Monitor's read API through the action system so agents
  can access runtime health data via Executor dispatch.

  Uses runtime bridge pattern (`Code.ensure_loaded?` + `apply/3`) since
  arbor_monitor is a standalone app with no compile-time dependency.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `Read` | Read monitor metrics, anomalies, or status |
  """

  defmodule Read do
    @moduledoc """
    Read runtime health data from Arbor.Monitor.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `query` | string | yes | What to read: "status", "anomalies", "metrics", "skills", "healing_status", "collect" |
    | `skill` | string | no | Specific skill name for targeted metrics (e.g., "beam", "processes") |

    ## Returns

    Map with the requested data under a `:data` key plus the `:query` that was run.
    """

    use Jido.Action,
      name: "monitor_read",
      description: "Read runtime health data from Arbor Monitor",
      category: "monitor",
      tags: ["monitor", "health", "metrics", "anomalies"],
      schema: [
        query: [
          type: {:in, ["status", "anomalies", "metrics", "skills", "healing_status", "collect"]},
          required: true,
          doc: "What to read: status, anomalies, metrics, skills, healing_status, collect"
        ],
        skill: [
          type: :string,
          doc: "Specific skill name for targeted metrics or collection (e.g., beam, processes)"
        ]
      ]

    @monitor_mod Arbor.Monitor
    @known_skills [:beam, :memory, :ets, :processes, :supervisor, :system]

    def taint_roles do
      %{query: :control, skill: :data}
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(%{query: query} = params, _context) do
      if monitor_available?() do
        execute_query(query, params)
      else
        {:error, :monitor_unavailable}
      end
    rescue
      ArgumentError -> {:error, :monitor_unavailable}
    catch
      :exit, _ -> {:error, :monitor_unavailable}
    end

    defp execute_query("status", _params) do
      {:ok, %{query: "status", data: call_monitor(:status, [])}}
    end

    defp execute_query("anomalies", _params) do
      {:ok, %{query: "anomalies", data: call_monitor(:anomalies, [])}}
    end

    defp execute_query("metrics", %{skill: skill}) when is_binary(skill) do
      case safe_skill_atom(skill) do
        {:ok, skill_atom} ->
          case call_monitor(:metrics, [skill_atom]) do
            {:ok, data} -> {:ok, %{query: "metrics", skill: skill, data: data}}
            :not_found -> {:error, {:skill_not_found, skill}}
          end

        {:error, _} ->
          {:error, {:unknown_skill, skill}}
      end
    end

    defp execute_query("metrics", _params) do
      {:ok, %{query: "metrics", data: call_monitor(:metrics, [])}}
    end

    defp execute_query("skills", _params) do
      {:ok, %{query: "skills", data: call_monitor(:skills, [])}}
    end

    defp execute_query("healing_status", _params) do
      {:ok, %{query: "healing_status", data: call_monitor(:healing_status, [])}}
    end

    defp execute_query("collect", %{skill: skill}) when is_binary(skill) do
      case safe_skill_atom(skill) do
        {:ok, skill_atom} ->
          {:ok, %{query: "collect", skill: skill, data: call_monitor(:collect, [skill_atom])}}

        {:error, _} ->
          {:error, {:unknown_skill, skill}}
      end
    end

    defp execute_query("collect", _params) do
      {:ok, %{query: "collect", data: call_monitor(:collect, [])}}
    end

    defp call_monitor(function, args) do
      apply(@monitor_mod, function, args)
    end

    defp safe_skill_atom(skill) do
      Arbor.Common.SafeAtom.to_allowed(skill, @known_skills)
    end

    defp monitor_available? do
      Code.ensure_loaded?(@monitor_mod) and
        Process.whereis(Arbor.Monitor.Supervisor) != nil
    end
  end
end
