defmodule Arbor.Contracts.LLM.AuthProvenance do
  @moduledoc """
  Versioned, closed metadata for the owner of a rotating authentication family.

  This contract deliberately carries no credential, token, authority, or
  executable data. `source` identifies where read-through metadata came from;
  it is not a path or a secret.
  """

  use TypedStruct

  alias Arbor.Contracts.LLM.ControlPlaneSupport, as: Support

  @schema_version 1
  @owners ["arbor_owned", "source_owned"]
  @fields [:version, :owner, :generation, :source, :source_generation, :source_observed_at]
  @max_bytes 16_384

  typedstruct enforce: true do
    field(:version, pos_integer(), default: @schema_version)
    field(:owner, String.t())
    field(:generation, non_neg_integer())
    field(:source, String.t())
    field(:source_generation, non_neg_integer() | nil, default: nil)
    field(:source_observed_at, String.t() | nil, default: nil)
  end

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec owners() :: [String.t()]
  def owners, do: @owners

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, tuple()}
  def new(attrs) do
    with {:ok, attrs} <- Support.normalize_object(attrs, @fields, :invalid_auth_provenance),
         {:ok, version} <- version(Map.get(attrs, :version, @schema_version)),
         {:ok, owner} <- Support.normalize_enum(Map.get(attrs, :owner), @owners, :owner),
         {:ok, generation} <- generation(Map.get(attrs, :generation), :generation),
         {:ok, source} <- Support.normalize_identifier(Map.get(attrs, :source), :source),
         {:ok, source_generation} <-
           Support.optional_nonnegative_integer(attrs, :source_generation),
         {:ok, source_observed_at, _datetime} <-
           Support.optional_timestamp(attrs, :source_observed_at) do
      {:ok,
       %__MODULE__{
         version: version,
         owner: owner,
         generation: generation,
         source: source,
         source_generation: source_generation,
         source_observed_at: source_observed_at
       }}
    end
  rescue
    _ -> {:error, {:invalid_auth_provenance, :malformed}}
  catch
    _, _ -> {:error, {:invalid_auth_provenance, :malformed}}
  end

  @spec to_map(t()) :: map() | {:error, tuple()}
  def to_map(%__MODULE__{} = provenance) do
    %{
      "version" => provenance.version,
      "owner" => provenance.owner,
      "generation" => provenance.generation,
      "source" => provenance.source
    }
    |> Support.put_optional("source_generation", provenance.source_generation)
    |> Support.put_optional("source_observed_at", provenance.source_observed_at)
  end

  def to_map(_value), do: {:error, {:invalid_auth_provenance, :struct_required}}

  @spec normalize(map() | keyword()) :: {:ok, map()} | {:error, tuple()}
  def normalize(attrs) do
    with {:ok, provenance} <- new(attrs), do: {:ok, to_map(provenance)}
  end

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = provenance), do: match?({:ok, _}, new(to_map(provenance)))
  def valid?(attrs) when is_map(attrs) or is_list(attrs), do: match?({:ok, _}, new(attrs))
  def valid?(_attrs), do: false

  @spec canonical_bytes(t() | map() | keyword()) :: {:ok, binary()} | {:error, tuple()}
  def canonical_bytes(%__MODULE__{} = provenance) do
    with {:ok, normalized} <- new(to_map(provenance)),
         {:ok, bytes} <-
           Support.canonical_bytes(
             to_map(normalized),
             @fields,
             :invalid_auth_provenance,
             @max_bytes
           ) do
      {:ok, bytes}
    end
  end

  def canonical_bytes(attrs) when is_map(attrs) or is_list(attrs) do
    with {:ok, provenance} <- new(attrs), do: canonical_bytes(provenance)
  end

  def canonical_bytes(_value), do: {:error, {:invalid_auth_provenance, :object_required}}

  @spec digest(t() | map() | keyword()) :: {:ok, String.t()} | {:error, tuple()}
  def digest(value) do
    with {:ok, bytes} <- canonical_bytes(value),
         do: Support.digest(bytes, :invalid_auth_provenance)
  rescue
    _ -> {:error, {:invalid_auth_provenance, :malformed}}
  catch
    _, _ -> {:error, {:invalid_auth_provenance, :malformed}}
  end

  defp version(@schema_version), do: {:ok, @schema_version}
  defp version(_version), do: {:error, {:invalid_field, "version"}}

  defp generation(value, _field)
       when is_integer(value) and value >= 0 and value <= 1_000_000_000_000,
       do: {:ok, value}

  defp generation(_value, field), do: {:error, {:invalid_field, Atom.to_string(field)}}
end
