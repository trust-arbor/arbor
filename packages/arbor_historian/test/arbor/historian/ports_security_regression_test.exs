defmodule Arbor.Historian.PortsSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag :fast
  alias Arbor.Historian.Ports.{Authorizer, AuthoritySource, Observation}

  defmodule Echo do
    @moduledoc false
    def authorize(_principal, _resource, _action, _opts),
      do: reply(:authorize, {:ok, :authorized})

    def authorize_self_scoped(_principal, _resource, _owner, _prefix, _action, _opts),
      do: reply(:self_scoped, {:ok, :authorized})

    def reconcile_authority_audit, do: reply(:reconcile, :ok)
    def authority_audit_delivery_batch, do: reply(:batch, {:ok, []})
    def acknowledge_authority_audit(_id, _digest), do: reply(:acknowledge, {:ok, :committed})

    defp reply(operation, result) do
      send(Application.fetch_env!(:arbor_historian, :port_test_pid), {operation, self()})
      result
    end
  end

  defmodule Broken do
    @moduledoc false
    def authorize(_, _, _, _), do: raise("private provider detail")
    def authorize_self_scoped(_, _, _, _, _, _), do: exit(:private_provider_detail)
    def reconcile_authority_audit, do: throw(:private_provider_detail)
    def authority_audit_delivery_batch, do: raise("private provider detail")
    def acknowledge_authority_audit(_, _), do: exit(:private_provider_detail)
  end

  defmodule Malformed do
    @moduledoc false
    def authorize(_, _, _, _), do: {:ok, true}
    def authorize_self_scoped(_, _, _, _, _, _), do: {:ok, :pending_approval, %{private: true}}
    def reconcile_authority_audit, do: {:ok, :reconciled}
    def authority_audit_delivery_batch, do: {:ok, [nil]}
    def acknowledge_authority_audit(_, _), do: :ok
  end

  defmodule Incomplete do
    @moduledoc false
    def authorize(_, _, _, _), do: flunk_side_effect()
    def reconcile_authority_audit, do: flunk_side_effect()

    defp flunk_side_effect,
      do: send(Application.fetch_env!(:arbor_historian, :port_test_pid), :incomplete_invoked)
  end

  setup do
    keys = [:authorizer, :authority_source, :event_provider, :port_test_pid]
    previous = Map.new(keys, &{&1, Application.fetch_env(:arbor_historian, &1)})
    Application.put_env(:arbor_historian, :port_test_pid, self())

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_historian, key, value)
        {key, :error} -> Application.delete_env(:arbor_historian, key)
      end)
    end)

    :ok
  end

  test "security regression: absent or invalid static authority bindings never fall back" do
    for provider <- [nil, false, "provider", __MODULE__.Missing, Incomplete] do
      configure(provider)

      assert {:error, {:unauthorized, :security_provider_unavailable}} =
               Arbor.Historian.authorize_query("agent_port", category: :security)

      assert {:error, :security_provider_unavailable} =
               Authorizer.authorize_self_scoped(
                 "a",
                 "arbor://historian/query/a",
                 "a",
                 "arbor://historian/query",
                 :query,
                 []
               )

      assert {:error, :security_provider_unavailable} =
               AuthoritySource.reconcile_authority_audit()

      assert {:error, :security_provider_unavailable} =
               AuthoritySource.authority_audit_delivery_batch()

      assert {:error, :security_provider_unavailable} =
               AuthoritySource.acknowledge_authority_audit("id", "digest")
    end

    refute_receive :incomplete_invoked
  end

  test "security regression: crashes and malformed successes return closed errors without provider details" do
    configure(Broken)
    assert {:error, :security_provider_unavailable} = Authorizer.authorize("a", "uri", :query, [])

    assert {:error, :security_provider_unavailable} =
             Authorizer.authorize_self_scoped("a", "uri", "a", "parent", :query, [])

    assert {:error, :security_provider_unavailable} = AuthoritySource.reconcile_authority_audit()

    assert {:error, :security_provider_unavailable} =
             AuthoritySource.authority_audit_delivery_batch()

    assert {:error, :security_provider_unavailable} =
             AuthoritySource.acknowledge_authority_audit("id", "digest")

    configure(Malformed)
    assert {:error, :invalid_authorization_reply} = Authorizer.authorize("a", "uri", :query, [])

    assert {:error, :invalid_authorization_reply} =
             Authorizer.authorize_self_scoped("a", "uri", "a", "parent", :query, [])

    assert {:error, :invalid_authority_source_reply} = AuthoritySource.reconcile_authority_audit()

    assert {:error, :invalid_authority_source_reply} =
             AuthoritySource.authority_audit_delivery_batch()

    assert {:error, :invalid_authority_source_reply} =
             AuthoritySource.acknowledge_authority_audit("id", "digest")
  end

  test "journal and authorization callbacks execute inline in the actual caller PID" do
    configure(Echo)
    caller = self()
    assert {:ok, :authorized} = Authorizer.authorize("a", "uri", :query, [])
    assert_receive {:authorize, ^caller}

    assert {:ok, :authorized} =
             Authorizer.authorize_self_scoped("a", "uri", "a", "parent", :query, [])

    assert_receive {:self_scoped, ^caller}
    assert :ok = AuthoritySource.reconcile_authority_audit()
    assert_receive {:reconcile, ^caller}
    assert {:ok, []} = AuthoritySource.authority_audit_delivery_batch()
    assert_receive {:batch, ^caller}
    assert {:ok, :committed} = AuthoritySource.acknowledge_authority_audit("id", "digest")
    assert_receive {:acknowledge, ^caller}
  end

  test "observation absence and failure do not become authorization or durable acknowledgement" do
    Application.delete_env(:arbor_historian, :event_provider)
    assert :ok = Observation.emit(:historian, :example, %{})
    Application.put_env(:arbor_historian, :event_provider, Broken)
    assert :ok = Observation.emit(:historian, :example, %{})
    configure(nil)

    assert {:error, :security_provider_unavailable} =
             AuthoritySource.acknowledge_authority_audit("id", "digest")
  end

  defp configure(provider) do
    Application.put_env(:arbor_historian, :authorizer, provider)
    Application.put_env(:arbor_historian, :authority_source, provider)
  end
end
