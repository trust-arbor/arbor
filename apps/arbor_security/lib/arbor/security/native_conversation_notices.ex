defmodule Arbor.Security.NativeConversationNotices do
  @moduledoc false
  alias Arbor.Security.{Config, NativeNoticeBroker, SigningAuthorityBroker}

  def open_source(authority) do
    # Protect private acquisition/source/bootstrap RPC replies for this source
    # owner's remaining lifetime, before any secret may enter its mailbox.
    Process.flag(:sensitive, true)
    adapter = Config.native_notice_source_authorizer()

    with true <- is_atom(adapter) and adapter not in [nil, true, false],
         {:ok, %{principal_id: principal, purpose: purpose}} <-
           SigningAuthorityBroker.owned_identity(authority),
         true <- purpose in [:session, :heartbeat],
         {:ok, ticket} <- NativeNoticeBroker.begin_acquisition(principal) do
      try do
        owner = self()

        with {:ok, %{owner_pid: ^owner, principal_id: ^principal} = source} <-
               apply(adapter, :acquire, [principal, owner]),
             payload = acquisition_payload(source),
             {:ok, proof} <- SigningAuthorityBroker.sign(authority, payload) do
          NativeNoticeBroker.open(source, authority, proof, ticket)
        else
          _ -> {:error, :native_notice_source_required}
        end
      after
        NativeNoticeBroker.cancel_acquisition(ticket)
      end
    else
      _ -> {:error, :native_notice_source_required}
    end
  rescue
    _ -> {:error, :native_notice_source_required}
  catch
    _, _ -> {:error, :native_notice_source_required}
  end

  def acquisition_payload(source),
    do: :erlang.term_to_binary(["arbor.native.notice.source.v1", source], [:deterministic])

  defdelegate delegate_worker(source, worker), to: NativeNoticeBroker

  # Only a private ETS locator is process-local. The opaque credential stays
  # in its actual worker-owned private table; copied/dummy process-dictionary
  # locators cannot be read by another PID and are never authority. Neither
  # value enters Engine/action JSON, options, params, results or signals.
  @custody_key {__MODULE__, :worker_custody}
  def claim_worker(bootstrap) do
    # Broker replies may queue while the caller is descheduled. Protect the
    # carrier BEFORE making the private RPC, not after receiving its result.
    Process.flag(:sensitive, true)

    case NativeNoticeBroker.claim_worker(bootstrap) do
      {:ok, custody} when is_reference(custody) ->
        case Process.get(@custody_key) do
          nil -> :ok
          old -> if :ets.info(old, :owner) == self(), do: :ets.delete(old)
        end

        table = :ets.new(__MODULE__, [:set, :private])
        :ets.insert(table, {:custody, custody})
        Process.put(@custody_key, table)
        :ok

      other ->
        other
    end
  end

  def resource(params), do: NativeNoticeBroker.resource(params, custody())
  def prepare(params, taints), do: NativeNoticeBroker.prepare(params, taints, custody())
  def activate(prepared), do: NativeNoticeBroker.activate(prepared, custody())
  def peek(params), do: NativeNoticeBroker.peek(params, custody())
  def consume_value(scope, value), do: NativeNoticeBroker.consume_value(scope, value, custody())

  def reconcile_value(scope, value),
    do: NativeNoticeBroker.reconcile_value(scope, value, custody())

  def finish(params, outcome), do: NativeNoticeBroker.finish(params, outcome, custody())
  def discard(), do: NativeNoticeBroker.discard(custody())

  def close_worker do
    try do
      NativeNoticeBroker.close_worker(custody())
    after
      case Process.delete(@custody_key) do
        nil -> :ok
        table -> if :ets.info(table, :owner) == self(), do: :ets.delete(table)
      end
    end
  end

  defp custody do
    case Process.get(@custody_key) do
      nil ->
        nil

      table ->
        case :ets.lookup(table, :custody) do
          [{:custody, custody}] when is_reference(custody) -> custody
          _ -> nil
        end
    end
  rescue
    ArgumentError -> nil
  end
end
