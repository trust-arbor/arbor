defmodule Mix.Tasks.Arbor.DoctorLocalProviderTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Arbor.Contracts.AI.{Capabilities, RuntimeContract}
  alias Mix.Tasks.Arbor.Doctor

  @catalog_table :arbor_provider_catalog

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.IO)

    table_preexisted? = :ets.whereis(@catalog_table) != :undefined

    previous_catalog =
      if table_preexisted?, do: :ets.lookup(@catalog_table, :catalog), else: []

    unless table_preexisted? do
      :ets.new(@catalog_table, [:named_table, :set, :public, read_concurrency: true])
    end

    :ets.insert(
      @catalog_table,
      {:catalog, local_failure_catalog(), System.monotonic_time(:millisecond)}
    )

    on_exit(fn ->
      Mix.shell(previous_shell)

      if table_preexisted? and :ets.whereis(@catalog_table) != :undefined do
        :ets.delete(@catalog_table, :catalog)
        Enum.each(previous_catalog, &:ets.insert(@catalog_table, &1))
      end
    end)

    :ok
  end

  test "unavailable local provider prints an actionable server hint" do
    output = capture_io(fn -> Doctor.run([]) end)

    assert output =~ "LM Studio: Start the local server at http://localhost:1234/v1"
    refute output =~ "LM Studio: \n"
  end

  test "verbose output handles a scalar local-provider failure" do
    output = capture_io(fn -> Doctor.run(["--verbose"]) end)

    assert output =~ "availability: FAILED"
    assert output =~ "LM Studio: Start the local server at http://localhost:1234/v1"
  end

  defp local_failure_catalog do
    capabilities = Capabilities.new()

    {:ok, contract} =
      RuntimeContract.new(
        provider: "lm_studio",
        display_name: "LM Studio",
        type: :local,
        probes: [
          %{type: :http, url: "http://localhost:1234/v1/models", timeout_ms: 2_000}
        ],
        capabilities: capabilities
      )

    %{
      "lm_studio" => %{
        provider: "lm_studio",
        display_name: "LM Studio",
        type: :local,
        available?: false,
        capabilities: capabilities,
        contract: contract,
        check_result: {:error, {:transport, :econnrefused}},
        adapter_module: Arbor.LLM.Adapter.ReqLLM
      }
    }
  end
end
