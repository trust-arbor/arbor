defmodule Arbor.LLM.PackageConfigSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.AI.{Capabilities, RuntimeContract}

  alias Arbor.LLM.{
    Client,
    Config,
    ContentPart,
    Message,
    ProviderCatalog,
    Request,
    Response,
    ToolLoop
  }

  alias Arbor.LLM.TestSupport.SensitivityFixture

  @moduletag :fast
  @moduletag :security_regression
  @provider "package_registry_fixture"

  defmodule FirstAdapter do
    alias Arbor.LLM.PackageConfigSecurityRegressionTest

    def provider, do: "package_registry_fixture"
    def complete(_request, _opts), do: {:error, :fixture_only}
    def available?, do: true

    def runtime_contract do
      send(self(), {:external_contract, __MODULE__})
      PackageConfigSecurityRegressionTest.contract("First")
    end
  end

  defmodule SecondAdapter do
    alias Arbor.LLM.PackageConfigSecurityRegressionTest

    def provider, do: "package_registry_fixture"
    def complete(_request, _opts), do: {:error, :fixture_only}
    def available?, do: true

    def runtime_contract do
      send(self(), {:external_contract, __MODULE__})
      PackageConfigSecurityRegressionTest.contract("Second")
    end
  end

  defmodule CredentialPendingAdapter do
    alias Arbor.LLM.PackageConfigSecurityRegressionTest

    def provider, do: "package_registry_fixture"
    def complete(_request, _opts), do: {:error, :fixture_login_required}
    def available?, do: true

    def runtime_contract do
      PackageConfigSecurityRegressionTest.contract("Needs credential", [
        %{name: "ARBOR_PACKAGE_REGISTRY_FIXTURE_CREDENTIAL", required: true}
      ])
    end
  end

  defmodule LegacyAdapter do
    def provider, do: "acp"
    def complete(_request, _opts), do: {:error, :fixture_only}
    def available?, do: true

    def runtime_contract do
      {:ok, contract} =
        RuntimeContract.new(provider: "acp", display_name: "Fixture ACP", type: :cli)

      contract
    end
  end

  defmodule AllowPolicy do
    def authorize_llm_sensitivity(_destination), do: :ok
  end

  defmodule ToolAdapter do
    @behaviour Arbor.LLM.ProviderAdapter

    alias Arbor.LLM.TestSupport.SensitivityFixture
    def provider, do: "package_audit_fixture"

    def complete(request, _opts) do
      observer =
        request.provider_options
        |> SensitivityFixture.get_controls()
        |> Map.fetch!(:observer)

      send(observer, :tool_adapter_requested)

      if Enum.any?(request.messages, &(&1.role == :tool)) do
        {:ok, %Response{text: "done", finish_reason: :stop, raw: %{}}}
      else
        {:ok,
         %Response{
           text: "",
           finish_reason: :tool_calls,
           raw: %{},
           content_parts: [ContentPart.tool_call("package_audit_call", "fixture_effect", %{})]
         }}
      end
    end
  end

  defmodule Executor do
    def execute(_name, _args, _workdir, _opts) do
      send(self(), :tool_effect)
      {:ok, "effect"}
    end
  end

  setup do
    previous_client = :persistent_term.get({Client, :default_client}, :missing)
    Client.clear_default_client()

    keys = [
      :tool_invocation_auditor,
      :sensitivity_policy,
      :external_provider_adapters,
      :discover_local_providers,
      :lm_studio,
      :ollama
    ]

    previous = Enum.map(keys, &{&1, Application.fetch_env(:arbor_llm, &1)})
    Enum.each(keys, &Application.delete_env(:arbor_llm, &1))
    Application.put_env(:arbor_llm, :discover_local_providers, false)
    # A bound, non-listening private socket excludes any operator local server
    # and keeps the existing catalog's local-inventory probes fail-closed.
    {:ok, socket} = :socket.open(:inet, :stream, :tcp)
    :ok = :socket.bind(socket, %{family: :inet, addr: {127, 0, 0, 1}, port: 0})
    {:ok, %{port: port}} = :socket.sockname(socket)

    for provider <- [:lm_studio, :ollama] do
      Application.put_env(:arbor_llm, provider, base_url: "http://127.0.0.1:#{port}/v1")
    end

    clear_catalog()

    on_exit(fn ->
      _ = :socket.close(socket)

      case previous_client do
        :missing -> Client.clear_default_client()
        entry -> :persistent_term.put({Client, :default_client}, entry)
      end

      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_llm, key, value)
        {key, :error} -> Application.delete_env(:arbor_llm, key)
      end)

      clear_catalog()
    end)

    :ok
  end

  test "security regression: absent and nil host auditors deny before an executor effect" do
    SensitivityFixture.setup([ToolAdapter])

    for setting <- [:absent, nil] do
      if setting == :absent,
        do: Application.delete_env(:arbor_llm, :tool_invocation_auditor),
        else: Application.put_env(:arbor_llm, :tool_invocation_auditor, setting)

      assert {:ok, _} = run_tool()
      assert_receive :tool_adapter_requested
      refute_receive :tool_effect
      assert is_nil(Config.tool_invocation_auditor())
    end

    Application.put_env(:arbor_llm, :tool_invocation_auditor, :disabled)
    assert {:ok, _} = run_tool()
    assert_receive :tool_effect
  end

  test "security regression: missing host policy stays closed with the package classifier" do
    assert {:error, {:sensitivity_blocked, :policy_unavailable}} =
             Arbor.LLM.authorize_sensitivity(@provider, "fixture", "public text")

    assert is_nil(Config.sensitivity_policy())

    Application.put_env(:arbor_llm, :sensitivity_policy, AllowPolicy)
    assert :ok = Arbor.LLM.authorize_sensitivity(@provider, "fixture", "public text")
  end

  test "security regression: client and cached catalog follow trusted registry replacement" do
    Application.put_env(:arbor_llm, :external_provider_adapters, %{@provider => FirstAdapter})
    assert {:ok, FirstAdapter} = selected_adapter()
    assert {:ok, %{display_name: "First"}} = ProviderCatalog.get_contract(@provider)
    assert_receive {:external_contract, FirstAdapter}
    assert {:ok, %{display_name: "First"}} = ProviderCatalog.get_contract(@provider)
    refute_receive {:external_contract, FirstAdapter}

    Application.put_env(:arbor_llm, :external_provider_adapters, %{@provider => SecondAdapter})
    assert {:ok, SecondAdapter} = selected_adapter()
    assert {:ok, %{display_name: "Second"}} = ProviderCatalog.get_contract(@provider)
    assert_receive {:external_contract, SecondAdapter}

    opts = [external_provider_adapters: %{@provider => FirstAdapter}]
    assert {:ok, SecondAdapter} = selected_adapter(opts)

    assert Enum.find(ProviderCatalog.all(opts), &(&1.provider == @provider)).adapter_module ==
             SecondAdapter

    refute_receive {:external_contract, FirstAdapter}

    Application.delete_env(:arbor_llm, :external_provider_adapters)
    assert {:error, {:unknown_provider, @provider}} = selected_adapter(opts)
    assert {:error, :not_found} = ProviderCatalog.get_contract(@provider)
  end

  test "security regression: automatic default client follows trusted selection while explicit clients remain explicit" do
    Application.put_env(:arbor_llm, :external_provider_adapters, %{@provider => FirstAdapter})
    assert {:ok, FirstAdapter} = selected_default_adapter()

    Application.put_env(:arbor_llm, :external_provider_adapters, %{@provider => SecondAdapter})
    assert {:ok, SecondAdapter} = selected_default_adapter()

    Application.delete_env(:arbor_llm, :external_provider_adapters)
    assert {:error, {:unknown_provider, @provider}} = selected_default_adapter()

    explicit = Client.new(adapters: %{@provider => FirstAdapter}, default_provider: @provider)
    assert :ok = Client.set_default_client(explicit)
    Application.put_env(:arbor_llm, :external_provider_adapters, %{@provider => SecondAdapter})
    assert {:ok, FirstAdapter} = selected_default_adapter()

    assert :ok = Client.clear_default_client()
    assert {:ok, SecondAdapter} = selected_default_adapter()
  end

  test "known external registration remains independent of credential readiness" do
    key = "ARBOR_PACKAGE_REGISTRY_FIXTURE_CREDENTIAL"
    previous = System.fetch_env(key)
    System.delete_env(key)

    on_exit(fn ->
      case previous do
        {:ok, value} -> System.put_env(key, value)
        :error -> System.delete_env(key)
      end
    end)

    Application.put_env(:arbor_llm, :external_provider_adapters, %{
      @provider => CredentialPendingAdapter
    })

    assert {:ok, CredentialPendingAdapter} = selected_adapter()
    entry = Enum.find(ProviderCatalog.all(), &(&1.provider == @provider))
    refute entry.available?
    assert {:error, _} = entry.check_result
  end

  test "legacy ACP discovery switch uses the shared configured selection" do
    Application.put_env(:arbor_llm, :external_provider_adapters, %{"acp" => LegacyAdapter})
    assert {:ok, LegacyAdapter} = selected_adapter([], "acp")
    assert Enum.any?(ProviderCatalog.all(), &(&1.provider == "acp"))
    assert {:error, {:unknown_provider, "acp"}} = selected_adapter([discover_acp: false], "acp")
    refute Enum.any?(ProviderCatalog.all(discover_acp: false), &(&1.provider == "acp"))
  end

  test "security regression: malformed registry names and module values do not register routes" do
    for registry <- [
          nil,
          [],
          %{"" => FirstAdapter},
          %{<<255>> => FirstAdapter},
          %{"with space" => FirstAdapter},
          %{@provider => "Elixir.Untrusted"},
          %{@provider => nil},
          %{@provider => false}
        ] do
      Application.put_env(:arbor_llm, :external_provider_adapters, registry)
      assert {:error, {:unknown_provider, @provider}} = selected_adapter()
      assert {:error, :not_found} = ProviderCatalog.get_contract(@provider)
      refute_receive {:external_contract, FirstAdapter}
    end
  end

  def contract(display_name, env_vars \\ []) do
    {:ok, contract} =
      RuntimeContract.new(
        provider: @provider,
        display_name: display_name,
        type: :api,
        env_vars: env_vars,
        capabilities: Capabilities.new()
      )

    contract
  end

  defp client(opts \\ []) do
    Client.from_env(
      Keyword.merge(
        [
          discover_local: false,
          discover_oauth: false,
          discover_keyless: false,
          default_provider: @provider
        ],
        opts
      )
    )
  end

  defp selected_adapter(opts \\ [], provider \\ @provider) do
    Client.adapter_for(client(opts), %Request{provider: provider, model: "fixture"})
  end

  defp selected_default_adapter do
    client =
      Client.default_client(
        discover_local: false,
        discover_oauth: false,
        discover_keyless: false,
        default_provider: @provider
      )

    Client.adapter_for(client, %Request{provider: @provider, model: "fixture"})
  end

  defp clear_catalog do
    if :ets.whereis(:arbor_provider_catalog) != :undefined,
      do: :ets.delete_all_objects(:arbor_provider_catalog)
  end

  defp run_tool do
    client =
      Client.new(default_provider: ToolAdapter.provider()) |> Client.register_adapter(ToolAdapter)

    request = %Request{
      provider: ToolAdapter.provider(),
      model: "fixture",
      messages: [Message.new(:user, "use the tool")],
      provider_options: SensitivityFixture.put_controls(%{observer: self()})
    }

    tools = [
      %{
        "type" => "function",
        "function" => %{
          "name" => "fixture_effect",
          "description" => "fixture",
          "parameters" => %{"type" => "object", "properties" => %{}}
        }
      }
    ]

    ToolLoop.run(client, request,
      tool_executor: Executor,
      tools: tools,
      max_turns: 3,
      agent_id: "agent_package_audit_fixture",
      workdir: System.tmp_dir!()
    )
  end
end
