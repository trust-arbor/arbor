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
  - `startup_fingerprint` — deterministic hash of immutable startup opts
    (`adapter_opts`, `client_opts`, `capabilities`); raw values are never stored
  - `name` — human-readable identifier for dashboards
  - `tags` — arbitrary metadata map for developer grouping
  - `affinity_key` — sticky routing key (same key → same session only when
    the full profile is also compatible)
  - `profile_hash` — computed SHA over every immutable reuse boundary

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

  # Keys considered secret-bearing; redacted before fingerprint materialization
  # so diagnostics never retain raw values (the fingerprint is still over the
  # redacted canonical form plus presence markers).
  @secret_key_fragments ~w(
    password token secret api_key authorization auth credential
    refresh_token access_token private_key signing_key bearer
  )

  @max_fingerprint_depth 8
  @max_fingerprint_entries 64
  @max_fingerprint_binary_bytes 4_096

  @doc """
  Build a SessionProfile from options, computing the profile hash.

  ## Options

  Accepts all struct fields as keyword opts. `profile_hash` is computed
  automatically. When `startup_fingerprint` is omitted, it is derived from
  `:adapter_opts`, `:client_opts`, and `:capabilities` in `opts`.

      SessionProfile.new(provider: :claude, tool_modules: [Trust.ListPresets])
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    {startup_fp, opts} =
      case Keyword.pop(opts, :startup_fingerprint) do
        {nil, rest} -> {compute_startup_fingerprint(rest), rest}
        {fp, rest} when is_binary(fp) -> {fp, rest}
        {_other, rest} -> {compute_startup_fingerprint(rest), rest}
      end

    profile =
      struct!(__MODULE__, Keyword.put(opts, :startup_fingerprint, startup_fp))

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
      startup_fingerprint: compute_startup_fingerprint(opts)
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
  Deterministic fingerprint of immutable caller-controlled startup configuration.

  Hashes a JSON-safe canonical form of `adapter_opts`, `client_opts`, and
  `capabilities`. Secret-looking keys are redacted before encoding so the
  material never retains credentials; only the resulting hex digest is stored.
  """
  @spec compute_startup_fingerprint(keyword() | map()) :: String.t()
  def compute_startup_fingerprint(opts) when is_list(opts) or is_map(opts) do
    material = %{
      "adapter_opts" => normalize_for_fingerprint(get_opt(opts, :adapter_opts)),
      "client_opts" => normalize_for_fingerprint(get_opt(opts, :client_opts)),
      "capabilities" => normalize_for_fingerprint(get_opt(opts, :capabilities))
    }

    encoded =
      case Jason.encode(material) do
        {:ok, json} -> json
        {:error, _} -> inspect(material, limit: 200, printable_limit: 200)
      end

    :crypto.hash(:sha256, encoded)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  def compute_startup_fingerprint(_), do: compute_startup_fingerprint([])

  # -- Private --

  defp compute_hash(%__MODULE__{} = profile) do
    tools =
      profile.tool_modules
      |> normalize_tool_modules()
      |> Enum.map(&to_string/1)
      |> Enum.sort()

    parts = [
      "provider=#{encode_scalar(profile.provider)}",
      "tools=#{Enum.join(tools, ",")}",
      "agent=#{encode_scalar(profile.agent_id)}",
      "trust=#{encode_scalar(profile.trust_domain)}",
      "model=#{encode_scalar(profile.model)}",
      "cwd=#{encode_scalar(profile.cwd)}",
      "task=#{encode_scalar(profile.task_id)}",
      "startup=#{encode_scalar(profile.startup_fingerprint)}"
    ]

    :crypto.hash(:sha256, Enum.join(parts, "|"))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp encode_scalar(nil), do: "nil"
  defp encode_scalar(value) when is_atom(value), do: "a:" <> Atom.to_string(value)
  defp encode_scalar(value) when is_binary(value), do: "b:" <> value
  defp encode_scalar(value), do: "t:" <> inspect(value, limit: 50, printable_limit: 50)

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

      # Reject NUL / control bytes so path work stays bounded and JSON-safe
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

  defp normalize_for_fingerprint(term), do: normalize_for_fingerprint(term, 0)

  defp normalize_for_fingerprint(_term, depth) when depth > @max_fingerprint_depth do
    %{"__truncated__" => "max_depth"}
  end

  defp normalize_for_fingerprint(nil, _depth), do: nil
  defp normalize_for_fingerprint(true, _depth), do: true
  defp normalize_for_fingerprint(false, _depth), do: false

  defp normalize_for_fingerprint(value, _depth) when is_atom(value),
    do: %{"__atom__" => Atom.to_string(value)}

  defp normalize_for_fingerprint(value, _depth) when is_integer(value) do
    # Bound bignums so fingerprint material stays finite
    digits = value |> Integer.to_string() |> byte_size()

    if digits > 64 do
      %{"__integer__" => "overflow", "digits" => digits}
    else
      value
    end
  end

  defp normalize_for_fingerprint(value, _depth) when is_float(value), do: value

  defp normalize_for_fingerprint(value, _depth) when is_binary(value) do
    if byte_size(value) > @max_fingerprint_binary_bytes do
      digest =
        :crypto.hash(:sha256, value) |> Base.encode16(case: :lower) |> binary_part(0, 16)

      %{
        "__binary__" => "truncated",
        "byte_size" => byte_size(value),
        "sha256_16" => digest
      }
    else
      if String.valid?(value) do
        value
      else
        digest =
          :crypto.hash(:sha256, value) |> Base.encode16(case: :lower) |> binary_part(0, 16)

        %{"__bytes__" => digest, "byte_size" => byte_size(value)}
      end
    end
  end

  defp normalize_for_fingerprint(list, depth) when is_list(list) do
    if keyword_list?(list) do
      list
      |> Enum.take(@max_fingerprint_entries)
      |> Enum.map(fn {k, v} ->
        key = normalize_key(k)

        value =
          if secret_key?(key),
            do: %{"__redacted__" => true},
            else: normalize_for_fingerprint(v, depth + 1)

        {key, value}
      end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Map.new()
    else
      list
      |> Enum.take(@max_fingerprint_entries)
      |> Enum.map(&normalize_for_fingerprint(&1, depth + 1))
    end
  end

  defp normalize_for_fingerprint(map, depth) when is_map(map) do
    map
    |> Enum.take(@max_fingerprint_entries)
    |> Enum.map(fn {k, v} ->
      key = normalize_key(k)

      value =
        if secret_key?(key),
          do: %{"__redacted__" => true},
          else: normalize_for_fingerprint(v, depth + 1)

      {key, value}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Map.new()
  end

  defp normalize_for_fingerprint(other, _depth) do
    %{"__term__" => :erlang.phash2(other)}
  end

  defp keyword_list?([]), do: true

  defp keyword_list?([{key, _value} | rest]) when is_atom(key), do: keyword_list?(rest)

  defp keyword_list?(_), do: false

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: inspect(key, limit: 32)

  defp secret_key?(key) when is_binary(key) do
    lowered = String.downcase(key)
    Enum.any?(@secret_key_fragments, &String.contains?(lowered, &1))
  end

  defp secret_key?(_), do: false

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
