Code.require_file("../../support/private_snapshot_fixture.ex", __DIR__)

defmodule Arbor.Memory.PrivateRelationshipSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.TaintEnvelope
  alias Arbor.Memory
  alias Arbor.Memory.MemoryStore
  alias Arbor.Memory.Test.PrivateSnapshotFixture, as: Fixture
  alias Arbor.Security

  @moduletag :integration
  @moduletag :security_regression

  setup do
    for {app, key, value} <- [
          {:arbor_security, :identity_verification, true},
          {:arbor_security, :policy_enforcer_enabled, false},
          {:arbor_security, :approval_guard_enabled, false},
          {:arbor_security, :reflex_checking_enabled, false},
          {:arbor_security, :uri_registry_enforcement, false},
          {:arbor_trust, :policy_enforcer_enabled, false},
          {:arbor_trust, :approval_guard_enabled, false},
          {:arbor_memory, :private_memory_security, Security}
        ] do
      previous = Application.fetch_env(app, key)
      Application.put_env(app, key, value)
      on_exit(fn -> restore_env(app, key, previous) end)
    end

    %{fixture: Fixture.start!(), owner: Fixture.owner!()}
  end

  test "real root declaration and correction survive cold owners and remain pair scoped", ctx do
    first = Fixture.admission!(ctx.owner)
    assert {:ok, %{fence: :not_found, relationship: %{}}} = Memory.get_private_relationship(first)
    original = source!(first, "Remember my current focus: observatory calibration")
    assert {:ok, :saved} = Memory.apply_private_relationship_source(first, original, :not_found)

    assert {:ok, :unchanged} =
             Memory.apply_private_relationship_source(first, original, :not_found)

    assert :ok = Security.close_private_memory_admission(first)

    second = Fixture.admission!(ctx.owner, engagement_id: "new-engagement")

    assert {:ok, %{fence: before, relationship: %{"current_focus" => "observatory calibration"}}} =
             Memory.get_private_relationship(second)

    correction = source!(second, "Correction: my current focus is: telescope alignment")
    assert {:ok, :saved} = Memory.apply_private_relationship_source(second, correction, before)
    assert :ok = Security.close_private_memory_admission(second)
    assert :ok = Fixture.restart_store!(ctx.fixture)
    assert :ok = Fixture.restart_root!(ctx.fixture)

    third = Fixture.admission!(ctx.owner, session_id: "later-session")

    assert {:ok, %{fence: after_record, relationship: projection}} =
             Memory.get_private_relationship(third)

    assert projection == %{
             "current_focus" => "telescope alignment",
             "source_kind" => "user_corrected"
           }

    assert after_record.data["snapshot_revision"] == 2
    assert after_record.data["last_operation"] == "correct"
    assert after_record.data["source_proof"] == Map.take(correction, ["descriptor", "stamp"])
    assert after_record.data["scope"]["engagement_id"] == "new-engagement"

    for other <- [Fixture.owner!(ctx.owner.agent), Fixture.owner!(nil, ctx.owner.human)] do
      assert {:ok, %{relationship: %{}, fence: :not_found}} =
               Memory.get_private_relationship(Fixture.admission!(other))
    end
  end

  test "historical sources and stale observed fences cannot overwrite a newer focus", ctx do
    first = Fixture.admission!(ctx.owner)
    old = source!(first, "Remember my current focus: initial focus")
    assert {:ok, :saved} = Memory.apply_private_relationship_source(first, old, :not_found)
    assert {:ok, %{fence: before}} = Memory.get_private_relationship(first)

    second = Fixture.admission!(ctx.owner)
    newer = source!(second, "Correction: my current focus is: newer focus")
    assert {:ok, :saved} = Memory.apply_private_relationship_source(second, newer, before)

    assert {:error, :private_relationship_source_not_current} =
             Memory.apply_private_relationship_source(second, old, before)

    late = source!(first, "Correction: my current focus is: late stale focus")

    assert {:error, :private_relationship_conflict} =
             Memory.apply_private_relationship_source(first, late, before)

    assert {:ok, %{relationship: %{"current_focus" => "newer focus"}}} =
             Memory.get_private_relationship(second)
  end

  test "declaration cannot silently replace a focus and correction requires an existing declaration",
       ctx do
    admission = Fixture.admission!(ctx.owner)
    correction = source!(admission, "Correction: my current focus is: unestablished")

    assert {:error, :private_relationship_missing} =
             Memory.apply_private_relationship_source(admission, correction, :not_found)

    original = source!(admission, "Remember my current focus: original")

    assert {:ok, :saved} =
             Memory.apply_private_relationship_source(admission, original, :not_found)

    assert {:ok, %{fence: before}} = Memory.get_private_relationship(admission)

    fresh = Fixture.admission!(ctx.owner)
    replacement = source!(fresh, "Remember my current focus: replacement")

    assert {:error, :private_relationship_correction_required} =
             Memory.apply_private_relationship_source(fresh, replacement, before)

    ignored = source!(fresh, "They said, Remember my current focus: someone else's focus")

    assert {:ok, :not_requested} =
             Memory.apply_private_relationship_source(fresh, ignored, before)

    assert {:ok, %{fence: ^before}} = Memory.get_private_relationship(fresh)
  end

  test "source content tamper, forged admission and copied live handles confer no authority",
       ctx do
    admission = Fixture.admission!(ctx.owner)
    source = source!(admission, "Remember my current focus: authentic focus")

    assert {:error, _} =
             Memory.apply_private_relationship_source(
               admission,
               Map.put(source, "user_content", "Remember my current focus: forged"),
               :not_found
             )

    fake = %{agent_id: ctx.owner.agent.agent_id, human_id: ctx.owner.human.agent_id}
    assert {:error, _} = Memory.get_private_relationship(fake)
    assert {:error, _} = Memory.apply_private_relationship_source(fake, source, :not_found)

    copied =
      Task.async(fn ->
        Memory.apply_private_relationship_source(admission, source, :not_found)
      end)

    assert {:error, _} = Task.await(copied)
    assert {:ok, %{fence: :not_found}} = Memory.get_private_relationship(admission)

    assert :ok = Security.revoke(ctx.owner.write_cap.id)
    assert {:error, _} = Memory.apply_private_relationship_source(admission, source, :not_found)
  end

  test "rehashed durable body and cross-owner record transplants are rejected on cold reads",
       ctx do
    admission = Fixture.admission!(ctx.owner)
    source = source!(admission, "Remember my current focus: sealed focus")
    assert {:ok, :saved} = Memory.apply_private_relationship_source(admission, source, :not_found)
    assert {:ok, %{fence: record}} = Memory.get_private_relationship(admission)
    key = String.replace_prefix(record.key, "private_relationships:", "")
    forged = Map.put(record.data, "current_focus", "forged focus")

    # Fixture-only hostile persistence write recomputes the unkeyed taint digest.
    assert {:ok, _} =
             MemoryStore.compare_and_swap_tainted("private_relationships", key, record, forged,
               taint: TaintEnvelope.missing_fallback()
             )

    assert :ok = Fixture.restart_store!(ctx.fixture)

    assert {:error, :invalid_private_relationship_snapshot} =
             Memory.get_private_relationship(admission)

    other = Fixture.owner!(ctx.owner.agent)
    other_admission = Fixture.admission!(other)
    assert {:ok, other_scope} = Security.authorize_private_memory_turn(other_admission, :read)

    assert {:ok, bytes} =
             TaintEnvelope.canonical_json([other_scope.agent_id, other_scope.human_id])

    other_key = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    assert {:ok, _} =
             MemoryStore.compare_and_swap_tainted(
               "private_relationships",
               other_key,
               :not_found,
               record.data,
               taint: TaintEnvelope.missing_fallback()
             )

    assert {:error, :invalid_private_relationship_snapshot} =
             Memory.get_private_relationship(other_admission)
  end

  test "delete and reinsert seals a fresh logical snapshot despite a new physical incarnation",
       ctx do
    admission = Fixture.admission!(ctx.owner)
    source = source!(admission, "Remember my current focus: first incarnation")
    assert {:ok, :saved} = Memory.apply_private_relationship_source(admission, source, :not_found)
    assert {:ok, %{fence: before}} = Memory.get_private_relationship(admission)

    assert :ok =
             Arbor.Persistence.buffered_store_acknowledged_compare_and_delete(
               :arbor_memory_durable,
               before.key,
               before
             )

    assert :ok = Fixture.restart_store!(ctx.fixture)

    fresh = Fixture.admission!(ctx.owner)
    source = source!(fresh, "Remember my current focus: recreated focus")
    assert {:ok, :saved} = Memory.apply_private_relationship_source(fresh, source, :not_found)
    assert :ok = Fixture.restart_store!(ctx.fixture)

    assert {:ok, %{fence: after_record, relationship: %{"current_focus" => "recreated focus"}}} =
             Memory.get_private_relationship(fresh)

    assert after_record.generation > before.generation
    assert after_record.data["snapshot_revision"] == 1
  end

  defp source!(admission, user) do
    assert {:ok, source} =
             Memory.prepare_private_conversation_source(admission, %{
               user: user,
               assistant: "Acknowledged."
             })

    source
  end

  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env(app, key, :error), do: Application.delete_env(app, key)
end
