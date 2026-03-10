defmodule Arbor.AI.AcpPool.SessionProfile do
  @moduledoc """
  Describes the configuration and identity of an ACP session.

  Used by `AcpPool` to match checkout requests to compatible sessions.
  Matching is hash-based: two profiles are compatible if they have the
  same `profile_hash` (derived from provider + tool modules).

  ## Fields

  - `provider` — CLI agent type (`:claude`, `:gemini`, etc.)
  - `tool_modules` — list of Jido action modules available to this session
  - `agent_id` — owning Arbor agent ID
  - `trust_domain` — security boundary; sessions never cross domains
  - `name` — human-readable identifier for dashboards
  - `tags` — arbitrary metadata map for developer grouping
  - `affinity_key` — for sticky routing (same key → same session)
  - `trust_tier` — agent's trust level
  - `workspace` — filesystem scope/path for the CLI agent
  - `profile_hash` — computed SHA of provider + sorted tool modules (for O(1) matching)

  ## Matching Rules

  1. Same `affinity_key` → return exact session (hard affinity)
  2. Same `profile_hash` + same `trust_domain` → compatible for reuse
  3. Different `agent_id` → never reuse (ephemeral by default)
  4. No match → mint fresh session
  """

  @type t :: %__MODULE__{
          provider: atom(),
          tool_modules: [module()],
          agent_id: String.t() | nil,
          trust_domain: atom() | nil,
          name: String.t() | nil,
          tags: map(),
          affinity_key: String.t() | nil,
          trust_tier: atom() | nil,
          workspace: String.t() | nil,
          profile_hash: String.t() | nil
        }

  defstruct [
    :provider,
    :agent_id,
    :trust_domain,
    :name,
    :affinity_key,
    :trust_tier,
    :workspace,
    :profile_hash,
    tool_modules: [],
    tags: %{}
  ]

  @doc """
  Build a SessionProfile from options, computing the profile hash.

  ## Options

  Accepts all struct fields as keyword opts. `profile_hash` is computed
  automatically from `provider` and `tool_modules`.

      SessionProfile.new(provider: :claude, tool_modules: [Trust.ListPresets])
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    profile = struct!(__MODULE__, opts)
    %{profile | profile_hash: compute_hash(profile)}
  end

  @doc """
  Build a SessionProfile from a map (e.g., from pool checkout opts).
  """
  @spec from_opts(atom(), keyword()) :: t()
  def from_opts(provider, opts) do
    new(
      provider: provider,
      tool_modules: Keyword.get(opts, :tool_modules, []),
      agent_id: Keyword.get(opts, :agent_id),
      trust_domain: Keyword.get(opts, :trust_domain),
      name: Keyword.get(opts, :name) || generate_name(provider, opts),
      tags: Keyword.get(opts, :tags, %{}),
      affinity_key: Keyword.get(opts, :affinity_key),
      trust_tier: Keyword.get(opts, :trust_tier),
      workspace: Keyword.get(opts, :workspace)
    )
  end

  @doc """
  Check if two profiles are compatible for session reuse.

  Compatible means: same profile hash, same trust domain, same agent_id.
  Different agent_ids are never compatible (ephemeral by default).
  """
  @spec compatible?(t(), t()) :: boolean()
  def compatible?(%__MODULE__{} = a, %__MODULE__{} = b) do
    a.profile_hash == b.profile_hash and
      a.trust_domain == b.trust_domain and
      same_agent?(a.agent_id, b.agent_id)
  end

  @doc """
  Generate the URN for this profile.

  Format: `acp:<provider>:<agent_id>:<hash_prefix>`
  """
  @spec urn(t()) :: String.t()
  def urn(%__MODULE__{} = profile) do
    agent = profile.agent_id || "anonymous"
    hash_prefix = String.slice(profile.profile_hash || "0000", 0, 8)
    "acp:#{profile.provider}:#{agent}:#{hash_prefix}"
  end

  # -- Private --

  defp compute_hash(%__MODULE__{provider: provider, tool_modules: tools}) do
    sorted_tools =
      tools
      |> Enum.map(&to_string/1)
      |> Enum.sort()

    input = "#{provider}:#{Enum.join(sorted_tools, ",")}"
    :crypto.hash(:sha256, input) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  defp same_agent?(nil, _), do: true
  defp same_agent?(_, nil), do: true
  defp same_agent?(a, b), do: a == b

  defp generate_name(provider, opts) do
    agent_id = Keyword.get(opts, :agent_id)
    tools = Keyword.get(opts, :tool_modules, [])

    tool_hint =
      case tools do
        [] -> "general"
        [single] -> single |> Module.split() |> List.last() |> Macro.underscore()
        multiple -> "#{length(multiple)}-tools"
      end

    parts = [to_string(provider), tool_hint]
    parts = if agent_id, do: parts ++ [short_id(agent_id)], else: parts
    Enum.join(parts, "-")
  end

  defp short_id(id) when is_binary(id) do
    if String.length(id) > 8, do: String.slice(id, -8, 8), else: id
  end

  defp short_id(id), do: to_string(id)
end
