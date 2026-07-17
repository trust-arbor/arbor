defmodule Arbor.Shell.AppleContainerUnitName do
  @moduledoc """
  Canonical identity contract for Arbor-owned Apple Container units.

  Unit names are versioned so durable journal and recovery code can distinguish
  Arbor-owned units from unrelated containers without accepting caller-chosen
  names.
  """

  @prefix "arbor-v1-"
  @entropy_bytes 16
  @name_re ~r/\Aarbor-v1-[0-9a-f]{32}\z/

  @doc """
  Derive a canonical unit name from exactly 128 bits of injected entropy.
  """
  @spec from_entropy(term()) :: {:ok, String.t()} | {:error, :invalid_unit_name_entropy}
  def from_entropy(entropy) when is_binary(entropy) and byte_size(entropy) == @entropy_bytes do
    {:ok, @prefix <> Base.encode16(entropy, case: :lower)}
  end

  def from_entropy(_entropy), do: {:error, :invalid_unit_name_entropy}

  @doc """
  Validate the canonical durable unit-name format.
  """
  @spec validate(term()) :: {:ok, String.t()} | {:error, :invalid_unit_name}
  def validate(name) when is_binary(name) do
    if String.valid?(name) and Regex.match?(@name_re, name) do
      {:ok, name}
    else
      {:error, :invalid_unit_name}
    end
  end

  def validate(_name), do: {:error, :invalid_unit_name}
end
