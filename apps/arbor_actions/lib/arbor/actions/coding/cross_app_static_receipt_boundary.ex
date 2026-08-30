defmodule Arbor.Actions.Coding.CrossApp.StaticReceiptBoundary do
  @moduledoc """
  Process-local MFA boundary for Engine-native CrossApp static receipts.

  Sink/source tuples are installed by the trusted executor only. This module
  never selects paths and never imports Orchestrator internals. Reads re-admit
  the closed static-stage receipt and exact-match its canonical digest.
  """

  alias Arbor.Actions

  @digest_regex ~r/\A[0-9a-f]{64}\z/
  @signal_keys [
    :cross_app_static_receipt_boundary_error,
    "cross_app_static_receipt_boundary_error",
    :cross_app_static_receipt_sink,
    "cross_app_static_receipt_sink",
    :cross_app_static_receipt_source,
    "cross_app_static_receipt_source"
  ]

  @doc "True when a trusted sink and source are present and the boundary is ready."
  @spec present?(term()) :: boolean()
  def present?(context) when is_map(context) do
    case {sink(context), source(context)} do
      {{:ok, _sink}, {:ok, _source}} -> true
      _ -> false
    end
  end

  def present?(_context), do: false

  @doc """
  True when Engine boundary configuration was supplied or attempted.

  Genuine direct calls carry none of the sink, source, or boundary-error keys.
  A missing, partial, or malformed Engine boundary is still an attempt and must
  fail closed rather than falling through to the ordinary Mix path.
  """
  @spec attempted?(term()) :: boolean()
  def attempted?(context) when is_map(context) do
    Enum.any?(@signal_keys, &Map.has_key?(context, &1))
  end

  def attempted?(_context), do: false

  @doc """
  Boundary configuration state for initial-window selection.

  * `:absent` — genuine direct call with no Engine boundary signal
  * `:invalid` — Engine attempted to configure the boundary but it is not ready
  * `:ready` — trusted sink and source are present
  """
  @spec state(term()) :: :absent | :invalid | :ready
  def state(context) do
    cond do
      present?(context) -> :ready
      attempted?(context) -> :invalid
      true -> :absent
    end
  end

  @doc "Trusted archive MFA, or a closed boundary error."
  @spec sink(term()) :: {:ok, {module(), atom(), list()}} | {:error, atom()}
  def sink(context) when is_map(context) do
    with :ok <- boundary_ready(context) do
      fetch_mfa(context, :cross_app_static_receipt_sink)
    end
  end

  def sink(_context), do: {:error, :invalid_trusted_cross_app_static_receipt_boundary}

  @doc "Trusted read MFA, or a closed boundary error."
  @spec source(term()) :: {:ok, {module(), atom(), list()}} | {:error, atom()}
  def source(context) when is_map(context) do
    with :ok <- boundary_ready(context) do
      fetch_mfa(context, :cross_app_static_receipt_source)
    end
  end

  def source(_context), do: {:error, :invalid_trusted_cross_app_static_receipt_boundary}

  @doc "Archive an admitted receipt by digest through the trusted sink."
  @spec archive(term(), String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def archive(context, digest, receipt)
      when is_map(context) and is_binary(digest) and is_map(receipt) and not is_struct(receipt) do
    with :ok <- admit_digest(digest),
         {:ok, sink} <- sink(context) do
      call_sink(sink, digest, receipt)
    end
  end

  def archive(_context, _digest, _receipt),
    do: {:error, :invalid_trusted_cross_app_static_receipt_boundary}

  @doc "Read, re-admit, and digest-match a receipt by expected digest through the trusted source."
  @spec read(term(), String.t()) :: {:ok, map()} | {:error, atom()}
  def read(context, digest) when is_map(context) and is_binary(digest) do
    with :ok <- admit_digest(digest),
         {:ok, source} <- source(context),
         {:ok, raw} <- call_source(source, digest),
         {:ok, admitted} <- Actions.coding_cross_app_static_receipt_admit(raw),
         {:ok, canonical_digest} <-
           Actions.coding_cross_app_static_receipt_digest(admitted),
         :ok <- match_static_receipt_digest(canonical_digest, digest) do
      {:ok, admitted}
    end
  end

  def read(_context, _digest),
    do: {:error, :invalid_trusted_cross_app_static_receipt_boundary}

  defp boundary_ready(context) do
    case Map.get(context, :cross_app_static_receipt_boundary_error) ||
           Map.get(context, "cross_app_static_receipt_boundary_error") do
      nil -> :ok
      _error -> {:error, :invalid_trusted_cross_app_static_receipt_boundary}
    end
  end

  defp fetch_mfa(context, key) do
    string_key = Atom.to_string(key)
    has_atom = Map.has_key?(context, key)
    has_string = Map.has_key?(context, string_key)

    cond do
      has_atom and has_string ->
        {:error, :invalid_trusted_cross_app_static_receipt_boundary}

      true ->
        case Map.get(context, key) || Map.get(context, string_key) do
          {module, function, fixed_args}
          when is_atom(module) and is_atom(function) and is_list(fixed_args) ->
            {:ok, {module, function, fixed_args}}

          _other ->
            {:error, :invalid_trusted_cross_app_static_receipt_boundary}
        end
    end
  end

  defp admit_digest(digest) when is_binary(digest) do
    if Regex.match?(@digest_regex, digest),
      do: :ok,
      else: {:error, :invalid_static_receipt_digest}
  end

  defp match_static_receipt_digest(actual, expected) do
    if actual === expected, do: :ok, else: {:error, :static_receipt_drift}
  end

  defp call_sink({module, function, fixed_args}, digest, receipt) do
    case apply(module, function, fixed_args ++ [digest, receipt]) do
      {:ok, descriptor} when is_map(descriptor) and not is_struct(descriptor) ->
        {:ok, descriptor}

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      {:error, _reason} ->
        {:error, :static_receipt_archive_failed}

      _other ->
        {:error, :static_receipt_archive_failed}
    end
  rescue
    UndefinedFunctionError -> {:error, :static_receipt_sink_unavailable}
    _ -> {:error, :static_receipt_archive_failed}
  catch
    :exit, _ -> {:error, :static_receipt_sink_unavailable}
    _, _ -> {:error, :static_receipt_archive_failed}
  end

  defp call_source({module, function, fixed_args}, digest) do
    case apply(module, function, fixed_args ++ [digest]) do
      {:ok, %{"receipt" => receipt}} when is_map(receipt) and not is_struct(receipt) ->
        {:ok, receipt}

      {:ok, receipt} when is_map(receipt) and not is_struct(receipt) ->
        {:ok, receipt}

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      {:error, _reason} ->
        {:error, :cross_app_static_receipt_unavailable}

      _other ->
        {:error, :cross_app_static_receipt_unavailable}
    end
  rescue
    UndefinedFunctionError -> {:error, :static_receipt_source_unavailable}
    _ -> {:error, :cross_app_static_receipt_unavailable}
  catch
    :exit, _ -> {:error, :static_receipt_source_unavailable}
    _, _ -> {:error, :cross_app_static_receipt_unavailable}
  end
end
