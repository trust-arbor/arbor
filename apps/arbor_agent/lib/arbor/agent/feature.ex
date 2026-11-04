defmodule Arbor.Agent.Feature do
  @moduledoc """
  Passive description of the Agent Application's direct startup contributions.

  `children/1` accepts an owner-resolved snapshot, never a proposed child plan.
  The disabled snapshot is exactly `%{start_children: false}`. The enabled
  snapshot supplies `start_children: true`, `profile_backend`,
  `user_config_backend`, `recovery_backend`, `recovery_durability`,
  `reconciliation_backend`, `reconciliation_durability` and the existing
  `system_lifecycle_token` reference. The two durability facts must each be
  `:node_restart`; this module does not collect or attest either fact. Separate
  backend reads remain separate inputs. A reference supplied here is data for
  trusted local comparison, not proof of authority or a public reporting input.

  Missing or unsupported facts are unresolved by the reporting host. Direct
  malformed calls raise a fixed redacted error. Complete child maps are private:
  reports must drop every start value and all private options and references.

  `requires/0` names the fixed host prerequisite, not an optional Shared-layer
  classification or complete Mix dependency closure. Empty action/URI lists
  declare no additional DIRECT Application-entrypoint global catalog/provider
  contribution here. They do not establish global absence of actions or URIs.
  Optional routes, graphs and commands are undeclared.

  Startup remains unchanged. Even disabled startup registers the identity alias
  resolver and creates its lifecycle reference; successful startup also schedules
  migration and template warmup. Describing no children performs or observes none
  of those separate effects. Health is unobserved.
  """

  @behaviour Arbor.Contracts.Feature

  @invalid_snapshot "invalid or incomplete agent feature snapshot"

  @impl true
  def id, do: :agent

  @impl true
  def requires, do: [:core]

  @impl true
  def action_modules, do: []

  @impl true
  def uri_prefixes, do: []

  @impl true
  def health, do: %{status: :unobserved}

  @impl true
  def children(%{start_children: false} = snapshot) when map_size(snapshot) == 1, do: []

  def children(
        %{
          start_children: true,
          profile_backend: profile_backend,
          user_config_backend: user_config_backend,
          recovery_backend: recovery_backend,
          recovery_durability: :node_restart,
          reconciliation_backend: reconciliation_backend,
          reconciliation_durability: :node_restart,
          system_lifecycle_token: lifecycle_token
        } = snapshot
      )
      when map_size(snapshot) == 8 and is_atom(profile_backend) and
             is_atom(user_config_backend) and is_atom(recovery_backend) and
             not is_nil(recovery_backend) and is_atom(reconciliation_backend) and
             not is_nil(reconciliation_backend) and is_reference(lifecycle_token) do
    profile_ack_mode = if is_nil(profile_backend), do: :cache, else: :backend

    [
      %{id: :arbor_agents_pg, start: {:pg, :start_link, [:arbor_agents]}},
      registry(Arbor.Agent.ExecutorRegistry),
      registry(Arbor.Agent.ReasoningLoopRegistry),
      registry(Arbor.Agent.MonitorLoopRegistry),
      registry(Arbor.Agent.ActionCycleRegistry),
      registry(Arbor.Agent.MaintenanceRegistry),
      registry(Arbor.Agent.RuntimeAdmissionRegistry),
      supervisor(Arbor.Agent.RuntimeAdmission.Supervisor),
      store(:arbor_agent_profiles,
        name: :arbor_agent_profiles,
        backend: profile_backend,
        backend_opts: [repo: Arbor.Persistence.Repo],
        write_mode: :sync,
        ack_mode: profile_ack_mode,
        collection: "agent_profiles"
      ),
      worker(Arbor.Agent.ProfileAuthorityOwner),
      store(:arbor_user_config,
        name: :arbor_user_config,
        backend: user_config_backend,
        backend_opts: [repo: Arbor.Persistence.Repo],
        write_mode: :sync,
        collection: "user_config"
      ),
      worker(Arbor.Agent.Registry),
      worker(Arbor.Agent.SummaryCache),
      worker(Arbor.Agent.Fitness),
      worker(Arbor.Agent.SessionManager),
      %{
        id: Arbor.Agent.Orchestration.TaskSupervisor,
        start: {Task.Supervisor, :start_link, [[name: Arbor.Agent.Orchestration.TaskSupervisor]]},
        type: :supervisor
      },
      store(:arbor_agent_task_control_recovery,
        name: :arbor_agent_task_control_recovery,
        backend: recovery_backend,
        backend_opts: [repo: Arbor.Persistence.Repo],
        write_mode: :sync,
        ack_mode: :backend,
        collection: "task_control_recovery"
      ),
      store(:arbor_agent_template_authority_reconciliation,
        name: :arbor_agent_template_authority_reconciliation,
        backend: reconciliation_backend,
        backend_opts: [repo: Arbor.Persistence.Repo],
        write_mode: :sync,
        ack_mode: :backend,
        collection: "template_authority_reconciliation"
      ),
      worker(Arbor.Agent.Orchestration.TaskStore),
      worker(Arbor.Agent.Orchestration.LeaseGrantOwner),
      supervisor(Arbor.Agent.ActionCycleSupervisor),
      supervisor(Arbor.Agent.MaintenanceSupervisor),
      supervisor(Arbor.Agent.Supervisor),
      supervisor(Arbor.Agent.UserSupervisor),
      worker(Arbor.Agent.SystemLifecycleAuthority, system_lifecycle_token: lifecycle_token),
      worker(Arbor.Agent.Bootstrap, system_lifecycle_token: lifecycle_token),
      worker(Arbor.Agent.Reconciler, system_lifecycle_token: lifecycle_token)
    ]
  end

  def children(_snapshot), do: raise(ArgumentError, @invalid_snapshot)

  defp registry(name) do
    %{
      id: name,
      start: {Registry, :start_link, [[keys: :unique, name: name]]},
      type: :supervisor
    }
  end

  defp worker(module, opts \\ []) do
    %{id: module, start: {module, :start_link, [opts]}}
  end

  defp supervisor(module) do
    %{id: module, start: {module, :start_link, [[]]}, type: :supervisor}
  end

  defp store(id, opts) do
    %{id: id, start: {Arbor.Persistence.BufferedStore, :start_link, [opts]}}
  end
end
