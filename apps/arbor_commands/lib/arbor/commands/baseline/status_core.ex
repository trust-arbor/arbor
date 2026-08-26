defmodule Arbor.Commands.Baseline.StatusCore do
  @moduledoc """
  Pure projection of `mix arbor.baseline.status` from facade maps.
  """

  @spec project(map()) :: map()
  def project(input) when is_map(input) do
    runtime = stringify_map(Map.get(input, :runtime, %{}))
    baseline = stringify_map(Map.get(input, :baseline, %{}))
    mix_lock = Map.get(input, :mix_lock_digest)
    head = Map.get(input, :head_mix_lock_digest)
    probe = Map.get(input, :probe)

    %{
      "driver" => Map.get(runtime, "driver"),
      "runtime_state" => Map.get(runtime, "state"),
      "runtime_reason" => Map.get(runtime, "reason"),
      "baseline_state" => Map.get(baseline, "state"),
      "baseline_reason" => Map.get(baseline, "reason"),
      "host_platform" => Map.get(input, :host_platform),
      "guest_platform" => Map.get(input, :guest_platform),
      "mix_lock_digest" => digest_or_nil(mix_lock),
      "mix_lock_matches_head" => mix_lock_matches?(mix_lock, head),
      "image_reachable" => image_reachable?(probe)
    }
  end

  def project(_input) do
    %{
      "driver" => "unavailable",
      "runtime_state" => "unavailable",
      "runtime_reason" => "invalid_status_input",
      "baseline_state" => "unavailable",
      "baseline_reason" => nil,
      "host_platform" => nil,
      "guest_platform" => nil,
      "mix_lock_digest" => nil,
      "mix_lock_matches_head" => false,
      "image_reachable" => false
    }
  end

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} when is_binary(key) -> {key, value}
      {key, value} -> {inspect(key), value}
    end)
  end

  defp stringify_map(_other), do: %{}

  defp digest_or_nil(digest) when is_binary(digest), do: digest
  defp digest_or_nil({:ok, digest}) when is_binary(digest), do: digest
  defp digest_or_nil(_other), do: nil

  defp mix_lock_matches?({:ok, digest}, head)
       when is_binary(digest) and is_binary(head),
       do: digest == head

  defp mix_lock_matches?(digest, head) when is_binary(digest) and is_binary(head),
    do: digest == head

  defp mix_lock_matches?(_digest, _head), do: false

  defp image_reachable?({:ok, _receipt}), do: true
  defp image_reachable?(_other), do: false
end
