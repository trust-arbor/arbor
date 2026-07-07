defmodule Arbor.Trust.Presets do
  @moduledoc """
  Single source of truth for trust presets and the default security ceiling.

  Previously the preset `{baseline, rules}` data lived in `Arbor.Trust.Authority`
  and the security ceiling was defined TWICE (a 2-entry pure fallback in
  `Authority`, a fuller config-backed one in `ProfileResolver`) — which drifted.
  This module owns both; `Authority` and `ProfileResolver` read from here so there
  is one place to change policy data.

  ## P1 (forbid `:auto` baseline)

  Every preset baseline here is `:block` or `:ask` — never `:auto`/`:allow`.
  Reach is granted by explicit per-URI `:auto`/`:allow` RULES, not by a permissive
  baseline (which would invert deny-by-default; see capability-policy-model-review).
  The hard-danger set (`shell`, `governance`, `net`, `trust`, agent-lifecycle,
  `consensus/admin`) stays `:ask` even at full trust, and is also ceiling-enforced.
  """

  @type mode :: :block | :ask | :allow | :auto
  @type rules :: %{optional(String.t()) => mode()}

  @doc """
  Preset `{baseline, rules}` for a named preset.

  Names: `:cautious` (default), `:balanced`, `:hands_off`, `:full_trust`.
  """
  @spec preset_rules(atom()) :: {mode(), rules()}
  def preset_rules(:cautious) do
    {:ask,
     %{
       "arbor://code/read" => :auto,
       "arbor://code/write" => :block,
       "arbor://fs/read" => :auto,
       "arbor://historian/query" => :auto,
       "arbor://orchestrator" => :auto,
       # Proactive notify allowed by default (bounded by a rate-limit constraint);
       # the user dials block/ask in their profile.
       "arbor://comms/notify/session" => :allow,
       "arbor://shell" => :block,
       "arbor://shell/exec" => :ask
     }}
  end

  def preset_rules(:balanced) do
    {:ask,
     %{
       "arbor://code/read" => :auto,
       "arbor://code/write" => :ask,
       "arbor://fs/read" => :auto,
       "arbor://fs/write" => :allow,
       "arbor://historian/query" => :auto,
       "arbor://orchestrator" => :auto,
       "arbor://comms/notify/session" => :allow,
       "arbor://shell" => :ask,
       "arbor://memory" => :auto
     }}
  end

  # P1 rewrite (2026-07-06): baseline was :allow (polarity inversion). Now :ask,
  # with reach as explicit :auto rules and dangerous ops explicit :ask.
  def preset_rules(:hands_off) do
    {:ask,
     %{
       "arbor://code/read" => :auto,
       "arbor://fs/read" => :auto,
       "arbor://fs/list" => :auto,
       "arbor://historian" => :auto,
       "arbor://memory" => :auto,
       "arbor://orchestrator" => :auto,
       "arbor://status" => :auto,
       "arbor://monitor" => :auto,
       "arbor://signals" => :auto,
       "arbor://ai" => :auto,
       "arbor://comms/notify" => :auto,
       "arbor://comms/send" => :auto,
       # Writes: grant-with-confirm, not silent auto (also ceiling-gated).
       "arbor://code/write" => :allow,
       "arbor://fs/write" => :allow,
       # Hard-danger — always :ask.
       "arbor://shell" => :ask,
       "arbor://governance" => :ask,
       "arbor://net" => :ask,
       "arbor://trust" => :ask,
       "arbor://agent/create" => :ask,
       "arbor://agent/destroy" => :ask,
       "arbor://agent/spawn" => :ask,
       "arbor://sandbox" => :ask,
       "arbor://consensus/admin" => :ask
     }}
  end

  # P1 rewrite (2026-07-06): baseline was :auto (extreme polarity inversion, only 2
  # rules). Now :ask with an enumerated allowlist — full trust is still an allowlist,
  # not "everything". The hard-danger set stays :ask even here.
  def preset_rules(:full_trust) do
    {:ask,
     %{
       "arbor://code" => :auto,
       "arbor://fs" => :auto,
       "arbor://historian" => :auto,
       "arbor://memory" => :auto,
       "arbor://orchestrator" => :auto,
       "arbor://status" => :auto,
       "arbor://monitor" => :auto,
       "arbor://signals" => :auto,
       "arbor://ai" => :auto,
       "arbor://comms" => :auto,
       "arbor://eval" => :auto,
       "arbor://pipeline" => :auto,
       "arbor://persistence" => :auto,
       "arbor://actions" => :auto,
       "arbor://tool" => :auto,
       "arbor://consensus/ask" => :auto,
       # Never auto, even at full trust (also ceiling-backed).
       "arbor://shell" => :ask,
       "arbor://governance" => :ask,
       "arbor://net" => :ask,
       "arbor://trust" => :ask,
       "arbor://agent/create" => :ask,
       "arbor://agent/destroy" => :ask,
       "arbor://agent/spawn" => :ask,
       "arbor://consensus/admin" => :ask
     }}
  end

  def preset_rules(_), do: preset_rules(:cautious)

  @doc """
  The default security ceiling — the fuller, write-gating set (was in
  `ProfileResolver`; `Authority`'s divergent 2-entry fallback is gone). System
  ceilings clamp a profile to a maximum: `most_restrictive([user, ceiling, model])`.
  Operator override is layered on top of this default at the ProfileResolver boundary.
  """
  @spec default_security_ceilings() :: rules()
  def default_security_ceilings do
    %{
      "arbor://shell" => :ask,
      "arbor://actions/execute/shell.execute" => :ask,
      "arbor://actions/execute/shell.execute_script" => :ask,
      "arbor://governance" => :ask,
      "arbor://code/write" => :ask,
      "arbor://fs/write" => :ask,
      "arbor://actions/execute/file.write" => :ask,
      "arbor://actions/execute/file.edit" => :ask,
      "arbor://actions/execute/code.compile_and_test" => :ask,
      "arbor://actions/execute/code.hot_load" => :ask
    }
  end
end
