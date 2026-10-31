defmodule Arbor.LLM.TestSupport.SensitivityFixture do
  @moduledoc """
  Scoped admission for in-memory test adapters, with fixture controls kept out
  of provider payloads. Call setup/1 only from synchronous test modules.
  Real and unlisted providers retain the configured production policy.
  """

  @context_key :test_fixture_sensitivity_policy
  @controls Module.concat(__MODULE__, Controls)

  def setup(adapters) when is_list(adapters) do
    keys = [:sensitivity_policy, :sensitivity_guarded_adapters, @context_key]
    previous = Enum.map(keys, &{&1, Application.fetch_env(:arbor_llm, &1)})
    delegate = Arbor.LLM.Config.sensitivity_policy()
    guarded = Arbor.LLM.Config.sensitivity_guarded_adapters()
    provider_names = Enum.map(adapters, fn adapter -> adapter.provider() end)

    if Enum.any?(provider_names, &Arbor.LLM.ProviderRegistry.known?/1) do
      raise ArgumentError,
            "fixture sensitivity adapters must use unique non-production provider names"
    end

    providers = MapSet.new(provider_names)

    ExUnit.Callbacks.start_supervised!(
      {Agent, fn -> %{} end},
      id: @controls
    )
    |> then(&Process.register(&1, @controls))

    Application.put_env(:arbor_llm, @context_key, %{providers: providers, delegate: delegate})
    Application.put_env(:arbor_llm, :sensitivity_guarded_adapters, Enum.uniq(guarded ++ adapters))
    Application.put_env(:arbor_llm, :sensitivity_policy, __MODULE__)

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_llm, key, value)
        {key, :error} -> Application.delete_env(:arbor_llm, key)
      end)
    end)

    :ok
  end

  @doc """
  Register exact fixture adapters without changing sensitivity clearance policy.

  Use this when an in-memory adapter's route must retain a real local provider
  name; endpoint locality and provider/model clearance remain production checks.
  """
  def register_guarded_adapters(adapters) when is_list(adapters) do
    previous = Application.fetch_env(:arbor_llm, :sensitivity_guarded_adapters)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_llm, :sensitivity_guarded_adapters, value)
        :error -> Application.delete_env(:arbor_llm, :sensitivity_guarded_adapters)
      end
    end)

    guarded = Arbor.LLM.Config.sensitivity_guarded_adapters()
    Application.put_env(:arbor_llm, :sensitivity_guarded_adapters, Enum.uniq(guarded ++ adapters))
    :ok
  end

  def put_controls(controls) when is_map(controls) do
    token = "fixture_" <> Integer.to_string(System.unique_integer([:positive]))
    Agent.update(@controls, &Map.put(&1, token, controls))
    %{fixture_control: token}
  end

  def get_controls(%{fixture_control: token}) when is_binary(token),
    do: Agent.get(@controls, &Map.fetch!(&1, token))

  def get_controls(_), do: %{}

  def authorize_llm_sensitivity(%{provider: provider} = destination) do
    case Application.get_env(:arbor_llm, @context_key) do
      %{providers: providers, delegate: delegate} ->
        if not Arbor.LLM.ProviderRegistry.known?(provider) and MapSet.member?(providers, provider) do
          :ok
        else
          delegate.authorize_llm_sensitivity(destination)
        end

      _ ->
        {:error, :invalid_destination}
    end
  end
end
