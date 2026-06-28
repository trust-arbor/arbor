defmodule Arbor.Gateway.Chat.Agents do
  @moduledoc """
  Builds the "agents this principal may chat with" listing for the
  `GET /api/chat/agents` endpoint (`Arbor.Gateway.Chat.Router`).

  Discovery has to work while DETACHED (no WebSocket) — that's exactly when a
  client needs to find an agent to attach to — so this is a plain signed HTTP
  GET, not a WS frame.

  The *authorization* set is derived purely from the principal's **capabilities**:
  the chat gate is a capability-presence check on `arbor://chat/agent/<id>` (see
  `Arbor.Gateway.Chat.Socket.authorized_to_chat?/2`). We keep the caps whose
  `resource_uri` matches that namespace and extract the `<id>`.

  Resolution mirrors `mix arbor.agent list --all` (the canonical agent listing,
  `Mix.Tasks.Arbor.Agent`): an authorized agent is listed whether it is RUNNING
  OR STOPPED. Running agents come from the agent-manager/registry (alive +
  metadata → `model`); stopped-but-authorized agents come from the persisted
  profile (`Lifecycle.list_agents` → `display_name`/`template`). Listing stopped
  agents matters — that's what the upcoming `/start` lifecycle command acts on.

  Cross-app reach (Security / Agent.Manager / Agent.Lifecycle are at/above this
  app's level) goes through the same `bridge_call/3` runtime indirection the
  Socket + MCP.Handler use — no compile-time deps on arbor_security/arbor_agent
  are added. Resolution never crashes on a stale id: an id that resolves to
  neither a live agent nor a profile is reported `running: false` with the bare
  id as its name and "-" for template/model.
  """

  require Logger

  @chat_prefix "arbor://chat/agent/"

  @typedoc "One listed agent (string-keyed for JSON)."
  @type agent :: %{
          required(String.t()) => String.t() | boolean()
        }

  @doc """
  Returns the list of agents `principal` is authorized to chat with.

  Each entry is a string-keyed map `%{"agent_id", "display_name", "template",
  "model", "running"}`. Returns `[]` when the principal holds no chat
  capabilities (or the security subsystem is unreachable).
  """
  @spec list_for_principal(String.t()) :: [agent()]
  def list_for_principal(principal) when is_binary(principal) do
    ids = chat_agent_ids(principal)
    profiles = list_profiles()

    Enum.map(ids, &resolve_agent(&1, profiles))
  end

  @doc """
  Resolve a single agent's human-friendly display name (live registry metadata →
  persisted profile → the bare id as fallback). Used by the chat Socket to label
  the attached agent in the client header.
  """
  @spec display_name_for(String.t()) :: String.t()
  def display_name_for(agent_id) when is_binary(agent_id) do
    resolve_agent(agent_id, list_profiles())["display_name"] || agent_id
  end

  @typedoc "Why a token couldn't be resolved to a single agent."
  @type resolve_error :: :not_found | {:ambiguous, [agent()]}

  @doc """
  Resolve a user-typed token to a full agent_id, SCOPED to the agents `principal`
  is authorized to chat with (so a prefix can never reveal an agent the caller
  can't access). Lets users type something short instead of the full
  `agent_<64hex>`.

  Match precedence (first tier with any match wins; >1 in that tier ⇒ ambiguous):

    1. a user-defined alias (exact), if it still points at an authorized agent
    2. an exact full agent_id
    3. an exact display_name (case-insensitive)
    4. a unique agent_id prefix
    5. a unique display_name prefix (case-insensitive)

  Returns `{:ok, agent_id}`, `{:error, :not_found}`, or
  `{:error, {:ambiguous, candidates}}` (the matching agent maps, for a helpful
  "did you mean" message).
  """
  @spec resolve_token(String.t(), String.t()) :: {:ok, String.t()} | {:error, resolve_error()}
  def resolve_token(principal, token) when is_binary(principal) and is_binary(token) do
    do_resolve(String.trim(token), list_for_principal(principal), aliases_for(principal))
  end

  defp do_resolve("", _agents, _aliases), do: {:error, :not_found}

  defp do_resolve(token, agents, aliases) do
    ids = Enum.map(agents, & &1["agent_id"])
    aliased = Map.get(aliases, token)
    down = String.downcase(token)

    cond do
      # 1. user alias — only if it still resolves to an authorized agent
      is_binary(aliased) and aliased in ids ->
        {:ok, aliased}

      # 2. exact full id
      token in ids ->
        {:ok, token}

      true ->
        # 3→5: first non-empty tier decides; a tie within a tier is ambiguous
        [
          Enum.filter(agents, &(String.downcase(&1["display_name"] || "") == down)),
          Enum.filter(agents, &String.starts_with?(&1["agent_id"], token)),
          Enum.filter(
            agents,
            &String.starts_with?(String.downcase(&1["display_name"] || ""), down)
          )
        ]
        |> Enum.find(&(&1 != []))
        |> case do
          nil -> {:error, :not_found}
          [only] -> {:ok, only["agent_id"]}
          many -> {:error, {:ambiguous, many}}
        end
    end
  end

  # Per-principal user-defined aliases (`nickname => agent_id`). Stubbed empty in
  # Phase 1; Phase 2 backs this with a per-user store + the /alias command.
  defp aliases_for(_principal), do: %{}

  # ── Authorization: chat-cap ids ───────────────────────────────────────────

  defp chat_agent_ids(principal) do
    case bridge_call(security_mod(), :list_capabilities, [principal, []]) do
      {:ok, {:ok, caps}} when is_list(caps) -> extract_ids(caps)
      {:ok, caps} when is_list(caps) -> extract_ids(caps)
      _ -> []
    end
  end

  defp extract_ids(caps) do
    caps
    |> Enum.map(&resource_uri/1)
    |> Enum.filter(&match?(@chat_prefix <> _rest, &1 || ""))
    |> Enum.map(fn @chat_prefix <> id -> id end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp resource_uri(%{resource_uri: uri}) when is_binary(uri), do: uri
  defp resource_uri(%{"resource_uri" => uri}) when is_binary(uri), do: uri
  defp resource_uri(uri) when is_binary(uri), do: uri
  defp resource_uri(_), do: nil

  # ── Persisted profiles (for stopped + name/template) ──────────────────────

  # Indexed by agent_id so each id is a cheap lookup. list_agents/0 reads the
  # ProfileStore without per-agent signal side effects (unlike Lifecycle.restore).
  defp list_profiles do
    case bridge_call(lifecycle_mod(), :list_agents, []) do
      {:ok, profiles} when is_list(profiles) ->
        Map.new(profiles, fn p -> {profile_field(p, :agent_id), p} end)

      _ ->
        %{}
    end
  end

  # ── Per-agent resolution (running ⊕ stopped) ──────────────────────────────

  # find_agent/1 returns {:ok, pid, metadata} for a live agent → running, with
  # the model from metadata.model_config.id; the profile (if any) supplies the
  # display name + template. Anything else means it isn't running right now — we
  # fall back to the persisted profile, or the bare id if there's no profile.
  defp resolve_agent(agent_id, profiles) do
    profile = Map.get(profiles, agent_id)

    case bridge_call(agent_manager(), :find_agent, [agent_id]) do
      {:ok, {:ok, pid, metadata}} when is_pid(pid) ->
        %{
          "agent_id" => agent_id,
          "display_name" => display_name(metadata, profile, agent_id),
          "template" => template(profile),
          "model" => model_from_metadata(metadata),
          "running" => true
        }

      _ ->
        %{
          "agent_id" => agent_id,
          "display_name" => display_name(nil, profile, agent_id),
          "template" => template(profile),
          "model" => "-",
          "running" => false
        }
    end
  end

  # Prefer the live registry metadata name, then the persisted profile, then the
  # bare id (never crash on a stale id).
  defp display_name(metadata, profile, agent_id) do
    metadata_name(metadata) || profile_name(profile) || agent_id
  end

  defp metadata_name(metadata) when is_map(metadata) do
    case Map.get(metadata, :display_name) || Map.get(metadata, "display_name") do
      name when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  defp metadata_name(_), do: nil

  defp profile_name(nil), do: nil

  defp profile_name(profile) do
    case profile_field(profile, :display_name) do
      name when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  # Mirror Mix.Tasks.Arbor.Agent.format_template/1.
  defp template(nil), do: "-"

  defp template(profile) do
    case profile_field(profile, :template) do
      nil -> "-"
      t when is_binary(t) -> t
      t when is_atom(t) -> Atom.to_string(t)
      other -> to_string(other)
    end
  end

  defp model_from_metadata(metadata) when is_map(metadata) do
    case get_in(metadata, [:model_config, :id]) ||
           get_in(metadata, ["model_config", "id"]) do
      id when is_binary(id) -> id
      _ -> "-"
    end
  end

  defp model_from_metadata(_), do: "-"

  # Profile may be a struct (production) or a plain map (tests/fakes).
  defp profile_field(profile, key) when is_map(profile) do
    Map.get(profile, key) || Map.get(profile, Atom.to_string(key))
  end

  defp profile_field(_, _), do: nil

  # ── Bridge + config seams ─────────────────────────────────────────────────

  # Returns {:ok, result} | {:error, reason}; never raises. Mirror of
  # Socket.bridge_call/3.
  defp bridge_call(module, function, args) do
    if Code.ensure_loaded?(module) do
      {:ok, apply(module, function, args)}
    else
      {:error, :not_available}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # Config-resolved collaborators so tests can inject fakes — same keys the
  # Socket uses where they overlap (`:chat_security` = Arbor.Security;
  # `:chat_agent_manager` = Arbor.Agent.Manager). `:chat_lifecycle` is new (for
  # the persisted-profile / stopped-agent listing).
  defp security_mod,
    do: Application.get_env(:arbor_gateway, :chat_security, Arbor.Security)

  defp agent_manager,
    do: Application.get_env(:arbor_gateway, :chat_agent_manager, Arbor.Agent.Manager)

  defp lifecycle_mod,
    do: Application.get_env(:arbor_gateway, :chat_lifecycle, Arbor.Agent.Lifecycle)
end
