defmodule Arbor.Voice.BudgetLedger.Reservation do
  @moduledoc """
  Opaque, immutable admission receipt returned by
  `Arbor.Voice.BudgetLedger.reserve/5`.

  Carries only source-owned identity needed to settle the exact user/day
  durable record it was admitted against: `key` is the namespaced storage key
  (a hashed user id and UTC day — see `Arbor.Voice.BudgetLedger`), never a raw
  user id. No credentials, raw provider data, or backend handles.

  These fields are not trusted at face value: `consume/3` and `release/2`
  recompute a fingerprint from them and require it to match the fingerprint
  durably recorded at reservation time, so a caller cannot forge a larger
  `requested_ms` or altered timestamps to double-spend budget.

  All six fields are `@enforce_keys`; they are populated only by a successful
  `reserve/5` call. Callers must not construct a Reservation by hand.
  """

  @enforce_keys [:id, :key, :utc_day, :requested_ms, :reserved_at_ms, :expires_at_ms]
  defstruct [:id, :key, :utc_day, :requested_ms, :reserved_at_ms, :expires_at_ms]

  @type t :: %__MODULE__{
          id: String.t(),
          key: String.t(),
          utc_day: String.t(),
          requested_ms: pos_integer(),
          reserved_at_ms: non_neg_integer(),
          expires_at_ms: non_neg_integer()
        }
end
