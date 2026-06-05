defmodule Arbor.Contracts.Security.Capability do
  @moduledoc """
  Represents a permission grant for resource access.

  This is the fundamental security primitive in the Arbor system. Capabilities
  are unforgeable tokens that grant specific permissions to access resources
  or perform operations.

  ## Capability Model

  - **Resource-oriented**: Each capability grants access to a specific resource
  - **Time-limited**: Capabilities can have expiration times
  - **Delegatable**: Capabilities can be delegated with reduced permissions
  - **Constrainable**: Additional constraints can limit capability scope

  ## Resource URIs

  Resources are identified by URIs following the pattern:
  `arbor://{type}/{operation}/{path}`

  Examples:
  - `arbor://fs/read/project/docs` - Read access to directory
  - `arbor://tool/execute/code_analyzer` - Execute specific tool
  - `arbor://api/call/external_service` - Call external API

  ## Usage

      {:ok, cap} = Capability.new(
        resource_uri: "arbor://fs/read/project/src",
        principal_id: "agent_abc123",
        expires_at: DateTime.utc_now() |> DateTime.add(3600, :second)
      )
  """

  use TypedStruct

  alias Arbor.Types

  @derive {Jason.Encoder, except: [:signature, :issuer_signature]}
  typedstruct enforce: true do
    @typedoc "A capability granting access to a specific resource"

    field(:id, Types.capability_id())
    field(:resource_uri, Types.resource_uri())
    field(:principal_id, Types.agent_id())
    field(:granted_at, DateTime.t())
    field(:expires_at, DateTime.t(), enforce: false)
    field(:not_before, DateTime.t(), enforce: false)
    field(:parent_capability_id, Types.capability_id(), enforce: false)
    field(:delegation_depth, non_neg_integer(), default: 3)
    field(:max_uses, pos_integer(), enforce: false)
    field(:allowed_delegatees, [binary()], enforce: false)
    field(:session_id, binary(), enforce: false)
    field(:task_id, binary(), enforce: false)
    # Multi-user: binds this capability to a specific user principal (nil = any user)
    field(:principal_scope, binary(), enforce: false)
    field(:constraints, map(), default: %{})
    field(:signature, binary(), enforce: false)
    field(:issuer_id, Types.agent_id(), enforce: false)
    field(:issuer_signature, Types.signature(), enforce: false)
    field(:signed_at, DateTime.t(), enforce: false)
    field(:delegation_chain, [Types.delegation_record()], default: [])
    field(:metadata, map(), default: %{})
  end

  @doc """
  Create a new capability with validation.

  ## Options

  - `:resource_uri` (required) - URI of the resource this capability grants access to
  - `:principal_id` (required) - ID of the agent receiving this capability
  - `:expires_at` - When this capability expires (optional)
  - `:parent_capability_id` - Parent capability if this is a delegation
  - `:not_before` - Capability is not valid before this time (optional)
  - `:delegation_depth` - How many times this capability can be delegated (default: 3, 0 = non-delegatable)
  - `:max_uses` - Maximum number of successful authorizations before auto-revoke (nil = unlimited)
  - `:allowed_delegatees` - List of agent IDs this cap can be delegated to (nil = anyone)
  - `:session_id` - Bind capability to a specific session (nil = any session)
  - `:task_id` - Bind capability to a specific task/pipeline execution (nil = any task)
  - `:principal_scope` - Bind capability to a specific user principal (nil = any user)
  - `:constraints` - Additional constraints on capability usage
  - `:metadata` - Additional metadata

  ## Examples

      # Basic capability
      {:ok, cap} = Capability.new(
        resource_uri: "arbor://fs/read/project/docs",
        principal_id: "agent_worker001"
      )

      # Time-limited capability
      {:ok, cap} = Capability.new(
        resource_uri: "arbor://api/call/openai",
        principal_id: "agent_llm001",
        expires_at: DateTime.utc_now() |> DateTime.add(1, :hour),
        constraints: %{max_requests: 100}
      )
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    capability = %__MODULE__{
      id: attrs[:id] || generate_capability_id(),
      resource_uri: Keyword.fetch!(attrs, :resource_uri),
      principal_id: Keyword.fetch!(attrs, :principal_id),
      granted_at: attrs[:granted_at] || DateTime.utc_now(),
      expires_at: attrs[:expires_at],
      not_before: attrs[:not_before],
      parent_capability_id: attrs[:parent_capability_id],
      delegation_depth: attrs[:delegation_depth] || 3,
      max_uses: attrs[:max_uses],
      allowed_delegatees: attrs[:allowed_delegatees],
      session_id: attrs[:session_id],
      task_id: attrs[:task_id],
      principal_scope: attrs[:principal_scope],
      constraints: atomize_known_constraint_keys(attrs[:constraints] || %{}),
      issuer_id: attrs[:issuer_id],
      issuer_signature: attrs[:issuer_signature],
      delegation_chain: attrs[:delegation_chain] || [],
      metadata: attrs[:metadata] || %{}
    }

    case validate_capability(capability) do
      :ok -> {:ok, capability}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Check if a capability is currently valid.

  A capability is valid if:
  - It has not expired
  - Its not_before time has passed (if set)
  - It has delegation depth remaining (if delegated)
  """
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{} = cap) do
    not_expired?(cap) and not_before_passed?(cap) and has_delegation_depth?(cap)
  end

  @doc """
  Check if a capability grants access to a specific resource.

  Supports exact matching and pattern matching for hierarchical resources.
  """
  @spec grants_access?(t(), String.t()) :: boolean()
  def grants_access?(%__MODULE__{resource_uri: cap_uri}, resource_uri) do
    cap_uri == resource_uri or String.starts_with?(resource_uri, cap_uri <> "/")
  end

  @doc """
  Check if URI pattern `child` is a subset of URI pattern `parent`.

  A child URI pattern is a subset of a parent URI pattern when every concrete
  URI matched by `child` is also matched by `parent`. Supports the same
  wildcard suffixes as `Arbor.Security.AuthDecision` capability matching:
  `/**` (any subtree depth) and `/*` (exactly one level).

  Used to enforce that delegated/declared capabilities stay within the bounds
  of their parent or issuer envelope.

  ## Examples

      iex> alias Arbor.Contracts.Security.Capability
      iex> Capability.uri_subset?("arbor://fs/write/X", "arbor://fs/write/**")
      true

      iex> alias Arbor.Contracts.Security.Capability
      iex> Capability.uri_subset?("arbor://fs/write/X/Y/**", "arbor://fs/write/X/**")
      true

      iex> alias Arbor.Contracts.Security.Capability
      iex> Capability.uri_subset?("arbor://fs/write/**", "arbor://fs/write/X/**")
      false

      iex> alias Arbor.Contracts.Security.Capability
      iex> Capability.uri_subset?("arbor://fs/write/X", "arbor://fs/read/X")
      false
  """
  @spec uri_subset?(String.t(), String.t()) :: boolean()
  def uri_subset?(child, parent) when is_binary(child) and is_binary(parent) do
    child_prefix = strip_uri_wildcards(child)
    parent_prefix = strip_uri_wildcards(parent)

    uri_prefix_of?(parent_prefix, child_prefix) and
      parent_wildcard_covers_child?(parent, child)
  end

  def uri_subset?(_, _), do: false

  defp strip_uri_wildcards(uri) do
    uri
    |> String.replace_suffix("/**", "")
    |> String.replace_suffix("/*", "")
  end

  defp uri_prefix_of?(a, b), do: a == b or String.starts_with?(b, a <> "/")

  defp parent_wildcard_covers_child?(parent, child) do
    cond do
      # Parent allows any subtree — covers any child shape under its prefix
      String.ends_with?(parent, "/**") -> true
      # Parent allows exactly one level — child must NOT use /** (would go deeper)
      String.ends_with?(parent, "/*") -> not String.ends_with?(child, "/**")
      # Parent is concrete; its prefix rule already covers subtree access
      true -> true
    end
  end

  @doc """
  Check if `child_constraints` are at-least-as-restrictive as `parent_constraints`.

  For each key present in `child`:
    - If `parent` lacks the key, parent imposes no limit on it — any child
      value is more restrictive (subset).
    - If `parent` has the key with the same value, that's equality (subset).
    - For integer keys like `:rate_limit` / `:max_uses` / `:max_size`, child
      must be `<=` parent (tighter limit).
    - For `:requires_approval`, child=true is always permitted; if parent=true
      then child must also be true (can't remove approval requirement).
    - Otherwise, the rule is conservative: NOT subset.

  Returns `true` if child is a valid subset, `false` if it widens any constraint.

  ## Examples

      iex> alias Arbor.Contracts.Security.Capability
      iex> Capability.constraints_subset?(%{rate_limit: 50}, %{rate_limit: 100})
      true

      iex> alias Arbor.Contracts.Security.Capability
      iex> Capability.constraints_subset?(%{rate_limit: 200}, %{rate_limit: 100})
      false

      iex> alias Arbor.Contracts.Security.Capability
      iex> Capability.constraints_subset?(%{max_size: 1024}, %{})
      true

      iex> alias Arbor.Contracts.Security.Capability
      iex> Capability.constraints_subset?(%{requires_approval: false}, %{requires_approval: true})
      false
  """
  @spec constraints_subset?(map(), map()) :: boolean()
  def constraints_subset?(child, parent) when is_map(child) and is_map(parent) do
    Enum.all?(child, fn {key, child_value} ->
      case Map.fetch(parent, key) do
        # Parent imposes no limit on this key — child adding a limit is restriction
        :error -> true
        {:ok, parent_value} -> constraint_value_subset?(key, child_value, parent_value)
      end
    end)
  end

  def constraints_subset?(_, _), do: false

  defp constraint_value_subset?(:requires_approval, child, parent)
       when is_boolean(child) and is_boolean(parent) do
    # parent=true requires approval; child must also require approval (can't remove)
    # parent=false: child can either require approval (tighter) or skip it (equal)
    parent == false or child == true
  end

  defp constraint_value_subset?(_key, child, parent)
       when is_integer(child) and is_integer(parent) do
    child <= parent
  end

  defp constraint_value_subset?(_key, value, value), do: true
  defp constraint_value_subset?(_key, _child, _parent), do: false

  @doc """
  Check whether capability `child` is fully contained within capability `parent`.

  Combines `uri_subset?/2` AND `constraints_subset?/2`. Used both for delegation
  attenuation enforcement (a delegated cap must not widen its parent) and for
  verifying capabilities declared in a `.caps.json` file fit within their
  issuer's max-envelope capability.

  Note: this does NOT check `expires_at`, `not_before`, `delegation_depth`,
  `session_id`, `task_id`, or `principal_scope` — those have their own
  attenuation rules in `delegate/3` and `scope_matches?/2`.
  """
  @spec envelope_subset?(t(), t()) :: boolean()
  def envelope_subset?(%__MODULE__{} = child, %__MODULE__{} = parent) do
    uri_subset?(child.resource_uri, parent.resource_uri) and
      constraints_subset?(child.constraints, parent.constraints)
  end

  @doc """
  Check if a capability's scope bindings match the given context.

  A capability matches if:
  - Its `session_id` is nil (unbound) or matches `context[:session_id]`
  - Its `task_id` is nil (unbound) or matches `context[:task_id]`
  - Its `principal_scope` is nil (unbound) or matches `context[:principal_scope]`

  Returns `true` if scope matches, `false` otherwise.
  """
  @spec scope_matches?(t(), keyword()) :: boolean()
  def scope_matches?(%__MODULE__{} = cap, context \\ []) do
    session_ok = cap.session_id == nil or cap.session_id == context[:session_id]
    task_ok = cap.task_id == nil or cap.task_id == context[:task_id]

    principal_ok =
      cap.principal_scope == nil or cap.principal_scope == context[:principal_scope]

    session_ok and task_ok and principal_ok
  end

  @doc """
  Create a delegated capability with reduced permissions.

  The new capability will have:
  - Reduced delegation depth
  - Same or shorter expiration time
  - Additional constraints as specified
  """
  @spec delegate(t(), Types.agent_id(), keyword()) :: {:ok, t()} | {:error, term()}
  def delegate(%__MODULE__{} = parent, new_principal_id, opts \\ []) do
    new_constraints = Map.merge(parent.constraints, opts[:constraints] || %{})

    cond do
      parent.delegation_depth <= 0 ->
        {:error, :delegation_depth_exhausted}

      parent.allowed_delegatees != nil and
          new_principal_id not in parent.allowed_delegatees ->
        {:error, {:delegatee_not_allowed, new_principal_id}}

      # Envelope enforcement: the merged constraints must not widen the parent's
      # constraints. `Map.merge` lets `opts[:constraints]` override parent values,
      # so without this check a delegator could call delegate/3 with
      # `constraints: %{rate_limit: 1_000_000}` and silently expand a parent
      # cap that only allowed 100/sec. Reject construction.
      not constraints_subset?(new_constraints, parent.constraints) ->
        {:error, :widens_envelope}

      true ->
        new_expires_at = min_datetime(parent.expires_at, opts[:expires_at])
        new_not_before = opts[:not_before] || parent.not_before

        # max_uses on delegated cap: use opts if given, else inherit parent's
        new_max_uses = min_pos_integer(parent.max_uses, opts[:max_uses])

        # Build delegation chain: inherit parent's chain + new entry if delegator info provided
        delegation_chain =
          case opts[:delegation_record] do
            nil -> parent.delegation_chain
            record -> parent.delegation_chain ++ [record]
          end

        # Scope binding: inherit parent's session/task/principal binding (can't unbind)
        session_id = opts[:session_id] || parent.session_id
        task_id = opts[:task_id] || parent.task_id
        principal_scope = opts[:principal_scope] || parent.principal_scope

        # Attenuation: delegated caps can only restrict, never expand
        new(
          resource_uri: parent.resource_uri,
          principal_id: new_principal_id,
          expires_at: new_expires_at,
          not_before: new_not_before,
          parent_capability_id: parent.id,
          delegation_depth:
            min(
              parent.delegation_depth - 1,
              opts[:delegation_depth] || parent.delegation_depth - 1
            ),
          max_uses: new_max_uses,
          allowed_delegatees: opts[:allowed_delegatees] || parent.allowed_delegatees,
          session_id: session_id,
          task_id: task_id,
          principal_scope: principal_scope,
          constraints: new_constraints,
          delegation_chain: delegation_chain,
          metadata: opts[:metadata] || %{}
        )
    end
  end

  @doc """
  Compute the canonical signing payload for a capability.

  This is the deterministic binary that gets signed by the issuer.
  Excludes `issuer_signature`, `delegation_chain` signatures, and `signature` fields.

  Each variable-length field is length-prefixed (`<<byte_size::32, field::binary>>`)
  to prevent field-boundary ambiguity attacks.
  """
  @spec signing_payload(t()) :: binary()
  def signing_payload(%__MODULE__{} = cap) do
    constraints_json =
      cap.constraints
      |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
      |> Jason.encode!()

    expires_bin = if cap.expires_at, do: DateTime.to_iso8601(cap.expires_at), else: ""
    not_before_bin = if cap.not_before, do: DateTime.to_iso8601(cap.not_before), else: ""

    length_prefix(cap.id) <>
      length_prefix(cap.resource_uri) <>
      length_prefix(cap.principal_id) <>
      length_prefix(cap.issuer_id || "") <>
      length_prefix(DateTime.to_iso8601(cap.granted_at)) <>
      length_prefix(expires_bin) <>
      length_prefix(not_before_bin) <>
      length_prefix(Integer.to_string(cap.delegation_depth)) <>
      length_prefix(if(cap.max_uses, do: Integer.to_string(cap.max_uses), else: "")) <>
      length_prefix(cap.session_id || "") <>
      length_prefix(cap.task_id || "") <>
      length_prefix(constraints_json) <>
      length_prefix(if cap.signed_at, do: DateTime.to_iso8601(cap.signed_at), else: "")
  end

  defp length_prefix(field) when is_binary(field) do
    <<byte_size(field)::32, field::binary>>
  end

  @doc """
  Returns true if the capability has been signed (has a non-nil, non-empty issuer_signature).
  """
  @spec signed?(t()) :: boolean()
  def signed?(%__MODULE__{issuer_signature: nil}), do: false
  def signed?(%__MODULE__{issuer_signature: sig}) when byte_size(sig) == 0, do: false
  def signed?(%__MODULE__{}), do: true

  # Private functions

  defp generate_capability_id do
    "cap_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  # Constraint keys the enforcer recognizes (see Arbor.Security.Constraint).
  # Constraints crossing a JSON / gateway / LLM boundary may arrive with
  # string keys; the enforcer reads atom keys, so unrecognized string
  # variants would silently disable enforcement. Atomize at the data-entry
  # point to make the cap match the operator's intent regardless of how
  # the grant was constructed.
  @known_constraint_keys [
    :time_window,
    :allowed_paths,
    :rate_limit,
    :requires_approval,
    :taint_policy
  ]

  defp atomize_known_constraint_keys(constraints) when is_map(constraints) do
    Enum.reduce(@known_constraint_keys, constraints, fn key, acc ->
      string_key = Atom.to_string(key)

      case Map.pop(acc, string_key) do
        {nil, _} -> acc
        {value, rest} -> Map.put(rest, key, value)
      end
    end)
  end

  defp atomize_known_constraint_keys(other), do: other

  defp validate_capability(%__MODULE__{} = cap) do
    validators = [
      &validate_resource_uri/1,
      &validate_principal_id/1,
      &validate_expiration/1,
      &validate_not_before/1,
      &validate_delegation_depth/1,
      &validate_issuer_id/1
    ]

    Enum.reduce_while(validators, :ok, fn validator, :ok ->
      case validator.(cap) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_resource_uri(%{resource_uri: uri}) do
    if valid_resource_uri?(uri) do
      :ok
    else
      {:error, {:invalid_resource_uri, uri}}
    end
  end

  defp validate_principal_id(%{principal_id: id}) do
    if String.starts_with?(id, "agent_") or String.starts_with?(id, "human_") do
      :ok
    else
      {:error, {:invalid_principal_id, id}}
    end
  end

  defp validate_expiration(%{granted_at: _granted, expires_at: nil}), do: :ok

  defp validate_expiration(%{granted_at: granted, expires_at: expires}) do
    if DateTime.compare(expires, granted) == :gt do
      :ok
    else
      {:error, {:expires_before_granted, expires, granted}}
    end
  end

  defp validate_not_before(%{not_before: nil}), do: :ok

  defp validate_not_before(%{not_before: not_before, expires_at: nil}) do
    if is_struct(not_before, DateTime), do: :ok, else: {:error, {:invalid_not_before, not_before}}
  end

  defp validate_not_before(%{not_before: not_before, expires_at: expires_at}) do
    cond do
      not is_struct(not_before, DateTime) ->
        {:error, {:invalid_not_before, not_before}}

      DateTime.compare(not_before, expires_at) != :lt ->
        {:error, {:not_before_after_expires, not_before, expires_at}}

      true ->
        :ok
    end
  end

  defp validate_delegation_depth(%{delegation_depth: depth}) when depth >= 0 and depth <= 10 do
    :ok
  end

  defp validate_delegation_depth(%{delegation_depth: depth}) do
    {:error, {:invalid_delegation_depth, depth}}
  end

  defp validate_issuer_id(%{issuer_id: nil}), do: :ok

  defp validate_issuer_id(%{issuer_id: id}) do
    if String.starts_with?(id, "agent_") or id == "system_authority" do
      :ok
    else
      {:error, {:invalid_issuer_id, id}}
    end
  end

  defp valid_resource_uri?(uri) when is_binary(uri) do
    # Supports:
    #   arbor://**                       (root wildcard - all resources)
    #   arbor://category/**              (category wildcard - all ops in category)
    #   arbor://category/action/path     (specific resource)
    #   arbor://category/action/**       (prefix wildcard - matches any subpath)
    #   arbor://category/action/         (prefix wildcard - matches any path)
    #   arbor://category/action          (exact action without path)
    uri == "arbor://**" or
      String.match?(uri, ~r/^arbor:\/\/[a-z_]+\/((\*\*)|[a-z_]+(\/.*)?)?$/)
  end

  defp valid_resource_uri?(_), do: false

  defp not_expired?(%{expires_at: nil}), do: true

  defp not_expired?(%{expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :gt
  end

  defp not_before_passed?(%{not_before: nil}), do: true

  defp not_before_passed?(%{not_before: not_before}) do
    DateTime.compare(DateTime.utc_now(), not_before) != :lt
  end

  defp has_delegation_depth?(%{delegation_depth: depth}), do: depth >= 0

  defp min_datetime(nil, nil), do: nil
  defp min_datetime(dt, nil), do: dt
  defp min_datetime(nil, dt), do: dt

  defp min_datetime(dt1, dt2) do
    case DateTime.compare(dt1, dt2) do
      :lt -> dt1
      _ -> dt2
    end
  end

  # Attenuation for max_uses: delegated cap gets the smaller of parent/opts values
  defp min_pos_integer(nil, nil), do: nil
  defp min_pos_integer(n, nil), do: n
  defp min_pos_integer(nil, n), do: n
  defp min_pos_integer(a, b), do: min(a, b)

  # =============================================================================
  # Taint Policy Accessors
  # =============================================================================

  @valid_taint_policies [:strict, :permissive, :audit_only]

  @doc """
  Get the taint policy from a capability's constraints.

  Taint policies control how tainted data is handled for actions:
  - `:permissive` (default) — Block `:untrusted`/`:hostile` on `:control` params.
    Allow `:derived` on `:control` (audited but not blocked).
  - `:strict` — Block `:derived`, `:untrusted`, `:hostile` on `:control` params.
    Only `:trusted` allowed for control parameters.
  - `:audit_only` — Log taint violations but don't block execution.

  ## Examples

      iex> {:ok, cap} = Capability.new(
      ...>   resource_uri: "arbor://shell/exec",
      ...>   principal_id: "agent_001",
      ...>   constraints: %{taint_policy: :strict}
      ...> )
      iex> Capability.taint_policy(cap)
      :strict

      iex> {:ok, cap} = Capability.new(
      ...>   resource_uri: "arbor://shell/exec",
      ...>   principal_id: "agent_001"
      ...> )
      iex> Capability.taint_policy(cap)
      :permissive
  """
  @spec taint_policy(t()) :: :strict | :permissive | :audit_only
  def taint_policy(%__MODULE__{constraints: constraints}) do
    Map.get(constraints, :taint_policy, :permissive)
  end

  @doc """
  Check if a taint policy value is valid.

  Valid policies are `:strict`, `:permissive`, and `:audit_only`.

  ## Examples

      iex> Capability.valid_taint_policy?(:strict)
      true

      iex> Capability.valid_taint_policy?(:permissive)
      true

      iex> Capability.valid_taint_policy?(:audit_only)
      true

      iex> Capability.valid_taint_policy?(:invalid)
      false
  """
  @spec valid_taint_policy?(term()) :: boolean()
  def valid_taint_policy?(policy) when policy in @valid_taint_policies, do: true
  def valid_taint_policy?(_), do: false

  @doc """
  Returns the list of valid taint policies.
  """
  @spec valid_taint_policies() :: [atom()]
  def valid_taint_policies, do: @valid_taint_policies
end
