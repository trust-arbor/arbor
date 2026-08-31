defmodule Arbor.Security.ConfigReplayPeersOptsTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Security.Config

  setup do
    original = Application.fetch_env(:arbor_security, :replay_peers)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:arbor_security, :replay_peers, value)
        :error -> Application.delete_env(:arbor_security, :replay_peers)
      end
    end)

    :ok
  end

  test "unset config yields empty opts (ReplayPeers defaults apply)" do
    Application.delete_env(:arbor_security, :replay_peers)
    assert Config.replay_peers_start_opts() == []
  end

  test "only the three timing knobs pass through" do
    Application.put_env(:arbor_security, :replay_peers,
      foreign_ttl_ms: 1,
      replay_peer_ttl_ms: 2,
      probe_timeout_ms: 3,
      # Anything else must be dropped. :probe_fun in particular would let app
      # config replace the probe and silence the gate; there must also be no
      # allowlist-shaped passenger.
      probe_fun: fn _node, _generation -> :foreign end,
      trusted_nodes: [:evil@host],
      bogus: 4
    )

    opts = Config.replay_peers_start_opts()

    assert Enum.sort(opts) ==
             Enum.sort(foreign_ttl_ms: 1, replay_peer_ttl_ms: 2, probe_timeout_ms: 3)
  end
end
