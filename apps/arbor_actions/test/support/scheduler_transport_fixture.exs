defmodule Arbor.Actions.SchedulerTransportFixture do
  @moduledoc false

  alias Arbor.Actions
  alias Arbor.Actions.Scheduler.{CancelRoutine, EnqueueRoutine, ListRoutines}
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Security

  # This adapter stops at the Scheduler peer boundary. It uses the real public
  # payload codec and Security verifier; it does not claim to test Oban storage,
  # catalog admission, standing trust policy, or delayed execution authority.
  defmodule SchedulerPeer do
    alias Arbor.Scheduler
    alias Arbor.Security

    def prepare_routine_intent(principal, routine, at, id) do
      send(__MODULE__, {:routine_prepared, principal})

      {:ok,
       %{
         "version" => 1,
         "routine" => routine,
         "scheduled_at" => at,
         "request_id" => id,
         "manifest_digest" => String.duplicate("a", 64),
         "parents" => [
           %{
             "resource_uri" => "arbor://action/reports/build_morning_digest",
             "capability_id" => "cap_" <> String.duplicate("1", 32),
             "capability_digest" => String.duplicate("b", 64)
           }
         ]
       }}
    end

    defdelegate routine_request_payload(operation, value), to: Scheduler

    def enqueue_routine(value, proof), do: accept(:enqueue, value, proof)
    def list_owned_routines(value, proof), do: accept(:list, value, proof)

    def cancel_owned_routine(value, proof) do
      case accept(:cancel, value, proof) do
        {:ok, _} -> :ok
        error -> error
      end
    end

    def routine_effect_requirement(_principal), do: {:ok, true}

    def authorize_routine_effect(token, effect) do
      send(__MODULE__, {:routine_effect, token, effect})
      {:error, :test_effect_boundary_stop}
    end

    defp accept(operation, value, proof) do
      with {:ok, expected} <- Scheduler.routine_request_payload(operation, value),
           true <- proof.payload == expected,
           {:ok, principal} <- Security.verify_request(proof) do
        send(__MODULE__, {:routine_accepted, operation, value, proof, principal})
        {:ok, %{owner_id: principal, operation: Atom.to_string(operation)}}
      else
        _ -> {:error, :routine_authentication_failed}
      end
    end
  end

  def start! do
    :ok = Security.TestBootstrap.start!()
    {:ok, _} = Application.ensure_all_started(:arbor_trust)

    unless Process.whereis(Arbor.Trust.Store),
      do: ExUnit.Callbacks.start_supervised!(Arbor.Trust.Store)

    overrides = [
      {:arbor_actions, :scheduler_module, SchedulerPeer},
      {:arbor_security, :identity_verification, true},
      {:arbor_security, :capability_signing_required, true},
      {:arbor_security, :strict_identity_mode, false},
      {:arbor_security, :uri_registry_enforcement, false},
      {:arbor_security, :reflex_checking_enabled, false},
      {:arbor_security, :consensus_escalation_enabled, false},
      {:arbor_security, :approval_guard_enabled, false},
      {:arbor_trust, :approval_guard_enabled, false},
      {:arbor_trust, :policy_enforcer_enabled, false}
    ]

    previous =
      Enum.map(overrides, fn {app, key, _} -> {app, key, Application.fetch_env(app, key)} end)

    Enum.each(overrides, fn {app, key, value} -> Application.put_env(app, key, value) end)
    Process.register(self(), SchedulerPeer)

    ExUnit.Callbacks.on_exit(fn ->
      for {app, key, prior} <- previous do
        case prior do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end
    end)

    %{owner: identity!(), other: identity!()}
  end

  def identity! do
    {:ok, identity} = Security.generate_identity()
    :ok = Security.register_identity(identity)
    :ok = Security.store_signing_key(identity.agent_id, identity.private_key)

    caps =
      for module <- [
            EnqueueRoutine,
            ListRoutines,
            CancelRoutine,
            Actions.Reports.BuildMorningDigest
          ] do
        {:ok, cap} =
          Security.grant(
            principal: identity.agent_id,
            resource: Actions.canonical_uri_for(module, %{})
          )

        cap
      end

    {:ok, proof} =
      Security.build_signing_authority_acquisition_proof(
        identity.agent_id,
        identity.private_key,
        purpose: :scheduler_transport_test,
        owner: self()
      )

    {:ok, authority} = Security.open_signing_authority(proof)

    ExUnit.Callbacks.on_exit(fn ->
      Security.close_signing_authority(authority)
      for cap <- caps, do: Security.revoke(cap.id)
      Security.delete_signing_key(identity.agent_id)
      Security.deregister_identity(identity.agent_id)
    end)

    %{identity: identity, authority: authority}
  end

  def params(:enqueue),
    do: %{
      routine: "morning_digest",
      scheduled_at: "2026-09-10T12:00:00Z",
      request_id: "transport_request_0001"
    }

  def params(:list), do: %{limit: 7, before_id: 91}
  def params(:cancel), do: %{job_id: 73}

  def request!(owner, module, params) do
    {:ok, request} = Actions.prepare_routine_request(module, params, owner.identity.agent_id)

    {:ok, proof} =
      SignedRequest.sign(request.payload, owner.identity.agent_id, owner.identity.private_key)

    %{operation: request.operation, value: request.value, proof: proof}
  end

  def context!(owner, module, params, additions \\ %{}) do
    {:ok, signed} =
      SignedRequest.sign(
        Actions.canonical_uri_for(module, params),
        owner.identity.agent_id,
        owner.identity.private_key
      )

    Map.merge(%{signed_request: signed, taint: :trusted}, additions)
  end
end
