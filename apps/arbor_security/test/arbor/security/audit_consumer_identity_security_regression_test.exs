defmodule Arbor.Security.AuditConsumerIdentitySecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "SSEC-011"

  @moduletag :fast
  @moduletag security: :regression

  alias Arbor.Security
  alias Arbor.Security.AuditJournalOwner
  alias Arbor.Security.CapabilityAuditCore
  alias Arbor.Security.SupervisedOwner
  alias Arbor.Contracts.Persistence.Record

  defmodule SupervisedConsumer do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, :ok, name: name)
    def run(name, fun), do: GenServer.call(name, {:run, fun})

    @impl true
    def init(:ok), do: {:ok, %{}}

    @impl true
    def handle_call({:run, fun}, _from, state), do: {:reply, fun.(), state}
  end

  @tag spec: "SSEC-011"
  test "security regression: a registered-name squatter cannot read, acknowledge, or reconcile the authority journal" do
    name = :"audit_consumer_squatter_#{System.unique_integer([:positive, :monotonic])}"
    journal_name = :"audit_consumer_journal_#{System.unique_integer([:positive, :monotonic])}"
    previous_name = Application.fetch_env(:arbor_security, :authority_audit_consumer_name)

    previous_application =
      Application.fetch_env(:arbor_security, :authority_audit_consumer_application)

    Application.put_env(:arbor_security, :authority_audit_consumer_name, name)
    Application.put_env(:arbor_security, :authority_audit_consumer_application, :arbor_historian)
    {:ok, journal} = AuditJournalOwner.start_link(mode: :ephemeral, name: journal_name)
    Process.unlink(journal)

    on_exit(fn ->
      if Process.alive?(journal), do: GenServer.stop(journal)

      restore_env(:authority_audit_consumer_name, previous_name)
      restore_env(:authority_audit_consumer_application, previous_application)
    end)

    parent = self()

    attacker =
      spawn(fn ->
        true = Process.register(self(), name)
        send(parent, {:audit_consumer_squatter_ready, self()})

        send(parent, {
          :audit_consumer_squatter_result,
          AuditJournalOwner.delivery_batch(journal),
          AuditJournalOwner.acknowledge_delivery(journal, "missing", String.duplicate("00", 32)),
          Security.reconcile_authority_audit()
        })
      end)

    assert_receive {:audit_consumer_squatter_ready, ^attacker}

    assert_receive {
      :audit_consumer_squatter_result,
      {:error, :unauthorized_audit_consumer},
      {:error, :unauthorized_audit_consumer},
      {:error, :unauthorized_audit_consumer}
    }
  end

  test "security regression: a raw gen_call cannot impersonate the exact supervised audit consumer" do
    consumer_name =
      :"audit_consumer_exact_#{System.unique_integer([:positive, :monotonic])}"

    journal_name =
      :"audit_consumer_exact_journal_#{System.unique_integer([:positive, :monotonic])}"

    previous_name = Application.fetch_env(:arbor_security, :authority_audit_consumer_name)

    previous_application =
      Application.fetch_env(:arbor_security, :authority_audit_consumer_application)

    {:ok, root} = SupervisedOwner.application_root(:arbor_security)

    child_spec =
      Supervisor.child_spec({SupervisedConsumer, consumer_name},
        id: consumer_name,
        restart: :temporary
      )

    {:ok, consumer} = Supervisor.start_child(root, child_spec)
    assert Process.whereis(consumer_name) == consumer

    Application.put_env(:arbor_security, :authority_audit_consumer_name, consumer_name)
    Application.put_env(:arbor_security, :authority_audit_consumer_application, :arbor_security)

    {:ok, journal} =
      AuditJournalOwner.start_link(
        mode: :ephemeral,
        name: journal_name,
        capacity_profile: :operational
      )

    Process.unlink(journal)

    on_exit(fn ->
      if Process.alive?(journal), do: GenServer.stop(journal)
      _ = Supervisor.terminate_child(root, consumer_name)
      _ = Supervisor.delete_child(root, consumer_name)
      restore_env(:authority_audit_consumer_name, previous_name)
      restore_env(:authority_audit_consumer_application, previous_application)
    end)

    intent = grant_intent()
    assert {:ok, admitted, "prepared"} = AuditJournalOwner.prepare(journal_name, intent)
    assert admitted["operation_id"] == intent["operation_id"]

    assert {:ok, :committed} =
             AuditJournalOwner.observe(journal_name, intent["operation_id"], :applied)

    assert {:ok, [item]} =
             SupervisedConsumer.run(consumer_name, fn ->
               AuditJournalOwner.delivery_batch(journal_name)
             end)

    operation_id = item["operation_id"]
    digest = item["intent_sha256"]

    assert {:error, :unauthorized_audit_consumer} =
             forged_call(journal, consumer, :delivery_batch)

    assert {:error, :unauthorized_audit_consumer} =
             forged_call(journal, consumer, {:acknowledge_delivery, operation_id, digest})

    assert {:ok, [still_pending]} =
             SupervisedConsumer.run(consumer_name, fn ->
               AuditJournalOwner.delivery_batch(journal_name)
             end)

    assert still_pending["operation_id"] == operation_id

    assert {:ok, :committed} =
             SupervisedConsumer.run(consumer_name, fn ->
               AuditJournalOwner.acknowledge_delivery(journal_name, operation_id, digest)
             end)
  end

  defp forged_call(journal, asserted_pid, message) do
    reply = :erlang.alias()
    tag = [:alias | reply]
    send(journal, {:"$gen_call", {asserted_pid, tag}, message})

    try do
      receive do
        {^tag, result} -> result
      after
        2_000 -> flunk("forged audit-consumer call did not settle")
      end
    after
      :erlang.unalias(reply)
    end
  end

  defp grant_intent do
    suffix = System.unique_integer([:positive, :monotonic])
    capability_id = "cap_" <> String.pad_leading(Integer.to_string(suffix), 32, "0")
    principal = "agent_" <> String.duplicate("a", 64)

    data = %{
      "id" => capability_id,
      "principal_id" => principal,
      "resource_uri" => "arbor://memory/read/audit-consumer-authentication"
    }

    replacement = CapabilityAuditCore.replacement(Record.new(capability_id, data), :absent)
    prepared_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    {:ok, intent} =
      CapabilityAuditCore.intent(:grant, :absent, replacement, data, prepared_at)

    intent
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:arbor_security, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:arbor_security, key)
end
