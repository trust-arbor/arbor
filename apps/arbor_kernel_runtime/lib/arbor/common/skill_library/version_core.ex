defmodule Arbor.Common.SkillLibrary.VersionCore do
  @moduledoc false

  alias Arbor.Contracts.Security.TaintEnvelope

  @fields ~w(name description body tags category source metadata license compatibility allowed_tools provenance taint version template_vars source_bytes path)a
  @max_text 262_144

  def new(skill) when is_map(skill) do
    with true <- map_size(skill) <= 32,
         name when is_binary(name) and byte_size(name) in 1..128 <- field(skill, :name),
         true <- String.valid?(name),
         body when is_binary(body) and byte_size(body) <= @max_text <- field(skill, :body),
         true <- String.valid?(body),
         :ok <- source_bytes(field(skill, :source_bytes)),
         :ok <- strings(field(skill, :allowed_tools) || [], 64),
         :ok <- strings(field(skill, :template_vars) || [], 64),
         projection <- Map.new(@fields, &{Atom.to_string(&1), normalize(field(skill, &1))}),
         {:ok, bytes} <- TaintEnvelope.canonical_json(projection),
         true <- byte_size(bytes) <= 1_048_576 do
      digest = sha256(bytes)
      uri = "arbor://skill/use/#{sha256(name)}/#{digest}"
      {:ok, %{name: name, digest: digest, resource_uri: uri, skill: skill}}
    else
      _ -> {:error, :invalid_skill_version}
    end
  rescue
    _ -> {:error, :invalid_skill_version}
  end

  def new(_), do: {:error, :invalid_skill_version}

  def reference(version, cap_id, cap_digest) do
    %{
      name: version.name,
      version_digest: version.digest,
      approval_id: cap_id,
      approval_digest: cap_digest
    }
  end

  def match_reference(version, reference) when is_map(reference) do
    field(reference, :name) == version.name and
      field(reference, :version_digest) == version.digest and
      digest?(field(reference, :approval_digest)) and
      is_binary(field(reference, :approval_id))
  end

  def match_reference(_, _), do: false

  def digest?(value) when is_binary(value) and byte_size(value) == 64,
    do: Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  def digest?(_), do: false

  def field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  def field(_, _), do: nil
  def sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp normalize(value) when is_atom(value) and not is_nil(value) and not is_boolean(value),
    do: Atom.to_string(value)

  defp normalize(value), do: value
  defp source_bytes(nil), do: :ok

  defp source_bytes(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_text,
    do: if(String.valid?(bytes), do: :ok, else: :error)

  defp source_bytes(_), do: :error
  defp strings([], _), do: :ok

  defp strings([s | rest], remaining)
       when is_binary(s) and byte_size(s) <= 1024 and remaining > 0,
       do: if(String.valid?(s), do: strings(rest, remaining - 1), else: :error)

  defp strings(_, _), do: :error
end
