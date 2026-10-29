defmodule KernelStandaloneConsumer.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([], strategy: :one_for_one, name: KernelStandaloneConsumer.Supervisor)
  end
end

defmodule KernelStandaloneConsumer do
  @moduledoc false

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Contracts.Security.SigningAuthority
  alias Arbor.Contracts.Security.SigningAuthority.Validator
  alias Arbor.Contracts.Security.SigningAuthorityBootstrap

  @token "kernel-consumer-bearer-do-not-print"
  @contract_modules [
    SigningAuthority,
    SigningAuthorityBootstrap,
    Validator,
    Identity,
    SignedRequest,
    Arbor.Identifiers
  ]

  def verify!(opts \\ []) do
    if Keyword.get(opts, :require_no_mix, false) do
      false = Code.ensure_loaded?(Mix)
      release_root = Path.expand(System.fetch_env!("KERNEL_RELEASE_ROOT")) <> "/"

      for module <- [__MODULE__ | @contract_modules] do
        path = module |> :code.which() |> List.to_string() |> Path.expand()
        true = String.starts_with?(path, release_root)
      end
    end

    true = :crypto in Application.spec(:arbor_kernel, :applications)
    true = List.keymember?(Application.started_applications(), :crypto, 0)
    true = Application.spec(:arbor_kernel, :mod) in [nil, []]

    {:ok, identity} = Identity.generate(name: "standalone-kernel-consumer")
    true = identity.agent_id == Identity.derive_agent_id(identity.public_key)

    {:ok, request} =
      SignedRequest.sign("standalone-kernel", identity.agent_id, identity.private_key)

    true =
      :crypto.verify(:eddsa, :sha512, SignedRequest.signing_payload(request), request.signature, [
        identity.public_key,
        :ed25519
      ])

    attrs = [token: @token, principal_id: identity.agent_id, purpose: :standalone]
    {:ok, authority} = SigningAuthority.new(attrs)
    {:ok, ^authority} = SigningAuthority.canonicalize(authority)
    {:ok, bootstrap} = SigningAuthorityBootstrap.new(attrs)
    {:ok, ^bootstrap} = SigningAuthorityBootstrap.canonicalize(bootstrap)

    for {contract, value} <- [
          {SigningAuthority, authority},
          {SigningAuthorityBootstrap, bootstrap}
        ] do
      {:ok, ^value} =
        contract.canonicalize(%{
          "token" => @token,
          "principal_id" => identity.agent_id,
          "purpose" => :standalone
        })

      redacted = inspect(value)
      true = String.contains?(redacted, "[REDACTED]")
      false = String.contains?(redacted, @token)
      :ok = reject_json!(value)

      {:error, :token_too_short} =
        contract.canonicalize(%{__struct__: contract, token: "short"})

      {:error, :invalid_purpose} =
        contract.canonicalize(%{
          __struct__: contract,
          token: @token,
          principal_id: identity.agent_id,
          purpose: true
        })

      {:error, :invalid_principal_id} =
        contract.new(token: @token, principal_id: <<255>>, purpose: :standalone)

      {:error, :invalid_principal_id} =
        contract.new(token: @token, principal_id: "agent_unsafe\0suffix", purpose: :standalone)

      {:error, :zero_token} =
        contract.new(
          token: :binary.copy(<<0>>, 32),
          principal_id: identity.agent_id,
          purpose: :standalone
        )

      {:error, :duplicate_attribute} =
        contract.new([
          {:token, @token},
          {"token", @token},
          {:principal_id, identity.agent_id},
          {:purpose, :standalone}
        ])

      {:error, :unknown_attribute} = contract.new(Keyword.put(attrs, :unexpected, :value))
      {:error, :invalid_attrs} = contract.new([:not_an_attribute_pair])
    end

    for module <- @contract_modules do
      {:ok, :arbor_kernel} = :application.get_application(module)
    end

    compiled = compiled_applications()
    loaded = Application.loaded_applications() |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    started = Application.started_applications() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    for apps <- [
          compiled,
          Enum.map(loaded, &Atom.to_string/1),
          Enum.map(started, &Atom.to_string/1)
        ] do
      ["arbor_kernel"] = Enum.filter(apps, &String.starts_with?(&1, "arbor_"))
    end

    false = Code.ensure_loaded?(Arbor.Security)
    false = Code.ensure_loaded?(Arbor.KernelRuntime)

    %{
      package: "arbor_kernel",
      version: Application.spec(:arbor_kernel, :vsn) |> List.to_string(),
      authority_contracts: "canonicalized, redacted, JSON-refused, hostile inputs rejected",
      crypto: "identity generation and signed-request verification passed",
      compiled_applications: compiled,
      loaded_applications: Enum.map(loaded, &Atom.to_string/1),
      started_applications: Enum.map(started, &Atom.to_string/1),
      mix_available: Code.ensure_loaded?(Mix),
      code_paths:
        Map.new(@contract_modules, &{Atom.to_string(&1), List.to_string(:code.which(&1))})
    }
  end

  defp reject_json!(value) do
    Jason.encode!(value)
    raise "opaque signing references unexpectedly have a JSON encoder"
  rescue
    Protocol.UndefinedError -> :ok
  end

  defp compiled_applications do
    :code.get_path()
    |> Enum.map(fn path ->
      path
      |> List.to_string()
      |> Path.dirname()
      |> Path.basename()
      |> String.replace(~r/-\d.*$/, "")
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
