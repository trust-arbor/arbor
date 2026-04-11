defmodule Arbor.Dashboard.Components.ExternalAgentsComponent do
  @moduledoc """
  Socket-first delegate component for the External Agents section of the
  Settings page.

  Owns the side effects (`Arbor.Agent.Lifecycle.create/2`,
  `Arbor.Agent.Lifecycle.list_agents/0`, `Arbor.Security.revoke_identity/2`)
  and delegates pure logic to `Arbor.Dashboard.Cores.ExternalAgentsCore`.

  Events are namespaced as `"external_agents:<action>"`.

  ## Assigns managed by this component

  - `:external_agents_state` — `ExternalAgentsCore.state()` (filtered + shaped rows)
  - `:agent_types` — list of available templates for the registration form
  - `:show_register_form` — boolean for the registration modal
  - `:just_registered` — non-nil after successful registration; carries the
    one-time-shown private key for the operator
  - `:external_agents_error` — flash error message, nil when no error
  """

  use Phoenix.Component

  import Arbor.Web.Components

  alias Arbor.Agent.{Character, Lifecycle}
  alias Arbor.Dashboard.Cores.ExternalAgentsCore

  require Logger

  # ===========================================================================
  # Mount / Update (socket delegation)
  # ===========================================================================

  @doc """
  Initialize external-agents assigns on the socket.

  Pulls the current owner's `agent_id` from `socket.assigns.current_agent_id`
  (set by `Arbor.Dashboard.Nav` on_mount). Loads the initial agent list from
  `Lifecycle.list_agents/0` filtered by ownership.
  """
  def mount(socket, _opts) do
    socket
    |> assign(:agent_types, ExternalAgentsCore.agent_types())
    |> assign(:show_register_form, false)
    |> assign(:just_registered, nil)
    |> assign(:external_agents_error, nil)
    |> assign(:editing_agent_id, nil)
    |> reload_state()
  end

  @doc """
  Handle namespaced events from the LiveView's handle_event/3.

  Phoenix's handle_event is always /3 with a params map (possibly empty),
  so the /3 clauses are the entry points. Events that need params have
  explicit /3 clauses; events that don't fall through the /3 catch-all
  into the /2 clauses where the actual logic lives.
  """
  def update_external_agents(
        socket,
        "submit_registration",
        %{"display_name" => name, "agent_type" => type}
      ) do
    case do_register(name, type, socket) do
      {:ok, profile, identity} ->
        view = ExternalAgentsCore.build_just_registered_view(profile, identity, type)

        socket
        |> assign(:just_registered, view)
        |> assign(:show_register_form, false)
        |> reload_state()

      {:error, reason} ->
        Logger.warning(
          "[ExternalAgentsComponent] Registration failed: #{inspect(reason)}"
        )

        assign(socket, :external_agents_error, ExternalAgentsCore.format_error(reason))
    end
  end

  def update_external_agents(socket, "revoke_external_agent", %{"agent_id" => agent_id}) do
    owner = socket.assigns[:current_agent_id]

    case do_revoke(agent_id, owner) do
      :ok ->
        reload_state(socket)

      {:error, reason} ->
        assign(socket, :external_agents_error, ExternalAgentsCore.format_error(reason))
    end
  end

  def update_external_agents(socket, "start_rename", %{"agent_id" => agent_id}) do
    socket
    |> assign(:editing_agent_id, agent_id)
    |> assign(:external_agents_error, nil)
  end

  def update_external_agents(
        socket,
        "submit_rename",
        %{"agent_id" => agent_id, "display_name" => new_name}
      ) do
    owner = socket.assigns[:current_agent_id]

    case do_rename(agent_id, new_name, owner) do
      :ok ->
        socket
        |> assign(:editing_agent_id, nil)
        |> reload_state()

      {:error, reason} ->
        assign(socket, :external_agents_error, ExternalAgentsCore.format_error(reason))
    end
  end

  # /3 catch-all: delegate to /2 for events that don't need params.
  def update_external_agents(socket, event, _params) do
    update_external_agents(socket, event)
  end

  def update_external_agents(socket, "open_register_form") do
    socket
    |> assign(:show_register_form, true)
    |> assign(:external_agents_error, nil)
  end

  def update_external_agents(socket, "close_register_form") do
    assign(socket, :show_register_form, false)
  end

  def update_external_agents(socket, "dismiss_just_registered") do
    assign(socket, :just_registered, nil)
  end

  def update_external_agents(socket, "cancel_rename") do
    socket
    |> assign(:editing_agent_id, nil)
    |> assign(:external_agents_error, nil)
  end

  # Catch-all for unknown 2-arg events
  def update_external_agents(socket, _event), do: socket

  # ===========================================================================
  # Side effects
  # ===========================================================================

  defp reload_state(socket) do
    owner = socket.assigns[:current_agent_id]
    profiles = safe_list_agents()
    state = ExternalAgentsCore.new(profiles, owner)
    assign(socket, :external_agents_state, state)
  end

  defp safe_list_agents do
    Lifecycle.list_agents()
    |> Enum.map(&normalize_profile_metadata/1)
    |> Enum.filter(&external_and_active?/1)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  # Persistence layer (JSON / JSONB) round-trips atom-keyed metadata into
  # string-keyed metadata, so a profile written with `%{external_agent: true}`
  # comes back as `%{"external_agent" => true}`. We re-atomize at the side-effect
  # boundary so the pure Core only ever sees the canonical atom-keyed shape.
  #
  # `SafeAtom.atomize_keys/2` only converts the explicitly listed known keys —
  # other (unknown) metadata keys are preserved as strings, so this is safe
  # against arbitrary user input.
  @known_metadata_keys [:external_agent, :created_by, :agent_type, :registered_via]

  defp normalize_profile_metadata(profile) do
    meta = profile.metadata || %{}
    %{profile | metadata: Arbor.Common.SafeAtom.atomize_keys(meta, @known_metadata_keys)}
  end

  # Pre-filter at the side-effect boundary: only profiles flagged as external
  # AND whose identity is NOT explicitly revoked make it through to the pure
  # Core. We deliberately keep `:not_found` agents visible — that state happens
  # when the IdentityRegistry (ETS-backed) gets cleared on a dev server restart
  # but the profile lives on in BufferedStore. Hiding those would make any
  # agent registered before a restart vanish from the dashboard.
  #
  # Only `:revoked` is treated as "hide" — that's the user-initiated dead
  # state we set via `Arbor.Security.revoke_identity/2`.
  defp external_and_active?(profile) do
    external? = Map.get(profile.metadata || %{}, :external_agent) == true
    external? and not identity_revoked?(profile.agent_id)
  end

  defp identity_revoked?(agent_id) do
    case Arbor.Security.identity_status(agent_id) do
      {:ok, :revoked} -> true
      {:ok, _} -> false
      {:error, :not_found} -> false
      _ -> false
    end
  rescue
    # Defensive: if the status check crashes (security subsystem missing,
    # registry GenServer down, etc.) we err on the side of showing the agent
    # rather than silently hiding all of the user's registered agents.
    _ -> false
  catch
    :exit, _ -> false
  end

  defp do_register(display_name, agent_type, socket) do
    character = Character.new(name: display_name, tone: "external")

    opts =
      ExternalAgentsCore.build_registration_opts(
        display_name,
        agent_type,
        socket.assigns[:tenant_context]
      )
      |> Keyword.put(:character, character)

    try do
      case Lifecycle.create(display_name, opts) do
        {:ok, profile, identity} -> {:ok, profile, identity}
        {:ok, _profile} -> {:error, :return_identity_not_honored}
        {:error, reason} -> {:error, reason}
      end
    catch
      :exit, _ -> {:error, :security_unavailable}
    end
  end

  defp do_revoke(_agent_id, nil), do: {:error, :not_owner}

  defp do_revoke(agent_id, owner) do
    with {:ok, profile} <- safe_restore(agent_id),
         true <- ExternalAgentsCore.owns?(profile, owner) || {:error, :not_owner},
         :ok <- safe_revoke_identity(agent_id) do
      :ok
    else
      {:error, _} = err -> err
      false -> {:error, :not_owner}
    end
  end

  defp safe_restore(agent_id) do
    case Lifecycle.restore(agent_id) do
      {:ok, profile} -> {:ok, normalize_profile_metadata(profile)}
      {:error, _} = err -> err
    end
  rescue
    _ -> {:error, :security_unavailable}
  catch
    :exit, _ -> {:error, :security_unavailable}
  end

  defp safe_revoke_identity(agent_id) do
    Arbor.Security.revoke_identity(agent_id, reason: "user requested via dashboard")
  rescue
    _ -> {:error, :security_unavailable}
  catch
    :exit, _ -> {:error, :security_unavailable}
  end

  defp do_rename(_agent_id, _new_name, nil), do: {:error, :not_owner}

  defp do_rename(agent_id, new_name, owner) do
    with {:ok, profile} <- safe_restore(agent_id),
         true <- ExternalAgentsCore.owns?(profile, owner) || {:error, :not_owner},
         {:ok, _updated} <- safe_rename(agent_id, new_name) do
      :ok
    else
      {:error, _} = err -> err
      false -> {:error, :not_owner}
    end
  end

  defp safe_rename(agent_id, new_name) do
    Lifecycle.rename(agent_id, new_name)
  rescue
    _ -> {:error, :security_unavailable}
  catch
    :exit, _ -> {:error, :security_unavailable}
  end

  # ===========================================================================
  # Function components
  # ===========================================================================

  @doc "Top-level External Agents card with list, register button, and modals."
  attr :authenticated?, :boolean, required: true
  attr :external_agents_state, :map, required: true
  attr :agent_types, :list, required: true
  attr :show_register_form, :boolean, default: false
  attr :just_registered, :any, default: nil
  attr :external_agents_error, :string, default: nil
  attr :editing_agent_id, :any, default: nil

  def external_agents_section(assigns) do
    ~H"""
    <div>
      <%= if @external_agents_error do %>
        <div style="background: var(--aw-error-bg, #fee); color: var(--aw-error, #c00); padding: 0.75rem 1rem; border-radius: 0.5rem; margin-bottom: 1rem;">
          {@external_agents_error}
        </div>
      <% end %>

      <.card title="External Agents">
        <p style="margin-bottom: 1rem; color: var(--aw-text-muted, #888);">
          Register external tools (Claude Code, Codex, others) to authenticate to this Arbor cluster.
          Each registration generates an Ed25519 keypair; the private key is shown <strong>once</strong>
          and must be copied or downloaded before dismissal.
        </p>

        <%= if not @authenticated? do %>
          <p style="color: var(--aw-text-muted, #888);">
            Sign in to register external agents.
          </p>
        <% else %>
          <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 1rem;">
            <strong>{length(@external_agents_state.rows)} registered</strong>
            <button
              type="button"
              phx-click="external_agents:open_register_form"
              class="aw-button-primary"
              style="padding: 0.5rem 1rem;"
            >
              Register New
            </button>
          </div>

          <%= if @external_agents_state.rows == [] do %>
            <p style="color: var(--aw-text-muted, #888); font-style: italic;">
              No external agents registered yet.
            </p>
          <% else %>
            <.agents_table rows={@external_agents_state.rows} editing_agent_id={@editing_agent_id} />
          <% end %>
        <% end %>
      </.card>

      <.register_form_modal show={@show_register_form} agent_types={@agent_types} />
      <.just_registered_modal just_registered={@just_registered} />
    </div>
    """
  end

  attr :rows, :list, required: true
  attr :editing_agent_id, :any, default: nil

  defp agents_table(assigns) do
    ~H"""
    <table style="width: 100%; border-collapse: collapse;">
      <thead>
        <tr style="border-bottom: 1px solid var(--aw-border, #ddd);">
          <th style="text-align: left; padding: 0.5rem;">Display Name</th>
          <th style="text-align: left; padding: 0.5rem;">Type</th>
          <th style="text-align: left; padding: 0.5rem;">Agent ID</th>
          <th style="text-align: left; padding: 0.5rem;">Created</th>
          <th style="text-align: right; padding: 0.5rem;">Actions</th>
        </tr>
      </thead>
      <tbody>
        <tr
          :for={row <- @rows}
          style="border-bottom: 1px solid var(--aw-border-light, #eee);"
        >
          <td style="padding: 0.5rem;">
            <%= if @editing_agent_id == row.agent_id do %>
              <form id={"rename-form-#{row.agent_id}"} phx-submit="external_agents:submit_rename">
                <input type="hidden" name="agent_id" value={row.agent_id} />
                <input
                  type="text"
                  name="display_name"
                  value={row.display_name}
                  required
                  autofocus
                  style="width: 100%; padding: 0.25rem 0.5rem; border: 1px solid var(--aw-border, #ddd); border-radius: 0.25rem;"
                />
              </form>
            <% else %>
              {row.display_name}
            <% end %>
          </td>
          <td style="padding: 0.5rem;">{row.agent_type}</td>
          <td style="padding: 0.5rem; font-family: monospace; font-size: 0.85em;">
            {String.slice(row.agent_id, 0, 24)}...
          </td>
          <td style="padding: 0.5rem;">{ExternalAgentsCore.format_time(row.created_at)}</td>
          <td style="padding: 0.5rem; text-align: right; white-space: nowrap;">
            <%= if @editing_agent_id == row.agent_id do %>
              <button
                type="submit"
                form={"rename-form-#{row.agent_id}"}
                class="aw-button-primary"
                style="padding: 0.25rem 0.75rem; font-size: 0.85em;"
              >
                Save
              </button>
              <button
                type="button"
                phx-click="external_agents:cancel_rename"
                class="aw-button-secondary"
                style="padding: 0.25rem 0.75rem; font-size: 0.85em;"
              >
                Cancel
              </button>
            <% else %>
              <button
                type="button"
                phx-click="external_agents:start_rename"
                phx-value-agent_id={row.agent_id}
                class="aw-button-secondary"
                style="padding: 0.25rem 0.75rem; font-size: 0.85em;"
              >
                Edit
              </button>
              <button
                type="button"
                phx-click="external_agents:revoke_external_agent"
                phx-value-agent_id={row.agent_id}
                data-confirm={"Revoke #{row.display_name}? This cannot be undone."}
                class="aw-button-danger"
                style="padding: 0.25rem 0.75rem; font-size: 0.85em;"
              >
                Revoke
              </button>
            <% end %>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  attr :show, :boolean, required: true
  attr :agent_types, :list, required: true

  defp register_form_modal(assigns) do
    ~H"""
    <.modal
      id="register-form-modal"
      show={@show}
      title="Register External Agent"
      on_cancel={Phoenix.LiveView.JS.push("external_agents:close_register_form")}
    >
      <form phx-submit="external_agents:submit_registration">
        <div style="margin-bottom: 1rem;">
          <label style="display: block; margin-bottom: 0.25rem; font-weight: 500;">
            Display Name
          </label>
          <input
            type="text"
            name="display_name"
            required
            autofocus
            placeholder="Claude on phone"
            style="width: 100%; padding: 0.5rem; border: 1px solid var(--aw-border, #ddd); border-radius: 0.25rem;"
          />
        </div>

        <div style="margin-bottom: 1rem;">
          <label style="display: block; margin-bottom: 0.25rem; font-weight: 500;">
            Agent Type
          </label>
          <select
            name="agent_type"
            style="width: 100%; padding: 0.5rem; border: 1px solid var(--aw-border, #ddd); border-radius: 0.25rem;"
          >
            <option :for={type <- @agent_types} value={type.type}>{type.label}</option>
          </select>
          <p style="margin-top: 0.5rem; color: var(--aw-text-muted, #888); font-size: 0.85em;">
            Each type ships with a default capability set; you can grant more after registration.
          </p>
        </div>

        <div style="display: flex; gap: 0.5rem; justify-content: flex-end;">
          <button
            type="button"
            phx-click="external_agents:close_register_form"
            class="aw-button-secondary"
          >
            Cancel
          </button>
          <button type="submit" class="aw-button-primary">
            Generate Keypair
          </button>
        </div>
      </form>
    </.modal>
    """
  end

  attr :just_registered, :any, default: nil

  defp just_registered_modal(assigns) do
    ~H"""
    <.modal
      id="just-registered-modal"
      show={@just_registered != nil}
      title="Save Your Private Key"
      on_cancel={Phoenix.LiveView.JS.push("external_agents:dismiss_just_registered")}
    >
      <%= if @just_registered do %>
        <div style="background: var(--aw-warning-bg, #fff8e1); border: 1px solid var(--aw-warning, #f5a623); padding: 0.75rem; border-radius: 0.5rem; margin-bottom: 1rem;">
          <strong>This key is shown only once.</strong>
          Copy it now or download it as a file. After you dismiss this dialog, you cannot retrieve it again — only revoke and re-register.
        </div>

        <div style="margin-bottom: 1rem;">
          <strong>Display name:</strong> {@just_registered.display_name}
        </div>

        <div style="margin-bottom: 1rem;">
          <strong>Agent ID:</strong>
          <code style="font-family: monospace; font-size: 0.85em;">{@just_registered.agent_id}</code>
        </div>

        <div style="margin-bottom: 1rem;">
          <strong>Private key (base64, Ed25519):</strong>
          <textarea
            id="just-registered-key"
            readonly
            rows="4"
            style="width: 100%; font-family: monospace; font-size: 0.8em; margin-top: 0.25rem; padding: 0.5rem; border: 1px solid var(--aw-border, #ddd); border-radius: 0.25rem;"
          >{@just_registered.private_key_b64}</textarea>
        </div>

        <div style="display: flex; gap: 0.5rem; justify-content: flex-end;">
          <button
            type="button"
            onclick={"navigator.clipboard.writeText(document.getElementById('just-registered-key').value); this.textContent='Copied!'"}
            class="aw-button-secondary"
          >
            Copy
          </button>
          <a
            href={download_data_url(@just_registered)}
            download={download_filename(@just_registered)}
            class="aw-button-secondary"
            style="display: inline-block; padding: 0.5rem 1rem; text-decoration: none;"
          >
            Download .key
          </a>
          <button
            type="button"
            phx-click="external_agents:dismiss_just_registered"
            class="aw-button-primary"
          >
            I have saved it
          </button>
        </div>
      <% end %>
    </.modal>
    """
  end

  # Native data URL download — using a real <a download> element instead of
  # the synthetic-click-on-detached-node trick avoids triggering the modal's
  # phx-click-away handler (the synthetic click bubbles from outside the
  # modal subtree and dismisses it before the user can copy the key).
  defp download_data_url(%{agent_id: agent_id, private_key_b64: key}) do
    contents = ExternalAgentsCore.build_key_file_contents(agent_id, key)
    encoded = Base.encode64(contents)
    "data:application/octet-stream;base64," <> encoded
  end

  defp download_filename(%{display_name: name}) do
    ExternalAgentsCore.sanitize_filename(name) <> ".arbor.key"
  end
end
