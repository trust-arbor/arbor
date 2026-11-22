defmodule Arbor.LLM.TransportContractTest do
  use ExUnit.Case, async: false

  alias Arbor.LLM.TestSupport.TransportContract

  @moduletag :fast

  test "empty raw models are literal routes bound into the finite policy identity" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    origin = "http://127.0.0.1:#{port}"

    TransportContract.setup([
      TransportContract.route("unknown", "declared-model", :public, origin)
    ])

    empty = %{
      provider: "unknown",
      model: "",
      sensitivity: :public,
      runtime: :arbor,
      base_url: origin
    }

    assert {:error, :destination_disallowed} =
             TransportContract.authorize_llm_sensitivity(empty)

    assert {:ok, before_identity} = TransportContract.llm_sensitivity_identity()

    TransportContract.allow([
      TransportContract.route("unknown", "", :public, origin)
    ])

    assert :ok = TransportContract.authorize_llm_sensitivity(empty)

    for unlisted <- [
          %{empty | model: "different-model"},
          %{empty | provider: "openai"},
          %{empty | base_url: "http://127.0.0.2:#{port}"},
          %{empty | base_url: nil},
          %{empty | sensitivity: :internal}
        ] do
      assert {:error, :destination_disallowed} =
               TransportContract.authorize_llm_sensitivity(unlisted)
    end

    assert {:ok, after_identity} = TransportContract.llm_sensitivity_identity()
    refute after_identity["configuration_digest"] == before_identity["configuration_digest"]
    assert after_identity["implementation"] == before_identity["implementation"]

    assert after_identity["implementation"] == [
             %{
               "module" => Atom.to_string(TransportContract),
               "md5" => Base.encode16(TransportContract.module_info(:md5), case: :lower)
             }
           ]
  end
end
