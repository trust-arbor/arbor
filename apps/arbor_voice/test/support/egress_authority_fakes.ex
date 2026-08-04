defmodule Arbor.Voice.Test.EgressAuthorityFakes do
  @moduledoc false

  alias __MODULE__.Store

  @route %{
    destination: "api.x.ai",
    provider: "xai",
    runtime: "arbor",
    model: "grok-voice-latest"
  }

  def reset(opts \\ []) do
    Store.ensure_started()

    Store.replace(%{
      events: [],
      modes: Map.new(Keyword.get(opts, :modes, [])),
      claimed_user: Keyword.get(opts, :claimed_user),
      next_id: 1,
      capabilities: %{}
    })
  end

  def set_mode(key, mode), do: Store.update(&put_in(&1, [:modes, key], mode))
  def set_claimed_user(user_id), do: Store.update(&Map.put(&1, :claimed_user, user_id))
  def events, do: Store.get(&Enum.reverse(&1.events))
  def capabilities, do: Store.get(& &1.capabilities)

  def active_capabilities do
    capabilities()
    |> Map.values()
    |> Enum.reject(& &1.revoked)
  end

  def record(event),
    do: Store.update(&Map.update!(&1, :events, fn events -> [event | events] end))

  def mode(key, default) do
    selected = Store.get(&Map.get(&1.modes, key, :default))
    interpret(selected, default)
  end

  def next_capability_id do
    Store.get_and_update(fn state ->
      id = "cap_" <> (state.next_id |> Integer.to_string(16) |> String.pad_leading(32, "0"))
      {id, %{state | next_id: state.next_id + 1}}
    end)
  end

  def put_capability(capability) do
    Store.update(fn state ->
      key = {capability.principal_id, capability.resource_uri}

      capabilities =
        state.capabilities
        |> Enum.reject(fn {_id, existing} ->
          {existing.principal_id, existing.resource_uri} == key
        end)
        |> Map.new()
        |> Map.put(capability.id, capability)

      %{state | capabilities: capabilities}
    end)
  end

  def capability(id), do: Store.get(&Map.get(&1.capabilities, id))

  def replace_with_substitute(id) do
    case capability(id) do
      %{kind: :route} = capability ->
        substitute_id = next_capability_id()
        put_capability(%{capability | id: substitute_id, revoked: false})
        {:ok, substitute_id}

      _ ->
        {:error, :not_found}
    end
  end

  def revoke_capability(id) do
    Store.get_and_update(fn state ->
      case Map.fetch(state.capabilities, id) do
        {:ok, capability} ->
          capabilities = Map.put(state.capabilities, id, %{capability | revoked: true})
          {:ok, %{state | capabilities: capabilities}}

        :error ->
          {{:error, :not_found}, state}
      end
    end)
  end

  def claimed_user(default), do: Store.get(&(&1.claimed_user || default))
  def route, do: @route

  defp interpret(:default, default), do: default.()
  defp interpret(:ok, default), do: default.()
  defp interpret({:return, value}, _default), do: value
  defp interpret({:raise, reason}, _default), do: raise(reason)
  defp interpret({:throw, reason}, _default), do: throw(reason)
  defp interpret({:exit, reason}, _default), do: exit(reason)
  defp interpret(_malformed, _default), do: :malformed

  defmodule Store do
    @moduledoc false
    use Agent

    def ensure_started do
      case Process.whereis(__MODULE__) do
        nil ->
          case Agent.start_link(fn -> %{} end, name: __MODULE__) do
            {:ok, _pid} -> :ok
            {:error, {:already_started, _pid}} -> :ok
          end

        _pid ->
          :ok
      end
    end

    def replace(state), do: Agent.update(__MODULE__, fn _ -> state end)
    def update(fun), do: Agent.update(__MODULE__, fun)
    def get(fun), do: Agent.get(__MODULE__, fun)
    def get_and_update(fun), do: Agent.get_and_update(__MODULE__, fun)
  end

  defmodule AI do
    @moduledoc false
    alias Arbor.Voice.Test.EgressAuthorityFakes

    def egress_tier_for(provider, destination) do
      EgressAuthorityFakes.record({:classify, provider, destination})

      EgressAuthorityFakes.mode(:classify, fn ->
        if provider == "xai" and destination == "https://api.x.ai",
          do: :external_provider,
          else: :unknown
      end)
    end
  end

  defmodule Trust do
    @moduledoc false
    alias Arbor.Voice.Test.EgressAuthorityFakes

    def authorize_egress(agent_id, tier, opts) do
      EgressAuthorityFakes.record({:trust, agent_id, tier, opts})
      EgressAuthorityFakes.mode(:trust, fn -> :allow end)
    end
  end

  defmodule Security do
    @moduledoc false
    alias Arbor.Voice.Test.EgressAuthorityFakes

    def authorize_and_issue_delivery_receipt(user_id, resource, action, opts) do
      token_present? = Keyword.get(opts, :session_token) not in [nil, ""]
      EgressAuthorityFakes.record({:receipt_issue, user_id, resource, action, token_present?})

      EgressAuthorityFakes.mode(:receipt_issue, fn ->
        {:ok, {:voice_test_receipt, user_id, resource, action}}
      end)
    end

    def consume_delivery_receipt(receipt, resource, action) do
      EgressAuthorityFakes.record({:receipt_consume, resource, action})

      EgressAuthorityFakes.mode(:receipt_consume, fn ->
        case receipt do
          {:voice_test_receipt, user_id, ^resource, ^action} ->
            {:ok, EgressAuthorityFakes.claimed_user(user_id)}

          _ ->
            {:error, :invalid_receipt}
        end
      end)
    end

    def uri_registered?(resource) do
      EgressAuthorityFakes.record({:uri_registered, resource})

      EgressAuthorityFakes.mode(:uri_registered, fn ->
        String.starts_with?(resource, "arbor://voice/realtime/xai/session_")
      end)
    end

    def grant_capability_id(opts) do
      EgressAuthorityFakes.record({:grant, redacted_grant(opts)})

      EgressAuthorityFakes.mode(:grant, fn ->
        id = EgressAuthorityFakes.next_capability_id()

        capability = %{
          id: id,
          kind: :route,
          principal_id: Keyword.fetch!(opts, :principal),
          resource_uri: Keyword.fetch!(opts, :resource),
          session_id: Keyword.fetch!(opts, :session_id),
          task_id: Keyword.fetch!(opts, :task_id),
          principal_scope: Keyword.fetch!(opts, :principal_scope),
          constraints: Keyword.fetch!(opts, :constraints),
          revoked: false
        }

        EgressAuthorityFakes.put_capability(capability)
        {:ok, id}
      end)
    end

    def authorize(principal_id, resource, effect, opts) do
      EgressAuthorityFakes.record({:authorize, principal_id, resource, effect, opts})

      EgressAuthorityFakes.mode({:authorize, effect}, fn ->
        EgressAuthorityFakes.mode(:authorize, fn ->
          id = Keyword.get(opts, :exact_capability_id)
          expected_session_id = Keyword.get(opts, :session_id)
          expected_task_id = Keyword.get(opts, :task_id)
          expected_scope = Keyword.get(opts, :principal_scope)

          case EgressAuthorityFakes.capability(id) do
            %{
              kind: :route,
              principal_id: ^principal_id,
              resource_uri: ^resource,
              session_id: ^expected_session_id,
              task_id: ^expected_task_id,
              principal_scope: ^expected_scope,
              revoked: false
            } ->
              {:ok, :authorized}

            _ ->
              {:error, :unauthorized}
          end
        end)
      end)
    end

    def issue_disclosure_capability_id(opts) do
      EgressAuthorityFakes.record({:disclosure_issue, opts})

      EgressAuthorityFakes.mode(:issue_disclosure, fn ->
        id = EgressAuthorityFakes.next_capability_id()

        capability = %{
          id: id,
          kind: :disclosure,
          principal_id: Keyword.fetch!(opts, :principal_id),
          resource_uri: "disclosure://#{id}",
          session_id: Keyword.fetch!(opts, :session_id),
          task_id: Keyword.fetch!(opts, :task_id),
          principal_scope: Keyword.fetch!(opts, :principal_scope),
          destination: Keyword.fetch!(opts, :destination),
          provider: Keyword.fetch!(opts, :provider),
          runtime: Keyword.fetch!(opts, :runtime),
          model: Keyword.fetch!(opts, :model),
          revoked: false
        }

        EgressAuthorityFakes.put_capability(capability)
        {:ok, id}
      end)
    end

    def validate_disclosure_capability(principal_id, id, opts) do
      EgressAuthorityFakes.record({:disclosure_validate, principal_id, id, opts})

      EgressAuthorityFakes.mode(:validate_disclosure, fn ->
        expected_session_id = Keyword.get(opts, :session_id)
        expected_task_id = Keyword.get(opts, :task_id)
        expected_scope = Keyword.get(opts, :principal_scope)
        expected_destination = Keyword.get(opts, :egress_destination)
        expected_provider = Keyword.get(opts, :egress_provider)
        expected_runtime = Keyword.get(opts, :egress_runtime)
        expected_model = Keyword.get(opts, :egress_model)

        case EgressAuthorityFakes.capability(id) do
          %{
            kind: :disclosure,
            principal_id: ^principal_id,
            session_id: ^expected_session_id,
            task_id: ^expected_task_id,
            principal_scope: ^expected_scope,
            destination: ^expected_destination,
            provider: ^expected_provider,
            runtime: ^expected_runtime,
            model: ^expected_model,
            revoked: false
          } ->
            :ok

          _ ->
            {:error, :invalid_disclosure}
        end
      end)
    end

    def revoke(capability_id) do
      EgressAuthorityFakes.record({:revoke, capability_id})

      EgressAuthorityFakes.mode({:revoke, capability_id}, fn ->
        EgressAuthorityFakes.mode(:revoke, fn ->
          EgressAuthorityFakes.revoke_capability(capability_id)
        end)
      end)
    end

    defp redacted_grant(opts) do
      Keyword.take(opts, [
        :principal,
        :resource,
        :expires_at,
        :delegation_depth,
        :session_id,
        :task_id,
        :principal_scope,
        :constraints
      ])
    end
  end
end
