defmodule Arbor.Contracts.Agent.Authority do
  @moduledoc """
  Authority domain — who the agent is, what it can do, how trusted it is.

  Lifecycle: mostly static, changes infrequently.
  Persistence: durable, snapshot on change.

  Sub-structs:
  - Identity: immutable crypto identity (agent_id, public_key, endorsement)
  - Character: mutable personality (name, traits, values, voice)
  - Trust: trust tier, score, profile, stats
  - Security: capabilities, taint state, tokenization
  """

  alias Arbor.Contracts.Agent.Authority.{Identity, Character, Trust, Security}

  @type t :: %__MODULE__{
          identity: Identity.t(),
          character: Character.t(),
          trust: Trust.t(),
          security: Security.t(),
          template: atom() | String.t() | nil
        }

  @enforce_keys [:identity, :character, :trust, :security]
  defstruct [
    :identity,
    :character,
    :trust,
    :security,
    :template
  ]
end

defmodule Arbor.Contracts.Agent.Authority.Identity do
  @moduledoc """
  Immutable cryptographic identity. Created once, never modified.

  Private keys are NEVER stored here — only in SigningKeyStore or TEE.
  The public_key and agent_id are derived at creation and never change.
  """

  @type t :: %__MODULE__{
          agent_id: String.t(),
          public_key: binary(),
          encryption_public_key: binary() | nil,
          endorsement: endorsement() | nil,
          svid: String.t() | nil,
          key_version: pos_integer(),
          status: :active | :suspended | :revoked,
          status_changed_at: DateTime.t() | nil,
          status_reason: String.t() | nil,
          created_at: DateTime.t()
        }

  @type endorsement :: %{
          agent_id: String.t(),
          agent_public_key: binary(),
          authority_id: String.t(),
          authority_signature: binary(),
          endorsed_at: DateTime.t()
        }

  @enforce_keys [:agent_id, :public_key, :created_at]
  @derive {Inspect, except: [:public_key, :encryption_public_key]}
  defstruct [
    :agent_id,
    :public_key,
    :encryption_public_key,
    :endorsement,
    :svid,
    :status_changed_at,
    :status_reason,
    key_version: 1,
    status: :active,
    created_at: nil
  ]
end

defmodule Arbor.Contracts.Agent.Authority.Character do
  @moduledoc """
  Mutable personality and behavioral definition.

  This is the "who" that evolves — traits can change, voice can adapt,
  instructions can be updated. Identity (crypto) stays fixed.
  """

  @type trait :: %{name: String.t(), intensity: float()}

  @type t :: %__MODULE__{
          display_name: String.t(),
          name: String.t(),
          description: String.t() | nil,
          role: String.t() | nil,
          background: String.t() | nil,
          traits: [trait()],
          values: [String.t()],
          quirks: [String.t()],
          tone: String.t() | nil,
          style: String.t() | nil,
          knowledge: [map()],
          instructions: [String.t()]
        }

  @enforce_keys [:name]
  defstruct [
    :display_name,
    :name,
    :description,
    :role,
    :background,
    :tone,
    :style,
    traits: [],
    values: [],
    quirks: [],
    knowledge: [],
    instructions: []
  ]
end

defmodule Arbor.Contracts.Agent.Authority.Trust do
  @moduledoc """
  Trust state — tier, score, profile rules, and activity stats.

  Changes on approvals, violations, and decay. The trust profile contains
  URI-prefix rules that determine what the agent can do at each trust level.
  """

  @type trust_tier :: :untrusted | :probationary | :established | :trusted | :full_partner
  @type trust_mode :: :block | :ask | :allow | :auto

  @type stats :: %{
          total_actions: non_neg_integer(),
          successful_actions: non_neg_integer(),
          security_violations: non_neg_integer(),
          proposals_submitted: non_neg_integer(),
          proposals_approved: non_neg_integer(),
          proposals_rejected: non_neg_integer(),
          installations_successful: non_neg_integer(),
          installations_rolled_back: non_neg_integer()
        }

  @type component_scores :: %{
          success_rate: float(),
          uptime: float(),
          security: float(),
          test_pass: float(),
          rollback: float()
        }

  @type t :: %__MODULE__{
          tier: trust_tier(),
          trust_score: non_neg_integer(),
          trust_points: non_neg_integer(),
          baseline: trust_mode(),
          rules: %{String.t() => trust_mode()},
          model_constraints: map(),
          frozen: boolean(),
          frozen_reason: atom() | String.t() | nil,
          frozen_at: DateTime.t() | nil,
          scores: component_scores(),
          stats: stats(),
          updated_at: DateTime.t(),
          last_activity_at: DateTime.t() | nil
        }

  defstruct [
    :frozen_reason,
    :frozen_at,
    :last_activity_at,
    tier: :untrusted,
    trust_score: 0,
    trust_points: 0,
    baseline: :ask,
    rules: %{},
    model_constraints: %{},
    frozen: false,
    scores: %{
      success_rate: 0.0,
      uptime: 0.0,
      security: 100.0,
      test_pass: 0.0,
      rollback: 100.0
    },
    stats: %{
      total_actions: 0,
      successful_actions: 0,
      security_violations: 0,
      proposals_submitted: 0,
      proposals_approved: 0,
      proposals_rejected: 0,
      installations_successful: 0,
      installations_rolled_back: 0
    },
    updated_at: nil
  ]
end

defmodule Arbor.Contracts.Agent.Authority.Security do
  @moduledoc """
  Security state — capabilities, taint, and PII tokenization.

  Changes on capability grants/revocations, taint updates, and session
  sensitivity escalation (monotonic ratchet).
  """

  alias Arbor.Contracts.Security.{Capability, Taint}

  @type sensitivity :: :public | :internal | :confidential | :restricted

  @type t :: %__MODULE__{
          capabilities: [Capability.t()],
          taint_state: Taint.t() | nil,
          session_sensitivity: sensitivity(),
          token_map: map() | nil,
          delegation_relationships: [delegation()]
        }

  @type delegation :: %{
          delegator_id: String.t(),
          delegated_capabilities: [Capability.t()]
        }

  defstruct [
    :taint_state,
    :token_map,
    capabilities: [],
    session_sensitivity: :public,
    delegation_relationships: []
  ]
end
