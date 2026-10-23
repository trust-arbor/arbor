defmodule Arbor.Security.FileGuardWildcardConstraintsSecurityRegressionTest do
  @moduledoc """
  Security regression: the exact `arbor://fs/**` wildcard branch used to
  return `Path.expand(requested)` from `FileGuard.authorize/3` and
  `authorize_with_capability/3`, skipping pattern, exclude, and depth
  constraints. The descriptor read path already applied them.

  Pre-fix, a wildcard grant with `exclude: [".env"]` authorized
  `/workspace/.env`. The gate must deny that path.
  """

  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag security: :regression
  @moduletag spec: "SSEC-015"

  alias Arbor.Security
  alias Arbor.Security.FileGuard

  setup do
    agent_id = "agent_fg_wc_#{:erlang.unique_integer([:positive])}"
    {:ok, agent_id: agent_id}
  end

  test "security regression: a wildcard cap with an exclude denies the excluded path",
       %{agent_id: agent_id} do
    {:ok, _cap} =
      Security.grant_fixture(
        principal: agent_id,
        resource: "arbor://fs/**",
        constraints: %{exclude: [".env", "*.secret"]}
      )

    # Positive control: the wildcard grant is live and still covers ordinary files.
    assert {:ok, _resolved} = FileGuard.authorize(agent_id, "/workspace/config.exs", :read)

    assert {:error, :excluded_pattern} =
             FileGuard.authorize(agent_id, "/workspace/.env", :read)

    assert {:error, :excluded_pattern} =
             FileGuard.authorize(agent_id, "/workspace/api.secret", :write)

    assert {:error, :excluded_pattern} =
             FileGuard.authorize_with_capability(agent_id, "/etc/.env", :list)
  end

  test "security regression: a wildcard cap with patterns denies a mismatch",
       %{agent_id: agent_id} do
    {:ok, _cap} =
      Security.grant_fixture(
        principal: agent_id,
        resource: "arbor://fs/**",
        constraints: %{patterns: ["*.ex", "*.exs"]}
      )

    assert {:ok, _resolved} = FileGuard.authorize(agent_id, "/workspace/file.ex", :read)

    assert {:error, :pattern_mismatch} =
             FileGuard.authorize(agent_id, "/workspace/file.txt", :read)
  end

  test "security regression: a wildcard cap with max_depth is measured from filesystem root",
       %{agent_id: agent_id} do
    {:ok, _cap} =
      Security.grant_fixture(
        principal: agent_id,
        resource: "arbor://fs/**",
        constraints: %{max_depth: 2}
      )

    # `/workspace/file.ex` is depth 2 from `/`.
    assert {:ok, _resolved} = FileGuard.authorize(agent_id, "/workspace/file.ex", :read)

    assert {:error, :max_depth_exceeded} =
             FileGuard.authorize(agent_id, "/workspace/src/file.ex", :read)
  end

  test "security regression: an unconstrained wildcard still authorizes every fs operation",
       %{agent_id: agent_id} do
    {:ok, _cap} =
      Security.grant_fixture(
        principal: agent_id,
        resource: "arbor://fs/**"
      )

    for op <- [:read, :write, :execute, :delete, :list] do
      assert {:ok, resolved} = FileGuard.authorize(agent_id, "/workspace/file.ex", op)
      assert is_binary(resolved)
    end
  end
end
