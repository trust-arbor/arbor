defmodule Arbor.Security.Identity.DefaultRegistrationPolicy do
  @moduledoc false

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security.Config
  alias Arbor.Security.OIDC.Config, as: OIDCConfig

  @local_issuer "arbor://local"
  @max_allowlist_entries 1_024
  @max_subject_bytes 256
  @max_domain_bytes 253

  @spec authorize_registration(Identity.t(), keyword()) :: :ok | {:error, atom()}
  def authorize_registration(%Identity{agent_id: "agent_" <> _rest}, opts)
      when is_list(opts) do
    if Keyword.get(opts, :registration_actor_verified, false) == true or
         Keyword.get(opts, :system_authority_bootstrap, false) == true or
         Keyword.get(opts, :scheduler_identity_bootstrap, false) == true or
         Keyword.get(opts, :trust_capability_grant_owner_bootstrap, false) == true or
         test_fixture_registration?(opts) do
      :ok
    else
      {:error, :registration_actor_required}
    end
  end

  def authorize_registration(%Identity{agent_id: "human_" <> _rest}, opts)
      when is_list(opts) do
    issuer = Keyword.get(opts, :oidc_issuer)

    cond do
      issuer == @local_issuer and
          Application.get_env(:arbor_security, :allow_local_human_identity, false) == true ->
        :ok

      Config.oidc_registration_mode() == :allow ->
        :ok

      allowlisted?(issuer, opts) ->
        :ok

      true ->
        {:error, :oidc_subject_not_allowlisted}
    end
  rescue
    _ -> {:error, :oidc_registration_policy_error}
  catch
    _, _ -> {:error, :oidc_registration_policy_error}
  end

  def authorize_registration(_identity, _opts), do: {:error, :invalid_identity_namespace}

  if Mix.env() == :test do
    defp test_fixture_registration?(opts),
      do: Keyword.get(opts, :test_fixture_registration, false) == true
  else
    defp test_fixture_registration?(_opts), do: false
  end

  defp allowlisted?(issuer, opts) when is_binary(issuer) do
    case configured_provider(issuer) do
      nil ->
        false

      provider ->
        subject_allowlisted?(provider, Keyword.get(opts, :oidc_subject)) or
          email_domain_allowlisted?(
            provider,
            Keyword.get(opts, :oidc_email),
            Keyword.get(opts, :oidc_email_verified, false)
          )
    end
  end

  defp allowlisted?(_issuer, _opts), do: false

  defp configured_provider(issuer) do
    entries = OIDCConfig.providers() ++ List.wrap(OIDCConfig.device_flow())
    Enum.find(entries, &(field(&1, :issuer) == issuer))
  end

  defp subject_allowlisted?(provider, subject) when is_binary(subject) do
    case bounded_string_list(field(provider, :allowed_subjects, []), @max_subject_bytes) do
      {:ok, subjects} -> subject in subjects
      :error -> false
    end
  end

  defp subject_allowlisted?(_provider, _subject), do: false

  defp email_domain_allowlisted?(provider, email, true) when is_binary(email) do
    with {:ok, domain} <- email_domain(email),
         {:ok, domains} <-
           bounded_string_list(field(provider, :allowed_email_domains, []), @max_domain_bytes) do
      domain in Enum.map(domains, &String.downcase/1)
    else
      _ -> false
    end
  end

  defp email_domain_allowlisted?(_provider, _email, _verified), do: false

  defp email_domain(email) do
    case String.split(email, "@") do
      [local, domain]
      when local != "" and domain != "" and byte_size(domain) <= @max_domain_bytes ->
        if String.valid?(domain) and not String.match?(domain, ~r/\s/u),
          do: {:ok, String.downcase(domain)},
          else: :error

      _ ->
        :error
    end
  end

  defp bounded_string_list(values, maximum) when is_list(values) do
    if length(values) <= @max_allowlist_entries and
         Enum.all?(values, fn value ->
           is_binary(value) and byte_size(value) in 1..maximum//1 and String.valid?(value)
         end) do
      {:ok, values}
    else
      :error
    end
  end

  defp bounded_string_list(_values, _maximum), do: :error

  defp field(value, key, default \\ nil)

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp field(_value, _key, default), do: default
end
