defmodule Arbor.Agent.Profile do
  @moduledoc """
  An agent's complete identity profile.

  The Profile is the trust-arbor equivalent of old arbor's Seed.
  It composes a Character (personality, voice, knowledge) with
  Arbor-specific security and lifecycle fields (trust tier, capabilities,
  cryptographic identity).

  ## Two Layers

  - **Character** — personality, voice, traits, knowledge, instructions.
    Rendered to system prompts via `Character.to_system_prompt/1`.
  - **Profile** (this struct) — security identity, trust tier, capabilities,
    goals. Manages the Arbor-specific concerns.
  """

  use TypedStruct

  alias Arbor.Agent.Character
  alias Arbor.Common.SafeAtom

  @known_tiers ~w(untrusted probationary trusted veteran autonomous)a

  typedstruct do
    field(:agent_id, String.t(), enforce: true)
    field(:display_name, String.t(), default: nil)
    field(:character, Character.t(), enforce: true)
    field(:trust_tier, atom(), default: :untrusted)
    field(:template, atom(), default: nil)
    field(:initial_goals, [map()], default: [])
    field(:initial_capabilities, [map()], default: [])
    field(:identity, map(), default: nil)
    field(:keychain_ref, String.t(), default: nil)
    field(:metadata, map(), default: %{})
    field(:created_at, DateTime.t())
    field(:version, pos_integer(), default: 1)
  end

  @doc """
  Render the agent's personality to a system prompt.
  """
  @spec system_prompt(t()) :: String.t()
  def system_prompt(%__MODULE__{character: character}) do
    Character.to_system_prompt(character)
  end

  @doc """
  Serialize the profile to a JSON-encodable map.

  Private keys are NOT included — only public identity data.
  """
  @spec serialize(t()) :: map()
  def serialize(%__MODULE__{} = profile) do
    %{
      "version" => profile.version,
      "agent_id" => profile.agent_id,
      "display_name" => profile.display_name,
      "trust_tier" => Atom.to_string(profile.trust_tier),
      "template" => if(profile.template, do: Atom.to_string(profile.template)),
      "character" => Character.to_map(profile.character),
      "initial_goals" => profile.initial_goals,
      "initial_capabilities" => profile.initial_capabilities,
      "identity" => serialize_identity(profile.identity),
      "keychain_ref" => profile.keychain_ref,
      "metadata" => profile.metadata,
      "created_at" => if(profile.created_at, do: DateTime.to_iso8601(profile.created_at))
    }
  end

  @doc """
  Deserialize a profile from a map (e.g., from JSON).
  """
  @spec deserialize(map()) :: {:ok, t()} | {:error, term()}
  def deserialize(map) when is_map(map) do
    profile = %__MODULE__{
      agent_id: map["agent_id"],
      display_name: map["display_name"],
      character: deserialize_character(map),
      trust_tier: safe_to_atom(map["trust_tier"] || "untrusted"),
      template: maybe_to_atom(map["template"]),
      initial_goals: map["initial_goals"] || [],
      initial_capabilities: map["initial_capabilities"] || [],
      identity: deserialize_identity(map["identity"] || legacy_identity(map["identity_ref"])),
      keychain_ref: map["keychain_ref"],
      metadata: map["metadata"] || %{},
      created_at: maybe_datetime(map["created_at"]),
      version: map["version"] || 1
    }

    {:ok, profile}
  rescue
    e -> {:error, e}
  end

  @doc """
  Encode profile to JSON string.
  """
  @spec to_json(t()) :: {:ok, String.t()} | {:error, term()}
  def to_json(%__MODULE__{} = profile) do
    profile
    |> serialize()
    |> Jason.encode(pretty: true)
  end

  @doc """
  Decode profile from JSON string.
  """
  @spec from_json(String.t()) :: {:ok, t()} | {:error, term()}
  def from_json(json) when is_binary(json) do
    with {:ok, map} <- Jason.decode(json) do
      deserialize(map)
    end
  end

  # -- Private helpers --

  defp deserialize_character(map) do
    Character.from_map(map["character"] || %{"name" => "Unknown"})
  end

  defp maybe_to_atom(nil), do: nil
  defp maybe_to_atom(str) when is_binary(str), do: safe_to_atom(str)

  defp serialize_identity(nil), do: nil

  defp serialize_identity(%{} = identity) do
    endorsement = identity[:endorsement]

    %{
      "agent_id" => identity[:agent_id],
      "public_key" => identity[:public_key],
      "endorsement" => serialize_endorsement(endorsement)
    }
  end

  defp serialize_endorsement(nil), do: nil

  defp serialize_endorsement(%{} = e) do
    %{
      "agent_id" => e[:agent_id],
      "agent_public_key" => maybe_hex_encode(e[:agent_public_key]),
      "authority_id" => e[:authority_id],
      "authority_signature" => maybe_hex_encode(e[:authority_signature]),
      "endorsed_at" => if(e[:endorsed_at], do: DateTime.to_iso8601(e[:endorsed_at]))
    }
  end

  defp deserialize_identity(nil), do: nil

  defp deserialize_identity(%{} = map) do
    %{
      agent_id: map["agent_id"],
      public_key: map["public_key"],
      endorsement: deserialize_endorsement(map["endorsement"])
    }
  end

  defp deserialize_endorsement(nil), do: nil

  defp deserialize_endorsement(%{} = map) do
    %{
      agent_id: map["agent_id"],
      agent_public_key: maybe_hex_decode(map["agent_public_key"]),
      authority_id: map["authority_id"],
      authority_signature: maybe_hex_decode(map["authority_signature"]),
      endorsed_at: maybe_datetime(map["endorsed_at"])
    }
  end

  # Backward compat: old profiles stored only "identity_ref" (agent_id string)
  defp legacy_identity(nil), do: nil
  defp legacy_identity(ref) when is_binary(ref), do: %{"agent_id" => ref}

  defp maybe_hex_encode(nil), do: nil
  defp maybe_hex_encode(bin) when is_binary(bin), do: Base.encode16(bin, case: :lower)

  defp maybe_hex_decode(nil), do: nil
  defp maybe_hex_decode(str) when is_binary(str) do
    case Base.decode16(str, case: :mixed) do
      {:ok, bin} -> bin
      :error -> str
    end
  end

  defp maybe_datetime(nil), do: nil

  defp maybe_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp safe_to_atom(str) when is_binary(str) do
    case SafeAtom.to_allowed(str, @known_tiers) do
      {:ok, atom} -> atom
      # Fallback for template module names and other non-tier atoms
      {:error, _} -> String.to_existing_atom(str)
    end
  end

  defp safe_to_atom(atom) when is_atom(atom), do: atom
end
