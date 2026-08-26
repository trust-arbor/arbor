defmodule Arbor.Actions.Coding.ValidationRuntimeAdmissionCore do
  @moduledoc """
  Pure projection of validation-runtime facade maps into a live-readiness envelope.

  Copies driver/state/probe/host_os. A nonzero probe may add closed
  `probe_exit_code` and sanitised `probe_output_tail` fields. Never includes
  image digests or host paths.
  """

  @drivers MapSet.new(["podman", "apple_container", "unavailable"])
  @states MapSet.new(["pinned", "available", "unavailable", "unconfigured", "unsupported"])
  @host_oses MapSet.new(["linux", "macos", "unknown"])
  @configured_states MapSet.new(["pinned", "available"])
  @max_driver_bytes 32
  @max_probe_tail_bytes 512

  @type envelope :: %{
          required(String.t()) => String.t()
        }

  @doc "Project a redacted status map and probe result into a closed envelope."
  @spec observe(term(), term(), term()) :: {:ok, envelope()} | {:error, :malformed}
  def observe(status, probe, host_os) when is_map(status) and not is_struct(status) do
    with {:ok, driver} <- bound_driver(status),
         {:ok, state} <- bound_state(status),
         {:ok, probe_label} <- bound_probe(probe, state),
         {:ok, os} <- bound_host_os(host_os),
         {:ok, extras} <- bound_probe_extras(probe, probe_label) do
      {:ok,
       extras
       |> Map.merge(%{
         "driver" => driver,
         "state" => canonical_state(state),
         "probe" => probe_label,
         "host_os" => os
       })}
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
    if MapSet.member?(@configured_states, state) do
      bound_configured_probe(probe)
    else
      bound_unconfigured_probe(probe)
    end
  end

  defp bound_configured_probe({:ok, _}), do: {:ok, "passed"}
  defp bound_configured_probe({:error, :untrusted_home}), do: {:ok, "failed_untrusted_home"}

  defp bound_configured_probe({:error, :linux_dependency_baseline_authority_unavailable}),
    do: {:ok, "failed_starting"}

  defp bound_configured_probe({:error, {:probe_nonzero_exit, _detail}}), do: {:ok, "failed"}
  defp bound_configured_probe({:error, _reason}), do: {:ok, "failed"}
  defp bound_configured_probe(_other), do: {:error, :malformed}

  defp bound_unconfigured_probe(:skipped), do: {:ok, "skipped"}
  defp bound_unconfigured_probe({:error, _reason}), do: {:ok, "skipped"}
  defp bound_unconfigured_probe({:ok, _}), do: {:ok, "skipped"}
  defp bound_unconfigured_probe(_other), do: {:error, :malformed}

  defp bound_probe_extras({:error, {:probe_nonzero_exit, detail}}, "failed")
       when is_map(detail) do
    extras = %{}

    extras =
      case closed_exit_code(detail) do
        {:ok, code} -> Map.put(extras, "probe_exit_code", code)
        :error -> extras
      end

    extras =
      case closed_output_tail(detail) do
        {:ok, tail} -> Map.put(extras, "probe_output_tail", tail)
        :error -> extras
      end

    {:ok, extras}
  end

  defp bound_probe_extras(_probe, _label), do: {:ok, %{}}

  defp closed_exit_code(detail) do
    case Map.get(detail, :exit_code) || Map.get(detail, "exit_code") do
      code when is_integer(code) and code >= 1 and code <= 65_535 ->
        {:ok, Integer.to_string(code)}

      _other ->
        :error
    end
  end

  defp closed_output_tail(detail) do
    case Map.get(detail, :output_tail) || Map.get(detail, "output_tail") do
      tail when is_binary(tail) and tail != "" and byte_size(tail) <= 2_048 ->
        sanitised = sanitise_probe_tail(tail)

        if sanitised != "" and byte_size(sanitised) <= @max_probe_tail_bytes and
             String.valid?(sanitised) do
          {:ok, sanitised}
        else
          :error
        end

      _other ->
        :error
    end
  end

  defp sanitise_probe_tail(tail) do
    tail
    |> String.replace(~r/sha256:[0-9a-f]{64}/, "sha256:<redacted>")
    |> String.replace(~r/(^|[\s])(\/(?:[A-Za-z0-9._-]+\/)*[A-Za-z0-9._-]+)/, "\\1<path>")
    |> then(fn text ->
      if byte_size(text) <= @max_probe_tail_bytes do
        text
      else
        binary_part(text, 0, @max_probe_tail_bytes)
      end
    end)
    |> then(fn text ->
      if String.valid?(text), do: text, else: ""
    end)
  end

  defp bound_host_os(host_os) when is_binary(host_os) do
    if MapSet.member?(@host_oses, host_os), do: {:ok, host_os}, else: {:error, :malformed}
  end

  defp bound_host_os(_host_os), do: {:error, :malformed}
end
