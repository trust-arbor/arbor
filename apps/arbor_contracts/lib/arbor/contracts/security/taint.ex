defmodule Arbor.Contracts.Security.Taint do
  @moduledoc """
  Four-dimensional taint tracking for information flow control.

  Extends the original atom-based taint level with sensitivity classification,
  sanitization tracking, and confidence scoring. Together these dimensions enable:

  - **Level** — provenance tracking (trusted → hostile)
  - **Sensitivity** — data classification for provider routing (public → restricted)
  - **Sanitizations** — bitmask tracking which sanitization steps have been applied
  - **Confidence** — how much we trust the taint classification itself

  ## Defaults

  Conservative by design (council decisions #4, #6):
  - `:internal` sensitivity (not public by default)
  - 0 sanitizations (nothing has been cleaned)
  - `:unverified` confidence (we don't know how reliable the classification is)
  """

  use TypedStruct

  @type level :: :trusted | :derived | :untrusted | :hostile
  @type sensitivity :: :public | :internal | :confidential | :restricted
  @type confidence :: :unverified | :plausible | :corroborated | :verified

  # Phase 1 sanitization bit positions (8-bit)
  @xss 0b00000001
  @sqli 0b00000010
  @command_injection 0b00000100
  @path_traversal 0b00001000
  @prompt_injection 0b00010000
  @ssrf 0b00100000
  @log_injection 0b01000000
  @deserialization 0b10000000

  @sanitization_bits %{
    xss: @xss,
    sqli: @sqli,
    command_injection: @command_injection,
    path_traversal: @path_traversal,
    prompt_injection: @prompt_injection,
    ssrf: @ssrf,
    log_injection: @log_injection,
    deserialization: @deserialization
  }

  @derive Jason.Encoder
  typedstruct do
    field :level, level(), default: :trusted
    field :sensitivity, sensitivity(), default: :internal
    field :sanitizations, non_neg_integer(), default: 0
    field :confidence, confidence(), default: :unverified
    field :source, String.t()
    field :chain, [String.t()], default: []
  end

  # ── Sanitization Constants ──────────────────────────────────────────

  @doc "Returns the sanitization bit positions map."
  @spec sanitization_bits() :: %{atom() => non_neg_integer()}
  def sanitization_bits, do: @sanitization_bits

  @doc "Returns the bit position for a named sanitization."
  @spec sanitization_bit(atom()) :: {:ok, non_neg_integer()} | :error
  def sanitization_bit(name) when is_atom(name) do
    case Map.fetch(@sanitization_bits, name) do
      {:ok, _bit} = ok -> ok
      :error -> :error
    end
  end

  # ── Ordering Constants ──────────────────────────────────────────────

  @doc "Returns valid levels in severity order (lowest to highest)."
  @spec levels() :: [level()]
  def levels, do: [:trusted, :derived, :untrusted, :hostile]

  @doc "Returns valid sensitivity levels in severity order."
  @spec sensitivities() :: [sensitivity()]
  def sensitivities, do: [:public, :internal, :confidential, :restricted]

  @doc "Returns valid confidence levels in certainty order."
  @spec confidences() :: [confidence()]
  def confidences, do: [:unverified, :plausible, :corroborated, :verified]
end
