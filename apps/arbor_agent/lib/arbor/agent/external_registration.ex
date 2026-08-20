defmodule Arbor.Agent.ExternalRegistration do
  @moduledoc """
  Authorized registration of fixed-policy external agents.

  The caller selects a named profile, never an arbitrary capability list. Each
  profile is owned here, at the Agent domain boundary, and filesystem authority
  is limited to the Arbor repository plus the caller's tenant workspace.
  """

  alias Arbor.Agent.{Character, Lifecycle}
  alias Arbor.Contracts.TenantContext

  @max_principal_bytes 256
  @max_display_name_bytes 200
  @max_session_token_bytes 4_096
  @allowed_opts [:identity_verified, :session_token]

  @profiles [
    %{
      type: "claude_code",
      label: "Claude Code",
      description:
        "Anthropic's Claude Code CLI / desktop client with repository-scoped files, reviewed shell tools, HTTP access, and limited agent spawning.",
      capabilities: [
        %{resource: "arbor://fs/read/repo"},
        %{resource: "arbor://fs/write/repo"},
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
      description: "OpenAI Codex CLI with repository-scoped read access, Git, and Arbor tools.",
      capabilities: [
        %{resource: "arbor://fs/read/repo"},
        %{resource: "arbor://shell/exec/git"},
        %{resource: "arbor://tool/use/"}
      ]
    },
    %{
      type: "external",
      label: "Generic External Agent",
      description: "Minimal profile with repository-scoped read access and Arbor tools.",
      capabilities: [
        %{resource: "arbor://fs/read/repo"},
        %{resource: "arbor://tool/use/"}
      ]
    }
  ]

  @type registration_error ::
          :invalid_caller
          | :invalid_display_name
          | :invalid_opts
          | :unsupported_agent_type
          | :unauthorized
          | :security_unavailable
          | {:approval_required, String.t()}
          | term()

  @doc "Return the external-agent profiles available to presentation layers."
  @spec types() :: [map()]
  def types do
    Enum.map(@profiles, &Map.take(&1, [:type, :label, :description]))
  end

  @doc false
  @spec capabilities_for(String.t()) :: {:ok, [map()]} | {:error, :unsupported_agent_type}
  def capabilities_for(type) when is_binary(type) do
    case find_profile(type) do
      nil -> {:error, :unsupported_agent_type}
      profile -> {:ok, profile.capabilities}
    end
  end

  def capabilities_for(_type), do: {:error, :unsupported_agent_type}

  @doc """
  Register an external agent after authorizing the caller for the selected
  fixed profile.

  Accepted options are the caller proof only: `:session_token` for an OIDC
  dashboard session, or `identity_verified: true` for a trusted in-process
  boundary such as the explicitly enabled local-development operator.
  """
  @spec register(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Arbor.Agent.Profile.t(), Arbor.Contracts.Security.Identity.t()}
          | {:error, registration_error()}
  def register(caller_id, display_name, type, opts \\ []) do
    with :ok <- validate_caller(caller_id),
         {:ok, display_name} <- validate_display_name(display_name),
         {:ok, profile} <- fetch_profile(type),
         {:ok, auth_opts} <- validate_auth_opts(opts),
         :ok <- authorize(caller_id, type, auth_opts) do
      create(caller_id, display_name, profile)
    end
  end

  defp create(caller_id, display_name, profile) do
    tenant_context = TenantContext.new(caller_id)

    opts = [
      character: Character.new(name: display_name, tone: "external"),
      capabilities: profile.capabilities,
      tenant_context: tenant_context,
      metadata: %{
        external_agent: true,
        agent_type: profile.type,
        registered_via: "external_registration"
      },
      return_identity: true
    ]

    case Lifecycle.create(display_name, opts) do
      {:ok, agent_profile, identity} -> {:ok, agent_profile, identity}
      {:ok, _agent_profile} -> {:error, :return_identity_not_honored}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, {:registration_exception, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:registration_exit, reason}}
    kind, reason -> {:error, {:registration_failure, kind, reason}}
  end

  defp authorize(caller_id, type, auth_opts) do
    resource = "arbor://agent/lifecycle/create/external/#{type}"

    case Arbor.Security.authorize(caller_id, resource, :create, auth_opts) do
      {:ok, :authorized} -> :ok
      {:ok, :pending_approval, approval_id} -> {:error, {:approval_required, approval_id}}
      {:error, _reason} -> {:error, :unauthorized}
      _other -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :security_unavailable}
  catch
    :exit, _ -> {:error, :security_unavailable}
    _, _ -> {:error, :security_unavailable}
  end

  defp validate_caller(caller_id)
       when is_binary(caller_id) and byte_size(caller_id) > 0 and
              byte_size(caller_id) <= @max_principal_bytes,
       do: :ok

  defp validate_caller(_caller_id), do: {:error, :invalid_caller}

  defp validate_display_name(display_name)
       when is_binary(display_name) and byte_size(display_name) > 0 and
              byte_size(display_name) <= @max_display_name_bytes do
    if String.valid?(display_name) and String.trim(display_name) != "" do
      {:ok, String.trim(display_name)}
    else
      {:error, :invalid_display_name}
    end
  end

  defp validate_display_name(_display_name), do: {:error, :invalid_display_name}

  defp fetch_profile(type) when is_binary(type) do
    case find_profile(type) do
      nil -> {:error, :unsupported_agent_type}
      profile -> {:ok, profile}
    end
  end

  defp fetch_profile(_type), do: {:error, :unsupported_agent_type}

  defp find_profile(type), do: Enum.find(@profiles, &(&1.type == type))

  defp validate_auth_opts(opts) when is_list(opts) do
    keys =
      Enum.map(opts, fn
        {key, _value} when is_atom(key) -> key
        _other -> :invalid
      end)

    session_token = Keyword.get(opts, :session_token)
    identity_verified = Keyword.get(opts, :identity_verified, false)

    cond do
      not Keyword.keyword?(opts) ->
        {:error, :invalid_opts}

      length(keys) != length(Enum.uniq(keys)) ->
        {:error, :invalid_opts}

      not Enum.all?(keys, &(&1 in @allowed_opts)) ->
        {:error, :invalid_opts}

      not valid_session_token?(session_token) ->
        {:error, :invalid_opts}

      identity_verified not in [true, false] ->
        {:error, :invalid_opts}

      identity_verified and not is_nil(session_token) ->
        {:error, :invalid_opts}

      true ->
        {:ok, compact_auth_opts(session_token, identity_verified)}
    end
  rescue
    _ -> {:error, :invalid_opts}
  end

  defp validate_auth_opts(_opts), do: {:error, :invalid_opts}

  defp valid_session_token?(nil), do: true

  defp valid_session_token?(token) when is_binary(token) do
    byte_size(token) > 0 and byte_size(token) <= @max_session_token_bytes
  end

  defp valid_session_token?(_token), do: false

  defp compact_auth_opts(session_token, identity_verified) do
    []
    |> maybe_put(:session_token, session_token, not is_nil(session_token))
    |> maybe_put(:identity_verified, true, identity_verified)
  end

  defp maybe_put(opts, key, value, true), do: Keyword.put(opts, key, value)
  defp maybe_put(opts, _key, _value, false), do: opts
end
