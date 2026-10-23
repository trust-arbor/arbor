defmodule Arbor.Actions.RoutineEffectFailClosedSecurityRegressionTest do
  @moduledoc """
  Security regression: group U — cooperative routine per-effect check.

  `OwnedRoutines.check_effect` is only invoked when an action calls
  `authorize_routine_effect`. A catalog action that skips that call can
  still exercise the ephemeral run identity's granted file capability.
  The identity must fail closed: no effect is admitted unless
  `check_effect` has approved it.
  """
  use ExUnit.Case, async: false

  alias Arbor.Actions
  alias Arbor.Actions.File, as: FileActions
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Security

  @moduletag :fast
  @moduletag :security_regression

  @catalog_uri "arbor://action/reports/build_morning_digest"

  defmodule SkipCheckCatalogAction do
    @moduledoc false

    use Jido.Action,
      name: "reports_skip_check_catalog",
      description: "Catalog-shaped write that skips the routine effect check",
      category: "reports",
      tags: ["reports"],
      schema: [
        path: [type: :string, required: true],
        content: [type: :string, required: true]
      ]

    def requires_authenticated_principal?, do: true
    def effect_class, do: :local_write
    def taint_roles, do: %{path: :control, content: :data}
    def authorization_resource(_params), do: {:ok, "arbor://action/reports/build_morning_digest"}

    def run(%{path: path, content: content}, context) do
      with {:ok, path} <- FileActions.authorize_file_op(context, path, :write),
           :ok <- File.write(path, content) do
        {:ok, %{path: path}}
      end
    end
  end

  defmodule RoutinePeer do
    @moduledoc false

    def routine_effect_requirement(_principal), do: {:ok, true}

    def authorize_routine_effect(token, effect) do
      send(self(), {:routine_effect, token, effect})
      :ok
    end
  end

  setup do
    unless Process.whereis(Arbor.Trust.Store), do: start_supervised!(Arbor.Trust.Store)

    previous = Application.fetch_env(:arbor_actions, :scheduler_module)
    Application.put_env(:arbor_actions, :scheduler_module, RoutinePeer)

    on_exit(fn ->
      case previous do
        {:ok, module} -> Application.put_env(:arbor_actions, :scheduler_module, module)
        :error -> Application.delete_env(:arbor_actions, :scheduler_module)
      end
    end)

    temporary =
      Path.join(System.tmp_dir!(), "arbor-routine-effect-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temporary)
    target = Path.join(temporary, "skipped-check.md")

    {:ok, identity} = Security.generate_identity()
    :ok = Security.register_identity_fixture(identity)

    resources = [
      @catalog_uri,
      "arbor://fs/write#{temporary}/**"
    ]

    caps =
      for resource <- resources do
        {:ok, cap} = Security.grant_fixture(principal: identity.agent_id, resource: resource)
        cap
      end

    on_exit(fn ->
      for cap <- caps, do: Security.revoke_fixture(cap.id)
      Security.deregister_identity_fixture(identity.agent_id)
      File.rm_rf!(temporary)
    end)

    %{identity: identity, target: target, temporary: temporary}
  end

  test "security regression: a catalog action that skips check_effect is denied for a routine identity",
       fixture do
    assert {:error, :routine_effect_token_required} =
             execute(fixture, SkipCheckCatalogAction, %{
               path: fixture.target,
               content: "must not land"
             })

    refute File.exists?(fixture.target)
    refute_received {:routine_effect, _, _}
  end

  test "security regression: an approved token is required before a skip-check catalog write",
       fixture do
    token = %{
      lease: "lease_" <> Base.url_encode64(:binary.copy(<<41>>, 18), padding: false),
      token: Base.url_encode64(:binary.copy(<<42>>, 32), padding: false)
    }

    assert {:ok, %{path: path}} =
             execute(
               fixture,
               SkipCheckCatalogAction,
               %{path: fixture.target, content: "admitted after check"},
               token
             )

    assert path == fixture.target
    assert File.read!(fixture.target) == "admitted after check"
    assert_received {:routine_effect, ^token, %{operation: :enter, principal: principal}}
    assert principal == fixture.identity.agent_id
    assert_received {:routine_effect, ^token, %{operation: :write, path: ^path}}
  end

  test "security regression: every catalog action module still invokes the effect check" do
    assert Arbor.Scheduler.catalog_action_uri() == @catalog_uri

    source =
      File.read!(
        Path.expand("../../../lib/arbor/actions/reports/build_morning_digest.ex", __DIR__)
      )

    assert source =~ "authorize_routine_effect"
  end

  test "security regression: a routine identity cannot write through File.authorize_file_op without an approved effect",
       fixture do
    assert {:error, :routine_effect_token_required} =
             FileActions.authorize_file_op(
               %{agent_id: fixture.identity.agent_id},
               fixture.target,
               :write
             )

    refute File.exists?(fixture.target)
    refute_received {:routine_effect, _, _}
  end

  defp execute(fixture, module, params, token \\ nil) do
    {:ok, proof} =
      SignedRequest.sign(@catalog_uri, fixture.identity.agent_id, fixture.identity.private_key)

    context = %{
      signed_request: proof,
      workdir: fixture.temporary,
      taint_policy: :permissive
    }

    context =
      if token, do: Map.put(context, :routine_effect_token, token), else: context

    Actions.authorize_and_execute(fixture.identity.agent_id, module, params, context)
  end
end
