defmodule Arbor.Commands.SourceCoupling.Bands do
  @moduledoc """
  Governing package-band table for source-coupling census (SPIKE-3B).

  Pure data: app → band code and rank. Bands are not fates; fate is derived
  from band rank pairs (intra_band / downward / upward).
  """

  @type band :: String.t()
  @type app :: String.t()

  @band_rank %{
    "K" => 0,
    "P" => 1,
    "C" => 2,
    "I" => 3
  }

  # Exact governing table from approved design §7 (full app names).
  @app_band %{
    "arbor_kernel" => "K",
    "arbor_kernel_runtime" => "K",
    "arbor_contracts" => "K",
    "arbor_common" => "K",
    "arbor_signals" => "K",
    "arbor_monitor" => "K",
    "arbor_cartographer" => "P",
    "arbor_llm" => "P",
    "arbor_security" => "P",
    "arbor_persistence" => "P",
    "arbor_persistence_ecto" => "P",
    "arbor_shell" => "P",
    "arbor_sandbox" => "P",
    "arbor_historian" => "P",
    "arbor_trust" => "P",
    "arbor_ai" => "C",
    "arbor_memory" => "C",
    "arbor_consensus" => "C",
    "arbor_actions" => "C",
    "arbor_comms" => "C",
    "arbor_scheduler" => "C",
    "arbor_orchestrator" => "C",
    "arbor_agent" => "C",
    "arbor_gateway" => "C",
    "arbor_commands" => "I",
    "arbor_web" => "I",
    "arbor_dashboard" => "I",
    "arbor_voice" => "I"
  }

  @doc "Return band code for a tracked umbrella app."
  @spec band_of(app()) :: {:ok, band()} | {:error, :unknown_package_band}
  def band_of(app) when is_binary(app) do
    case Map.fetch(@app_band, app) do
      {:ok, band} -> {:ok, band}
      :error -> {:error, :unknown_package_band}
    end
  end

  def band_of(_), do: {:error, :unknown_package_band}

  @doc "Numeric rank for a band code (K=0 … I=3)."
  @spec rank(band()) :: {:ok, non_neg_integer()} | {:error, :unknown_band}
  def rank(band) when is_binary(band) do
    case Map.fetch(@band_rank, band) do
      {:ok, r} -> {:ok, r}
      :error -> {:error, :unknown_band}
    end
  end

  def rank(_), do: {:error, :unknown_band}

  @doc """
  Fate from band ranks: intra_band | downward | upward.
  """
  @spec fate(band(), band()) ::
          {:ok, String.t()} | {:error, :unknown_band | :unknown_package_band}
  def fate(from_band, to_band) when is_binary(from_band) and is_binary(to_band) do
    with {:ok, rf} <- rank(from_band),
         {:ok, rt} <- rank(to_band) do
      cond do
        rf == rt -> {:ok, "intra_band"}
        rf > rt -> {:ok, "downward"}
        true -> {:ok, "upward"}
      end
    end
  end

  def fate(_, _), do: {:error, :unknown_band}

  @doc "Directed band pair label, e.g. \"C->P\"."
  @spec band_pair(band(), band()) :: String.t()
  def band_pair(from_band, to_band)
      when is_binary(from_band) and is_binary(to_band),
      do: from_band <> "->" <> to_band

  def band_pair(_, _), do: "?>?"

  @doc "All known apps sorted."
  @spec known_apps() :: [app()]
  def known_apps, do: @app_band |> Map.keys() |> Enum.sort()

  @doc "Frozen app→band map (read-only copy)."
  @spec app_band_map() :: %{optional(app()) => band()}
  def app_band_map, do: @app_band
end
