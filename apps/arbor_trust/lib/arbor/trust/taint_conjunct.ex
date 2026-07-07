defmodule Arbor.Trust.TaintConjunct do
  @moduledoc """
  TRUST-15 taint conjunct for trust-mode resolution.

  Static trust standing is not enough for operations whose current inputs came
  from untrusted or hostile sources. For egress, process spawning, financial, and
  identity-mutating effects, hostile input degrades an otherwise `:auto` or
  `:allow` mode to at least `:ask`.

  This module is pure apart from reading the already-resolved capability profile
  projection by URI when the caller did not provide an explicit `:effect_class`.
  """

  alias Arbor.Trust.CapabilityProfileRegistry

  @type mode :: :block | :ask | :allow | :auto
  @type taint_level :: :trusted | :derived | :untrusted | :hostile

  @degraded_effect_classes [:network_egress, :process_spawn, :financial, :identity_mutating]
  @known_effect_classes [
    :read,
    :local_write,
    :process_spawn,
    :network_egress,
    :financial,
    :identity_mutating,
    :governance,
    :trust_mutating
  ]
  @blocking_taint [:untrusted, :hostile]
  @taint_rank %{trusted: 0, derived: 1, untrusted: 2, hostile: 3}

  @doc """
  Return the trust-mode ceiling imposed by operation taint.

  `:ask` means TRUST-15 applies. `:auto` means the taint conjunct imposes no
  additional restriction, leaving the normal profile/ceiling/model layers to
  decide.
  """
  @spec mode(String.t(), keyword()) :: mode()
  def mode(resource_uri, opts \\ []) when is_list(opts) do
    %{taint_mode: mode} = explain(resource_uri, opts)
    mode
  end

  @doc "Return the inputs that drove the taint conjunct decision."
  @spec explain(String.t(), keyword()) :: %{
          required(:effect_class) => atom() | nil,
          required(:operation_taint) => taint_level() | nil,
          required(:taint_mode) => mode()
        }
  def explain(resource_uri, opts \\ []) when is_list(opts) do
    effect_class = effect_class(resource_uri, opts)
    operation_taint = operation_taint(opts)

    taint_mode =
      if effect_class in @degraded_effect_classes and operation_taint in @blocking_taint do
        :ask
      else
        :auto
      end

    %{
      effect_class: effect_class,
      operation_taint: operation_taint,
      taint_mode: taint_mode
    }
  end

  @doc "Resolve an operation's effect class from opts, then profile metadata by URI."
  @spec effect_class(String.t(), keyword()) :: atom() | nil
  def effect_class(resource_uri, opts) when is_binary(resource_uri) and is_list(opts) do
    explicit = explicit_effect_class(opts)

    explicit || profile_effect_class(resource_uri)
  end

  def effect_class(_resource_uri, opts) when is_list(opts) do
    explicit_effect_class(opts)
  end

  @doc "Resolve the operation input taint level from authorization opts."
  @spec operation_taint(keyword()) :: taint_level() | nil
  def operation_taint(opts) when is_list(opts) do
    opts
    |> first_present([:operation_taint, :egress_taint, :taint])
    |> taint_level()
  end

  defp profile_effect_class(resource_uri) do
    case CapabilityProfileRegistry.profile_for(resource_uri) do
      %{effect_class: effect_class} -> effect_class
      _ -> nil
    end
  end

  defp explicit_effect_class(opts) do
    opts
    |> first_present([:effect_class, :operation_effect_class])
    |> normalize_effect_class()
  end

  defp normalize_effect_class(effect_class) when effect_class in @known_effect_classes,
    do: effect_class

  defp normalize_effect_class(effect_class) when is_binary(effect_class) do
    Enum.find(@known_effect_classes, &(Atom.to_string(&1) == effect_class))
  end

  defp normalize_effect_class(_effect_class), do: nil

  defp first_present(opts, keys) do
    Enum.find_value(keys, fn key ->
      if Keyword.has_key?(opts, key), do: Keyword.get(opts, key), else: nil
    end)
  end

  defp taint_level(%{level: level}), do: normalize_taint(level)
  defp taint_level(%{"level" => level}), do: normalize_taint(level)
  defp taint_level(%{taint: taint}), do: taint_level(taint)
  defp taint_level(%{"taint" => taint}), do: taint_level(taint)
  defp taint_level(level) when is_atom(level), do: normalize_taint(level)
  defp taint_level(level) when is_binary(level), do: normalize_taint(level)

  defp taint_level(taint_map) when is_map(taint_map) do
    taint_map
    |> Map.values()
    |> Enum.map(&taint_level/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&Map.get(@taint_rank, &1, 2), fn -> nil end)
  end

  defp taint_level(_taint), do: nil

  defp normalize_taint(level) when level in [:trusted, :derived, :untrusted, :hostile],
    do: level

  defp normalize_taint(level) when is_binary(level) do
    case level do
      "trusted" -> :trusted
      "derived" -> :derived
      "untrusted" -> :untrusted
      "hostile" -> :hostile
      _ -> nil
    end
  end

  defp normalize_taint(_level), do: nil
end
