defmodule Arbor.Agent.TemplateAuthorityCrossPrincipalPreparationSecurityRegressionTest do
  @moduledoc """
  Phase 4C C3B2 follow-up — cross-principal preparation constructor bind.

  Immediate parent: eb6c773eb2b2a7d886c21b86e196d38a39b1a554
  On parent, TemplateAuthorityPreparation.new/1 accepts Record.key ≠ data agent_id
  when other closed fields are valid — the single ordinary assertion failure.
  Correction rejects with {:error, :invalid_preparation}.
  """

  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Agent.TemplateAuthorityCapabilityProjection
  alias Arbor.Agent.TemplateAuthorityPolicy
  alias Arbor.Agent.TemplateAuthorityPreparation
  alias Arbor.Contracts.Persistence.Record

  @record_key "agent_record_key"
  @data_principal "agent_data_principal"
  @repo_root "/Users/dev/arbor"

  @template_data %{
    "name" => "scout",
    "required_capabilities" => [
      %{"resource" => "arbor://fs/write"},
      %{"resource" => "arbor://orchestrator/execute"}
    ],
    "trust_preset" => %{
      "baseline" => "block",
      "rules" => %{
        "arbor://fs/write" => "ask",
        "arbor://orchestrator/execute" => "auto"
      }
    },
    "template_source" => %{"name" => "scout", "layer" => "shipped"}
  }

  test "security regression: preparation rejects Record.key ≠ serialized agent_id" do
    assert {:ok, envelope} = TemplateAuthorityPolicy.build("scout", @template_data)
    snap = TemplateAuthorityPolicy.snapshot(envelope)
    declared = TemplateAuthorityPolicy.capabilities(snap)
    prov = TemplateAuthorityPolicy.provenance(snap)

    assert {:ok, caps} =
             TemplateAuthorityCapabilityProjection.project_normalized(
               declared,
               @record_key,
               repo_root: @repo_root
             )

    record = %Record{
      id: "agent_profile:#{@record_key}",
      key: @record_key,
      data: %{
        "agent_id" => @data_principal,
        "template" => "scout",
        "initial_capabilities" => [],
        "metadata" => %{},
        "version" => 1
      },
      metadata: %{},
      generation: 1,
      revision: 1,
      inserted_at: ~U[2026-01-01 00:00:00Z],
      updated_at: ~U[2026-01-01 00:00:00Z]
    }

    desired = %{
      "envelope" => envelope,
      "declaration_digest" => envelope["digest"],
      "provenance" => %{
        "name" => Map.get(prov, "name") || Map.get(snap, "template"),
        "layer" => Map.get(prov, "layer")
      }
    }

    cas = %{
      "record_id" => record.id,
      "generation" => record.generation,
      "revision" => record.revision
    }

    attrs = %{
      record: record,
      profile_cas: cas,
      desired_authority: desired,
      repo_root: @repo_root,
      effective_capabilities: caps
    }

    # Parent (eb6c773e): constructor accepts key/data principal mismatch when
    # other closed fields are valid — this is the single ordinary assertion
    # failure. Correction must reject with {:error, :invalid_preparation}.
    assert match?(
             {:error, :invalid_preparation},
             TemplateAuthorityPreparation.new(attrs)
           ),
           "security regression: preparation must reject Record.key ≠ serialized agent_id"
  end
end
