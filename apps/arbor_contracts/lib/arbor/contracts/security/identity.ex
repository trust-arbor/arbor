defmodule Arbor.Contracts.Security.Identity do
  @moduledoc """
  Represents a cryptographic agent identity.

  Every agent in the Arbor system has an Ed25519 keypair. The agent ID is
  deterministically derived from the public key hash, creating an unforgeable
  binding between identity and cryptographic material.

  ## Identity Model

  - **Deterministic**: Agent IDs are `"agent_" <> hex(SHA-256(public_key))`
  - **Keypair-based**: Ed25519 for signing and verification
  - **Private-key-safe**: Private keys (32-byte Ed25519 seeds) are never serialized to JSON or stored in registries
  - **Named**: Optional human-readable name for display/logging (not an identifier)

  ## Usage

      # Generate a new identity
      {:ok, identity} = Identity.generate(name: "code-reviewer")

      # Create from existing public key
      {:ok, identity} = Identity.new(public_key: public_key, name: "auditor")

      # Agent ID is derived automatically
      identity.agent_id
      #=> "agent_a1b2c3..."

      # Human-readable display
      Identity.display_name(identity)
      #=> "code-reviewer (agent_a1b2c3..)"
  """

  use TypedStruct

  alias Arbor.Types

  @ed25519_public_key_size 32
  @ed25519_private_key_size 32
  @x25519_key_size 32

  @typedoc "Identity lifecycle status"
  @type status :: :active | :suspended | :revoked

  typedstruct enforce: true do
    @typedoc "A cryptographic agent identity"

    field(:agent_id, Types.agent_id())
    field(:name, String.t(), enforce: false)
    field(:public_key, Types.public_key())
    field(:private_key, Types.private_key(), enforce: false)
    field(:encryption_public_key, binary(), enforce: false)
    field(:encryption_private_key, binary(), enforce: false)
    field(:created_at, DateTime.t())
    field(:key_version, Types.key_version(), default: 1)
    field(:metadata, map(), default: %{})
    # Lifecycle status fields
    field(:status, status(), default: :active)
    field(:status_changed_at, DateTime.t(), enforce: false)
    field(:status_reason, String.t(), enforce: false)
  end

  @doc """
  Create a new identity from an existing public key.

  The agent ID is derived deterministically from the public key.

  ## Options

  - `:public_key` (required) - 32-byte Ed25519 public key
  - `:private_key` - 32-byte Ed25519 private key seed (optional, never stored in registries)
  - `:encryption_public_key` - 32-byte X25519 public key for encrypted comms (optional)
  - `:encryption_private_key` - 32-byte X25519 private key (optional, never stored in registries)
  - `:name` - Optional human-readable name (not an identifier, does not need to be unique)
  - `:key_version` - Key version number (default: 1)
  - `:metadata` - Additional metadata map

  ## Examples

      {:ok, identity} = Identity.new(public_key: public_key_bytes, name: "auditor")
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    public_key = Keyword.fetch!(attrs, :public_key)

    identity = %__MODULE__{
      agent_id: derive_agent_id(public_key),
      name: attrs[:name],
      public_key: public_key,
      private_key: attrs[:private_key],
      encryption_public_key: attrs[:encryption_public_key],
      encryption_private_key: attrs[:encryption_private_key],
      created_at: attrs[:created_at] || DateTime.utc_now(),
      key_version: attrs[:key_version] || 1,
      metadata: attrs[:metadata] || %{},
      status: attrs[:status] || :active,
      status_changed_at: attrs[:status_changed_at],
      status_reason: attrs[:status_reason]
    }

    case validate(identity) do
      :ok -> {:ok, identity}
      {:error, _} = error -> error
    end
  end

  @doc """
  Generate a new Ed25519 identity with a fresh keypair.

  ## Options

  - `:name` - Optional human-readable name
  - `:key_version` - Key version number (default: 1)
  - `:metadata` - Additional metadata map

  ## Examples

      {:ok, identity} = Identity.generate(name: "code-reviewer")
      identity.agent_id
      #=> "agent_a1b2c3d4..."
  """
  @spec generate(keyword()) :: {:ok, t()} | {:error, term()}
  def generate(opts \\ []) do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    {enc_public, enc_private} = :crypto.generate_key(:ecdh, :x25519)

    new(
      public_key: public_key,
      private_key: private_key,
      encryption_public_key: enc_public,
      encryption_private_key: enc_private,
      name: opts[:name],
      key_version: opts[:key_version] || 1,
      metadata: opts[:metadata] || %{}
    )
  end

  @doc """
  Derive an agent ID from a public key.

  The agent ID is `"agent_" <> hex(SHA-256(public_key))` in lowercase.
  """
  @spec derive_agent_id(Types.public_key()) :: Types.agent_id()
  def derive_agent_id(public_key) when is_binary(public_key) do
    "agent_" <> Base.encode16(:crypto.hash(:sha256, public_key), case: :lower)
  end

  @doc """
  Return a copy of the identity without private keys.

  Strips both the Ed25519 signing private key and the X25519 encryption
  private key. Use this before storing in registries or transmitting.
  Preserves the identity status for registry storage.
  """
  @spec public_only(t()) :: t()
  def public_only(%__MODULE__{} = identity) do
    %{identity | private_key: nil, encryption_private_key: nil}
  end

  @doc """
  Check if a value is a valid identity status.

  Valid statuses are `:active`, `:suspended`, and `:revoked`.

  ## Examples

      iex> Identity.valid_status?(:active)
      true

      iex> Identity.valid_status?(:suspended)
      true

      iex> Identity.valid_status?(:revoked)
      true

      iex> Identity.valid_status?(:invalid)
      false
  """
  @spec valid_status?(term()) :: boolean()
  def valid_status?(status) when status in [:active, :suspended, :revoked], do: true
  def valid_status?(_), do: false

  @doc """
  Return a human-readable display string for the identity.

  If the identity has a name, returns `"name (agent_xxxx..)"`.
  Otherwise returns the truncated agent_id: `"agent_xxxx.."`.

  ## Examples

      Identity.display_name(named_identity)
      #=> "code-reviewer (agent_a1b2c3d4..)"

      Identity.display_name(unnamed_identity)
      #=> "agent_a1b2c3d4.."
  """
  @spec display_name(t()) :: String.t()
  def display_name(%__MODULE__{name: name, agent_id: agent_id}) do
    short_id = String.slice(agent_id, 0, 16) <> ".."

    case name do
      nil -> short_id
      "" -> short_id
      name -> "#{name} (#{short_id})"
    end
  end

  # Validation

  defp validate(%__MODULE__{} = identity) do
    validators = [
      &validate_public_key/1,
      &validate_private_key/1,
      &validate_encryption_public_key/1,
      &validate_encryption_private_key/1,
      &validate_agent_id_matches/1,
      &validate_key_version/1,
      &validate_name/1
    ]

    Enum.reduce_while(validators, :ok, fn validator, :ok ->
      case validator.(identity) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_public_key(%{public_key: pk})
       when is_binary(pk) and byte_size(pk) == @ed25519_public_key_size do
    :ok
  end

  defp validate_public_key(%{public_key: pk}) do
    {:error,
     {:invalid_public_key_size, byte_size_or_type(pk), :expected, @ed25519_public_key_size}}
  end

  defp validate_private_key(%{private_key: nil}), do: :ok

  defp validate_private_key(%{private_key: sk})
       when is_binary(sk) and byte_size(sk) == @ed25519_private_key_size do
    :ok
  end

  defp validate_private_key(%{private_key: sk}) do
    {:error,
     {:invalid_private_key_size, byte_size_or_type(sk), :expected, @ed25519_private_key_size}}
  end

  defp validate_encryption_public_key(%{encryption_public_key: nil}), do: :ok

  defp validate_encryption_public_key(%{encryption_public_key: pk})
       when is_binary(pk) and byte_size(pk) == @x25519_key_size do
    :ok
  end

  defp validate_encryption_public_key(%{encryption_public_key: pk}) do
    {:error,
     {:invalid_encryption_public_key_size, byte_size_or_type(pk), :expected, @x25519_key_size}}
  end

  defp validate_encryption_private_key(%{encryption_private_key: nil}), do: :ok

  defp validate_encryption_private_key(%{encryption_private_key: sk})
       when is_binary(sk) and byte_size(sk) == @x25519_key_size do
    :ok
  end

  defp validate_encryption_private_key(%{encryption_private_key: sk}) do
    {:error,
     {:invalid_encryption_private_key_size, byte_size_or_type(sk), :expected, @x25519_key_size}}
  end

  defp validate_agent_id_matches(%{agent_id: agent_id, public_key: pk}) do
    expected = derive_agent_id(pk)

    if agent_id == expected do
      :ok
    else
      {:error, {:agent_id_mismatch, agent_id, :expected, expected}}
    end
  end

  defp validate_key_version(%{key_version: v}) when is_integer(v) and v >= 1, do: :ok
  defp validate_key_version(%{key_version: v}), do: {:error, {:invalid_key_version, v}}

  defp validate_name(%{name: nil}), do: :ok
  defp validate_name(%{name: name}) when is_binary(name) and byte_size(name) > 0, do: :ok
  defp validate_name(%{name: ""}), do: {:error, :empty_name}
  defp validate_name(%{name: name}), do: {:error, {:invalid_name, name}}

  defp byte_size_or_type(val) when is_binary(val), do: byte_size(val)
  defp byte_size_or_type(val), do: {:not_binary, val}
end

defimpl Jason.Encoder, for: Arbor.Contracts.Security.Identity do
  def encode(identity, opts) do
    identity
    |> Map.from_struct()
    |> Map.delete(:private_key)
    |> Map.delete(:encryption_private_key)
    |> Map.update!(:public_key, &Base.encode64/1)
    |> then(fn map ->
      case map.encryption_public_key do
        nil -> map
        key -> Map.put(map, :encryption_public_key, Base.encode64(key))
      end
    end)
    |> Map.update!(:created_at, &DateTime.to_iso8601/1)
    |> then(fn map ->
      case map.status_changed_at do
        nil -> map
        dt -> Map.put(map, :status_changed_at, DateTime.to_iso8601(dt))
      end
    end)
    |> Jason.Encode.map(opts)
  end
end
