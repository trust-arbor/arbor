defmodule Arbor.Agent.TemplateAuthorityCapabilityProjectionTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.TemplateAuthorityCapabilityProjection, as: Projection

  @moduletag :fast

  @repo_root "/Users/dev/arbor"

  test "resolves /self against the target agent id" do
    caps = [
      %{"resource" => "arbor://code/write/self/sandbox", "constraints" => %{"rate_limit" => 5}}
    ]

    assert {:ok, specs} =
             Projection.project(caps, "agent_abc123", repo_root: @repo_root)

    assert specs == [
             %{
               "resource" => "arbor://code/write/agent_abc123/sandbox",
               "constraints" => %{"rate_limit" => 5}
             }
           ]
  end

  test "expands orchestrator/execute to subtree for ordinary non-exact templates" do
    caps = [%{"resource" => "arbor://orchestrator/execute"}]

    assert {:ok, specs} =
             Projection.project(caps, "agent_ok1", repo_root: @repo_root)

    assert specs == [
             %{"resource" => "arbor://orchestrator/execute/**", "constraints" => %{}}
           ]
  end

  test "rejects unknown options and malformed closed inputs" do
    caps = [%{"resource" => "arbor://orchestrator/execute"}]

    assert {:error, {:template_authority_projection, :invalid_projection_options}} =
             Projection.project(caps, "agent_ok1",
               repo_root: @repo_root,
               exact_template?: true
             )

    assert {:error, {:template_authority_projection, :invalid_projection_options}} =
             Projection.project(caps, "agent_ok1", repo_root: @repo_root, unexpected: true)

    assert {:error, {:template_authority_projection, :invalid_projection_options}} =
             Projection.project(caps, "agent_ok1", unexpected: true)

    # Oversized opts spine: only one entry is admitted (:repo_root).
    assert {:error, {:template_authority_projection, :invalid_projection_options}} =
             Projection.project(caps, "agent_ok1",
               repo_root: @repo_root,
               repo_root: @repo_root
             )

    assert {:error, {:template_authority_projection, :invalid_projection_options}} =
             Projection.project(caps, "agent_ok1", [
               {:repo_root, @repo_root},
               {:repo_root, @repo_root},
               {:repo_root, @repo_root}
             ])

    # Improper opts spine and non-atom / non-pair entries fail closed.
    assert {:error, {:template_authority_projection, :invalid_projection_options}} =
             Projection.project(caps, "agent_ok1", [{:repo_root, @repo_root} | :tail])

    assert {:error, {:template_authority_projection, :invalid_projection_options}} =
             Projection.project(caps, "agent_ok1", [{"repo_root", @repo_root}])

    assert {:error, {:template_authority_projection, :invalid_projection_options}} =
             Projection.project(caps, "agent_ok1", [:repo_root])

    assert {:error, {:template_authority_projection, :agent_id_invalid}} =
             Projection.project(caps, "", repo_root: @repo_root)

    assert {:error, {:template_authority_projection, :agent_id_invalid}} =
             Projection.project(caps, "agent" <> <<0>>, repo_root: @repo_root)

    assert {:error, {:template_authority_projection, :agent_id_invalid}} =
             Projection.project(caps, <<0xFF, 0xFE>>, repo_root: @repo_root)

    assert {:error, {:template_authority_projection, :repo_root_missing_or_invalid}} =
             Projection.project([%{"resource" => "arbor://fs/read"}], "agent_ok1",
               repo_root: "relative/path"
             )

    assert {:error, {:template_authority_projection, :capability_resource_missing_or_invalid}} =
             Projection.project([%{"resource" => ""}], "agent_ok1", repo_root: @repo_root)

    assert {:error, {:template_authority_projection, :capability_resource_missing_or_invalid}} =
             Projection.project([%{"resource" => <<0xFF, 0xFE>>}], "agent_ok1",
               repo_root: @repo_root
             )
  end

  test "expands fs/read and fs/read/repo to bare gate plus repo-root scope" do
    for resource <- ["arbor://fs/read", "arbor://fs/read/repo"] do
      assert {:ok, specs} =
               Projection.project([%{"resource" => resource}], "agent_ok1", repo_root: @repo_root)

      assert specs == [
               %{"resource" => "arbor://fs/read", "constraints" => %{}},
               %{
                 "resource" => "arbor://fs/read/Users/dev/arbor/**",
                 "constraints" => %{}
               }
             ]
    end
  end

  test "expands fs/list and fs/list/repo identically" do
    assert {:ok, specs} =
             Projection.project([%{"resource" => "arbor://fs/list/repo"}], "agent_ok1",
               repo_root: @repo_root
             )

    assert specs == [
             %{"resource" => "arbor://fs/list", "constraints" => %{}},
             %{
               "resource" => "arbor://fs/list/Users/dev/arbor/**",
               "constraints" => %{}
             }
           ]
  end

  test "normalizes atom constraint keys like Lifecycle" do
    caps = [
      %{resource: "arbor://fs/write", constraints: %{rate_limit: 3, requires_approval: true}}
    ]

    assert {:ok, specs} = Projection.project(caps, "agent_ok1", repo_root: @repo_root)

    assert specs == [
             %{
               "resource" => "arbor://fs/write",
               "constraints" => %{"rate_limit" => 3, "requires_approval" => true}
             }
           ]
  end

  test "rejects conflicting atom/string constraint values deterministically" do
    conflict = [
      %{
        "resource" => "arbor://fs/write",
        "constraints" => %{"rate_limit" => 1, rate_limit: 2}
      }
    ]

    assert {:error, {:template_authority_projection, :capability_constraints_invalid}} =
             Projection.project(conflict, "agent_ok1", repo_root: @repo_root)

    agree = [
      %{
        "resource" => "arbor://fs/write",
        "constraints" => %{"rate_limit" => 3, rate_limit: 3}
      }
    ]

    assert {:ok, [%{"constraints" => %{"rate_limit" => 3}}]} =
             Projection.project(agree, "agent_ok1", repo_root: @repo_root)
  end

  test "rejects atom/string resource key conflicts and resource/resource_uri alias conflicts" do
    key_conflict = [
      %{"resource" => "arbor://fs/write", resource: "arbor://fs/read"}
    ]

    assert {:error, {:template_authority_projection, :capability_resource_key_conflict}} =
             Projection.project(key_conflict, "agent_ok1", repo_root: @repo_root)

    alias_conflict = [
      %{
        "resource" => "arbor://fs/write",
        "resource_uri" => "arbor://fs/read"
      }
    ]

    assert {:error, {:template_authority_projection, :capability_resource_alias_conflict}} =
             Projection.project(alias_conflict, "agent_ok1", repo_root: @repo_root)

    alias_agree = [
      %{
        "resource" => "arbor://fs/write",
        "resource_uri" => "arbor://fs/write",
        "constraints" => %{"rate_limit" => 1}
      }
    ]

    assert {:ok, [%{"resource" => "arbor://fs/write", "constraints" => %{"rate_limit" => 1}}]} =
             Projection.project(alias_agree, "agent_ok1", repo_root: @repo_root)

    atom_string_agree = [
      %{"resource" => "arbor://fs/write", resource: "arbor://fs/write"}
    ]

    assert {:ok, [%{"resource" => "arbor://fs/write"}]} =
             Projection.project(atom_string_agree, "agent_ok1", repo_root: @repo_root)
  end

  test "bounded single-pass list admission rejects oversize and improper spines" do
    too_many =
      for i <- 1..257 do
        %{"resource" => "arbor://custom/resource#{i}"}
      end

    assert {:error, {:template_authority_projection, :capabilities_too_many}} =
             Projection.project(too_many, "agent_ok1", repo_root: @repo_root)

    improper = [%{"resource" => "arbor://fs/write"} | :not_a_list]

    assert {:error, {:template_authority_projection, :capabilities_missing_or_invalid}} =
             Projection.project(improper, "agent_ok1", repo_root: @repo_root)

    assert {:error, {:template_authority_projection, :invalid_projection_input}} =
             Projection.project(:not_a_list, "agent_ok1", repo_root: @repo_root)
  end

  test "dedupes identical expansions and rejects constraint conflicts" do
    caps = [
      %{"resource" => "arbor://fs/write", "constraints" => %{"rate_limit" => 1}},
      %{"resource" => "arbor://fs/write", "constraints" => %{"rate_limit" => 1}}
    ]

    assert {:ok, specs} = Projection.project(caps, "agent_ok1", repo_root: @repo_root)
    assert length(specs) == 1

    conflict = [
      %{"resource" => "arbor://fs/write", "constraints" => %{"rate_limit" => 1}},
      %{"resource" => "arbor://fs/write", "constraints" => %{"rate_limit" => 2}}
    ]

    assert {:error, {:template_authority_projection, {:capability_resource_conflict, _}}} =
             Projection.project(conflict, "agent_ok1", repo_root: @repo_root)
  end

  test "requires repo_root for repo-scoped expansions" do
    assert {:error, {:template_authority_projection, :repo_root_missing_or_invalid}} =
             Projection.project([%{"resource" => "arbor://fs/read"}], "agent_ok1", [])
  end

  test "project_normalized matches project for valid inputs" do
    caps = [
      %{"resource" => "arbor://orchestrator/execute"},
      %{"resource" => "arbor://fs/write", "constraints" => %{"rate_limit" => 2}}
    ]

    assert {:ok, a} = Projection.project(caps, "agent_ok1", repo_root: @repo_root)
    assert {:ok, b} = Projection.project_normalized(caps, "agent_ok1", repo_root: @repo_root)
    assert a == b
  end
end
