defmodule Arbor.Orchestrator.Eval.Subjects.LLMTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.LLM.{Client, Request, Response}
  alias Arbor.LLM.Eval.Subject, as: CanonicalSubject
  alias Arbor.Orchestrator.Eval.Subjects.LLM, as: CompatibilitySubject

  defmodule CompatibilityAdapter do
    @behaviour Arbor.LLM.ProviderAdapter

    @impl true
    def provider, do: "compat_eval"

    @impl true
    def complete(%Request{model: "error"}, _opts), do: {:error, :compat_transport_failed}

    def complete(%Request{}, _opts) do
      {:ok, %Response{text: "compatible", usage: %{output_tokens: 3}, raw: %{}}}
    end
  end

  defp client do
    Client.new()
    |> Client.register_adapter(CompatibilityAdapter)
  end

  test "preserves the compatibility module and public arities" do
    assert CompatibilitySubject.module_info(:module) == CompatibilitySubject
    assert function_exported?(CompatibilitySubject, :run, 1)
    assert function_exported?(CompatibilitySubject, :run, 2)
  end

  test "delegates successful results to the canonical LLM subject" do
    opts = [client: client(), provider: "compat_eval", model: "model"]

    assert {:ok, compatibility_output} = CompatibilitySubject.run("hello", opts)
    assert {:ok, canonical_output} = CanonicalSubject.run("hello", opts)

    assert Map.delete(compatibility_output, :duration_ms) ==
             Map.delete(canonical_output, :duration_ms)

    assert is_integer(compatibility_output.duration_ms)
  end

  test "preserves canonical error behavior" do
    opts = [client: client(), provider: "compat_eval", model: "error"]

    assert CompatibilitySubject.run("hello", opts) == CanonicalSubject.run("hello", opts)
    assert CompatibilitySubject.run("hello", opts) == {:error, :compat_transport_failed}
  end

  test "preserves the unknown provider error shape" do
    assert {:error, message} =
             CompatibilitySubject.run("hello", provider: "definitely_not_a_provider")

    assert message =~ "unknown provider: definitely_not_a_provider"
    assert message =~ "Available:"
  end
end
