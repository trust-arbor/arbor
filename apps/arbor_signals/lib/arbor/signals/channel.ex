defmodule Arbor.Signals.Channel do
  @moduledoc """
  Struct representing an encrypted communication channel.

  Channels enable private agent-to-agent communication with end-to-end
  encryption. Each channel has:

  - A unique ID and human-readable name
  - A creator who manages membership
  - A set of members who can send/receive messages
  - An AES-256-GCM symmetric key for encryption
  - Key versioning for rotation support

  ## Channel Lifecycle

  1. **Create**: Creator generates channel key, becomes first member
  2. **Invite**: Creator seals channel key for invitee's encryption public key
  3. **Accept**: Invitee unseals key and stores in their keychain
  4. **Communicate**: Members encrypt/decrypt with shared channel key
  5. **Leave/Revoke**: Key rotation for remaining members

  ## Topic Pattern

  Channels use the topic pattern `channel.{channel_id}.*` for signals.
  """

  use TypedStruct

  @derive Jason.Encoder
  typedstruct enforce: true do
    @typedoc "An encrypted communication channel"

    field(:id, String.t())
    field(:name, String.t())
    field(:creator_id, String.t())
    field(:members, MapSet.t(String.t()), default: MapSet.new())
    field(:key_version, pos_integer(), default: 1)
    field(:created_at, DateTime.t())
    field(:metadata, map(), default: %{})
  end

  @doc """
  Create a new channel struct.

  The creator is automatically added as the first member.
  """
  @spec new(String.t(), String.t(), String.t(), keyword()) :: t()
  def new(id, name, creator_id, opts \\ []) do
    %__MODULE__{
      id: id,
      name: name,
      creator_id: creator_id,
      members: MapSet.new([creator_id]),
      key_version: 1,
      created_at: DateTime.utc_now(),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Add a member to the channel.
  """
  @spec add_member(t(), String.t()) :: t()
  def add_member(%__MODULE__{} = channel, agent_id) do
    %{channel | members: MapSet.put(channel.members, agent_id)}
  end

  @doc """
  Remove a member from the channel.
  """
  @spec remove_member(t(), String.t()) :: t()
  def remove_member(%__MODULE__{} = channel, agent_id) do
    %{channel | members: MapSet.delete(channel.members, agent_id)}
  end

  @doc """
  Check if an agent is a member of the channel.
  """
  @spec member?(t(), String.t()) :: boolean()
  def member?(%__MODULE__{members: members}, agent_id) do
    MapSet.member?(members, agent_id)
  end

  @doc """
  Increment the key version (after key rotation).
  """
  @spec increment_key_version(t()) :: t()
  def increment_key_version(%__MODULE__{key_version: v} = channel) do
    %{channel | key_version: v + 1}
  end

  @doc """
  Get the signal topic pattern for this channel.
  """
  @spec topic_pattern(t()) :: String.t()
  def topic_pattern(%__MODULE__{id: id}) do
    "channel.#{id}.*"
  end

  @doc """
  Get the base topic for this channel (for publishing).
  """
  @spec base_topic(t()) :: String.t()
  def base_topic(%__MODULE__{id: id}) do
    "channel.#{id}"
  end
end
