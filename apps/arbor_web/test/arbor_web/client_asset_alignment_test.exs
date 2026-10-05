defmodule Arbor.Web.ClientAssetAlignmentTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.LiveViewTest, only: [render_component: 2]

  @moduletag :fast

  defmodule ErrorHTML do
    def render(_template, _assigns), do: "invalid asset request"
  end

  defmodule Endpoint do
    use Arbor.Web.Endpoint,
      otp_app: :arbor_web,
      static_from: {__MODULE__, :app_static_path, []}

    plug(:not_found)

    def app_static_path do
      Application.fetch_env!(:arbor_web, :asset_alignment_test_static_path)
    end

    defp not_found(conn, _opts), do: Plug.Conn.send_resp(conn, 404, "not found")
  end

  setup do
    static_path =
      Path.join(System.tmp_dir!(), "client-assets-#{System.unique_integer([:positive])}")

    key = :asset_alignment_test_static_path
    previous = Application.fetch_env(:arbor_web, Endpoint)
    previous_path = Application.fetch_env(:arbor_web, key)

    for path <- [
          "assets/phoenix/phoenix.mjs",
          "assets/phoenix_live_view/phoenix_live_view.esm.js"
        ] do
      file = Path.join(static_path, path)
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, "app-owned shadow must not win")
    end

    Application.put_env(:arbor_web, key, static_path)

    Application.put_env(:arbor_web, Endpoint,
      server: false,
      secret_key_base: String.duplicate("asset-test-secret", 8),
      render_errors: [formats: [html: ErrorHTML], layout: false]
    )

    start_supervised!(Endpoint)

    on_exit(fn ->
      restore_env(Endpoint, previous)
      restore_env(key, previous_path)
      File.rm_rf!(static_path)
    end)

    :ok
  end

  test "browser dependency GET bytes match installed applications despite app asset shadows" do
    for {application, filename, url} <- asset_cases() do
      conn = request(:get, versioned(application, url))
      assert conn.status == 200

      assert conn.resp_body ==
               File.read!(Application.app_dir(application, "priv/static/#{filename}"))

      assert get_resp_header(conn, "content-type") |> hd() =~ "javascript"
    end
  end

  test "dependency clients support HEAD and conditional revalidation without immutable query caching" do
    for {_application, _filename, url} <- asset_cases() do
      conn = request(:get, url)
      assert conn.status == 200
      [etag] = get_resp_header(conn, "etag")
      assert request(:head, url).resp_body == ""

      cached =
        Plug.Test.conn(:get, url) |> put_req_header("if-none-match", etag) |> Endpoint.call([])

      assert cached.status == 304

      for query <- ["", "?v=installed", "?vsn=not-an-immutable-build"] do
        assert request(:get, url <> query) |> get_resp_header("cache-control") ==
                 ["public, max-age=0, must-revalidate"]
      end
    end
  end

  test "only the two shipped ES clients are exposed from dependency directories" do
    for url <- [
          "/assets/phoenix/phoenix.min.js",
          "/assets/phoenix/phoenix.min.mjs",
          "/assets/phoenix/phoenix.mjs.map",
          "/assets/phoenix/package.json",
          "/assets/phoenix/phoenix.mjs/nested.js",
          "/assets/phoenix_extra/phoenix.mjs",
          "/assets/phoenix_live_view/phoenix_live_view.cjs.js",
          "/assets/phoenix_live_view/phoenix_live_view.esm.js.map"
        ] do
      assert request(:get, url).status == 404
    end
  end

  test "preserves existing traversal denial for allowed dependency filenames" do
    for url <- [
          "/assets/phoenix/phoenix.mjs/../package.json",
          "/assets/phoenix/phoenix.mjs/%2e%2e/package.json",
          "/assets/phoenix_live_view/phoenix_live_view.esm.js/%2e%2e/package.json",
          "/assets/phoenix/phoenix.mjs%2f..%2fpackage.json"
        ] do
      assert_raise Plug.Static.InvalidPathError, fn -> request(:get, url) end
    end
  end

  test "rendered root importmap and preloads share exact same-origin installed-version URLs" do
    html = render_component(&Arbor.Web.Layouts.root/1, %{inner_content: "asset alignment"})
    document = Floki.parse_document!(html)
    [importmap] = Floki.find(document, "script[type=importmap]")
    imports = importmap |> Floki.text(js: true) |> Jason.decode!() |> Map.fetch!("imports")

    expected =
      Map.new(asset_cases(), fn {application, _filename, url} ->
        {Atom.to_string(application), versioned(application, url)}
      end)

    assert imports == expected

    assert Floki.attribute(document, "link[rel=modulepreload]", "href") |> Enum.sort() ==
             expected |> Map.values() |> Enum.sort()

    for {application, _filename, url} <- asset_cases() do
      uri = URI.parse(imports[Atom.to_string(application)])
      assert uri.scheme == nil and uri.host == nil and uri.path == url

      assert URI.decode_query(uri.query) == %{
               "v" => to_string(Application.spec(application, :vsn))
             }

      assert request(:get, imports[Atom.to_string(application)]).status == 200
    end

    refute html =~ "cdn.jsdelivr.net"
    {importmap_index, _} = :binary.match(html, "type=\"importmap\"")
    {application_index, _} = :binary.match(html, "src=\"/assets/arbor_web.js\"")
    assert importmap_index < application_index
  end

  test "existing shared application assets remain available" do
    for filename <- ["arbor_web.css", "arbor_web.js"] do
      conn = request(:get, "/assets/#{filename}")
      assert conn.status == 200

      assert conn.resp_body ==
               File.read!(Application.app_dir(:arbor_web, "priv/static/#{filename}"))
    end
  end

  defp asset_cases do
    [
      {:phoenix, "phoenix.mjs", "/assets/phoenix/phoenix.mjs"},
      {:phoenix_live_view, "phoenix_live_view.esm.js",
       "/assets/phoenix_live_view/phoenix_live_view.esm.js"}
    ]
  end

  defp versioned(application, url),
    do: url <> "?v=" <> URI.encode_www_form(to_string(Application.spec(application, :vsn)))

  defp request(method, path), do: Plug.Test.conn(method, path) |> Endpoint.call([])

  defp restore_env(key, {:ok, value}), do: Application.put_env(:arbor_web, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:arbor_web, key)
end
