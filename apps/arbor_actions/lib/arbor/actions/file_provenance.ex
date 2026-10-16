defmodule Arbor.Actions.FileProvenance do
  @moduledoc """
  Durable taint sidecar for workspace files written through `Arbor.Actions.File`.

  A file written under an untrusted (or otherwise labeled) context keeps that
  label on later reads, including in another process or session. Sidecars bind
  `Arbor.Contracts.Security.TaintEnvelope` to the content SHA-256 so later
  reads still match after SafePath vs absolute-join spelling differences.

  Fail-closed:
  - an agent write with unknown taint persists `:untrusted`
  - a present but unverifiable sidecar is `:hostile`, never `nil` / `:trusted`
  - missing sidecar falls back to `Arbor.Actions.Taint.path_provenance/1`
    so user-created workspace files stay unlabeled rather than trusted
  """

  alias Arbor.Actions.Taint, as: ActionTaint
  alias Arbor.Contracts.Security.{Taint, TaintEnvelope}

  @sidecar_suffix ".arbor-taint"
  @levels [:trusted, :derived, :untrusted, :hostile]

  @doc "Sidecar path beside `file_path` (hidden from default directory listings)."
  @spec sidecar_path(String.t()) :: String.t()
  def sidecar_path(file_path) when is_binary(file_path) do
    Path.join(Path.dirname(file_path), "." <> Path.basename(file_path) <> @sidecar_suffix)
  end

  @doc """
  Persist provenance after a successful write.

  System writes with no agent and no taint label leave no sidecar. Agent
  writes without a usable label persist `:untrusted`.
  """
  @spec persist(String.t(), binary(), map(), atom()) :: :ok | {:error, atom()}
  def persist(path, content, context, mode)
      when is_binary(path) and is_binary(content) and is_map(context) and is_atom(mode) do
    case taint_for_write(context) do
      :none ->
        :ok

      {:ok, taint} ->
        taint = maybe_join_existing(path, taint, mode)
        write_sidecar(path, content, taint)
    end
  rescue
    _ -> {:error, :provenance_persist_failed}
  catch
    _, _ -> {:error, :provenance_persist_failed}
  end

  def persist(_path, _content, _context, _mode), do: {:error, :provenance_persist_failed}

  @doc "Resolve the durable level for `path` plus on-disk (or supplied) bytes."
  @spec resolve(String.t(), binary() | nil) :: Taint.level() | nil
  def resolve(path, content) when is_binary(path) do
    cond do
      sidecar_path?(path) ->
        :untrusted

      is_binary(content) ->
        resolve_candidates([path], content)

      true ->
        resolve_path(path)
    end
  end

  def resolve(_path, _content), do: :untrusted

  @doc "Resolve provenance from a read-path param, trying expanded spellings."
  @spec resolve_path(term()) :: Taint.level() | nil
  def resolve_path(path) when is_binary(path) and path != "" do
    if sidecar_path?(path) do
      :untrusted
    else
      candidates =
        [path, Path.expand(path)]
        |> Enum.uniq()
        |> Enum.filter(&regular_file?/1)

      case candidates do
        [] ->
          ActionTaint.path_provenance(path)

        [found | _] ->
          case File.read(found) do
            {:ok, content} -> resolve_candidates([found | candidates], content)
            _ -> :untrusted
          end
      end
    end
  end

  def resolve_path(path), do: ActionTaint.path_provenance(path)

  defp resolve_candidates(paths, content) do
    Enum.reduce_while(paths, ActionTaint.path_provenance(List.first(paths)), fn path, fallback ->
      case lookup_sidecar(path, content) do
        :missing ->
          {:cont, fallback || ActionTaint.path_provenance(path)}

        {:ok, level} ->
          {:halt, level}
      end
    end)
  end

  defp lookup_sidecar(path, content) do
    sidecar = sidecar_path(path)

    case File.read(sidecar) do
      {:error, :enoent} ->
        :missing

      {:error, _reason} ->
        {:ok, :hostile}

      {:ok, json} ->
        {:ok, level_from_sidecar(json, payload(path, content))}
    end
  end

  defp level_from_sidecar(json, payload) do
    with {:ok, persisted} <- Jason.decode(json),
         {:ok, taint, status} <- TaintEnvelope.resolve(persisted, payload),
         true <- status in [:verified, :invalid_durable_provenance, :legacy_unlabeled] do
      if status == :verified, do: taint.level, else: fail_closed_level(taint)
    else
      _ -> :hostile
    end
  rescue
    _ -> :hostile
  catch
    _, _ -> :hostile
  end

  defp fail_closed_level(%Taint{level: level}) when level in @levels and level != :trusted do
    level
  end

  defp fail_closed_level(_), do: :untrusted

  defp write_sidecar(path, content, taint) do
    with {:ok, envelope} <- TaintEnvelope.new(payload(path, content), taint),
         {:ok, persisted} <- TaintEnvelope.to_map(envelope),
         {:ok, json} <- Jason.encode(persisted),
         :ok <- File.write(sidecar_path(path), json) do
      :ok
    else
      _ -> {:error, :provenance_persist_failed}
    end
  end

  defp payload(_path, content) do
    # Bind the sidecar to content bytes only. Path spelling can differ between
    # write (SafePath-normalized) and a later-process absolute join.
    %{"content_sha256" => Base.encode16(:crypto.hash(:sha256, content), case: :lower)}
  end

  defp taint_for_write(context) do
    case extract_context_taint(context) do
      {:ok, taint} ->
        {:ok, taint}

      :missing ->
        if agent_write?(context) do
          label_taint(:untrusted, "file_write_unknown_provenance")
        else
          :none
        end
    end
  end

  defp extract_context_taint(context) do
    raw = Map.get(context, :taint) || Map.get(context, "taint")

    cond do
      is_nil(raw) ->
        :missing

      match?(%Taint{}, raw) ->
        Taint.canonicalize(raw)

      raw in @levels ->
        label_taint(raw, "file_write")

      is_map(raw) ->
        Taint.canonicalize(raw)

      true ->
        :missing
    end
    |> case do
      {:ok, taint} -> {:ok, taint}
      {:error, _reason} -> label_taint(:untrusted, "file_write_unknown_provenance")
      :missing -> :missing
    end
  end

  defp label_taint(level, source) when level in @levels and is_binary(source) do
    Taint.new(%{
      level: level,
      sensitivity: if(level in [:untrusted, :hostile], do: :restricted, else: :internal),
      sanitizations: 0,
      confidence: :unverified,
      source: source,
      chain: []
    })
  end

  defp agent_write?(context) do
    agent = Map.get(context, :agent_id) || Map.get(context, "agent_id")
    is_binary(agent) and agent != ""
  end

  defp maybe_join_existing(path, taint, :append) do
    sidecar = sidecar_path(path)

    case File.read(sidecar) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, persisted} ->
            case TaintEnvelope.decode_persisted(persisted) do
              {:ok, envelope} ->
                case Taint.join(envelope.taint, taint) do
                  {:ok, joined} -> joined
                  _ -> taint
                end

              _ ->
                case Taint.join(Taint.invalid_durable_provenance(), taint) do
                  {:ok, joined} -> joined
                  _ -> taint
                end
            end

          _ ->
            taint
        end

      _ ->
        taint
    end
  end

  defp maybe_join_existing(_path, taint, _mode), do: taint

  defp sidecar_path?(path) when is_binary(path) do
    String.ends_with?(Path.basename(path), @sidecar_suffix)
  end

  defp regular_file?(path) do
    case File.regular?(path) do
      true -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end
