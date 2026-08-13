defmodule Arbor.LLM.OAuth.Login.LoopbackFlowSupervisor do
  @moduledoc false

  use Supervisor

  alias Arbor.LLM.OAuth.Login.LoopbackOwner
  alias Arbor.LLM.OAuth.Login.LoopbackPlug
  alias Arbor.LLM.OAuth.Login.LoopbackTransport

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  @doc false
  def arm(flow_supervisor, flow_id) do
    listeners =
      flow_supervisor
      |> Supervisor.which_children()
      |> Enum.flat_map(fn
        {LoopbackOwner, _pid, _, _} -> []
        {_id, pid, _, _} when is_pid(pid) -> [pid]
        _child -> []
      end)

    LoopbackOwner.arm(flow_id, flow_supervisor, listeners)
  end

  @impl true
  def init(opts) do
    flow_id = Keyword.fetch!(opts, :flow_id)
    selector = Keyword.fetch!(opts, :selector)
    port = Keyword.fetch!(opts, :port)
    addresses = Keyword.fetch!(opts, :addresses)

    owner = %{
      id: LoopbackOwner,
      start: {LoopbackOwner, :start_link, [[flow_id: flow_id, selector: selector]]},
      restart: :temporary,
      significant: true
    }

    listeners =
      addresses
      |> Enum.with_index()
      |> Enum.map(fn {address, index} ->
        flow_id
        |> listener_spec(port, address, index)
        |> Map.merge(%{restart: :temporary, significant: true})
      end)

    Supervisor.init([owner | listeners],
      strategy: :one_for_one,
      auto_shutdown: :any_significant
    )
  end

  defp listener_spec(flow_id, port, address, index) do
    family_opts =
      case tuple_size(address) do
        8 -> [:inet6, {:ipv6_v6only, true}]
        4 -> []
      end

    cowboy_opts = [
      scheme: :http,
      plug: {LoopbackPlug, [flow_id: flow_id, port: port]},
      ref: {:arbor_openai_loopback, flow_id, index},
      port: port,
      ip: address,
      stream_handlers: [:cowboy_stream_h],
      transport_options: [
        num_acceptors: 1,
        max_connections: 8,
        handshake_timeout: 2_000,
        socket_opts: family_opts ++ [backlog: 8]
      ],
      protocol_options: [
        protocols: [:http],
        request_timeout: 2_000,
        idle_timeout: 12_000,
        max_keepalive: 1,
        max_empty_lines: 0,
        max_method_length: 8,
        max_request_line_length: 5_000,
        max_authority_length: 64,
        max_headers: 24,
        max_header_name_length: 64,
        max_header_value_length: 1_024,
        max_skip_body_length: 0,
        linger_timeout: 0
      ]
    ]

    [ref, transport_opts, protocol_opts] =
      Plug.Cowboy.args(
        :http,
        LoopbackPlug,
        [flow_id: flow_id, port: port],
        Keyword.drop(cowboy_opts, [:scheme, :plug])
      )

    normalize_ranch_child_spec(
      :ranch.child_spec(ref, LoopbackTransport, transport_opts, :cowboy_clear, protocol_opts)
    )
  end

  defp normalize_ranch_child_spec({id, start, restart, shutdown, type, modules}) do
    %{id: id, start: start, restart: restart, shutdown: shutdown, type: type, modules: modules}
  end

  defp normalize_ranch_child_spec(spec) when is_map(spec), do: spec
end
