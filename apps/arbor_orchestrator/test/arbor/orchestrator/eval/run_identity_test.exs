defmodule Arbor.Orchestrator.Eval.RunIdentityTest do
  @moduledoc """
  Thin delegate tests — logic lives in arbor_persistence.
  """
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator.Eval.RunIdentity
  alias Arbor.Persistence

  test "capture/1 delegates to Persistence" do
    attrs =
      RunIdentity.capture(%{
        git_sha: "caller-sha",
        git_dirty: true,
        dataset_hash: "caller-hash",
        config_fingerprint: "caller-fp"
      })

    assert attrs[:git_sha] == "caller-sha"
    assert attrs[:git_dirty] == true
    assert attrs[:dataset_hash] == "caller-hash"
    assert attrs[:config_fingerprint] == "caller-fp"
  end

  test "dataset_hash/1 and config_fingerprint/1 match facade" do
    assert RunIdentity.dataset_hash(nil) == Persistence.eval_dataset_hash(nil)
    assert RunIdentity.config_fingerprint(%{}) == Persistence.eval_config_fingerprint(%{})

    cfg = %{timeout: 60}
    assert RunIdentity.config_fingerprint(cfg) == Persistence.eval_config_fingerprint(cfg)
  end
end
