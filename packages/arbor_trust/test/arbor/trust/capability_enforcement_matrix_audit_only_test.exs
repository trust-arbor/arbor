defmodule Arbor.Trust.CapabilityEnforcementMatrixAuditOnlyTest do
  @moduledoc """
  Regression: K5 matrix stays an audit declaration, not an authorize path.

  Conservative choice (2026-10-16): do not force-enforce the table at
  `Arbor.Security.authorize/4`. Hard gates must stay off that decision
  path. See `docs/arbor/K5_ENFORCEMENT_MATRIX.md`.
  """
  use ExUnit.Case, async: true

  alias Arbor.Trust.CapabilityEnforcementMatrix

  @moduletag :fast

  test "matrix API is read-only and does not authorize" do
    exports = CapabilityEnforcementMatrix.__info__(:functions)

    assert Keyword.has_key?(exports, :rows)
    assert Keyword.has_key?(exports, :row_for)
    refute Keyword.has_key?(exports, :authorize)
    refute Keyword.has_key?(exports, :check)
    refute Keyword.has_key?(exports, :enforce)
    refute Keyword.has_key?(exports, :allow)
    refute Keyword.has_key?(exports, :deny)

    rows = Arbor.Trust.capability_enforcement_rows()
    assert rows != []
    assert rows == CapabilityEnforcementMatrix.rows()

    for row <- rows do
      assert is_map(row)
      assert is_map(row.soft_gate)
      assert is_map(row.hard_gate)
      refute row.hard_gate.authorize4_dependent?
    end
  end
end
