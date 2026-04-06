defmodule Arbor.Contracts.Security.AuthContext do
  @moduledoc """
  Complete authorization context for a tool call or action.

  Assembled once at the start of an action execution, passed through every
  layer (action → facade → security). Contains everything needed to make
  authorization decisions without re-querying ETS or re-verifying identity.

  ## Why

  Previously, auth data was scattered across opts, context maps, and function
  parameters. Each layer assembled what it needed from fragments — leading to
  `signed_request` being lost, identity being re-verified (causing deadlocks),
  and capabilities being re-queried unnecessarily.

  ## Usage

      # Construct once at action entry point
      auth = AuthContext.new(agent_id, signer)

      # Evaluate authorization (pure function)
      case AuthDecision.evaluate(auth, "arbor://fs/list", :execute) do
        :authorized → proceed
        {:requires_approval, cap} → escalate
        :unauthorized → deny
      end

      # Pass to facade for sub-operation auth (identity already verified)
      case AuthDecision.evaluate(auth, "arbor://fs/read", :execute) do
        :authorized → proceed  # no re-verification, just capability check
      end
  """

  alias Arbor.Contracts.Security.{Capability, Taint}

  @type trust_tier :: :untrusted | :probationary | :established | :trusted | :veteran | :autonomous
  @type trust_mode :: :block | :ask | :allow | :auto

  @type decision :: :authorized | {:requires_approval, Capability.t()} | :unauthorized | {:error, term()}

  @type t :: %__MODULE__{
          # Identity (who)
          principal_id: String.t(),
          identity_verified: boolean(),
          signed_request: term() | nil,
          signer: (String.t() -> {:ok, term()} | {:error, term()}) | nil,

          # Trust (how trusted)
          trust_tier: trust_tier(),
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
    trust_tier: :untrusted,
    trust_baseline: :ask,
    trust_rules: %{},
    capabilities: [],
    decisions: []
  ]

  @doc """
  Create a new AuthContext for an agent.

  Loads capabilities and trust profile from ETS stores.
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
      # These get populated by AuthContext.load/1
      trust_tier: Keyword.get(opts, :trust_tier, :untrusted),
      trust_baseline: Keyword.get(opts, :trust_baseline, :ask),
      trust_rules: Keyword.get(opts, :trust_rules, %{}),
      capabilities: Keyword.get(opts, :capabilities, [])
    }
  end

  @doc """
  Load capabilities and trust profile from stores into the context.

  This is the ONE place where ETS reads happen. After this, all auth
  decisions are pure functions on the struct.
  """
  @spec load(t()) :: t()
  def load(%__MODULE__{} = ctx) do
    ctx
    |> load_capabilities()
    |> load_trust_profile()
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

  # ===========================================================================
  # Private — ETS loading (side effects, called once)
  # ===========================================================================

  defp load_capabilities(%__MODULE__{principal_id: pid, capabilities: []} = ctx) do
    cap_store = Arbor.Security.CapabilityStore

    if Code.ensure_loaded?(cap_store) and function_exported?(cap_store, :list_for_principal, 1) do
      case apply(cap_store, :list_for_principal, [pid]) do
        {:ok, caps} -> %{ctx | capabilities: caps}
        _ -> ctx
      end
    else
      ctx
    end
  rescue
    _ -> ctx
  catch
    :exit, _ -> ctx
  end

  # Don't reload if capabilities were pre-loaded
  defp load_capabilities(ctx), do: ctx

  defp load_trust_profile(%__MODULE__{principal_id: pid} = ctx) do
    store = Arbor.Trust.Store

    if Code.ensure_loaded?(store) and function_exported?(store, :get_profile, 1) do
      case apply(store, :get_profile, [pid]) do
        {:ok, profile} ->
          %{ctx |
            trust_tier: profile.tier || ctx.trust_tier,
            trust_baseline: profile.baseline || ctx.trust_baseline,
            trust_rules: profile.rules || ctx.trust_rules
          }

        _ ->
          ctx
      end
    else
      ctx
    end
  rescue
    _ -> ctx
  catch
    :exit, _ -> ctx
  end
end
