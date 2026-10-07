defmodule Arbor.Signals.ChannelsC1SecurityRegressionTest do
  @moduledoc """
  Channel rotation no longer creates a self-asserted authority keypair. Fresh
  keys are delivered only by a new recipient-pinned invitation.
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Signals.AuthorizedChannelsTestClient, as: Channels

  setup do
    Arbor.Signals.TestCase.ensure_processes()
    Arbor.Signals.Config.Testing.isolate_namespace()

    Arbor.Signals.Config.Testing.put(
      :channel_principal_authorizer,
      Arbor.Signals.TestChannelPrincipalAuthorizer
    )

    :ok
  end

  test "security regression: no TOFU redistribution authority exists in channel state" do
    creator_id = "agent_c1_creator"

    {:ok, channel, _key} = Channels.create("c1-regression-channel", creator_id)
    channel_id = channel.id

    state = :sys.get_state(Arbor.Signals.Channels)
    entry = state.channels[channel_id]

    assert entry != nil, "channel entry must exist in GenServer state"

    refute Map.has_key?(entry, :authority_keypair)
  end
end
