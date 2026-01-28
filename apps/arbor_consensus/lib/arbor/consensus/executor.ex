defmodule Arbor.Consensus.Executor do
  @moduledoc """
  Behaviour for optional proposal execution after approval.

  The default (when no executor is configured) is a no-op — the
  consensus system renders decisions but does not execute them.
  Host apps provide concrete execution logic.

  ## Example Implementation

      defmodule MyApp.ChangeExecutor do
        @behaviour Arbor.Consensus.Executor

        @impl true
        def execute(proposal, decision) do
          case proposal.change_type do
            :code_modification ->
              apply_code_change(proposal)
            :configuration_change ->
              apply_config_change(proposal)
            _ ->
              {:ok, :no_action}
          end
        end
      end
  """

  alias Arbor.Contracts.Autonomous.{CouncilDecision, Proposal}

  @doc """
  Execute an approved proposal.

  Called only when a proposal is approved and `auto_execute_approved`
  is true in the config, or when explicitly triggered.
  """
  @callback execute(
              proposal :: Proposal.t(),
              decision :: CouncilDecision.t()
            ) :: {:ok, term()} | {:error, term()}
end
