defmodule Arbor.Persistence.VectorPublicBoundarySecurityRegressionTest do
  use ExUnit.Case, async: false

  defmodule RegressionBackend do
    def search(agent_id, vector, opts) do
      send(self(), {:regression_backend_called, agent_id, vector, opts})
      {:ok, []}
    end
  end

  setup do
    original = Application.get_env(:arbor_persistence, :vector_store_backend, :not_configured)
    Application.put_env(:arbor_persistence, :vector_store_backend, RegressionBackend)

    on_exit(fn ->
      case original do
        :not_configured -> Application.delete_env(:arbor_persistence, :vector_store_backend)
        backend -> Application.put_env(:arbor_persistence, :vector_store_backend, backend)
      end
    end)

    :ok
  end

  test "security regression: malformed vector input never reaches a backend" do
    opts = [
      model_id: "provider/model-v1",
      dimensions: 768,
      encoding: :ieee754_float32_be_v1,
      category: "goal"
    ]

    assert {:error, :invalid_request} =
             Arbor.Persistence.search_vector_records("agent_alpha", [0.0], opts)

    refute_receive {:regression_backend_called, _agent_id, _vector, _opts}
  end
end
