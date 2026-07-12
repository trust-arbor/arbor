defmodule Arbor.LLM.PreflightTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.LLM.Preflight

  setup do
    original = Application.get_env(:arbor_llm, :trusted_proxy_endpoints)

    on_exit(fn ->
      if is_nil(original),
        do: Application.delete_env(:arbor_llm, :trusted_proxy_endpoints),
        else: Application.put_env(:arbor_llm, :trusted_proxy_endpoints, original)
    end)

    :ok
  end

  describe "strip_quant/1" do
    test "strips an LM Studio @quant suffix" do
      assert Preflight.strip_quant("gemma-4-e4b-it@q4_k_xl") == "gemma-4-e4b-it"
    end

    test "leaves an Ollama name:tag id untouched (no @)" do
      assert Preflight.strip_quant("granite4.1:3b") == "granite4.1:3b"
    end

    test "leaves a bare id untouched" do
      assert Preflight.strip_quant("gemma-4-e4b-it") == "gemma-4-e4b-it"
    end
  end

  describe "classify/3 — LM Studio (@quant)" do
    test "exact match → :ok" do
      loaded = ["gemma-4-e4b-it@q4_k_xl", "gemma-4-e4b-it@q8_k_xl"]
      assert Preflight.classify(:lm_studio, "gemma-4-e4b-it@q4_k_xl", loaded) == :ok
    end

    test "base loaded under a different quant → {:wrong_quant, served}" do
      assert Preflight.classify(:lm_studio, "gemma-4-e4b-it@q4_k_xl", ["gemma-4-e4b-it@q8_k_xl"]) ==
               {:wrong_quant, "gemma-4-e4b-it@q8_k_xl"}
    end

    test "base loaded as a bare id (one quant) → :unverified_quant" do
      assert Preflight.classify(:lm_studio, "gemma-4-e4b-it@q4_k_xl", ["gemma-4-e4b-it"]) ==
               :unverified_quant
    end

    test "base not loaded at all → :missing" do
      assert Preflight.classify(:lm_studio, "gemma-4-e4b-it@q4_k_xl", ["granite-4.1-3b"]) ==
               :missing
    end

    test "empty loaded list → :missing" do
      assert Preflight.classify(:lm_studio, "gemma-4-e4b-it@q4_k_xl", []) == :missing
    end
  end

  describe "classify/3 — Ollama (name:tag, implicit :latest)" do
    test "exact tag match → :ok" do
      assert Preflight.classify(:ollama, "granite4.1:3b", ["granite4.1:3b", "granite4:1b"]) == :ok
    end

    test "bare name matches the loaded :latest tag → :ok (Ollama's default tag)" do
      assert Preflight.classify(:ollama, "mxbai-embed-large", ["mxbai-embed-large:latest"]) == :ok
    end

    test "explicit tag that isn't loaded → :missing (even if another tag is)" do
      assert Preflight.classify(:ollama, "granite4.1:3b", ["granite4:1b"]) == :missing
    end

    test "bare name with no matching :latest → :missing" do
      assert Preflight.classify(:ollama, "mxbai-embed-large", ["nomic-embed-text:latest"]) ==
               :missing
    end
  end

  describe "configured_models/0" do
    test "returns only local-provider entries, incl. the needs_tools gate and the retrieval embed" do
      entries = Preflight.configured_models()

      assert Enum.all?(entries, &(&1.provider in [:lm_studio, :ollama]))

      assert Enum.any?(entries, &(&1.stage == :needs_tools and &1.provider == :lm_studio))
      assert Enum.any?(entries, &(&1.stage == :retrieval and &1.kind == :embed))
    end
  end

  describe "check/1 (injected fetcher)" do
    test "classifies each configured model and tags :unreachable when a provider errors" do
      # Everything 'loaded' → all :ok
      all_ok = fn _provider, _base -> {:ok, all_configured_ids()} end
      assert Enum.all?(Preflight.check(all_ok), &(&1.status == :ok))

      # Provider unreachable → :unreachable for those entries
      down = fn _provider, _base -> {:error, :econnrefused} end
      assert Enum.all?(Preflight.check(down), &(&1.status == :unreachable))

      # Nothing loaded → :missing
      empty = fn _provider, _base -> {:ok, []} end
      assert Enum.all?(Preflight.check(empty), &(&1.status == :missing))
    end

    test "queries each {provider, base_url} at most once (caches within a run)" do
      counter = :counters.new(1, [:atomics])

      fetch = fn _provider, _base ->
        :counters.add(counter, 1, 1)
        {:ok, all_configured_ids()}
      end

      _ = Preflight.check(fetch)

      # Default config: needs_tools on lm_studio:1234, the rest on ollama:11434 →
      # two distinct provider/base_url pairs regardless of how many stages there are.
      distinct =
        Preflight.configured_models() |> Enum.map(&{&1.provider, &1.base_url}) |> Enum.uniq()

      assert :counters.get(counter, 1) == length(distinct)
    end
  end

  describe "loaded_models/2 outbound boundary" do
    test "security regression: untrusted inventory destinations are never contacted" do
      {base_url, server} =
        start_inventory_server(fn socket, _origin ->
          send_json(socket, 200, %{"data" => [%{"id" => "unexpected"}]})
        end)

      assert {:error, :endpoint_origin_not_trusted} =
               Preflight.loaded_models(:lm_studio, base_url)

      assert :not_connected = Task.await(server, 2_500)
    end

    test "security regression: inventory redirects are not followed" do
      {base_url, server} = start_redirect_inventory_server()

      Application.put_env(:arbor_llm, :trusted_proxy_endpoints, %{
        "lm_studio" => [base_url]
      })

      assert {:error, _reason} = Preflight.loaded_models(:lm_studio, base_url)
      assert 1 = Task.await(server, 1_500)
    end

    test "security regression: encoded inventory responses are rejected" do
      {base_url, server} =
        start_inventory_server(fn socket, _origin ->
          body = Jason.encode!(%{"data" => [%{"id" => "compressed-model"}]})
          encoded = :zlib.gzip(body)

          send_response(socket, 200, encoded, [
            {"content-type", "application/json"},
            {"content-encoding", "gzip"}
          ])
        end)

      Application.put_env(:arbor_llm, :trusted_proxy_endpoints, %{
        "lm_studio" => [base_url]
      })

      assert {:error, {:invalid_inventory_response, {:invalid_content_encoding, _reason}}} =
               Preflight.loaded_models(:lm_studio, base_url)

      assert :connected = Task.await(server, 1_000)
    end
  end

  defp all_configured_ids do
    Preflight.configured_models() |> Enum.map(& &1.model) |> Enum.uniq()
  end

  defp start_inventory_server(responder) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    origin = "http://127.0.0.1:#{port}"

    server =
      Task.async(fn ->
        case :gen_tcp.accept(listener, 2_000) do
          {:ok, socket} ->
            :ok = :gen_tcp.close(listener)
            {:ok, _request} = receive_headers(socket, "")
            responder.(socket, origin)
            :ok = :gen_tcp.close(socket)
            :connected

          {:error, :timeout} ->
            :ok = :gen_tcp.close(listener)
            :not_connected
        end
      end)

    {origin <> "/v1", server}
  end

  defp start_redirect_inventory_server do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    origin = "http://127.0.0.1:#{port}"

    server =
      Task.async(fn ->
        {:ok, first} = :gen_tcp.accept(listener, 1_000)
        {:ok, _request} = receive_headers(first, "")

        send_response(first, 302, "{}", [
          {"content-type", "application/json"},
          {"location", origin <> "/redirected"}
        ])

        :ok = :gen_tcp.close(first)

        connections =
          case :gen_tcp.accept(listener, 500) do
            {:ok, second} ->
              {:ok, _request} = receive_headers(second, "")
              send_json(second, 200, %{"data" => [%{"id" => "redirected-model"}]})
              :ok = :gen_tcp.close(second)
              2

            {:error, :timeout} ->
              1
          end

        :ok = :gen_tcp.close(listener)
        connections
      end)

    {origin <> "/v1", server}
  end

  defp send_json(socket, status, value) do
    send_response(socket, status, Jason.encode!(value), [{"content-type", "application/json"}])
  end

  defp send_response(socket, status, body, headers) do
    reason = if status == 200, do: "OK", else: "Redirect"

    rendered_headers =
      Enum.map_join(headers, "", fn {name, value} -> "#{name}: #{value}\r\n" end)

    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 #{status} #{reason}\r\n" <>
          rendered_headers <>
          "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
      )
  end

  defp receive_headers(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 1_000) do
        {:ok, data} -> receive_headers(socket, acc <> data)
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
