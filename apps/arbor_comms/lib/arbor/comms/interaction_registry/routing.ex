defmodule Arbor.Comms.InteractionRegistry.Routing do
  @moduledoc false

  alias Arbor.Comms.InteractionRegistry.Authority

  @spec transition_target(node() | term(), node()) ::
          {:local, module()} | {:remote, node(), module()} | {:error, :invalid_authority}
  def transition_target(authority_node, local_node \\ node())

  def transition_target(authority_node, authority_node) when is_atom(authority_node) do
    {:local, Authority}
  end

  def transition_target(authority_node, local_node)
      when is_atom(authority_node) and is_atom(local_node) do
    {:remote, authority_node, Authority}
  end

  def transition_target(_authority_node, _local_node), do: {:error, :invalid_authority}

  @doc false
  @spec dispatch(node(), atom(), [term()], keyword()) :: term()
  def dispatch(authority_node, function, args, opts \\ [])
      when is_atom(function) and is_list(args) do
    local_node = Keyword.get(opts, :local_node, node())
    authority = Keyword.get(opts, :authority, Authority)
    timeout = Keyword.get(opts, :timeout, 5_000)
    local_call = Keyword.get(opts, :local_call, &apply/3)
    remote_call = Keyword.get(opts, :remote_call, &:rpc.call/5)

    result =
      case transition_target(authority_node, local_node) do
        {:local, _default_authority} ->
          local_call.(authority, function, args)

        {:remote, remote_node, _default_authority} ->
          remote_call.(remote_node, authority, function, args, timeout)

        {:error, _reason} ->
          {:error, :authority_unavailable}
      end

    case result do
      {:badrpc, _reason} -> {:error, :authority_unavailable}
      other -> other
    end
  end
end
