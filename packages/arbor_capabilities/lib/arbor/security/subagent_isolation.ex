defmodule Arbor.Security.SubagentIsolation do
  @moduledoc """
  Creates task-scoped, attenuated capability sets for worker subagents.

  The main agent (high trust, broad capabilities) delegates a narrow subset
  of its capabilities to a worker subagent for a specific task. The worker
  gets exactly the permissions it needs, no more:

  - **Task-bound**: Capabilities die when the task ends (`task_id` binding)
  - **Usage-limited**: Each cap can only be used `max_uses` times (default: 1)
  - **Non-delegatable**: Worker can't re-delegate (`delegation_depth: 0`)
  - **Time-limited**: Optional expiration for the task window

  ## Usage

      {:ok, isolation} = SubagentIsolation.create_isolation(
        parent_id: "agent_main",
        worker_id: "agent_worker_abc",
        resource_uris: ["arbor://fs/read/src", "arbor://shell/exec/test"],
        max_uses: 1,
        expires_in: 300
      )

      # Worker agent uses its delegated capabilities normally via authorize/4
      # When the task completes:
      {:ok, count} = SubagentIsolation.cleanup(isolation.task_id)

  ## Security Properties

  1. **Attenuation only**: Worker caps are strictly weaker than parent caps
  2. **Blast radius**: Worker can only access explicitly listed resources
  3. **Clean lifecycle**: `cleanup/1` revokes all task-scoped caps
  4. **Audit trail**: Each cap use generates a signed receipt (if enabled)
  """

  require Logger

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security
  alias Arbor.Security.CapabilityStore

  @type isolation :: %{
          task_id: String.t(),
          parent_id: String.t(),
          worker_id: String.t(),
          capabilities: [Capability.t()],
          created_at: DateTime.t()
        }

  @doc """
  Create an isolation context with task-scoped capabilities for a worker.

  Finds the parent's capabilities for each requested resource URI and
  delegates them to the worker with task binding, usage limits, and depth 0.

  ## Options

  - `:parent_id` (required) - Agent ID of the parent/delegator
  - `:worker_id` (required) - Agent ID of the worker receiving capabilities
  - `:resource_uris` (required) - List of resource URIs the worker needs
  - `:task_id` - Custom task ID (auto-generated if not provided)
  - `:session_id` - Session to bind capabilities to
  - `:max_uses` - Max uses per capability (default: 1, single-use)
  - `:expires_in` - Seconds until capabilities expire (default: nil, no expiry)
  - `:constraints` - Additional constraints for all delegated caps

  Returns `{:ok, isolation}` with the task_id and delegated capabilities,
  or `{:error, :no_capabilities_delegated}` if none could be delegated.
  """
  @spec create_isolation(keyword()) :: {:ok, isolation()} | {:error, term()}
  def create_isolation(opts) do
    with true <- Keyword.keyword?(opts),
         actor_authority when not is_nil(actor_authority) <-
           Keyword.get(opts, :actor_authority) do
      parent_id = Keyword.fetch!(opts, :parent_id)
      worker_id = Keyword.fetch!(opts, :worker_id)
      resource_uris = Keyword.fetch!(opts, :resource_uris)
      task_id = Keyword.get(opts, :task_id, generate_task_id())
      session_id = opts[:session_id]
      max_uses = Keyword.get(opts, :max_uses, 1)
      expires_in = opts[:expires_in]
      constraints = Keyword.get(opts, :constraints, %{})

      expires_at =
        if expires_in,
          do: DateTime.utc_now() |> DateTime.add(expires_in, :second),
          else: nil

      delegated =
        Enum.reduce(resource_uris, [], fn uri, acc ->
          case delegate_for_task(
                 parent_id,
                 worker_id,
                 uri,
                 task_id,
                 session_id,
                 max_uses,
                 expires_at,
                 constraints,
                 actor_authority
               ) do
            {:ok, cap} ->
              [cap | acc]

            {:error, reason} ->
              Logger.warning(
                "[SubagentIsolation] Could not delegate #{uri} from #{parent_id}: #{inspect(reason)}"
              )

              acc
          end
        end)

      if delegated == [] do
        {:error, :no_capabilities_delegated}
      else
        isolation = %{
          task_id: task_id,
          parent_id: parent_id,
          worker_id: worker_id,
          capabilities: Enum.reverse(delegated),
          created_at: DateTime.utc_now()
        }

        {:ok, isolation}
      end
    else
      _ -> {:error, :capability_mutation_unauthorized}
    end
  end

  @doc """
  Clean up all capabilities bound to a task.

  Call this when the worker task completes (success or failure).
  Revokes all capabilities with the given task_id.
  """
  @spec cleanup(String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup(task_id, opts \\ []) do
    with true <- Keyword.keyword?(opts),
         actor_authority when not is_nil(actor_authority) <-
           Keyword.get(opts, :actor_authority) do
      Security.revoke_by_task(task_id, actor_authority: actor_authority)
    else
      _ -> {:error, :capability_mutation_unauthorized}
    end
  end

  # Private

  defp delegate_for_task(
         parent_id,
         worker_id,
         resource_uri,
         task_id,
         session_id,
         max_uses,
         expires_at,
         constraints,
         actor_authority
       ) do
    case CapabilityStore.find_authorizing(parent_id, resource_uri) do
      {:ok, parent_cap} ->
        Security.delegate(parent_cap.id, worker_id,
          actor_authority: actor_authority,
          task_id: task_id,
          session_id: session_id,
          max_uses: max_uses,
          delegation_depth: 0,
          expires_at: expires_at,
          constraints: constraints
        )

      {:error, :not_found} ->
        {:error, {:parent_lacks_capability, resource_uri}}
    end
  end

  defp generate_task_id do
    "task_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
  end
end
