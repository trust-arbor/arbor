defmodule Arbor.Common.SafeAtom do
  @moduledoc """
  Safe string-to-atom conversion utilities that prevent DoS attacks.

  The BEAM atom table is limited (~1M atoms) and never garbage collected.
  Using `String.to_atom/1` with untrusted input enables resource exhaustion
  attacks. These utilities ensure we only convert strings to atoms that
  already exist in the VM or are explicitly allowed.

  ## Security Context

  This module is critical for handling:
  - LLM-generated JSON with string keys
  - External API responses
  - User input that might become atoms
  - Signal/event type parsing

  ## Examples

      # Safe conversion - returns error for unknown atoms
      iex> SafeAtom.to_existing("ok")
      {:ok, :ok}

      iex> SafeAtom.to_existing("definitely_not_an_atom_xyz123")
      {:error, {:unknown_atom, "definitely_not_an_atom_xyz123"}}

      # Allowlist-based conversion
      iex> SafeAtom.to_allowed("read", [:read, :write, :delete])
      {:ok, :read}

      iex> SafeAtom.to_allowed("execute", [:read, :write, :delete])
      {:error, {:not_allowed, "execute"}}

      # Safe map key atomization
      iex> SafeAtom.atomize_keys(%{"name" => "test", "unknown" => 1}, [:name, :id])
      %{name: "test", "unknown" => 1}
  """

  @type result :: {:ok, atom()} | {:error, {:unknown_atom, String.t()}}
  @type allowed_result :: {:ok, atom()} | {:error, {:not_allowed, String.t() | atom()}}

  @doc """
  Convert string to existing atom only. Returns error for unknown strings.

  This is the safest conversion method - it will only succeed if the atom
  already exists in the VM's atom table.

  ## Examples

      iex> Arbor.Common.SafeAtom.to_existing("ok")
      {:ok, :ok}

      iex> Arbor.Common.SafeAtom.to_existing("definitely_not_an_atom_12345")
      {:error, {:unknown_atom, "definitely_not_an_atom_12345"}}

      iex> Arbor.Common.SafeAtom.to_existing(:already_atom)
      {:ok, :already_atom}

      iex> Arbor.Common.SafeAtom.to_existing(nil)
      {:ok, nil}
  """
  @spec to_existing(String.t() | atom() | nil) :: result()
  def to_existing(string) when is_binary(string) do
    {:ok, String.to_existing_atom(string)}
  rescue
    ArgumentError -> {:error, {:unknown_atom, string}}
  end

  def to_existing(atom) when is_atom(atom), do: {:ok, atom}

  @doc """
  Convert string to existing atom, raising on unknown.

  Use only when you're certain the atom should exist (e.g., internal APIs
  where the set of possible values is known at compile time).

  ## Examples

      iex> Arbor.Common.SafeAtom.to_existing!("ok")
      :ok

      iex> Arbor.Common.SafeAtom.to_existing!("unknown_atom_xyz")
      ** (ArgumentError) argument error
  """
  @spec to_existing!(String.t() | atom()) :: atom()
  def to_existing!(string) when is_binary(string) do
    String.to_existing_atom(string)
  end

  def to_existing!(atom) when is_atom(atom), do: atom

  @doc """
  Convert string to atom if it's in the allowed set, otherwise error.

  This is useful when you have a known set of valid atoms (e.g., action types,
  status values) and want to safely convert user input.

  ## Examples

      iex> Arbor.Common.SafeAtom.to_allowed("read", [:read, :write, :delete])
      {:ok, :read}

      iex> Arbor.Common.SafeAtom.to_allowed("execute", [:read, :write, :delete])
      {:error, {:not_allowed, "execute"}}

      iex> Arbor.Common.SafeAtom.to_allowed(:read, [:read, :write])
      {:ok, :read}

      iex> Arbor.Common.SafeAtom.to_allowed(:other, [:read, :write])
      {:error, {:not_allowed, :other}}
  """
  @spec to_allowed(String.t() | atom(), [atom()]) :: allowed_result()
  def to_allowed(string, allowed) when is_binary(string) and is_list(allowed) do
    case to_existing(string) do
      {:ok, atom} ->
        if atom in allowed, do: {:ok, atom}, else: {:error, {:not_allowed, atom}}

      {:error, _} ->
        {:error, {:not_allowed, string}}
    end
  end

  def to_allowed(atom, allowed) when is_atom(atom) and is_list(allowed) do
    if atom in allowed do
      {:ok, atom}
    else
      {:error, {:not_allowed, atom}}
    end
  end

  @doc """
  Atomize only known keys in a map, keeping unknown keys as strings.

  This is safe for processing external data (e.g., JSON from LLMs or APIs)
  where you know which keys you expect but may receive additional unknown keys.

  ## Examples

      iex> Arbor.Common.SafeAtom.atomize_keys(%{"name" => "test", "unknown" => 1}, [:name, :id])
      %{name: "test", "unknown" => 1}

      iex> Arbor.Common.SafeAtom.atomize_keys(%{"action" => "read"}, [:action, :target])
      %{action: "read"}

      iex> Arbor.Common.SafeAtom.atomize_keys(%{already: "atom"}, [:already])
      %{already: "atom"}
  """
  @spec atomize_keys(map(), [atom()]) :: map()
  def atomize_keys(map, known_keys) when is_map(map) and is_list(known_keys) do
    known_strings = Map.new(known_keys, fn k -> {Atom.to_string(k), k} end)

    Map.new(map, fn
      {k, v} when is_binary(k) ->
        case Map.fetch(known_strings, k) do
          {:ok, atom_key} -> {atom_key, v}
          :error -> {k, v}
        end

      {k, v} ->
        {k, v}
    end)
  end

  @doc """
  Like `atomize_keys/2` but raises if unknown keys are found.

  Use for internal APIs where all keys should be known. Unknown keys
  indicate a programming error or unexpected data.

  ## Examples

      iex> Arbor.Common.SafeAtom.atomize_keys!(%{"name" => "test"}, [:name, :id])
      %{name: "test"}

      iex> Arbor.Common.SafeAtom.atomize_keys!(%{"name" => "test", "bad" => 1}, [:name])
      ** (ArgumentError) Unknown key: "bad"
  """
  @spec atomize_keys!(map(), [atom()]) :: map()
  def atomize_keys!(map, known_keys) when is_map(map) and is_list(known_keys) do
    known_strings = MapSet.new(known_keys, &Atom.to_string/1)

    Map.new(map, fn
      {k, v} when is_binary(k) ->
        if k in known_strings do
          {String.to_existing_atom(k), v}
        else
          raise ArgumentError, "Unknown key: #{inspect(k)}"
        end

      {k, v} when is_atom(k) ->
        if k in known_keys do
          {k, v}
        else
          raise ArgumentError, "Unknown key: #{inspect(k)}"
        end

      {k, v} ->
        {k, v}
    end)
  end

  @doc """
  Recursively atomize known keys in nested maps.

  Useful for deeply nested structures like LLM responses.

  ## Options

  - `:known_keys` - list of atoms to convert at this level
  - `:nested` - map of key => options for recursive processing

  ## Examples

      iex> data = %{"action" => "read", "params" => %{"path" => "/tmp"}}
      iex> Arbor.Common.SafeAtom.atomize_keys_deep(data,
      ...>   known_keys: [:action, :params],
      ...>   nested: %{params: [known_keys: [:path, :content]]}
      ...> )
      %{action: "read", params: %{path: "/tmp"}}
  """
  @spec atomize_keys_deep(map(), keyword()) :: map()
  def atomize_keys_deep(map, opts) when is_map(map) and is_list(opts) do
    known_keys = Keyword.get(opts, :known_keys, [])
    nested = Keyword.get(opts, :nested, %{})

    atomized = atomize_keys(map, known_keys)

    Enum.reduce(nested, atomized, fn {key, nested_opts}, acc ->
      case Map.fetch(acc, key) do
        {:ok, nested_map} when is_map(nested_map) ->
          Map.put(acc, key, atomize_keys_deep(nested_map, nested_opts))

        _ ->
          acc
      end
    end)
  end

  # =============================================================================
  # Enum generation for reducing allowlist boilerplate
  # =============================================================================
  #
  # Each call to `define_enum/3` below generates:
  #   - A module attribute `@valid_<name>` with the allowed atom list
  #   - A `<name>/0` function returning the allowed values
  #   - A `to_<converter>/1` function for safe string-to-atom conversion
  #
  # Modes:
  #   :strict  - returns {:ok, atom} | {:error, {:not_allowed, value}}
  #   :fallback - returns the atom directly, :unknown on miss
  #
  # Accept:
  #   :binary_only - converter only accepts binary input
  #   :any         - converter accepts both binary and atom input

  @enum_definitions [
    {:identity_statuses, [:active, :suspended, :revoked],
     converter: :to_identity_status, mode: :strict, accept: :any},
    {:taint_levels, [:trusted, :derived, :untrusted, :hostile],
     converter: :to_taint_level, mode: :strict, accept: :binary_only},
    {:taint_roles, [:control, :data],
     converter: :to_taint_role, mode: :strict, accept: :binary_only},
    {:taint_policies, [:strict, :permissive, :audit_only],
     converter: :to_taint_policy, mode: :strict, accept: :binary_only},
    {:signal_categories, [:activity, :security, :metrics, :traces, :logs, :alerts, :custom, :unknown],
     converter: :to_category, mode: :fallback, accept: :any},
    {:subject_types,
     [:agent, :session, :task, :action, :event, :signal, :capability, :identity, :unknown],
     converter: :to_subject_type, mode: :fallback, accept: :any}
  ]

  for {name, values, opts} <- @enum_definitions do
    converter = Keyword.fetch!(opts, :converter)
    mode = Keyword.fetch!(opts, :mode)
    accept = Keyword.fetch!(opts, :accept)

    # Safe: name comes from compile-time @enum_definitions literals, not user input
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    Module.put_attribute(__MODULE__, :"valid_#{name}", values)

    @doc false
    @spec unquote(name)() :: [atom()]
    def unquote(name)(), do: unquote(values)

    case {mode, accept} do
      {:strict, :binary_only} ->
        @doc false
        @spec unquote(converter)(String.t()) :: allowed_result()
        def unquote(converter)(value) when is_binary(value) do
          to_allowed(value, unquote(values))
        end

      {:strict, :any} ->
        @doc false
        @spec unquote(converter)(String.t() | atom()) :: allowed_result()
        def unquote(converter)(value) when is_binary(value) do
          to_allowed(value, unquote(values))
        end

        def unquote(converter)(value) when is_atom(value) do
          to_allowed(value, unquote(values))
        end

      {:fallback, :any} ->
        @doc false
        @spec unquote(converter)(String.t() | atom()) :: atom()
        def unquote(converter)(value) when is_binary(value) do
          case to_allowed(value, unquote(values)) do
            {:ok, atom} -> atom
            {:error, _} -> :unknown
          end
        end

        def unquote(converter)(value) when is_atom(value) do
          if value in unquote(values), do: value, else: :unknown
        end
    end
  end

  @doc """
  Safely decode an event type string to {category, signal_type} tuple.

  Event types are encoded as "category:signal_type" strings. This function
  safely converts them back to atoms using allowlists.

  ## Examples

      iex> Arbor.Common.SafeAtom.decode_event_type("activity:agent_started")
      {:activity, :agent_started}

      iex> Arbor.Common.SafeAtom.decode_event_type("evil:attack")
      {:unknown, :unknown}

      iex> Arbor.Common.SafeAtom.decode_event_type(:"security:auth_failed")
      {:security, :auth_failed}
  """
  @spec decode_event_type(String.t() | atom()) :: {atom(), atom()}
  def decode_event_type(event_type) when is_atom(event_type) do
    decode_event_type(Atom.to_string(event_type))
  end

  def decode_event_type(event_type) when is_binary(event_type) do
    case String.split(event_type, ":", parts: 2) do
      [category_str, type_str] ->
        category = to_category(category_str)
        # Signal types are more open-ended, use to_existing with fallback
        signal_type =
          case to_existing(type_str) do
            {:ok, atom} -> atom
            {:error, _} -> :unknown
          end

        {category, signal_type}

      [single] ->
        # Single value without colon - preserve as type if atom exists
        signal_type =
          case to_existing(single) do
            {:ok, atom} -> atom
            {:error, _} -> :unknown
          end

        {:unknown, signal_type}
    end
  end

  @doc """
  Safely encode a {category, signal_type} tuple to an atom.

  Only creates the atom if both category and signal_type are valid atoms.
  This is safe because we control the inputs (they must already be atoms).

  ## Examples

      iex> Arbor.Common.SafeAtom.encode_event_type(:activity, :agent_started)
      :"activity:agent_started"
  """
  @spec encode_event_type(atom(), atom()) :: atom()
  def encode_event_type(category, signal_type) when is_atom(category) and is_atom(signal_type) do
    # Safe: both inputs are guaranteed atoms by guard clause, combining existing atoms
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    :"#{category}:#{signal_type}"
  end

  @doc """
  Safely infer subject type from an entity ID string.

  Entity IDs follow "prefix_id" pattern. Returns `:unknown` for
  unrecognized prefixes.

  ## Examples

      iex> Arbor.Common.SafeAtom.infer_subject_type("agent_001")
      :agent

      iex> Arbor.Common.SafeAtom.infer_subject_type("malicious_injection")
      :unknown

      iex> Arbor.Common.SafeAtom.infer_subject_type("no_underscore")
      :unknown
  """
  @spec infer_subject_type(String.t()) :: atom()
  def infer_subject_type(subject_id) when is_binary(subject_id) do
    case String.split(subject_id, "_", parts: 2) do
      [prefix, _rest] -> to_subject_type(prefix)
      _ -> :unknown
    end
  end
end
