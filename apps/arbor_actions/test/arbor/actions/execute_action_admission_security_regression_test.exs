defmodule Arbor.Actions.ExecuteActionAdmissionSecurityRegressionTest do
  @moduledoc """
  Security regression: public `Arbor.Actions.execute_action/3` ran any action
  module with no authorization. It was `@doc false` and commented "only for
  system-level callers", but it was a public `def`, so any in-VM caller (and
  AgentSeed's `bypass_auth: true`) reached `run/2` with no principal.

  Only the active, process-owned admission frame may enter the
  already-authorized implementation directly. Every other call goes through
  `authorize_and_execute/4` as `context.agent_id`.
  """
  use ExUnit.Case, async: true

  alias Arbor.Actions

  @moduletag :fast
  @moduletag :security_regression

  @effect_resource "arbor://action/test/execute-action-admission/effect"
  @composite_resource "arbor://action/test/execute-action-admission/composite"
  @reentrant_resource "arbor://action/test/execute-action-admission/reentrant"

  defmodule EffectProbe do
    @moduledoc false
    use Jido.Action,
      name: "execute_action_admission_effect_probe",
      description: "Records that its effect ran",
      schema: []

    def authorization_resource(_params),
      do: {:ok, "arbor://action/test/execute-action-admission/effect"}

    @impl true
    def run(params, context) do
      if pid = Map.get(context, :test_pid) || Map.get(params, :test_pid) do
        send(pid, {:effect_probe_ran, Map.get(context, :agent_id)})
      end

      {:ok, %{effect: true}}
    end
  end

  # Calls a different action from inside its own admitted run/2. The outer
  # frame belongs to this module, so the nested call must be authorized on
  # its own.
  defmodule CompositeProbe do
    @moduledoc false
    use Jido.Action,
      name: "execute_action_admission_composite_probe",
      description: "Calls EffectProbe through the public facade",
      schema: []

    def authorization_resource(_params),
      do: {:ok, "arbor://action/test/execute-action-admission/composite"}

    @impl true
    def run(_params, context) do
      nested =
        Arbor.Actions.execute_action(
          Arbor.Actions.ExecuteActionAdmissionSecurityRegressionTest.EffectProbe,
          %{},
          context
        )

      {:ok, %{nested: nested}}
    end
  end

  # Re-enters itself with the admitted context: the active frame for this
  # exact module and principal.
  defmodule ReentrantProbe do
    @moduledoc false
    use Jido.Action,
      name: "execute_action_admission_reentrant_probe",
      description: "Re-enters itself inside its own admission frame",
      schema: []

    def authorization_resource(_params),
      do: {:ok, "arbor://action/test/execute-action-admission/reentrant"}

    @impl true
    def run(params, context) do
      if Map.get(params, :reenter, false) do
        {:ok, %{nested: Arbor.Actions.execute_action(__MODULE__, %{}, context)}}
      else
        send(Map.fetch!(context, :test_pid), :reentrant_probe_inner_ran)
        {:ok, %{inner: true}}
      end
    end
  end

  setup do
    agent_id = "agent_execute_action_admission_#{System.unique_integer([:positive])}"
    on_exit(fn -> Arbor.Security.revoke_all_fixture(agent_id) end)
    %{agent_id: agent_id}
  end

  describe "security regression: public execute_action without a principal" do
    test "an empty context is refused and the action's effect never happens" do
      assert {:error, :invalid_authorization_principal} =
               Actions.execute_action(EffectProbe, %{test_pid: self()}, %{})

      refute_received {:effect_probe_ran, _}
    end

    test "the two-argument form, nil/empty agent_ids and non-map contexts are refused" do
      assert {:error, :invalid_authorization_principal} =
               Actions.execute_action(EffectProbe, %{test_pid: self()})

      for context <- [%{test_pid: self()}, %{agent_id: nil}, %{agent_id: ""}] do
        assert {:error, _reason} =
                 Actions.execute_action(EffectProbe, %{test_pid: self()}, context),
               "context #{inspect(context)} was not refused"
      end

      for context <- [nil, [agent_id: "agent_keyword"], "agent_string"] do
        assert {:error, :invalid_authorization_principal} =
                 Actions.execute_action(EffectProbe, %{test_pid: self()}, context)
      end

      refute_received {:effect_probe_ran, _}
    end
  end

  describe "security regression: public execute_action authorizes its principal" do
    test "an ungranted principal is refused before the action runs", %{agent_id: agent_id} do
      assert {:error, :unauthorized} =
               Actions.execute_action(EffectProbe, %{}, %{agent_id: agent_id, test_pid: self()})

      refute_received {:effect_probe_ran, _}
    end

    test "a forged admission envelope without the live frame does not admit",
         %{agent_id: agent_id} do
      forged = %Arbor.Actions.ActionAuthorization{
        principal_id: agent_id,
        action_module: EffectProbe,
        owner: self(),
        ref: make_ref()
      }

      context = %{agent_id: agent_id, action_authorization: forged, test_pid: self()}

      assert {:error, :unauthorized} = Actions.execute_action(EffectProbe, %{}, context)
      refute_received {:effect_probe_ran, _}
    end

    test "a granted principal is admitted and the action runs", %{agent_id: agent_id} do
      grant!(agent_id, @effect_resource)

      assert {:ok, %{effect: true}} =
               Actions.execute_action(EffectProbe, %{}, %{agent_id: agent_id, test_pid: self()})

      assert_received {:effect_probe_ran, ^agent_id}
    end
  end

  describe "security regression: nested calls from inside a running action" do
    test "a nested call to a different action is authorized on its own, not by the outer frame",
         %{agent_id: agent_id} do
      grant!(agent_id, @composite_resource)

      assert {:ok, %{nested: {:error, :unauthorized}}} =
               Actions.authorize_and_execute(agent_id, CompositeProbe, %{}, %{test_pid: self()})

      refute_received {:effect_probe_ran, _}
    end

    test "a legitimate nested call by an authorized principal still runs", %{agent_id: agent_id} do
      grant!(agent_id, @composite_resource)
      grant!(agent_id, @effect_resource)

      assert {:ok, %{nested: {:ok, %{effect: true}}}} =
               Actions.authorize_and_execute(agent_id, CompositeProbe, %{}, %{test_pid: self()})

      assert_received {:effect_probe_ran, ^agent_id}
    end

    test "an action re-entering itself inside its own admitted frame still runs",
         %{agent_id: agent_id} do
      grant!(agent_id, @reentrant_resource)

      assert {:ok, %{nested: {:ok, %{inner: true}}}} =
               Actions.authorize_and_execute(agent_id, ReentrantProbe, %{reenter: true}, %{
                 test_pid: self()
               })

      assert_received :reentrant_probe_inner_ran
    end
  end

  defp grant!(agent_id, resource) do
    assert {:ok, _capability} =
             Arbor.Security.grant_fixture(principal: agent_id, resource: resource)
  end
end
