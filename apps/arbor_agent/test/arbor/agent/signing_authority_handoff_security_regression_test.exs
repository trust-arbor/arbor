defmodule Arbor.Agent.SigningAuthorityHandoffSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "SSEC-002,SSEC-013"

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Agent.Orchestration.TaskStore
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security

  setup do
    {:ok, identity} = Identity.generate(name: "handoff security regression")
    :ok = Security.register_identity_fixture(identity)
    :ok = Security.store_signing_key_fixture(identity.agent_id, identity.private_key)

    on_exit(fn ->
      _ = Security.delete_signing_key_fixture(identity.agent_id)
      _ = Security.deregister_identity_fixture(identity.agent_id)
    end)

    %{principal: identity.agent_id}
  end

  @tag spec: "SSEC-002,SSEC-013"
  test "security regression: ambient callers cannot obtain or transfer an agent signing authority",
       %{principal: principal} do
    context = handoff_context(:run)
    claimant = spawn(fn -> receive do: (:stop -> :ok) end)

    assert {:error, :signing_authority_handoff_required} =
             Arbor.Agent.issue_signing_authority_bootstrap(
               principal,
               :coding_task_executor
             )

    assert {:error, :signing_authority_handoff_required} =
             Arbor.Agent.issue_signing_authority_bootstrap(principal, :action_cycle)

    assert {:error, :signing_authority_handoff_unauthorized} =
             Arbor.Agent.transfer_signing_authority_handoff(
               principal,
               :coding_task_executor,
               claimant,
               context
             )

    Process.exit(claimant, :kill)
  end

  test "security regression: exact run and recovery claimants consume their handoff once",
       %{principal: principal} do
    for {purpose, operation} <- [
          {:coding_task_executor, :run},
          {:coding_task_recovery, :recover}
        ] do
      context = handoff_context(operation)
      parent = self()

      claimant =
        spawn(fn ->
          receive do
            :claim ->
              first = Arbor.Agent.issue_signing_authority_bootstrap(principal, purpose)
              second = Arbor.Agent.issue_signing_authority_bootstrap(principal, purpose)
              opened = open_and_close(first)
              send(parent, {:claim_result, purpose, first, second, opened})
          end
        end)

      assert :ok =
               TaskStore.authorize_signing_authority_handoff_fixture(
                 principal,
                 purpose,
                 claimant,
                 context
               )

      send(claimant, :claim)

      assert_receive {:claim_result, ^purpose, {:ok, _bootstrap},
                      {:error, :signing_authority_handoff_required}, :ok},
                     5_000
    end
  end

  test "security regression: operator handoff reaches only the exact two-hop verifier guard",
       %{principal: principal} do
    context = handoff_context(:operator_candidate_verification)
    parent = self()

    launcher =
      spawn(fn ->
        receive do
          :transfer ->
            worker =
              spawn(fn ->
                receive do
                  :transfer ->
                    guard =
                      spawn(fn ->
                        receive do
                          :claim ->
                            first =
                              Arbor.Agent.issue_signing_authority_bootstrap(
                                principal,
                                :coding_candidate_operator
                              )

                            second =
                              Arbor.Agent.issue_signing_authority_bootstrap(
                                principal,
                                :coding_candidate_operator
                              )

                            opened = open_and_close(first)
                            send(parent, {:operator_claim, first, second, opened})
                        end
                      end)

                    send(
                      parent,
                      {:guard_transfer,
                       Arbor.Agent.transfer_signing_authority_handoff(
                         principal,
                         :coding_candidate_operator,
                         guard,
                         context
                       )}
                    )

                    send(guard, :claim)
                end
              end)

            send(
              parent,
              {:worker_transfer,
               Arbor.Agent.transfer_signing_authority_handoff(
                 principal,
                 :coding_candidate_operator,
                 worker,
                 context
               )}
            )

            send(worker, :transfer)
        end
      end)

    assert :ok =
             TaskStore.authorize_signing_authority_handoff_fixture(
               principal,
               :coding_candidate_operator,
               launcher,
               context
             )

    send(launcher, :transfer)
    assert_receive {:worker_transfer, :ok}, 5_000
    assert_receive {:guard_transfer, :ok}, 5_000

    assert_receive {:operator_claim, {:ok, _bootstrap},
                    {:error, :signing_authority_handoff_required}, :ok},
                   5_000
  end

  defp handoff_context(operation) do
    %{
      operation: operation,
      task_id: "task_handoff_regression",
      control_principal_id: "human_handoff_regression",
      task_digest: String.duplicate("a", 64)
    }
  end

  defp open_and_close({:ok, bootstrap}) do
    with {:ok, authority} <- Security.claim_signing_authority(bootstrap),
         :ok <- Security.close_signing_authority(authority),
         :ok <- Security.close_signing_authority_bootstrap(bootstrap) do
      :ok
    end
  end

  defp open_and_close(error), do: error
end
