defmodule Arbor.Dashboard.Cores.ExternalAgentsCore do
  @moduledoc """
  Pure business logic for the External Agents section of the Settings page.

  Follows the Construct-Reduce-Convert pattern. All functions are pure
  and side-effect free — no Lifecycle calls, no Security calls, no DateTime.utc_now.

  ## Pipeline

      profiles
      |> ExternalAgentsCore.new(owner_agent_id)
      |> ExternalAgentsCore.show_table()

  ## Responsibilities

  - Static template definitions for known agent types
  - Filtering profiles to "external agents owned by this user"
  - Formatting profiles for display in the table
  - Building option lists for `Arbor.Agent.Lifecycle.create/2`
  - Display formatting (timestamps, error messages, filenames)

  Side effects (calling `Lifecycle.create`, `Security.revoke_identity`,
  `Lifecycle.list_agents`) live in `Arbor.Dashboard.Components.ExternalAgentsComponent`.
  """

  # ===========================================================================
  # Static configuration — agent type templates
  # ===========================================================================

  @agent_types [
    %{
      type: "claude_code",
      label: "Claude Code",
      description:
        "Anthropic's Claude Code CLI / desktop client. Default capabilities mirror the legacy ClaudeSession bridge: filesystem read/write, safe shell commands, web fetch, and limited agent spawning.",
      capabilities: [
        %{resource: "arbor://fs/read/**"},
        %{resource: "arbor://fs/write/**"},
        %{resource: "arbor://shell/exec/git"},
        %{resource: "arbor://shell/exec/mix"},
        %{resource: "arbor://shell/exec/elixir"},
        %{resource: "arbor://shell/exec/iex"},
        %{resource: "arbor://shell/exec/ls"},
        %{resource: "arbor://shell/exec/grep"},
        %{resource: "arbor://shell/exec/find"},
        %{resource: "arbor://shell/exec/curl"},
        %{resource: "arbor://agent/spawn"},
        %{resource: "arbor://net/http/"},
        %{resource: "arbor://tool/use/"}
      ]
    },
    %{
      type: "codex",
      label: "OpenAI Codex CLI",
      description: "Reserved for future use. Same default cap set as Claude Code.",
      capabilities: [
        %{resource: "arbor://fs/read/**"},
        %{resource: "arbor://shell/exec/git"},
        %{resource: "arbor://tool/use/"}
      ]
    },
    %{
      type: "external",
      label: "Generic External Agent",
      description:
        "Minimal cap set: read-only filesystem and tool use. Grant more after registration if needed.",
      capabilities: [
        %{resource: "arbor://fs/read/**"},
        %{resource: "arbor://tool/use/"}
      ]
    }
  ]

  @doc "Return the static list of available agent type templates."
  @spec agent_types() :: [map()]
  def agent_types, do: @agent_types

  @doc """
  Look up an agent type template by its `type` string.

  Falls back to the last entry (the generic `external` template) when the
  requested type is unknown, so the registration handler always has a usable
  template even for typos or removed types.
  """
  @spec find_agent_type(String.t()) :: map()
  def find_agent_type(type) when is_binary(type) do
    Enum.find(@agent_types, List.last(@agent_types), fn t -> t.type == type end)
  end

  # ===========================================================================
  # Construct
  # ===========================================================================

  @type agent_row :: %{
          agent_id: String.t(),
          display_name: String.t(),
          agent_type: String.t(),
          created_at: DateTime.t() | nil
        }

  @type state :: %{
          owner_agent_id: String.t() | nil,
          rows: [agent_row()]
        }

  @doc """
  Build display state from a list of `Arbor.Agent.Profile` structs and the
  owner's agent_id. Filters to external agents owned by the given owner and
  shapes them into rows for the table.

  When `owner_agent_id` is `nil` (unauthenticated session), returns an empty list.
  """
  @spec new([map()], String.t() | nil) :: state()
  def new(_profiles, nil) do
    %{owner_agent_id: nil, rows: []}
  end

  def new(profiles, owner_agent_id) when is_list(profiles) and is_binary(owner_agent_id) do
    rows =
      profiles
      |> Enum.filter(&owned_external_agent?(&1, owner_agent_id))
      |> Enum.map(&profile_to_row/1)
      |> Enum.sort_by(fn r -> r.created_at end, &compare_datetime_desc/2)

    %{owner_agent_id: owner_agent_id, rows: rows}
  end

  defp owned_external_agent?(profile, owner_agent_id) do
    meta = profile.metadata || %{}
    Map.get(meta, :external_agent) == true and Map.get(meta, :created_by) == owner_agent_id
  end

  defp profile_to_row(profile) do
    meta = profile.metadata || %{}

    %{
      agent_id: profile.agent_id,
      display_name: profile.display_name || profile.agent_id,
      agent_type: Map.get(meta, :agent_type, "external"),
      created_at: profile.created_at
    }
  end

  defp compare_datetime_desc(nil, nil), do: true
  defp compare_datetime_desc(nil, _), do: false
  defp compare_datetime_desc(_, nil), do: true

  defp compare_datetime_desc(%DateTime{} = a, %DateTime{} = b) do
    DateTime.compare(a, b) != :lt
  end

  # ===========================================================================
  # Reduce — pure builders for downstream side-effect callers
  # ===========================================================================

  @doc """
  Build the keyword list of options for `Arbor.Agent.Lifecycle.create/2` to
  register a new external agent.

  Pure: takes the display name, agent type string, and tenant context, returns
  the opts. The caller is responsible for actually invoking Lifecycle.

  Always sets `return_identity: true` so the caller can hand the freshly-generated
  private key to the human operator exactly once.
  """
  @spec build_registration_opts(String.t(), String.t(), any()) :: keyword()
  def build_registration_opts(display_name, agent_type, tenant_context) do
    template = find_agent_type(agent_type)

    [
      capabilities: template.capabilities,
      tenant_context: tenant_context,
      metadata: %{
        external_agent: true,
        agent_type: agent_type,
        registered_via: "dashboard"
      },
      return_identity: true
    ]
    |> maybe_add_display_name(display_name)
  end

  defp maybe_add_display_name(opts, nil), do: opts
  defp maybe_add_display_name(opts, ""), do: opts
  defp maybe_add_display_name(opts, _name), do: opts

  @doc """
  Check whether a given owner is the registered owner of a given profile.

  Used by the revoke handler to enforce that users can only revoke their own
  registered agents.
  """
  @spec owns?(map(), String.t()) :: boolean()
  def owns?(profile, owner_agent_id) when is_binary(owner_agent_id) do
    owned_external_agent?(profile, owner_agent_id)
  end

  def owns?(_profile, _), do: false

  @doc """
  Registration requires an authenticated principal. Fail closed when the
  session has no owner — the UI hiding Register New is not an authz gate.
  """
  @spec require_principal(String.t() | nil) :: :ok | {:error, :unauthenticated}
  def require_principal(owner_agent_id) when is_binary(owner_agent_id) and owner_agent_id != "",
    do: :ok

  def require_principal(_), do: {:error, :unauthenticated}

  @doc """
  Auto-save of private keys is local-dev only and must be explicitly enabled.
  """
  @spec auto_save_allowed?(boolean(), boolean()) :: boolean()
  def auto_save_allowed?(true, true), do: true
  def auto_save_allowed?(_, _), do: false

  @doc """
  Filename for a dashboard-issued `.arbor.key`: `<name>_<id8>.arbor.key`.
  """
  @spec key_filename(String.t(), String.t()) :: String.t()
  def key_filename(display_name, agent_id) do
    sanitize_filename(display_name) <> "_" <> agent_id8(agent_id) <> ".arbor.key"
  end

  defp agent_id8(agent_id) when is_binary(agent_id) do
    agent_id
    |> String.replace_prefix("agent_", "")
    |> String.slice(0, 8)
    |> case do
      "" -> "agent"
      id8 -> id8
    end
  end

  @doc """
  Ready-to-paste `mcpServers` JSON for `mix arbor.signer`.

  `repo_root`, `key_path`, and `upstream` are POSIX-single-quoted so a
  path with spaces cannot split the `sh -c` command string.
  """
  @spec build_mcp_servers_json(String.t(), String.t(), String.t()) :: String.t()
  def build_mcp_servers_json(repo_root, key_path, upstream \\ "http://localhost:4000/mcp") do
    command =
      "cd #{shell_quote(repo_root)} && exec ./bin/mix arbor.signer " <>
        "--key-file #{shell_quote(key_path)} --upstream #{shell_quote(upstream)}"

    Jason.encode!(
      %{
        "mcpServers" => %{
          "arbor" => %{
            "command" => "sh",
            "args" => ["-c", command]
          }
        }
      },
      pretty: true
    )
  end

  # POSIX single-quote wrapping: the only special character inside single
  # quotes is the quote itself, rewritten as `'\''` (end, escaped quote, start).
  defp shell_quote(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  @doc """
  Attach local-dev client-config fields (saved key path + MCP JSON) to the
  one-time registration view. Pure: the caller supplies paths.
  """
  @spec attach_client_config(map(), keyword()) :: map()
  def attach_client_config(view, opts) when is_map(view) and is_list(opts) do
    repo_root = Keyword.get(opts, :repo_root, "/absolute/path/to/arbor")
    upstream = Keyword.get(opts, :upstream, "http://localhost:4000/mcp")
    saved_key_path = Keyword.get(opts, :saved_key_path)

    key_path =
      saved_key_path ||
        Path.join(repo_root, key_filename(view.display_name || "external_agent", view.agent_id))

    Map.merge(view, %{
      saved_key_path: saved_key_path,
      mcp_json: build_mcp_servers_json(repo_root, key_path, upstream)
    })
  end

  # ===========================================================================
  # Convert — display formatting
  # ===========================================================================

  @doc "Format the result of a successful registration for the one-time key modal."
  @spec build_just_registered_view(map(), map(), String.t()) :: map()
  def build_just_registered_view(profile, identity, agent_type) do
    %{
      display_name: profile.display_name,
      agent_id: profile.agent_id,
      agent_type: agent_type,
      private_key_b64: Base.encode64(identity.private_key),
      public_key_hex: Base.encode16(identity.public_key, case: :lower)
    }
  end

  @doc """
  Build the contents of the downloadable `.arbor.key` file for the
  just-registered modal.
  """
  @spec build_key_file_contents(String.t(), String.t()) :: String.t()
  def build_key_file_contents(agent_id, private_key_b64) do
    "agent_id=" <> agent_id <> "\nprivate_key_b64=" <> private_key_b64 <> "\n"
  end

  @doc """
  Sanitize a display name into a safe filename component.

  Lowercases, replaces non-alphanumeric runs with underscores, trims leading
  and trailing underscores, and falls back to `external_agent` if the result
  is empty.
  """
  @spec sanitize_filename(String.t()) :: String.t()
  def sanitize_filename(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "external_agent"
      n -> n
    end
  end

  @doc "Format a DateTime for display in the agents table."
  @spec format_time(any()) :: String.t()
  def format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  def format_time(_), do: "—"

  @doc "Translate an internal error reason into a user-friendly message."
  @spec format_error(any()) :: String.t()
  def format_error(:not_owner), do: "You can only modify agents you registered."
  def format_error(:unauthenticated), do: "Sign in to register external agents."
  def format_error(:security_unavailable), do: "Security subsystem unavailable. Try again later."

  def format_error(:return_identity_not_honored),
    do: "Internal error: registration did not return an identity."

  def format_error({:error, reason}), do: "Registration failed: #{inspect(reason)}"
  def format_error(reason) when is_atom(reason), do: "Error: #{reason}"
  def format_error(reason), do: "Error: #{inspect(reason)}"
end
