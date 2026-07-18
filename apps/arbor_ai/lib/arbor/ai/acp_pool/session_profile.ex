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

  # Hard ceilings on startup fingerprint material. Oversized or unsupported
  # input is marked non-reusable (unique digest) rather than truncated.
  # All limits are enforced *before* unbounded traversal/allocation
  # (`length/1`, `Tuple.to_list/1`, `Map.from_struct/1`, huge integers).
  @max_startup_depth 12
  @max_startup_entries 128
  @max_startup_binary_bytes 8_192
  @max_startup_encoded_bytes 65_536
  # First integer with more than 64 decimal digits; reject without to_string.
  @max_integer_exclusive 10 ** 64
  @max_id_bytes 512
  @max_cwd_bytes 4_096
  @max_model_bytes 256
  @max_tool_modules 64

  @doc """
  Build a SessionProfile from options, computing the profile hash.

  ## Options

  Accepts struct fields as keyword opts plus startup config keys
  `:adapter_opts`, `:client_opts`, and `:capabilities` (fingerprinted only;
  never stored). Unknown keys are rejected by `struct!/2`.

  `startup_fingerprint` and `profile_hash` cannot be caller-overridden: the
  fingerprint is always derived from the actual adapter/client/capability
  inputs, and `profile_hash` is always recomputed.

      SessionProfile.new(provider: :claude, tool_modules: [Trust.ListPresets])
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    # Consume only startup config keys (not struct fields). Explicit
    # fingerprint/hash overrides are discarded so they cannot mask config.
    {adapter_opts, opts} = Keyword.pop(opts, :adapter_opts)
    {client_opts, opts} = Keyword.pop(opts, :client_opts)
    {capabilities, opts} = Keyword.pop(opts, :capabilities)
    {_ignored_fp, opts} = Keyword.pop(opts, :startup_fingerprint)
    {_ignored_hash, opts} = Keyword.pop(opts, :profile_hash)

    startup_fp =
      compute_startup_fingerprint(
        adapter_opts: adapter_opts,
        client_opts: client_opts,
        capabilities: capabilities
      )

    # Remaining opts go to struct! unchanged — unknown keys raise (closed).
    profile = struct!(__MODULE__, Keyword.put(opts, :startup_fingerprint, startup_fp))
    %{profile | profile_hash: compute_hash(profile)}
  end

  @doc """
  Build a SessionProfile from a pool checkout provider and keyword opts.

  Returns `{:ok, profile}` or `{:error, reason}` when a non-nil field is
  malformed (never silently normalizes malformed values to nil/empty so they
  would match an unscoped session).
  """
  @spec from_opts(atom(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_opts(provider, opts) when is_atom(provider) and is_list(opts) do
    with {:ok, agent_id} <- validate_optional_id(Keyword.get(opts, :agent_id), :agent_id),
         {:ok, task_id} <- validate_optional_id(Keyword.get(opts, :task_id), :task_id),
         {:ok, affinity_key} <-
           validate_optional_id(Keyword.get(opts, :affinity_key), :affinity_key),
         {:ok, model} <- validate_model(Keyword.get(opts, :model)),
         {:ok, cwd} <- validate_cwd(cwd_value(opts)),
         {:ok, tool_modules} <- validate_tool_modules(Keyword.get(opts, :tool_modules, [])),
         {:ok, trust_domain} <- validate_trust_domain(Keyword.get(opts, :trust_domain)),
         {:ok, tags} <- validate_tags(Keyword.get(opts, :tags, %{})),
         {:ok, name} <- validate_name(Keyword.get(opts, :name), provider, opts, tool_modules) do
      profile =
        new(
          provider: provider,
          tool_modules: tool_modules,
          agent_id: agent_id,
          trust_domain: trust_domain,
          model: model,
          cwd: cwd,
          task_id: task_id,
          name: name,
          tags: tags,
          affinity_key: affinity_key,
          adapter_opts: Keyword.get(opts, :adapter_opts),
          client_opts: Keyword.get(opts, :client_opts),
          capabilities: Keyword.get(opts, :capabilities)
        )

      {:ok, profile}
    end
  end

  def from_opts(_provider, _opts), do: {:error, :invalid_checkout_opts}

  defp cwd_value(opts) do
    case Keyword.fetch(opts, :cwd) do
      {:ok, nil} -> Keyword.get(opts, :workspace)
      {:ok, cwd} -> cwd
      :error -> Keyword.get(opts, :workspace)
    end
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
      a.tool_modules == b.tool_modules
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

  Bound-canonicalizes `adapter_opts`, `client_opts`, and `capabilities`
  (including secret-bearing values), then hashes the deterministic term
  encoding. Only the digest is retained.

  Oversized or unsupported terms produce a unique non-reusable fingerprint so
  they never match another profile (and never match each other by collision).
  """
  @spec compute_startup_fingerprint(keyword() | map()) :: String.t()
  def compute_startup_fingerprint(opts) when is_list(opts) or is_map(opts) do
    case bound_startup_material(opts) do
      {:ok, material} ->
        sha256_hex(:erlang.term_to_binary(material, [:deterministic]))

      :non_reusable ->
        non_reusable_fingerprint()
    end
  rescue
    _ ->
      non_reusable_fingerprint()
  end

  def compute_startup_fingerprint(_), do: non_reusable_fingerprint()

  # -- Private: hash --

  defp compute_hash(%__MODULE__{} = profile) do
    tools =
      profile.tool_modules
      |> List.wrap()
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

  # -- Private: field validation (fail closed; never coerce malformed → nil) --

  defp validate_optional_id(nil, _field), do: {:ok, nil}

  defp validate_optional_id(id, field) when is_binary(id) do
    trimmed = String.trim(id)

    cond do
      trimmed == "" ->
        {:error, {:invalid, field, :blank}}

      byte_size(trimmed) > @max_id_bytes ->
        {:error, {:invalid, field, :too_long}}

      String.contains?(trimmed, <<0>>) ->
        {:error, {:invalid, field, :nul_byte}}

      not String.valid?(trimmed) ->
        {:error, {:invalid, field, :invalid_utf8}}

      true ->
        {:ok, trimmed}
    end
  end

  defp validate_optional_id(id, field)
       when is_atom(id) and not is_boolean(id) and not is_nil(id) do
    validate_optional_id(Atom.to_string(id), field)
  end

  defp validate_optional_id(_id, field), do: {:error, {:invalid, field, :bad_type}}

  defp validate_model(nil), do: {:ok, nil}

  defp validate_model(model) when is_binary(model) do
    trimmed = String.trim(model)

    cond do
      trimmed == "" ->
        {:error, {:invalid, :model, :blank}}

      byte_size(trimmed) > @max_model_bytes ->
        {:error, {:invalid, :model, :too_long}}

      String.contains?(trimmed, <<0>>) ->
        {:error, {:invalid, :model, :nul_byte}}

      not String.valid?(trimmed) ->
        {:error, {:invalid, :model, :invalid_utf8}}

      true ->
        {:ok, trimmed}
    end
  end

  defp validate_model(model)
       when is_atom(model) and not is_boolean(model) and not is_nil(model) do
    validate_model(Atom.to_string(model))
  end

  defp validate_model(_), do: {:error, {:invalid, :model, :bad_type}}

  defp validate_cwd(nil), do: {:ok, nil}

  defp validate_cwd(path) when is_binary(path) do
    trimmed = String.trim(path)

    cond do
      trimmed == "" ->
        {:error, {:invalid, :cwd, :blank}}

      byte_size(trimmed) > @max_cwd_bytes ->
        {:error, {:invalid, :cwd, :too_long}}

      String.contains?(trimmed, <<0>>) ->
        {:error, {:invalid, :cwd, :nul_byte}}

      not String.valid?(trimmed) ->
        {:error, {:invalid, :cwd, :invalid_utf8}}

      true ->
        try do
          {:ok, Path.expand(trimmed)}
        rescue
          _ -> {:error, {:invalid, :cwd, :expand_failed}}
        end
    end
  end

  defp validate_cwd(_), do: {:error, {:invalid, :cwd, :bad_type}}

  defp validate_tool_modules(nil), do: {:ok, []}

  defp validate_tool_modules(tools) when is_list(tools) do
    # Walk with a counter so improper/overlong lists fail closed without
    # `length/1` (which raises on improper lists and walks the full spine first).
    validate_tool_module_entries(tools, [], 0)
  end

  defp validate_tool_modules(_), do: {:error, {:invalid, :tool_modules, :bad_type}}

  defp validate_tool_module_entries([], acc, _count) do
    {:ok, acc |> Enum.uniq() |> Enum.sort_by(&to_string/1)}
  end

  defp validate_tool_module_entries(_tools, _acc, count) when count >= @max_tool_modules do
    {:error, {:invalid, :tool_modules, :too_many}}
  end

  defp validate_tool_module_entries([mod | rest], acc, count)
       when is_atom(mod) and not is_nil(mod) and not is_boolean(mod) do
    validate_tool_module_entries(rest, [mod | acc], count + 1)
  end

  # Typed as modules only — binary names are accepted by neither ToolServer
  # conversion nor Jido action loading; reject at the profile boundary.
  defp validate_tool_module_entries([mod | _rest], _acc, _count) when is_binary(mod) do
    {:error, {:invalid, :tool_modules, :bad_entry}}
  end

  defp validate_tool_module_entries([_bad | _rest], _acc, _count),
    do: {:error, {:invalid, :tool_modules, :bad_entry}}

  defp validate_tool_module_entries(_improper, _acc, _count),
    do: {:error, {:invalid, :tool_modules, :bad_type}}

  defp validate_trust_domain(nil), do: {:ok, nil}

  defp validate_trust_domain(domain) when is_atom(domain) and not is_boolean(domain),
    do: {:ok, domain}

  defp validate_trust_domain(_), do: {:error, {:invalid, :trust_domain, :bad_type}}

  defp validate_tags(nil), do: {:ok, %{}}
  defp validate_tags(tags) when is_map(tags), do: {:ok, tags}
  defp validate_tags(_), do: {:error, {:invalid, :tags, :bad_type}}

  defp validate_name(nil, provider, opts, tool_modules) do
    {:ok, generate_name(provider, Keyword.put(opts, :tool_modules, tool_modules))}
  end

  defp validate_name(name, _provider, _opts, _tool_modules) when is_binary(name) do
    trimmed = String.trim(name)

    cond do
      trimmed == "" ->
        {:error, {:invalid, :name, :blank}}

      byte_size(trimmed) > @max_id_bytes ->
        {:error, {:invalid, :name, :too_long}}

      not String.valid?(trimmed) ->
        {:error, {:invalid, :name, :invalid_utf8}}

      true ->
        {:ok, trimmed}
    end
  end

  defp validate_name(_, _, _, _), do: {:error, {:invalid, :name, :bad_type}}

  # -- Private: bounded startup fingerprint --

  defp bound_startup_material(opts) do
    with {:ok, adapter, s1} <- bound_canonicalize(get_opt(opts, :adapter_opts), 0, 0),
         {:ok, client, s2} <- bound_canonicalize(get_opt(opts, :client_opts), 0, s1),
         {:ok, caps, _s3} <- bound_canonicalize(get_opt(opts, :capabilities), 0, s2) do
      material = {:acp_startup_v1, adapter, client, caps}
      encoded = :erlang.term_to_binary(material, [:deterministic])

      if byte_size(encoded) > @max_startup_encoded_bytes do
        :non_reusable
      else
        {:ok, material}
      end
    else
      :non_reusable -> :non_reusable
    end
  end

  defp bound_canonicalize(_term, depth, _size) when depth > @max_startup_depth,
    do: :non_reusable

  defp bound_canonicalize(_term, _depth, size) when size > @max_startup_encoded_bytes,
    do: :non_reusable

  defp bound_canonicalize(nil, _depth, size), do: {:ok, nil, size + 1}
  defp bound_canonicalize(true, _depth, size), do: {:ok, true, size + 1}
  defp bound_canonicalize(false, _depth, size), do: {:ok, false, size + 1}

  defp bound_canonicalize(value, _depth, size) when is_atom(value) do
    bytes = byte_size(Atom.to_string(value)) + 2
    check_size(value, size + bytes)
  end

  defp bound_canonicalize(value, _depth, size) when is_integer(value) do
    # Gate magnitude before Integer.to_string/1 so huge integers never allocate.
    if value <= -@max_integer_exclusive or value >= @max_integer_exclusive do
      :non_reusable
    else
      digits = value |> Integer.to_string() |> byte_size()
      check_size(value, size + digits + 1)
    end
  end

  defp bound_canonicalize(value, _depth, size) when is_float(value) do
    check_size(value, size + 8)
  end

  defp bound_canonicalize(value, _depth, size) when is_binary(value) do
    if byte_size(value) > @max_startup_binary_bytes do
      :non_reusable
    else
      check_size(value, size + byte_size(value) + 2)
    end
  end

  defp bound_canonicalize(list, depth, size) when is_list(list) do
    # Never call length/1 first: it walks the full spine and raises on improper lists.
    case classify_bounded_list(list, 0) do
      {:ok, :keyword} -> bound_keyword(list, depth, size, 0)
      {:ok, :list} -> bound_list(list, depth, size, 0)
      :non_reusable -> :non_reusable
    end
  end

  defp bound_canonicalize(%{__struct__: mod} = struct, depth, size) do
    # map_size/1 is O(1). Gate field count before Map.from_struct/1 allocates.
    field_count = map_size(struct) - 1

    if field_count > @max_startup_entries do
      :non_reusable
    else
      case bound_canonicalize(Map.from_struct(struct), depth + 1, size + 8) do
        {:ok, map_form, new_size} -> {:ok, {:struct, mod, map_form}, new_size}
        :non_reusable -> :non_reusable
      end
    end
  end

  defp bound_canonicalize(map, depth, size) when is_map(map) do
    if map_size(map) > @max_startup_entries do
      :non_reusable
    else
      bound_map_entries(Enum.to_list(map), depth, size, [])
    end
  end

  defp bound_canonicalize(tuple, depth, size) when is_tuple(tuple) do
    # tuple_size/1 is O(1). Never Tuple.to_list/1 before the entry ceiling.
    n = tuple_size(tuple)

    if n > @max_startup_entries do
      :non_reusable
    else
      bound_tuple_elems(tuple, 0, n, depth, size, [])
    end
  end

  # PIDs, refs, ports, funs, and any other opaque term: never reusable.
  defp bound_canonicalize(_other, _depth, _size), do: :non_reusable

  # Classify a list while counting entries. Stops at the first oversize/improper
  # observation without materializing a full length or walking past the ceiling.
  defp classify_bounded_list([], _count), do: {:ok, :keyword}

  defp classify_bounded_list(_list, count) when count >= @max_startup_entries,
    do: :non_reusable

  defp classify_bounded_list([{key, _value} | rest], count) when is_atom(key) do
    case classify_bounded_list(rest, count + 1) do
      {:ok, :keyword} -> {:ok, :keyword}
      {:ok, :list} -> {:ok, :list}
      :non_reusable -> :non_reusable
    end
  end

  defp classify_bounded_list([_item | rest], count) do
    case rest do
      [] ->
        {:ok, :list}

      [_ | _] ->
        count_remaining_list(rest, count + 1)

      _improper ->
        :non_reusable
    end
  end

  defp classify_bounded_list(_improper, _count), do: :non_reusable

  defp count_remaining_list([], _count), do: {:ok, :list}

  defp count_remaining_list(_list, count) when count >= @max_startup_entries,
    do: :non_reusable

  defp count_remaining_list([_item | rest], count) do
    case rest do
      [] ->
        {:ok, :list}

      [_ | _] ->
        count_remaining_list(rest, count + 1)

      _improper ->
        :non_reusable
    end
  end

  defp count_remaining_list(_improper, _count), do: :non_reusable

  defp bound_keyword(list, depth, size, count) do
    case bound_kv_pairs(list, depth, size, count, []) do
      {:ok, entries, new_size} ->
        sorted = Enum.sort_by(entries, fn {k, _} -> sort_key(k) end)
        {:ok, {:kw, sorted}, new_size}

      :non_reusable ->
        :non_reusable
    end
  end

  defp bound_list(list, depth, size, count) do
    bound_list_items(list, depth, size, count, [])
  end

  defp bound_list_items([], _depth, size, _count, acc) do
    {:ok, {:list, Enum.reverse(acc)}, size}
  end

  defp bound_list_items(_list, _depth, _size, count, _acc)
       when count >= @max_startup_entries,
       do: :non_reusable

  defp bound_list_items([item | rest], depth, size, count, acc) do
    case bound_canonicalize(item, depth + 1, size) do
      {:ok, canon, new_size} ->
        case rest do
          [] ->
            {:ok, {:list, Enum.reverse([canon | acc])}, new_size}

          [_ | _] ->
            bound_list_items(rest, depth, new_size, count + 1, [canon | acc])

          _improper ->
            :non_reusable
        end

      :non_reusable ->
        :non_reusable
    end
  end

  defp bound_list_items(_improper, _depth, _size, _count, _acc), do: :non_reusable

  defp bound_tuple_elems(_tuple, i, n, _depth, size, acc) when i == n do
    {:ok, {:tuple, Enum.reverse(acc)}, size}
  end

  defp bound_tuple_elems(tuple, i, n, depth, size, acc) do
    case bound_canonicalize(elem(tuple, i), depth + 1, size) do
      {:ok, canon, new_size} ->
        bound_tuple_elems(tuple, i + 1, n, depth, new_size, [canon | acc])

      :non_reusable ->
        :non_reusable
    end
  end

  defp bound_map_entries([], _depth, size, acc) do
    sorted = acc |> Enum.sort_by(fn {k, _} -> sort_key(k) end)
    {:ok, {:map, sorted}, size}
  end

  defp bound_map_entries([{k, v} | rest], depth, size, acc) do
    case bound_kv_pair(k, v, depth, size) do
      {:ok, pair, new_size} -> bound_map_entries(rest, depth, new_size, [pair | acc])
      :non_reusable -> :non_reusable
    end
  end

  defp bound_kv_pairs([], _depth, size, _count, acc), do: {:ok, acc, size}

  defp bound_kv_pairs(_list, _depth, _size, count, _acc)
       when count >= @max_startup_entries,
       do: :non_reusable

  defp bound_kv_pairs([{k, v} | rest], depth, size, count, acc) do
    case bound_kv_pair(k, v, depth, size) do
      {:ok, pair, new_size} ->
        case rest do
          [] ->
            {:ok, [pair | acc], new_size}

          [_ | _] ->
            bound_kv_pairs(rest, depth, new_size, count + 1, [pair | acc])

          _improper ->
            :non_reusable
        end

      :non_reusable ->
        :non_reusable
    end
  end

  defp bound_kv_pairs(_other, _depth, _size, _count, _acc), do: :non_reusable

  defp bound_kv_pair(k, v, depth, size) do
    case bound_key(k, size) do
      {:ok, key, size_after_key} ->
        case bound_canonicalize(v, depth + 1, size_after_key) do
          {:ok, val, new_size} -> {:ok, {key, val}, new_size}
          :non_reusable -> :non_reusable
        end

      :non_reusable ->
        :non_reusable
    end
  end

  defp bound_key(key, size) when is_atom(key) do
    s = Atom.to_string(key)
    check_size_pair({:a, s}, size + byte_size(s) + 2)
  end

  defp bound_key(key, size) when is_binary(key) do
    if byte_size(key) > @max_startup_binary_bytes do
      :non_reusable
    else
      check_size_pair({:b, key}, size + byte_size(key) + 2)
    end
  end

  defp bound_key(key, size) when is_integer(key) do
    if key <= -@max_integer_exclusive or key >= @max_integer_exclusive do
      :non_reusable
    else
      digits = key |> Integer.to_string() |> byte_size()
      check_size_pair({:i, key}, size + digits + 1)
    end
  end

  defp bound_key(_key, _size), do: :non_reusable

  defp check_size(value, new_size) do
    if new_size > @max_startup_encoded_bytes, do: :non_reusable, else: {:ok, value, new_size}
  end

  defp check_size_pair(value, new_size) do
    if new_size > @max_startup_encoded_bytes, do: :non_reusable, else: {:ok, value, new_size}
  end

  defp get_opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)

  defp get_opt(opts, key) when is_map(opts) do
    Map.get(opts, key) || Map.get(opts, Atom.to_string(key))
  end

  defp sort_key({:a, s}), do: {0, s}
  defp sort_key({:b, s}), do: {1, s}
  defp sort_key({:i, i}), do: {2, i}

  defp generate_name(provider, opts) do
    agent_id = Keyword.get(opts, :agent_id)
    tools = Keyword.get(opts, :tool_modules, [])

    tool_hint =
      case tools do
        [] ->
          "general"

        [single] when is_atom(single) ->
          single |> Module.split() |> List.last() |> Macro.underscore()

        multiple when is_list(multiple) ->
          "#{Enum.count(multiple)}-tools"

        _ ->
          "general"
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
