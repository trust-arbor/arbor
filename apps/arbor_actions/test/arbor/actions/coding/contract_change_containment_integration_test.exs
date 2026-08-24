defmodule Arbor.Actions.Coding.ContractChangeContainmentIntegrationTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Arbor.Actions.Coding.ContractChange.Core
  alias Arbor.Shell

  @moduletag :fast
  @moduletag :security_regression

  @mix_wrapper "/private/tmp/arbor-val/bin/mix"
  @worktree "/private/tmp/arbor-val/worktree"
  @contract_change_preflight_argv [
    "do",
    "compile",
    "--warnings-as-errors,",
    "xref",
    "graph,",
    "arbor.contracts.census",
    "--fail-on-violation"
  ]

  test "security regression: ContractChange.Core.preflight_argv cannot drift from public Shell Apple Container containment" do
    argv = Core.preflight_argv()

    assert argv == @contract_change_preflight_argv

    # {:error, :apple_container_unit_owner_required} means the reviewed argv passed mix-shape admission and stopped at the public owner gate.
    assert {:error, :apple_container_unit_owner_required} =
             Shell.execute_spawn_capable(@mix_wrapper, argv, spawn_preflight_opts())
  end

  defp spawn_preflight_opts do
    [
      cwd: @worktree,
      timeout: 60_000,
      sandbox: :basic,
      env: %{},
      clear_env: true,
      filesystem_projections: projections()
    ]
  end

  defp projections do
    %{
      read_only: [
        projection_entry(
          "/opt/homebrew/Cellar/erlang/28.4.1/lib/erlang",
          :read_only,
          :runtime_erlang
        ),
        projection_entry("/opt/homebrew/Cellar/elixir/1.19.5", :read_only, :runtime_elixir),
        projection_entry(@mix_wrapper, :read_only, :mix_wrapper),
        projection_entry("/private/tmp/arbor-val/runner", :read_only, :validation_runner)
      ],
      read_write: [
        projection_entry(@worktree, :read_write, :worktree),
        projection_entry("/private/tmp/arbor-val/home", :read_write, :home),
        projection_entry("/private/tmp/arbor-val/tmp", :read_write, :tmp),
        projection_entry("/private/tmp/arbor-val/build", :read_write, :build),
        projection_entry("/private/tmp/arbor-val/deps", :read_write, :deps),
        projection_entry("/private/tmp/arbor-val/result", :read_write, :validation_result)
      ],
      revision: "candidate"
    }
  end

  defp projection_entry(path, mode, purpose) do
    %{
      "path" => path,
      "mode" => Atom.to_string(mode),
      "purpose" => Atom.to_string(purpose)
    }
  end
end
