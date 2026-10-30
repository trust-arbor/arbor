defmodule Arbor.Security.RuntimeHostSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Security.Config
  alias Arbor.Security.Runtime

  @moduletag :fast
  @moduletag :security_regression
  @app :arbor_capabilities

  defmodule ConfiguredHost do
    @moduledoc false
    @behaviour Arbor.Security.Contracts.RuntimeHost

    @impl true
    def prepare_startup, do: :ok
    @impl true
    def start_profile, do: :activation_only
    @impl true
    def boot_profile, do: {:error, :not_bound}
    @impl true
    def provider_gate_child_spec(_name, _roots), do: {:error, :host_provider_not_ready}
    @impl true
    def start_provider_gate_supervisor(_children, _supervisor, _gate),
      do: {:error, :host_provider_not_ready}
  end

  defmodule RejectedStartupHost do
    @moduledoc false
    @behaviour Arbor.Security.Contracts.RuntimeHost

    @impl true
    def prepare_startup, do: {:error, :not_bound}
    @impl true
    defdelegate start_profile(), to: ConfiguredHost
    @impl true
    defdelegate boot_profile(), to: ConfiguredHost
    @impl true
    defdelegate provider_gate_child_spec(name, roots), to: ConfiguredHost
    @impl true
    defdelegate start_provider_gate_supervisor(children, supervisor, gate), to: ConfiguredHost
  end

  defmodule IncompleteHost do
    @moduledoc false
    def prepare_startup, do: :ok
  end

  defmodule CrashingHost do
    @moduledoc false
    @behaviour Arbor.Security.Contracts.RuntimeHost

    @impl true
    def prepare_startup, do: raise("private-runtime-host-exception")
    @impl true
    def start_profile, do: exit({:private_runtime_host_exit, self()})
    @impl true
    def boot_profile, do: throw(:private_runtime_host_throw)
    @impl true
    def provider_gate_child_spec(_name, _roots), do: raise("private-runtime-host-exception")
    @impl true
    def start_provider_gate_supervisor(_children, _supervisor, _gate),
      do: exit(:private_runtime_host_exit)
  end

  defmodule MalformedHost do
    @moduledoc false
    @behaviour Arbor.Security.Contracts.RuntimeHost

    @impl true
    def prepare_startup, do: :ready
    @impl true
    def start_profile, do: :unknown_profile
    @impl true
    def boot_profile, do: {:ok, :not_a_snapshot}
    @impl true
    def provider_gate_child_spec(_name, _roots), do: :none
    @impl true
    def start_provider_gate_supervisor(_children, _supervisor, _gate), do: :ignore
  end

  setup do
    previous = Map.new([:runtime_host, :runtime], &{&1, Application.fetch_env(@app, &1)})

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, original} -> Application.put_env(@app, key, original)
          :error -> Application.delete_env(@app, key)
        end
      end
    end)

    :ok
  end

  test "absent or nil host admits only standalone full and activation_only profiles" do
    Application.delete_env(@app, :runtime_host)
    Application.delete_env(@app, :runtime)
    assert Runtime.prepare_startup() == :ok
    assert Runtime.start_profile() == :full

    Application.put_env(@app, :runtime_host, nil)

    for profile <- [:full, :activation_only] do
      Application.put_env(@app, :runtime, start_profile: profile)
      assert Runtime.prepare_startup() == :ok
      assert Runtime.start_profile() == profile
      assert Runtime.boot_profile() == {:error, :not_bound}
      assert Runtime.provider_gate_child_spec(Arbor.Security.ProviderGate, [:req]) == :none
    end
  end

  test "unknown profiles and extra standalone fields reject before authority startup" do
    Application.put_env(@app, :runtime_host, nil)

    for {runtime, reason} <- [
          {[start_profile: :unknown_profile], {:invalid_start_profile, :unknown_profile}},
          {[start_profile: :full, extra: true], :invalid_runtime_configuration}
        ] do
      Application.put_env(@app, :runtime, runtime)
      assert Runtime.prepare_startup() == {:error, reason}
      assert_startup_untouched(reason)
    end
  end

  test "configured host is authoritative and its provider error cannot select standalone" do
    Application.put_env(@app, :runtime_host, ConfiguredHost)
    Application.put_env(@app, :runtime, start_profile: :full)

    assert Runtime.prepare_startup() == :ok
    assert Runtime.start_profile() == :activation_only

    assert Runtime.provider_gate_child_spec(Arbor.Security.ProviderGate, [:req]) ==
             {:error, :host_provider_not_ready}

    assert Runtime.start_provider_gate_supervisor(
             [],
             Arbor.Security.Supervisor,
             Arbor.Security.ProviderGate
           ) ==
             {:error, :host_provider_not_ready}

    Application.put_env(@app, :runtime_host, RejectedStartupHost)
    assert Runtime.prepare_startup() == {:error, :not_bound}
    assert_startup_untouched(:not_bound)
  end

  test "unavailable and incomplete configured providers never reopen standalone startup" do
    Application.put_env(@app, :runtime, start_profile: :full)

    for provider <- [false, __MODULE__.UnavailableHost, IncompleteHost] do
      Application.put_env(@app, :runtime_host, provider)
      assert Runtime.prepare_startup() == {:error, :runtime_host_unavailable}
      assert Runtime.start_profile() == {:error, :runtime_host_unavailable}
      assert Runtime.boot_profile() == {:error, :runtime_host_unavailable}
      assert_startup_untouched(:runtime_host_unavailable)
    end
  end

  test "provider exceptions exits and throws are redacted and leave live authority untouched" do
    Application.put_env(@app, :runtime_host, CrashingHost)
    Application.put_env(@app, :runtime, start_profile: :full)

    assert Runtime.prepare_startup() == {:error, :runtime_host_unavailable}
    assert Runtime.start_profile() == {:error, :runtime_host_unavailable}
    assert Runtime.boot_profile() == {:error, :runtime_host_unavailable}
    assert_startup_untouched(:runtime_host_unavailable)
  end

  test "malformed configured responses cannot masquerade as standalone absence or valid profiles" do
    Application.put_env(@app, :runtime_host, MalformedHost)
    Application.put_env(@app, :runtime, start_profile: :full)

    assert Runtime.prepare_startup() == {:error, :invalid_runtime_host_response}
    assert Runtime.start_profile() == {:error, {:invalid_start_profile, :unknown_profile}}
    assert Runtime.boot_profile() == {:error, :invalid_runtime_host_response}

    assert Runtime.provider_gate_child_spec(Arbor.Security.ProviderGate, [:req]) ==
             {:error, :invalid_runtime_host_response}

    assert Runtime.start_provider_gate_supervisor(
             [],
             Arbor.Security.Supervisor,
             Arbor.Security.ProviderGate
           ) ==
             {:error, :invalid_runtime_host_response}

    assert_startup_untouched(:invalid_runtime_host_response)
  end

  defp assert_startup_untouched(reason) do
    before = authority_snapshot()
    assert {:error, ^reason} = Arbor.Security.Application.start(:normal, [])
    assert authority_snapshot() == before
  end

  defp authority_snapshot do
    supervisor = Process.whereis(Arbor.Security.Supervisor)
    assert is_pid(supervisor)
    assert Process.alive?(supervisor)

    claims =
      for table <- [Config.EnforcementToggleClaim, Config.AuthorityRootClaim] do
        case :ets.whereis(table) do
          :undefined -> {table, :absent}
          tid -> {table, tid, :ets.info(tid, :owner), Enum.sort(:ets.tab2list(tid))}
        end
      end

    %{
      supervisor: supervisor,
      children: Enum.sort(Supervisor.which_children(supervisor)),
      claims: claims,
      enforcement_freeze: :persistent_term.get({Config, :enforcement_toggles}, :not_frozen),
      authority_freeze: :persistent_term.get({Config, :authority_root}, :not_frozen)
    }
  end
end
