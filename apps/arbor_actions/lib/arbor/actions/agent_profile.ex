defmodule Arbor.Actions.AgentProfile do
  @moduledoc """
  Self-service agent profile operations.

  Actions that any agent can use to manage its own profile, regardless of
  trust level. These are fundamental identity operations — an agent should
  always be able to set its own name.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `SetDisplayName` | Update the agent's display name |

  ## Authorization

  - SetDisplayName: `arbor://agent/profile`
  """

  defmodule SetDisplayName do
    @moduledoc """
    Update the agent's display name.

    Agents can rename themselves or accept a name given by the user.
    The display name is persisted in the agent's profile and reflected
    in the dashboard, signals, and any UI that references the agent.

    Only the agent itself (matching agent_id) can change its own name.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `agent_id` | string | yes | The agent's own ID |
    | `display_name` | string | yes | The new display name (1-100 chars) |

    ## Returns

    - `agent_id` - The agent's ID
    - `previous_name` - The old display name
    - `display_name` - The new display name
    """

    use Jido.Action,
      name: "agent_profile_set_display_name",
      description:
        "Update the agent's display name. Use when a user gives the agent a name or the agent wants to name itself.",
      category: "agent_profile",
      tags: ["agent", "profile", "identity", "name"],
      schema: [
        agent_id: [
          type: :string,
          required: true,
          doc: "The agent's own ID"
        ],
        display_name: [
          type: :string,
          required: true,
          doc: "The new display name (1-100 characters)"
        ]
      ]

    require Logger

    def taint_roles do
      %{agent_id: :control, display_name: :data}
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(params, _context) do
      %{agent_id: agent_id, display_name: new_name} = params

      with :ok <- validate_name(new_name),
           {:ok, profile} <- load_profile(agent_id),
           previous_name <- profile.display_name || profile.character.name || "Agent" do
        updated_profile = %{profile | display_name: new_name}

        case store_profile(updated_profile) do
          :ok ->
            emit_name_changed(agent_id, previous_name, new_name)

            Logger.info(
              "[AgentProfile] #{agent_id} renamed: #{inspect(previous_name)} → #{inspect(new_name)}"
            )

            {:ok,
             %{
               agent_id: agent_id,
               previous_name: previous_name,
               display_name: new_name
             }}

          {:error, reason} ->
            {:error, "Failed to persist profile: #{inspect(reason)}"}
        end
      end
    end

    defp validate_name(name) when is_binary(name) and byte_size(name) >= 1 and byte_size(name) <= 100 do
      :ok
    end

    defp validate_name(name) when is_binary(name) and byte_size(name) > 100 do
      {:error, "Display name must be 100 characters or fewer"}
    end

    defp validate_name(_), do: {:error, "Display name must be a non-empty string"}

    @profile_store Module.concat([:Arbor, :Agent, :ProfileStore])

    defp load_profile(agent_id) do
      if Code.ensure_loaded?(@profile_store) and
           function_exported?(@profile_store, :load_profile, 1) do
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        case apply(@profile_store, :load_profile, [agent_id]) do
          {:ok, profile} -> {:ok, profile}
          {:error, :not_found} -> {:error, "Agent profile not found: #{agent_id}"}
          {:error, reason} -> {:error, "Failed to load profile: #{inspect(reason)}"}
        end
      else
        {:error, "ProfileStore not available"}
      end
    end

    defp store_profile(profile) do
      if Code.ensure_loaded?(@profile_store) and
           function_exported?(@profile_store, :store_profile, 1) do
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(@profile_store, :store_profile, [profile])
      else
        {:error, :profile_store_unavailable}
      end
    end

    defp emit_name_changed(agent_id, previous_name, new_name) do
      if Code.ensure_loaded?(Arbor.Signals) and
           function_exported?(Arbor.Signals, :emit, 4) and
           Process.whereis(Arbor.Signals.Bus) != nil do
        Arbor.Signals.emit(:agent, :display_name_changed, %{
          agent_id: agent_id,
          previous_name: previous_name,
          display_name: new_name
        })
      end
    rescue
      _ -> :ok
    end
  end
end
