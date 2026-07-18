defmodule Arbor.AI.AcpPool.SessionProfile do
  @moduledoc """
  Describes the immutable configuration and identity of an ACP pool session.

  Used by `AcpPool` to match checkout requests to compatible sessions.
  Matching is fail-closed and hash-based: two profiles are compatible only when
  every immutable reuse boundary matches exactly.

  ## Fields

  - `provider` — CLI agent type (`:claude`, `:gemini`, etc.)
  - `tool_modules` — list of Jido action modules available to this session
  - `agent_id` — owning Arbor agent ID (`nil` matches only `nil`)
  - `trust_domain` — security boundary; sessions never cross domains
  - `model` — model override bound at session start
  - `cwd` — canonical workspace/cwd bound at session start
  - `task_id` — coding task scope; pooled coding checkouts are task-scoped
  - `startup_fingerprint` — full SHA-256 hex digest of immutable startup opts
    (`adapter_opts`, `client_opts`, `capabilities`); raw values are never stored
  - `name` — human-readable identifier for dashboards
  - `tags` — arbitrary metadata map for developer grouping
  - `affinity_key` — sticky routing key (same key → same session only when
    the full profile is also compatible)
  - `profile_hash` — full SHA-256 hex digest over every immutable reuse boundary

  ## Matching Rules

  1. Same `affinity_key` returns that session only when profiles are fully
     compatible; incompatible affinity is an explicit conflict, busy affinity
     is an explicit busy error
  2. Same `profile_hash` (provider, tools, agent, trust, model, cwd, task,
     startup fingerprint) → eligible for local process reuse
  3. Different task/cwd/model/agent/trust/startup config → never reuse
  4. Explicit cross-task provider continuity uses `resume_provider` +
     `resume_session_id` and must mint a fresh local process before loading
     that provider conversation
  5. No match → mint fresh session
  """

  @type t :: %__MODULE__{
          provider: atom(),
          tool_modules: [module()],
          agent_id: String.t() | nil,
          trust_domain: atom() | nil,
          model: String.t() | nil,
          cwd: String.t() | nil,
          task_id: String.t() | nil,
          startup_fingerprint: String.t() | nil,
          name: String.t() | nil,
          tags: map(),
          affinity_key: String.t() | nil,
          profile_hash: String.t() | nil
        }

  defstruct [
    :provider,
    :agent_id,
    :trust_domain,
    :model,
    :cwd,
    :task_id,
    :startup_fingerprint,
    :name,
    :affinity_key,
    :profile_hash,
    tool_modules: [],
    tags: %{}
  ]

  # Keys accepted by struct!/2. Startup config keys are consumed before construct.
  @struct_keys [
    :provider,
    :tool_modules,
    :agent_id,
    :trust_domain,
    :model,
    :cwd,
    :task_id,
    :startup_fingerprint,
    :name,
    :tags,
    :affinity_key,
    :profile_hash
  ]

  @doc """
  Build a SessionProfile from options, computing the profile hash.

  ## Options

  Accepts all struct fields as keyword opts plus startup config keys
  `:adapter_opts`, `:client_opts`, and `:capabilities` (fingerprinted only;
  never stored). `profile_hash` is computed automatically.

      SessionProfile.new(provider: :claude, tool_modules: [Trust.ListPresets])
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    {explicit_fp, opts} = Keyword.pop(opts, :startup_fingerprint)

    {adapter_opts, opts} = Keyword.pop(opts, :adapter_opts)
    {client_opts, opts} = Keyword.pop(opts, :client_opts)
    {capabilities, opts} = Keyword.pop(opts, :capabilities)

    startup_fp =
      case explicit_fp do
        fp when is_binary(fp) and fp != "" ->
          fp

        _ ->
          compute_startup_fingerprint(
            adapter_opts: adapter_opts,
            client_opts: client_opts,
            capabilities: capabilities
          )
      end

    profile_opts =
      opts
      |> Keyword.take(@struct_keys)
      |> Keyword.put(:startup_fingerprint, startup_fp)

    profile = struct!(__MODULE__, profile_opts)
    %{profile | profile_hash: compute_hash(profile)}
  end

  @doc """
  Build a SessionProfile from a pool checkout provider and keyword opts.
  """
  @spec from_opts(atom(), keyword()) :: t()
  def from_opts(provider, opts) when is_atom(provider) and is_list(opts) do
    cwd = canonical_cwd(Keyword.get(opts, :cwd) || Keyword.get(opts, :workspace))

    new(
      provider: provider,
      tool_modules: normalize_tool_modules(Keyword.get(opts, :tool_modules, [])),
      agent_id: normalize_optional_id(Keyword.get(opts, :agent_id)),
      trust_domain: Keyword.get(opts, :trust_domain),
      model: normalize_model(Keyword.get(opts, :model)),
      cwd: cwd,
      task_id: normalize_optional_id(Keyword.get(opts, :task_id)),
      name: Keyword.get(opts, :name) || generate_name(provider, opts),
      tags: normalize_tags(Keyword.get(opts, :tags, %{})),
      affinity_key: normalize_optional_id(Keyword.get(opts, :affinity_key)),
      adapter_opts: Keyword.get(opts, :adapter_opts),
      client_opts: Keyword.get(opts, :client_opts),
      capabilities: Keyword.get(opts, :capabilities)
    )
  end

  @doc """
  Check if two profiles are compatible for session reuse.

  Fail-closed: every immutable boundary must match exactly. `nil` agent_id or
  task_id matches only `nil` (never a wildcard for a non-nil identity).
  """
  @spec compatible?(t(), t()) :: boolean()
  def compatible?(%__MODULE__{} = a, %__MODULE__{} = b) do
    a.profile_hash == b.profile_hash and
      a.provider == b.provider and
      a.agent_id == b.agent_id and
      a.trust_domain == b.trust_domain and
      a.model == b.model and
      a.cwd == b.cwd and
      a.task_id == b.task_id and
      a.startup_fingerprint == b.startup_fingerprint and
      normalize_tool_modules(a.tool_modules) == normalize_tool_modules(b.tool_modules)
  end

  @doc """
  True when this profile requires a per-session ToolServer / MCP endpoint.

  Tool-enabled sessions must not be returned idle after ToolServer teardown
  because provider MCP registration is immutable at session create time.
  """
  @spec tool_enabled?(t()) :: boolean()
  def tool_enabled?(%__MODULE__{tool_modules: tools}) when is_list(tools), do: tools != []
  def tool_enabled?(_), do: false

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

  @doc """
  Full SHA-256 hex digest of immutable caller-controlled startup configuration.

  Canonicalizes `adapter_opts`, `client_opts`, and `capabilities` completely
  (including secret-bearing values) then hashes the deterministic term encoding.
  Only the digest is retained — never the raw material.

  Terms that cannot be safely/completely canonicalized yield a unique
  non-reusable fingerprint so distinct or unsupported configs never collide.
  """
  @spec compute_startup_fingerprint(keyword() | map()) :: String.t()
  def compute_startup_fingerprint(opts) when is_list(opts) or is_map(opts) do
    material = {
      :acp_startup_v1,
      canonicalize(get_opt(opts, :adapter_opts)),
      canonicalize(get_opt(opts, :client_opts)),
      canonicalize(get_opt(opts, :capabilities))
    }

    sha256_hex(:erlang.term_to_binary(material, [:deterministic]))
  rescue
    _ ->
      # Fail closed: non-encodable startup material is never reusable.
      non_reusable_fingerprint()
  end

  def compute_startup_fingerprint(_), do: compute_startup_fingerprint([])

  # -- Private --

  defp compute_hash(%__MODULE__{} = profile) do
    tools =
      profile.tool_modules
      |> normalize_tool_modules()
      |> Enum.map(&to_string/1)
      |> Enum.sort()

    material = {
      :acp_profile_v1,
      profile.provider,
      tools,
      profile.agent_id,
      profile.trust_domain,
      profile.model,
      profile.cwd,
      profile.task_id,
      profile.startup_fingerprint
    }

    sha256_hex(:erlang.term_to_binary(material, [:deterministic]))
  end

  defp sha256_hex(binary) when is_binary(binary) do
    :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
  end

  defp non_reusable_fingerprint do
    sha256_hex(
      :erlang.term_to_binary(
        {:acp_startup_non_reusable, :crypto.strong_rand_bytes(16)},
        [:deterministic]
      )
    )
  end

  defp normalize_tool_modules(nil), do: []

  defp normalize_tool_modules(tools) when is_list(tools) do
    tools
    |> Enum.filter(&(is_atom(&1) or is_binary(&1)))
    |> Enum.map(fn
      mod when is_atom(mod) -> mod
      mod when is_binary(mod) -> mod
    end)
    |> Enum.uniq()
    |> Enum.sort_by(&to_string/1)
  end

  defp normalize_tool_modules(_), do: []

  defp normalize_optional_id(nil), do: nil

  defp normalize_optional_id(id) when is_binary(id) do
    case String.trim(id) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_id(id) when is_atom(id) and not is_boolean(id) and id != nil do
    Atom.to_string(id)
  end

  defp normalize_optional_id(_), do: nil

  defp normalize_model(nil), do: nil

  defp normalize_model(model) when is_binary(model) do
    case String.trim(model) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_model(model) when is_atom(model) and not is_boolean(model) and model != nil do
    Atom.to_string(model)
  end

  defp normalize_model(_), do: nil

  defp normalize_tags(tags) when is_map(tags), do: tags
  defp normalize_tags(_), do: %{}

  defp canonical_cwd(nil), do: nil

  defp canonical_cwd(path) when is_binary(path) do
    trimmed = String.trim(path)

    cond do
      trimmed == "" ->
        nil

      String.contains?(trimmed, <<0>>) ->
        nil

      true ->
        try do
          Path.expand(trimmed)
        rescue
          _ -> trimmed
        end
    end
  end

  defp canonical_cwd(_), do: nil

  defp get_opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)

  defp get_opt(opts, key) when is_map(opts) do
    Map.get(opts, key) || Map.get(opts, Atom.to_string(key))
  end

  # Complete deterministic encoding — no truncation, no secret redaction, no
  # phash2/inspect lossy fallbacks. Keyword lists and maps become sorted
  # key/value tuples so equal logical configs hash identically.
  defp canonicalize(nil), do: nil
  defp canonicalize(true), do: true
  defp canonicalize(false), do: false
  defp canonicalize(value) when is_atom(value), do: value
  defp canonicalize(value) when is_integer(value), do: value
  defp canonicalize(value) when is_float(value), do: value
  defp canonicalize(value) when is_binary(value), do: value

  defp canonicalize(list) when is_list(list) do
    if keyword_list?(list) do
      entries =
        list
        |> Enum.map(fn {k, v} -> {canonicalize_key(k), canonicalize(v)} end)
        |> Enum.sort_by(fn {k, _} -> sort_key(k) end)

      {:kw, entries}
    else
      {:list, Enum.map(list, &canonicalize/1)}
    end
  end

  defp canonicalize(%{__struct__: mod} = struct) do
    {:struct, mod, canonicalize(Map.from_struct(struct))}
  end

  defp canonicalize(map) when is_map(map) do
    entries =
      map
      |> Enum.map(fn {k, v} -> {canonicalize_key(k), canonicalize(v)} end)
      |> Enum.sort_by(fn {k, _} -> sort_key(k) end)

    {:map, entries}
  end

  defp canonicalize(tuple) when is_tuple(tuple) do
    {:tuple, tuple |> Tuple.to_list() |> Enum.map(&canonicalize/1)}
  end

  defp canonicalize(other) do
    # PIDs, refs, ports, funs: full term encoding so distinct values never collide.
    {:opaque, :erlang.term_to_binary(other, [:deterministic])}
  end

  defp canonicalize_key(key) when is_atom(key), do: {:a, Atom.to_string(key)}
  defp canonicalize_key(key) when is_binary(key), do: {:b, key}
  defp canonicalize_key(key) when is_integer(key), do: {:i, key}
  defp canonicalize_key(key), do: {:t, :erlang.term_to_binary(key, [:deterministic])}

  defp sort_key({:a, s}), do: {0, s}
  defp sort_key({:b, s}), do: {1, s}
  defp sort_key({:i, i}), do: {2, i}
  defp sort_key({:t, bin}), do: {3, bin}

  defp keyword_list?([]), do: true
  defp keyword_list?([{key, _value} | rest]) when is_atom(key), do: keyword_list?(rest)
  defp keyword_list?(_), do: false

  defp generate_name(provider, opts) do
    agent_id = Keyword.get(opts, :agent_id)
    tools = Keyword.get(opts, :tool_modules, [])

    tool_hint =
      case tools do
        [] ->
          "general"

        [single] when is_atom(single) ->
          single |> Module.split() |> List.last() |> Macro.underscore()

        [single] when is_binary(single) ->
          single

        multiple ->
          "#{length(multiple)}-tools"
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
