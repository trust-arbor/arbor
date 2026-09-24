defmodule Arbor.Common.SkillLibrary.Versions do
  @moduledoc false

  alias Arbor.Common.{Config, SkillLibrary}
  alias Arbor.Common.SkillLibrary.VersionCore
  alias Arbor.Contracts.Security.Capability
  alias Arbor.Contracts.Security.TaintEnvelope

  def prepare(name) when is_binary(name) and byte_size(name) in 1..128 do
    with {:ok, skill} <- SkillLibrary.get(name), do: VersionCore.new(skill)
  end

  def prepare(_), do: {:error, :invalid_skill_version}

  def resolve(name, principal, reference \\ nil) do
    with {:ok, version} <- prepare(name),
         :ok <- expected_version(version, reference),
         {:ok, cap} <- selected_cap(principal, version, reference),
         digest <- VersionCore.sha256(Capability.signing_payload(cap)),
         :ok <- expected_cap(cap, digest, reference),
         {:ok, :authorized} <- authorize(principal, version.resource_uri, cap.id, digest) do
      {:ok, Map.put(version, :approval, VersionCore.reference(version, cap.id, digest))}
    else
      {:error, _} = error -> error
      _ -> {:error, :skill_not_approved}
    end
  rescue
    _ -> {:error, :skill_approval_unavailable}
  catch
    _, _ -> {:error, :skill_approval_unavailable}
  end

  def active(principal, entries) do
    entries
    |> bounded_entries()
    |> Enum.flat_map(fn entry ->
      case resolve(VersionCore.field(entry, :name), principal, entry) do
        {:ok, version} ->
          [
            Map.merge(
              Map.new(
                [:name, :description, :body, :taint, :provenance],
                &{&1, VersionCore.field(version.skill, &1)}
              ),
              version.approval
            )
          ]

        _ ->
          []
      end
    end)
  end

  def pinned(name) do
    with {:ok, version} <- prepare(name),
         pins when is_map(pins) <- Config.trusted_skill_versions(),
         digest when is_binary(digest) <- Map.get(pins, name),
         true <- VersionCore.digest?(digest) and digest == version.digest do
      {:ok, version.skill}
    else
      _ -> {:error, :skill_not_pinned}
    end
  end

  def status(name, principal, reference \\ nil) do
    case resolve(name, principal, reference) do
      {:ok, version} ->
        %{
          name: version.name,
          version_digest: version.digest,
          approval_state: "approved",
          approval: version.approval
        }

      {:error, :skill_version_changed} ->
        %{name: name, approval_state: "changed"}

      {:error, :skill_approval_unavailable} ->
        %{name: name, approval_state: "unavailable"}

      _ ->
        %{name: name, approval_state: if(is_nil(reference), do: "unapproved", else: "revoked")}
    end
  end

  def manifest(principal, entries) do
    with pins when is_map(pins) and map_size(pins) <= 64 <- Config.trusted_skill_versions(),
         {:ok, bytes} <- TaintEnvelope.canonical_json(pins),
         true <- byte_size(bytes) <= 16_384 do
      versions =
        active(principal, entries)
        |> Enum.map(&Map.take(&1, [:name, :version_digest, :approval_id, :approval_digest]))

      builtin_versions =
        Enum.map(pins, fn {name, digest} ->
          current =
            case prepare(name) do
              {:ok, version} -> version.digest
              _ -> nil
            end

          %{
            name: name,
            expected_digest: digest,
            current_digest: current,
            state:
              if(VersionCore.digest?(digest) and current == digest,
                do: "pinned",
                else: "fallback"
              )
          }
        end)

      implementation =
        Enum.map(
          [
            SkillLibrary,
            __MODULE__,
            VersionCore,
            Arbor.Common.SkillLibrary.SkillAdapter,
            Arbor.Common.SkillLibrary.FabricAdapter,
            Arbor.Common.SkillLibrary.RawAdapter
          ],
          fn module ->
            %{
              module: Atom.to_string(module),
              loaded_md5: Base.encode16(module.module_info(:md5), case: :lower)
            }
          end
        )

      {:ok,
       %{
         active_versions: Enum.sort_by(versions, & &1.name),
         builtin_versions: Enum.sort_by(builtin_versions, & &1.name),
         builtin_pin_digest: VersionCore.sha256(bytes),
         implementation: implementation
       }}
    else
      _ -> {:error, :skill_manifest_unavailable}
    end
  rescue
    _ -> {:error, :skill_manifest_unavailable}
  catch
    _, _ -> {:error, :skill_manifest_unavailable}
  end

  defp expected_version(_, nil), do: :ok

  defp expected_version(version, reference),
    do:
      if(VersionCore.match_reference(version, reference),
        do: :ok,
        else: {:error, :skill_version_changed}
      )

  defp expected_cap(_, _, nil), do: :ok

  defp expected_cap(cap, digest, reference) do
    if VersionCore.field(reference, :approval_id) == cap.id and
         VersionCore.field(reference, :approval_digest) == digest,
       do: :ok,
       else: {:error, :skill_not_approved}
  end

  defp selected_cap(principal, version, reference)
       when is_binary(principal) and byte_size(principal) <= 256 do
    with module when is_atom(module) and not is_nil(module) <- Config.skill_security_module(),
         {:ok, caps} when is_list(caps) <- apply(module, :list_capabilities, [principal]) do
      case Enum.find(caps, fn cap ->
             is_struct(cap, Capability) and cap.resource_uri == version.resource_uri and
               (is_nil(reference) or cap.id == VersionCore.field(reference, :approval_id))
           end) do
        nil -> {:error, :skill_not_approved}
        cap -> {:ok, cap}
      end
    else
      _ -> {:error, :skill_approval_unavailable}
    end
  end

  defp selected_cap(_, _, _), do: {:error, :skill_not_approved}

  defp authorize(principal, uri, id, digest) do
    case Config.skill_security_module() do
      nil ->
        {:error, :skill_approval_unavailable}

      module ->
        apply(module, :authorize_source_owned_selected_ordinary_capability, [
          principal,
          uri,
          :execute,
          id,
          digest
        ])
    end
  end

  defp bounded_entries(entries), do: bounded_entries(entries, 8, [])
  defp bounded_entries([], _, acc), do: Enum.reverse(acc)

  defp bounded_entries([entry | rest], n, acc) when is_map(entry) and n > 0,
    do: bounded_entries(rest, n - 1, [entry | acc])

  defp bounded_entries(_, _, _), do: []
end
