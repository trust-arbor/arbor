defmodule Arbor.Actions.Coding.ValidationRuntimeAdmissionCore do
  @moduledoc """
  Pure projection of validation-runtime facade maps into a live-readiness envelope.

  Copies only driver/state/probe/host_os. Never includes image digests, host
  paths, or probe payloads.
  """

  @drivers MapSet.new(["podman", "apple_container", "unavailable"])
  @states MapSet.new(["pinned", "available", "unavailable", "unconfigured", "unsupported"])
  @host_oses MapSet.new(["linux", "macos", "unknown"])
  @configured_states MapSet.new(["pinned", "available"])
  @max_driver_bytes 32

  @type envelope :: %{
          required(String.t()) => String.t()
        }

  @doc "Project a redacted status map and probe result into a closed envelope."
  @spec observe(term(), term(), term()) :: {:ok, envelope()} | {:error, :malformed}
  def observe(status, probe, host_os) when is_map(status) and not is_struct(status) do
    with {:ok, driver} <- bound_driver(status),
         {:ok, state} <- bound_state(status),
         {:ok, probe_label} <- bound_probe(probe, state),
         {:ok, os} <- bound_host_os(host_os) do
      {:ok,
       %{
         "driver" => driver,
         "state" => canonical_state(state),
         "probe" => probe_label,
         "host_os" => os
       }}
    else
      _other -> {:error, :malformed}
    end
  rescue
    _ -> {:error, :malformed}
  catch
    _, _ -> {:error, :malformed}
  end

  def observe(_status, _probe, _host_os), do: {:error, :malformed}

  defp bound_driver(status) do
    case Map.get(status, "driver") do
      "oci" -> {:ok, "podman"}
      driver when is_binary(driver) -> admit_driver(driver)
      _other -> {:error, :malformed}
    end
  end

  defp admit_driver(driver) do
    if MapSet.member?(@drivers, driver) and byte_size(driver) <= @max_driver_bytes and
         String.valid?(driver) do
      {:ok, driver}
    else
      {:error, :malformed}
    end
  end

  defp bound_state(status) do
    case Map.get(status, "state") do
      state when is_binary(state) and byte_size(state) <= @max_driver_bytes ->
        if MapSet.member?(@states, state), do: {:ok, state}, else: {:error, :malformed}

      _other ->
        {:error, :malformed}
    end
  end

  defp canonical_state(state) when state in ["pinned", "available"], do: state
  defp canonical_state(_state), do: "unavailable"

  defp bound_probe(probe, state) do
    configured? = MapSet.member?(@configured_states, state)

    cond do
      configured? and match?({:ok, _}, probe) ->
        {:ok, "passed"}

      configured? and match?({:error, :untrusted_home}, probe) ->
        {:ok, "failed_untrusted_home"}

      configured? and match?({:error, _}, probe) ->
        {:ok, "failed"}

      configured? ->
        {:error, :malformed}

      probe == :skipped ->
        {:ok, "skipped"}

      match?({:error, _}, probe) ->
        {:ok, "skipped"}

      match?({:ok, _}, probe) ->
        {:ok, "skipped"}

      true ->
        {:error, :malformed}
    end
  end

  defp bound_host_os(host_os) when is_binary(host_os) do
    if MapSet.member?(@host_oses, host_os), do: {:ok, host_os}, else: {:error, :malformed}
  end

  defp bound_host_os(_host_os), do: {:error, :malformed}
end
