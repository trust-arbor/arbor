defmodule Arbor.Contracts.TenantContext do
  @moduledoc """
  Context struct that identifies the acting principal and their scope.

  TenantContext flows through the system to answer "on whose behalf is this
  operation being performed?" It is injected at the boundary (dashboard session,
  API request, CLI invocation) and propagated through facades, sessions, and
  signal emissions.

  ## Design Principles

  - **Nil means global**: When `tenant_context` is nil, the system behaves
    identically to single-user mode. No existing code needs to change.
  - **Capability-scoped**: The workspace root and capability scope are derived
    from capabilities, not hardcoded paths or database lookups.
  - **Immutable per request**: Created at the boundary, passed through, never
    mutated mid-flow.

  ## Usage

      # At the dashboard boundary (OIDC callback)
      ctx = TenantContext.new("human_abc123")

      # With workspace scoping
      ctx = TenantContext.new("human_abc123",
        workspace_root: "~/.arbor/workspace/human_abc123"
      )

      # Injected into session opts
      Session.start_link(agent_id: "agent_x", tenant_context: ctx)

      # Checking context
      TenantContext.principal_id(ctx)  # => "human_abc123"
      TenantContext.principal_id(nil)  # => nil (single-user mode)
  """

  use TypedStruct

  @derive Jason.Encoder
  typedstruct do
    @typedoc "Identifies the acting principal and their operational scope"

    # The human user's agent ID (e.g., "human_abc123")
    field(:principal_id, String.t(), enforce: true)

    # Filesystem root for this user's workspace (optional)
    field(:workspace_root, String.t())

    # Display name for UI purposes
    field(:display_name, String.t())

    # Additional context (e.g., OIDC claims, org membership)
    field(:metadata, map(), default: %{})
  end

  @doc """
  Create a new TenantContext for a principal.

  ## Options

  - `:workspace_root` - Filesystem root for user's workspace
  - `:display_name` - Human-readable name for dashboards
  - `:metadata` - Additional context (OIDC claims, etc.)
  """
  @spec new(String.t(), keyword()) :: t()
  def new(principal_id, opts \\ []) when is_binary(principal_id) do
    %__MODULE__{
      principal_id: principal_id,
      workspace_root: Keyword.get(opts, :workspace_root),
      display_name: Keyword.get(opts, :display_name),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Extract principal_id from a context, returning nil for nil context.

  This is the primary accessor — callers should use this instead of
  pattern matching, so nil context (single-user mode) is handled uniformly.
  """
  @spec principal_id(t() | nil) :: String.t() | nil
  def principal_id(nil), do: nil
  def principal_id(%__MODULE__{principal_id: id}), do: id

  @doc """
  Extract workspace_root from a context, returning nil for nil context.
  """
  @spec workspace_root(t() | nil) :: String.t() | nil
  def workspace_root(nil), do: nil
  def workspace_root(%__MODULE__{workspace_root: root}), do: root

  @doc """
  Convert context to a metadata map suitable for signal emission.

  Returns an empty map for nil context, so signal metadata merging
  works without special-casing.
  """
  @spec to_signal_metadata(t() | nil) :: map()
  def to_signal_metadata(nil), do: %{}

  def to_signal_metadata(%__MODULE__{} = ctx) do
    %{principal_id: ctx.principal_id}
  end
end
