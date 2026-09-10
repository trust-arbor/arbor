defmodule Arbor.Scheduler.OwnedRoutineWireSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Persistence.Repo
  alias Arbor.Scheduler
  alias Arbor.Scheduler.Test.OwnedRoutineFixture, as: F

  @moduletag :integration
  @moduletag :database
  @moduletag :isolated_repo
  @moduletag :security_regression

  setup_all do
    case apply(Repo, :__adapter__, []) do
      Ecto.Adapters.SQLite3 -> F.start_sql!()
      Ecto.Adapters.Postgres -> F.start_postgres_sql!()
    end
  end

  setup context do
    F.start!(context)
  end

  test "public enqueue persists a binary-safe proof and cold historical execution retains exact signed bytes",
       f do
    intent = F.intent!(f)
    old = DateTime.add(DateTime.utc_now(), -120)
    F.env(:arbor_security, :timestamp_max_drift_seconds, 300)
    proof = F.proof!(f.owner, :enqueue, intent, timestamp: old)
    assert proof.payload =~ <<0>>
    assert {:ok, job} = Scheduler.enqueue_routine(intent, proof)
    Application.put_env(:arbor_security, :timestamp_max_drift_seconds, 60)

    assert :ok = Supervisor.terminate_child(f.repo_supervisor, Repo)
    assert {:ok, _} = Supervisor.restart_child(f.repo_supervisor, Repo)
    row = Repo.get!(Oban.Job, job.id)
    wire = row.args["owned_routine"]["proof"]

    assert Enum.sort(Map.keys(wire)) ==
             Enum.sort(~w(version payload_base64 agent_id timestamp nonce signature))

    assert wire["version"] == 2
    assert Base.decode64!(wire["payload_base64"]) == proof.payload
    assert wire["agent_id"] == f.owner.identity.agent_id
    assert wire["timestamp"] == DateTime.to_iso8601(old)
    refute Map.has_key?(wire, "payload")
    refute Jason.encode!(row.args) =~ "\\u0000"

    assert {:ok, %{items: [listed]}} = list(f)
    assert listed.id == job.id
    assert {:ok, %{items: []}} = list(f, f.other)
    assert %{success: 1, failure: 0} = F.drain()
    assert Repo.get!(Oban.Job, job.id).state == "completed"
    assert File.read!(F.report(f, "morning-digest")) =~ "first bounded source"
  end

  for variant <- [
        :unknown_version,
        :string_version,
        :missing_version,
        :mixed_payload,
        :extra_field,
        :wrong_encoding_type,
        :invalid_base64,
        :unpadded_base64,
        :oversized_encoding,
        :oversized_decoding,
        :changed_payload,
        :changed_signature,
        :changed_owner
      ] do
    test "security regression: persisted #{variant} proof cannot list, cancel or execute", f do
      intent = F.intent!(f)
      proof = F.proof!(f.owner, :enqueue, intent)
      assert {:ok, job} = Scheduler.enqueue_routine(intent, proof)
      assert {:ok, %{items: [_]}} = list(f)
      row = Repo.get!(Oban.Job, job.id)
      wire = wire(proof) |> corrupt(unquote(variant), f)
      args = put_in(row.args, ["owned_routine", "proof"], wire)
      Repo.update!(Ecto.Changeset.change(row, args: args))

      assert {:ok, %{items: []}} = list(f)

      assert {:error, :routine_cancel_denied} =
               Scheduler.cancel_owned_routine(job.id, F.proof!(f.owner, :cancel, job.id))

      assert %{discard: 1, success: 0} = F.drain()
      assert Repo.get!(Oban.Job, job.id).state == "discarded"
      assert File.read!(F.report(f, "morning-digest")) == "previous digest"
      refute_received {:routine_effect, _, _, _}
    end
  end

  if Application.compile_env(:arbor_persistence, :repo_adapter) == Ecto.Adapters.SQLite3 do
    test "exact legacy SQLite wire remains historically verified without rewriting stored proof",
         f do
      intent = F.intent!(f)
      old = DateTime.add(DateTime.utc_now(), -120)
      F.env(:arbor_security, :timestamp_max_drift_seconds, 300)
      proof = F.proof!(f.owner, :enqueue, intent, timestamp: old)
      assert {:ok, job} = Scheduler.enqueue_routine(intent, proof)
      Application.put_env(:arbor_security, :timestamp_max_drift_seconds, 60)
      legacy = legacy_wire(proof)
      row = Repo.get!(Oban.Job, job.id)
      args = put_in(row.args, ["owned_routine", "proof"], legacy)
      Repo.update!(Ecto.Changeset.change(row, args: args))

      assert :ok = Supervisor.terminate_child(f.repo_supervisor, Repo)
      assert {:ok, _} = Supervisor.restart_child(f.repo_supervisor, Repo)
      assert {:ok, %{items: [listed]}} = list(f)
      assert listed.id == job.id
      assert {:ok, %{items: []}} = list(f, f.other)

      assert :ok =
               Scheduler.cancel_owned_routine(job.id, F.proof!(f.owner, :cancel, job.id))

      row = Repo.get!(Oban.Job, job.id)
      assert row.state == "cancelled"
      assert row.args["owned_routine"]["proof"] == legacy
      assert File.read!(F.report(f, "morning-digest")) == "previous digest"
    end
  end

  defp list(f, owner \\ nil) do
    filters = %{"limit" => 20}
    Scheduler.list_owned_routines(filters, F.proof!(owner || f.owner, :list, filters))
  end

  # Hostile-storage fixtures are independent of the production wire encoder.
  defp wire(proof) do
    proof
    |> legacy_wire()
    |> Map.delete("payload")
    |> Map.merge(%{"version" => 2, "payload_base64" => Base.encode64(proof.payload)})
  end

  defp legacy_wire(proof) do
    %{
      "payload" => proof.payload,
      "agent_id" => proof.agent_id,
      "timestamp" => DateTime.to_iso8601(proof.timestamp),
      "nonce" => Base.encode64(proof.nonce),
      "signature" => Base.encode64(proof.signature)
    }
  end

  defp corrupt(wire, :unknown_version, _), do: Map.put(wire, "version", 3)
  defp corrupt(wire, :string_version, _), do: Map.put(wire, "version", "2")
  defp corrupt(wire, :missing_version, _), do: Map.delete(wire, "version")
  defp corrupt(wire, :mixed_payload, _), do: Map.put(wire, "payload", "ambiguous")
  defp corrupt(wire, :extra_field, _), do: Map.put(wire, "trusted", true)
  defp corrupt(wire, :wrong_encoding_type, _), do: Map.put(wire, "payload_base64", %{})
  defp corrupt(wire, :invalid_base64, _), do: Map.put(wire, "payload_base64", "!")
  defp corrupt(wire, :unpadded_base64, _), do: Map.put(wire, "payload_base64", "YQ")

  defp corrupt(wire, :oversized_encoding, _),
    do: Map.put(wire, "payload_base64", String.duplicate("A", 87_385))

  defp corrupt(wire, :oversized_decoding, _),
    do: Map.put(wire, "payload_base64", Base.encode64(String.duplicate("a", 65_537)))

  defp corrupt(wire, :changed_payload, _),
    do: Map.put(wire, "payload_base64", Base.encode64("other signed operation"))

  defp corrupt(wire, :changed_signature, _),
    do: Map.put(wire, "signature", Base.encode64(:binary.copy(<<0>>, 64)))

  defp corrupt(wire, :changed_owner, f),
    do: Map.put(wire, "agent_id", f.other.identity.agent_id)
end
