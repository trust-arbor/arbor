defmodule Arbor.Contracts.Security.AuthContext do
  @moduledoc """
  Complete authorization context for a tool call or action.

  Assembled once at the start of an action execution by the owning
  authorization path, then passed through every layer.

  This module is a pure data constructor and transformer. Callers inject
  identity, capabilities, and trust fields; this module does not load them.
  The struct is not a complete authorization decision: the owning path still
  performs its ordinary store lookup even when capabilities are already
  present on the struct.

  ## Why

  Previously, auth data was scattered across opts, context maps, and function
  parameters. Each layer assembled what it needed from fragments — leading to
  `signed_request` being lost and identity being re-verified (causing
  deadlocks).

  ## Usage

      auth = AuthContext.new(agent_id, signer: signer)

      # Pass the struct to the authorization decision function.
  """

  alias Arbor.Contracts.Security.{Capability, Taint}

  @type trust_mode :: :block | :ask | :allow | :auto

  @type decision ::
          :authorized | {:requires_approval, Capability.t()} | :unauthorized | {:error, term()}

  @type t :: %__MODULE__{
          # Identity (who)
          principal_id: String.t(),
          identity_verified: boolean(),
          signed_request: term() | nil,
          signer: (String.t() -> {:ok, term()} | {:error, term()}) | nil,

          # Trust (how trusted)
          trust_baseline: trust_mode(),
          trust_rules: %{String.t() => trust_mode()},

          # Capabilities (what they can do)
          capabilities: [Capability.t()],

          # Taint (data sensitivity)
          taint_state: Taint.t() | nil,

          # Session context
          session_id: String.t() | nil,
          tenant_context: term(),

          # Audit trail
          decisions: [%{resource: String.t(), result: decision(), at: DateTime.t()}]
        }

  @enforce_keys [:principal_id]
  defstruct [
    :principal_id,
    :signed_request,
    :signer,
    :taint_state,
    :session_id,
    :tenant_context,
    identity_verified: false,
    trust_baseline: :ask,
    trust_rules: %{},
    capabilities: [],
    decisions: []
  ]

  @doc """
  Create a new AuthContext for an agent.

  Optional fields (`:capabilities`, `:trust_baseline`, `:trust_rules`, and
  the identity/session keys) are constructor data injected by the caller.
  """
  @spec new(String.t(), keyword()) :: t()
  def new(principal_id, opts \\ []) do
    %__MODULE__{
      principal_id: principal_id,
      signer: Keyword.get(opts, :signer),
      signed_request: Keyword.get(opts, :signed_request),
      session_id: Keyword.get(opts, :session_id),
      tenant_context: Keyword.get(opts, :tenant_context),
      taint_state: Keyword.get(opts, :taint_state),
      trust_baseline: Keyword.get(opts, :trust_baseline, :ask),
      trust_rules: Keyword.get(opts, :trust_rules, %{}),
      capabilities: Keyword.get(opts, :capabilities, [])
    }
  end

  @doc """
  Mark identity as verified. Called once after signed_request verification.
  Subsequent auth checks skip identity re-verification.
  """
  @spec mark_verified(t()) :: t()
  def mark_verified(%__MODULE__{} = ctx) do
    %{ctx | identity_verified: true}
  end

  @doc """
  Sign a request for a resource URI using the context's signer.
  Returns updated context with the signed_request set.
  """
  @spec sign(t(), String.t()) :: {:ok, t()} | {:error, term()}
  def sign(%__MODULE__{signer: nil} = ctx, _resource), do: {:ok, ctx}

  def sign(%__MODULE__{signer: signer} = ctx, resource) when is_function(signer, 1) do
    case signer.(resource) do
      {:ok, signed} -> {:ok, %{ctx | signed_request: signed}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Record an authorization decision in the audit trail.
  """
  @spec record_decision(t(), String.t(), decision()) :: t()
  def record_decision(%__MODULE__{} = ctx, resource, result) do
    entry = %{resource: resource, result: result, at: DateTime.utc_now()}
    %{ctx | decisions: [entry | ctx.decisions]}
  end
end
