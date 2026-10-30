defmodule Arbor.Common.OAuth.HttpClient.Pool do
  @moduledoc """
  Dedicated Finch pool for bounded OAuth acquisition traffic.

  OAuth stays on HTTP/1 until Mint provides complete decoded HTTP/2 header
  byte/count bounds. Mint 1.9.3 enforces `:max_header_list_size` while parsing
  HTTP/1 response headers and trailers, before Req receives the response.
  """

  @name __MODULE__
  @max_header_list_size 32_768
  @protocols [:http1]

  @doc false
  def child_spec(_opts) do
    Supervisor.child_spec(
      {Finch, name: @name, pools: %{default: pool_options()}},
      id: __MODULE__
    )
  end

  @doc "Return the stable Finch pool name used by the OAuth Req adapter."
  @spec name() :: atom()
  def name, do: @name

  @doc "Return the parser-level HTTP/1 response-header byte limit."
  @spec max_header_list_size() :: pos_integer()
  def max_header_list_size, do: @max_header_list_size

  @doc "Return the closed Finch default-pool configuration."
  @spec pool_options() :: keyword()
  def pool_options do
    [
      size: 4,
      count: 1,
      protocols: @protocols,
      conn_opts: [max_header_list_size: @max_header_list_size],
      conn_max_idle_time: 60_000,
      pool_max_idle_time: 60_000
    ]
  end
end
