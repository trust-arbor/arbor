defmodule Arbor.Common.Sanitizers.XSSTest do
  use ExUnit.Case, async: true

  alias Arbor.Common.Sanitizers.XSS
  alias Arbor.Contracts.Security.Taint

  @bit 0b00000001

  describe "sanitize/3" do
    test "clean input entity-encoded with bit set" do
      taint = %Taint{level: :untrusted}
      {:ok, sanitized, updated} = XSS.sanitize("Hello World", taint)
      assert sanitized == "Hello World"
      assert Bitwise.band(updated.sanitizations, @bit) == @bit
    end

    test "encodes angle brackets" do
      taint = %Taint{}
      {:ok, sanitized, _} = XSS.sanitize("<b>bold</b>", taint)
      assert sanitized =~ "&lt;"
      assert sanitized =~ "&gt;"
    end

    test "encodes ampersand" do
      taint = %Taint{}
      {:ok, sanitized, _} = XSS.sanitize("a & b", taint)
      assert sanitized == "a &amp; b"
    end

    test "encodes quotes" do
      taint = %Taint{}
      {:ok, sanitized, _} = XSS.sanitize("say \"hello\" & 'bye'", taint)
      assert sanitized =~ "&quot;"
      assert sanitized =~ "&#39;"
    end

    test "neutralizes script tags via entity encoding" do
      taint = %Taint{}
      {:ok, sanitized, _} = XSS.sanitize("<script>alert('xss')</script>", taint)
      # Angle brackets are entity-encoded, preventing script execution
      refute sanitized =~ "<script>"
      assert sanitized =~ "&lt;script&gt;"
    end

    test "blocks javascript: URIs" do
      taint = %Taint{}
      {:ok, sanitized, _} = XSS.sanitize("javascript:alert(1)", taint)
      assert sanitized =~ "blocked:"
      refute sanitized =~ "javascript:"
    end

    test "blocks event handlers" do
      taint = %Taint{}
      {:ok, sanitized, _} = XSS.sanitize("<div onclick=\"alert(1)\">", taint)
      assert sanitized =~ "data-blocked-onclick"
      refute sanitized =~ " onclick="
    end

    test "blocks CSS expressions" do
      taint = %Taint{}
      {:ok, sanitized, _} = XSS.sanitize("style: expression(alert(1))", taint)
      assert sanitized =~ "blocked-expression"
    end

    test "handles double-encoded XSS" do
      taint = %Taint{}
      # %3Cscript%3E → <script> after decode → entity-encoded
      {:ok, sanitized, _} = XSS.sanitize("%3Cscript%3Ealert(1)%3C/script%3E", taint)
      refute sanitized =~ "<script>"
      assert sanitized =~ "&lt;"
    end

    test "handles triple-encoded XSS" do
      taint = %Taint{}
      # %253Cscript%253E → %3Cscript%3E → <script> → entity-encoded
      {:ok, sanitized, _} = XSS.sanitize("%253Cscript%253Ealert(1)%253C/script%253E", taint)
      refute sanitized =~ "<script>"
      assert sanitized =~ "&lt;"
    end

    test "handles Unicode escape XSS" do
      taint = %Taint{}
      {:ok, sanitized, _} = XSS.sanitize("\\u003Cscript\\u003Ealert(1)", taint)
      refute sanitized =~ "<script"
    end

    test "preserves existing sanitization bits" do
      taint = %Taint{sanitizations: 0b00000010}
      {:ok, _, updated} = XSS.sanitize("safe", taint)
      assert Bitwise.band(updated.sanitizations, 0b00000010) == 0b00000010
      assert Bitwise.band(updated.sanitizations, @bit) == @bit
    end
  end

  describe "detect/1" do
    test "clean input is safe" do
      assert {:safe, 1.0} = XSS.detect("Hello World")
    end

    test "detects script tag" do
      {:unsafe, patterns} = XSS.detect("<script>alert(1)</script>")
      assert "script_tag" in patterns
    end

    test "detects javascript URI" do
      {:unsafe, patterns} = XSS.detect("javascript:alert(1)")
      assert "javascript_uri" in patterns
    end

    test "detects event handler" do
      {:unsafe, patterns} = XSS.detect("<img onerror=\"alert(1)\">")
      assert "event_handler" in patterns
    end

    test "detects iframe injection" do
      {:unsafe, patterns} = XSS.detect("<iframe src=\"evil.com\">")
      assert "iframe_tag" in patterns
    end

    test "detects data URI with HTML" do
      {:unsafe, patterns} = XSS.detect("data:text/html,<script>")
      assert "data_uri_html" in patterns
    end

    test "detects CSS expression" do
      {:unsafe, patterns} = XSS.detect("expression(alert(1))")
      assert "css_expression" in patterns
    end

    test "flags encoded sequences as evasion" do
      {:unsafe, patterns} = XSS.detect("%3Cscript%3E")
      assert "encoded_lt" in patterns
    end

    test "flags HTML hex encoding" do
      {:unsafe, patterns} = XSS.detect("&#x3C;script&#x3E;")
      assert "html_hex_encoded_lt" in patterns
    end

    test "flags Unicode escapes" do
      {:unsafe, patterns} = XSS.detect("\\u003Cscript\\u003E")
      assert "unicode_escape_lt" in patterns
    end

    test "non-string returns safe" do
      assert {:safe, 1.0} = XSS.detect(42)
    end
  end

  describe "decode_value/1" do
    test "single URL encoding" do
      assert XSS.decode_value("%3C") == "<"
    end

    test "double URL encoding" do
      assert XSS.decode_value("%253C") == "<"
    end

    test "triple URL encoding decoded within max rounds" do
      assert XSS.decode_value("%25253C") == "<"
    end

    test "Unicode escapes normalized" do
      assert XSS.decode_value("\\u003C") == "<"
    end

    test "stable value not modified" do
      assert XSS.decode_value("hello") == "hello"
    end
  end

  describe "html_entity_encode/1" do
    test "encodes all 5 critical characters" do
      assert XSS.html_entity_encode("&<>\"'") == "&amp;&lt;&gt;&quot;&#39;"
    end

    test "leaves normal text unchanged" do
      assert XSS.html_entity_encode("hello world") == "hello world"
    end

    test "ampersand encoded first prevents double-encoding" do
      assert XSS.html_entity_encode("&lt;") == "&amp;lt;"
    end
  end
end
