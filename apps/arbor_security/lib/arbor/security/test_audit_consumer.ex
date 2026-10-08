if Mix.env() == :test do
  defmodule Arbor.Security.TestAuditConsumer do
    @moduledoc """
    Test-only stand-in for `Arbor.Historian.AuthorityAuditPuller`: acknowledges
    every delivered authority-audit operation so the Security audit journal
    retires them, as it does in production.

    Test runs do not start the Historian (`config :arbor_historian,
    start_children: false`), so without a consumer no operation is ever
    acknowledged. Each one stays pending with two written entries plus one
    reserved, and the ephemeral `:operational` journal's 3072-entry soft cap
    admits only about 1023 grants and revokes per test run. Past that, every
    grant fails with `{:error, :audit_unavailable}`, in whatever modules run last.

    This consumer polls with the puller's own calls:
    `Arbor.Security.reconcile_authority_audit/0`, then
    `authority_audit_delivery_batch/0`, acknowledging each item with
    `acknowledge_authority_audit/2`. Unlike the puller it writes no EventLog record,
    so an acknowledgement here is no durability evidence. That is acceptable
    only because test journals make no durability claim. It is authorized
    only through the test-build provenance `:authority_audit_consumer_application`
    `:test` (see `Arbor.Security.AuthorityAuditConsumer`), and the module is
    absent from non-test builds.

    `Arbor.Security.TestBootstrap.start!/1` starts it unless given
    `audit_consumer: false`. A test that needs to be the consumer itself, or to
    have none, swaps `:authority_audit_consumer_name` as before; this process
    is then unauthorized and its polls are refused until the name is restored.
    """

    use GenServer

    @name __MODULE__
    @poll_ms 100
    # Bounds one delivery pass, so a stream of new operations cannot keep it busy.
    @max_batches_per_pass 64

    @doc """
    Start the consumer and configure Security to accept it as the
    authority-audit consumer. Idempotent: when it is already running, the
    configuration is left alone, so a test that swapped in its own consumer
    keeps it (`TestBootstrap.restore_supervised_tree!/0` calls this again).
    """
    @spec ensure_started() :: :ok
    def ensure_started do
      case GenServer.start(__MODULE__, :ok, name: @name) do
        {:ok, _pid} ->
          Application.put_env(:arbor_security, :authority_audit_consumer_name, @name)
          Application.put_env(:arbor_security, :authority_audit_consumer_application, :test)

        {:error, {:already_started, _pid}} ->
          :ok
      end

      :ok
    end

    @doc """
    Acknowledge everything deliverable now instead of waiting for the next poll.
    Returns the number of operations acknowledged.
    """
    @spec drain(timeout()) :: non_neg_integer()
    def drain(timeout \\ 10_000), do: GenServer.call(@name, :drain, timeout)

    @impl true
    def init(:ok), do: {:ok, schedule(%{})}

    @impl true
    def handle_info(:poll, state) do
      _ = deliver()
      {:noreply, schedule(state)}
    end

    def handle_info(_message, state), do: {:noreply, state}

    @impl true
    def handle_call(:drain, _from, state), do: {:reply, deliver(), state}

    defp schedule(state) do
      Process.send_after(self(), :poll, @poll_ms)
      state
    end

    # Like the puller, first let CapabilityStore reobserve operations whose
    # effect was applied but not yet recorded. Refusals (another consumer
    # configured, journal restarting or unavailable) end the pass quietly; the
    # next poll retries. A batch in which nothing could be acknowledged also
    # ends it, so a stuck item cannot spin the loop.
    defp deliver do
      _ = Arbor.Security.reconcile_authority_audit()
      deliver(0, @max_batches_per_pass)
    catch
      :exit, _reason -> 0
    end

    defp deliver(acked, 0), do: acked

    defp deliver(acked, batches_left) do
      case Arbor.Security.authority_audit_delivery_batch() do
        {:ok, [_ | _] = batch} ->
          case Enum.count(batch, &acknowledge/1) do
            0 -> acked
            count -> deliver(acked + count, batches_left - 1)
          end

        _empty_or_refused ->
          acked
      end
    catch
      :exit, _reason -> acked
    end

    defp acknowledge(%{"operation_id" => id, "intent_sha256" => digest}) do
      match?({:ok, _}, Arbor.Security.acknowledge_authority_audit(id, digest))
    end

    defp acknowledge(_item), do: false
  end
end
