defmodule Arbor.Contracts.Autonomous.Installer do
  @moduledoc """
  Contract for the InstallerAgent - the single privileged agent for installation operations.

  The InstallerAgent is the only entity authorized to perform dangerous operations like
  hot-reload, restart, and code installation. It operates in the Privileged Zone and
  requires Council approval for ALL installations.

  ## Security Architecture

  ```
  ┌─────────────────────────────────────────────────────────────────┐
  │ PRIVILEGED ZONE (single trusted installer)                      │
  │                                                                 │
  │ InstallerAgent [:veteran]                                       │
  │   - READ: 5-completed/* (verified work only)                    │
  │   - PROPOSE: Changes to Council                                 │
  │   - EXECUTE: Hot-reload approved changes                        │
  │   - EXECUTE: Restart server if needed                           │
  │   - ROLLBACK: Revert on failure                                 │
  │                                                                 │
  │ Requirements:                                                   │
  │   - Council approval required for ALL installations             │
  │   - Automatic rollback on test failure                          │
  │   - All actions fully logged and auditable                      │
  │   - Single point of control for dangerous operations            │
  │                                                                 │
  └─────────────────────────────────────────────────────────────────┘
  ```

  ## Workflow

  ```
  5-completed/ → InstallerAgent reads verified work
        ↓
  InstallerAgent proposes to Council
        ↓
  Council approves/rejects
        ↓
  If approved: Execute installation
        ↓
  Run verification (tests, health checks)
        ↓
  If pass: Move to 7-installed/, award trust points
  If fail: Rollback, deduct trust points
  ```

  ## Installation Types

  - `:hot_reload` - Recompile and reload modules without restart
  - `:application_restart` - Restart specific application
  - `:full_restart` - Full server restart (requires human notification)
  - `:config_update` - Update runtime configuration
  - `:file_install` - Install files to filesystem
  """

  @type installation_id :: String.t()
  @type agent_id :: String.t()
  @type item_path :: String.t()

  @type installation_type ::
          :hot_reload
          | :application_restart
          | :full_restart
          | :config_update
          | :file_install

  @type installation_status ::
          :pending
          | :approved
          | :installing
          | :verifying
          | :installed
          | :rolled_back
          | :failed

  @type installation_request :: %{
          id: installation_id(),
          item_path: item_path(),
          proposer: agent_id(),
          installation_type: installation_type(),
          files_changed: [String.t()],
          modules_affected: [module()],
          description: String.t(),
          test_command: String.t() | nil,
          rollback_steps: [String.t()],
          metadata: map(),
          requested_at: DateTime.t()
        }

  @type installation_result :: %{
          id: installation_id(),
          status: installation_status(),
          council_decision: :approved | :rejected | nil,
          council_decision_id: String.t() | nil,
          installation_started_at: DateTime.t() | nil,
          installation_completed_at: DateTime.t() | nil,
          verification_passed: boolean() | nil,
          verification_details: map(),
          rollback_executed: boolean(),
          rollback_reason: String.t() | nil,
          trust_points_delta: integer(),
          error: term() | nil
        }

  @type rollback_result :: %{
          success: boolean(),
          steps_executed: [String.t()],
          error: term() | nil
        }

  # Callbacks

  @doc """
  Request installation of a completed work item.

  Creates an installation request and submits it to the Council for approval.
  Returns immediately with the installation ID - actual installation happens
  after Council approval.
  """
  @callback request_installation(installation_request()) ::
              {:ok, installation_id()} | {:error, term()}

  @doc """
  Get the status of an installation request.
  """
  @callback get_installation_status(installation_id()) ::
              {:ok, installation_result()} | {:error, :not_found}

  @doc """
  Execute an approved installation.

  Called by the InstallerAgent after Council approval.
  Performs the actual installation, verification, and handles rollback on failure.
  """
  @callback execute_installation(installation_id()) ::
              {:ok, installation_result()} | {:error, term()}

  @doc """
  Execute rollback for a failed installation.

  Reverts changes made during installation attempt.
  """
  @callback execute_rollback(installation_id()) :: {:ok, rollback_result()} | {:error, term()}

  @doc """
  Verify an installation succeeded.

  Runs tests and health checks after installation.
  """
  @callback verify_installation(installation_id()) :: {:ok, map()} | {:error, term()}

  @doc """
  List pending installation requests.
  """
  @callback list_pending() :: {:ok, [installation_request()]}

  @doc """
  List recent installations (installed or rolled back).
  """
  @callback list_recent(keyword()) :: {:ok, [installation_result()]}

  @doc """
  Cancel a pending installation request.

  Only works if the request hasn't been approved yet.
  """
  @callback cancel_request(installation_id()) :: :ok | {:error, term()}

  # Helper functions

  @doc """
  Determine installation type based on files changed.
  """
  @spec determine_installation_type([String.t()]) :: installation_type()
  def determine_installation_type(files_changed) do
    cond do
      Enum.any?(files_changed, &config_file?/1) -> :config_update
      Enum.any?(files_changed, &requires_restart?/1) -> :application_restart
      Enum.any?(files_changed, &elixir_module?/1) -> :hot_reload
      true -> :file_install
    end
  end

  @doc """
  Get modules affected by changed files.
  """
  @spec modules_for_files([String.t()]) :: [module()]
  def modules_for_files(files) do
    files
    |> Enum.filter(&elixir_module?/1)
    |> Enum.map(&file_to_module/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Generate rollback steps for an installation.
  """
  @spec generate_rollback_steps(installation_type(), [String.t()]) :: [String.t()]
  def generate_rollback_steps(:hot_reload, files) do
    modules = modules_for_files(files)

    [
      "git stash --include-untracked",
      "Recompile modules: #{inspect(modules)}",
      "git stash pop"
    ]
  end

  def generate_rollback_steps(:config_update, files) do
    [
      "Restore previous config files: #{inspect(files)}",
      "Application.put_env with previous values"
    ]
  end

  def generate_rollback_steps(:application_restart, _files) do
    [
      "Application.stop(:arbor_core)",
      "git checkout HEAD~1 -- .",
      "mix compile",
      "Application.start(:arbor_core)"
    ]
  end

  def generate_rollback_steps(:full_restart, _files) do
    [
      "git checkout HEAD~1 -- .",
      "mix compile",
      "Restart entire application"
    ]
  end

  def generate_rollback_steps(:file_install, files) do
    ["Remove installed files: #{inspect(files)}"]
  end

  @doc """
  Check if installation requires human notification.
  """
  @spec requires_human_notification?(installation_type()) :: boolean()
  def requires_human_notification?(:full_restart), do: true
  def requires_human_notification?(:application_restart), do: true
  def requires_human_notification?(_), do: false

  @doc """
  Calculate trust points delta for an installation result.
  """
  @spec calculate_trust_points(installation_result()) :: integer()
  def calculate_trust_points(%{status: :installed, verification_passed: true}) do
    # Successful installation with passing tests
    10
  end

  def calculate_trust_points(%{status: :rolled_back}) do
    # Installation required rollback
    -10
  end

  def calculate_trust_points(%{status: :failed}) do
    # Installation failed
    -5
  end

  def calculate_trust_points(_) do
    0
  end

  @doc """
  Default test command for a project.
  """
  @spec default_test_command() :: String.t()
  def default_test_command do
    "mix test"
  end

  @doc """
  All installation types.
  """
  @spec installation_types() :: [installation_type()]
  def installation_types do
    [:hot_reload, :application_restart, :full_restart, :config_update, :file_install]
  end

  @doc """
  All installation statuses.
  """
  @spec installation_statuses() :: [installation_status()]
  def installation_statuses do
    [:pending, :approved, :installing, :verifying, :installed, :rolled_back, :failed]
  end

  # Private helpers

  defp config_file?(path) do
    String.ends_with?(path, ["/config.exs", "/dev.exs", "/prod.exs", "/runtime.exs"])
  end

  defp requires_restart?(path) do
    # Files that typically require application restart
    String.ends_with?(path, ["/application.ex", "/supervisor.ex"]) or
      String.contains?(path, "/mix.exs")
  end

  defp elixir_module?(path) do
    String.ends_with?(path, ".ex") and not String.ends_with?(path, "_test.exs")
  end

  defp file_to_module(path) do
    # Extract module name from file path
    # e.g., "lib/arbor/core/gateway.ex" -> Arbor.Core.Gateway
    path
    |> String.replace(~r{^(apps/\w+/)?lib/}, "")
    |> String.replace(".ex", "")
    |> String.split("/")
    |> Enum.map_join(".", &Macro.camelize/1)
    |> String.to_atom()
  rescue
    _ -> nil
  end
end
