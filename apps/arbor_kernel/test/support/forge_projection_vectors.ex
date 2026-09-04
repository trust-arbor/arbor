defmodule Arbor.Contracts.Coding.ForgeProjectionVectors do
  @moduledoc false

  alias Arbor.Contracts.Coding.ForgeProjection

  @ledger_digest "sha256:c1158ffa3482f3ce65b7c0737d5cfefed360e078142888a36870fc5c5bc9342b"
  @candidate String.duplicate("b", 40)
  @reviewed_commit String.duplicate("c", 40)
  @key_id "agent_poster1234567890abcdef"

  @committed_body_sha256 "4b353a4f2aecdce4c74892e190843877cdde4ff5b4e87cde8d16ade898357b51"

  @committed_canonical_hex "000000196172626f722d666f7267652d70726f6a656374696f6e2d763100000007666163746f727900000011666f7267652e6578616d706c652e636f6d0000000a61636d652f6172626f72000000087461736b2d3030310000000131000000477368613235363a6331313538666661333438326633636536356237633037333764356366656665643336306530373831343238383861333638373066633563356263393334326200000028626262626262626262626262626262626262626262626262626262626262626262626262626262620000001c6167656e745f706f73746572313233343536373839306162636465660000001c6167656e745f706f73746572313233343536373839306162636465660000004034623335336134663261656364636534633734383932653139303834333837376364646534666635623465383763646538643136616465383938333537623531"

  @committed_body_hex "6172626f722d70726f6a656374696f6e3a207631207461736b3d7461736b2d303031206379636c653d31206c65646765723d7368613235363a633131353866666133343832663363653635623763303733376435636665666564333630653037383134323838386133363837306663356335626339333432622063616e6469646174653d626262626262626262626262626262626262626262626262626262626262626262626262626262620a7b2263616e646964617465223a2262626262626262626262626262626262626262626262626262626262626262626262626262626262222c226379636c65223a312c22646973706f736974696f6e223a22737563636565646564222c2265766964656e63655f726566223a2265766964656e63652f7461736b2d3030312f6379636c652d31222c2266696e64696e675f636f756e7473223a7b22626c6f636b696e67223a302c226d616a6f72223a312c226d696e6f72223a302c226e6974223a307d2c226b65795f6964223a226167656e745f706f7374657231323334353637383930616263646566222c226c65646765725f646967657374223a227368613235363a63313135386666613334383266336365363562376330373337643563666566656433363065303738313432383838613336383730666335633562633933343262222c2272657669657765645f636f6d6d6974223a2263636363636363636363636363636363636363636363636363636363636363636363636363636363222c22736368656d61223a226172626f722d666f7267652d70726f6a656374696f6e2d7631222c227461736b223a227461736b2d303031222c22746965725f726561736f6e73223a5b5d2c2276657264696374223a226175746f5f70726f63656564222c22766f74655f636f756e7473223a7b226162737461696e223a302c22617070726f7665223a322c226661696c6564223a302c2272656a656374223a302c227265706f72746564223a307d7d"

  @doc false
  @spec ledger_digest() :: String.t()
  def ledger_digest, do: @ledger_digest

  @doc false
  @spec candidate_oid() :: String.t()
  def candidate_oid, do: @candidate

  @doc false
  @spec reviewed_commit_oid() :: String.t()
  def reviewed_commit_oid, do: @reviewed_commit

  @doc false
  @spec key_id() :: String.t()
  def key_id, do: @key_id

  @doc false
  @spec build_input(map()) :: map()
  def build_input(overrides \\ %{}) do
    Map.merge(
      %{
        "task" => "task-001",
        "cycle" => 1,
        "verdict" => "auto_proceed",
        "disposition" => "succeeded",
        "vote_counts" => %{
          "approve" => 2,
          "reject" => 0,
          "abstain" => 0,
          "failed" => 0,
          "reported" => 0
        },
        "tier_reasons" => [],
        "finding_counts" => %{"blocking" => 0, "major" => 1, "minor" => 0, "nit" => 0},
        "reviewed_commit" => @reviewed_commit,
        "candidate" => @candidate,
        "ledger_digest" => @ledger_digest,
        "evidence_ref" => "evidence/task-001/cycle-1",
        "factory_id" => "factory",
        "forge_host" => "forge.example.com",
        "project" => "acme/arbor",
        "poster_agent_id" => @key_id,
        "key_id" => @key_id
      },
      overrides
    )
  end

  @doc false
  @spec committed_body_sha256() :: String.t()
  def committed_body_sha256, do: @committed_body_sha256

  @doc false
  @spec committed_body_hex() :: String.t()
  def committed_body_hex, do: @committed_body_hex

  @doc false
  @spec committed_canonical_hex() :: String.t()
  def committed_canonical_hex, do: @committed_canonical_hex

  @doc false
  @spec body_sha256(map()) :: {:ok, String.t()} | {:error, term()}
  def body_sha256(input \\ build_input()) do
    with {:ok, body} <- body_without_footer(input) do
      {:ok, Base.encode16(:crypto.hash(:sha256, body), case: :lower)}
    end
  end

  @doc false
  @spec body_hex(map()) :: {:ok, String.t()} | {:error, term()}
  def body_hex(input \\ build_input()) do
    with {:ok, body} <- body_without_footer(input) do
      {:ok, Base.encode16(body, case: :lower)}
    end
  end

  @doc false
  @spec canonical_hex(map()) :: {:ok, String.t()} | {:error, term()}
  def canonical_hex(input \\ build_input()) do
    with {:ok, projection} <- ForgeProjection.build(input),
         {:ok, canonical} <- ForgeProjection.canonical_v1(projection) do
      {:ok, Base.encode16(canonical, case: :lower)}
    end
  end

  @doc false
  @spec body_without_footer(map()) :: {:ok, binary()} | {:error, term()}
  def body_without_footer(input \\ build_input()) do
    with {:ok, projection} <- ForgeProjection.build(input),
         signature <- :crypto.strong_rand_bytes(64),
         {:ok, document} <- ForgeProjection.render(projection, signature),
         [header, rest] <- String.split(document, "\n", parts: 2),
         {:ok, json} <- strip_footer_json(rest) do
      {:ok, ForgeProjection.body_without_footer(header, json)}
    end
  end

  @doc false
  @spec render_document(map()) :: {:ok, binary()} | {:error, term()}
  def render_document(input \\ build_input()) do
    with {:ok, projection} <- ForgeProjection.build(input) do
      ForgeProjection.render(projection, :crypto.strong_rand_bytes(64))
    end
  end

  defp strip_footer_json(rest) do
    case Regex.run(~r/^(?<json>.*)<!-- arbor-sig v1 key=[^ ]+ sig=[A-Za-z0-9+\/=]+ -->$/s, rest) do
      [_, json] -> {:ok, json}
      _ -> {:error, :projection_invalid}
    end
  end
end
