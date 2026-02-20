defmodule Arbor.Common.Sanitizers.SSRFTest do
  use ExUnit.Case, async: true

  alias Arbor.Common.Sanitizers.SSRF
  alias Arbor.Contracts.Security.Taint

  @bit 0b00100000

  describe "sanitize/3" do
    test "valid public URL passes with bit set" do
      taint = %Taint{level: :untrusted}
      {:ok, url, updated} = SSRF.sanitize("https://example.com/api", taint)
      assert url == "https://example.com/api"
      assert Bitwise.band(updated.sanitizations, @bit) == @bit
    end

    test "rejects non-http scheme" do
      taint = %Taint{}
      assert {:error, {:blocked_scheme, "ftp"}} = SSRF.sanitize("ftp://evil.com", taint)
    end

    test "rejects file scheme" do
      taint = %Taint{}
      assert {:error, {:blocked_scheme, "file"}} = SSRF.sanitize("file:///etc/passwd", taint)
    end

    test "rejects missing host" do
      taint = %Taint{}
      assert {:error, _} = SSRF.sanitize("http://", taint)
    end

    test "rejects localhost" do
      taint = %Taint{}
      assert {:error, {:private_ip, "127.0.0.1"}} = SSRF.sanitize("http://localhost/admin", taint)
    end

    test "rejects 127.0.0.1 directly" do
      taint = %Taint{}
      assert {:error, {:private_ip, "127.0.0.1"}} = SSRF.sanitize("http://127.0.0.1/admin", taint)
    end

    test "rejects cloud metadata endpoint" do
      taint = %Taint{}

      assert {:error, {:metadata_endpoint, "169.254.169.254"}} =
               SSRF.sanitize("http://169.254.169.254/latest/meta-data", taint)
    end

    test "rejects blocked port" do
      taint = %Taint{}
      assert {:error, {:blocked_port, 22}} = SSRF.sanitize("http://example.com:22/ssh", taint)
    end

    test "allows port 8080" do
      taint = %Taint{}
      {:ok, _, _} = SSRF.sanitize("http://example.com:8080/api", taint)
    end

    test "allows private IPs when allow_private is true" do
      taint = %Taint{}
      {:ok, _, _} = SSRF.sanitize("http://localhost/api", taint, allow_private: true)
    end

    test "custom allowed schemes" do
      taint = %Taint{}

      {:ok, _, _} =
        SSRF.sanitize("ftp://example.com/file", taint,
          allowed_schemes: ["ftp", "http", "https"],
          allowed_ports: [21, 80, 443, 8080, 8443]
        )
    end

    test "rejects invalid URL" do
      taint = %Taint{}
      assert {:error, {:invalid_url, _}} = SSRF.sanitize("not a url", taint)
    end

    test "preserves existing sanitization bits" do
      taint = %Taint{sanitizations: 0b00000001}
      {:ok, _, updated} = SSRF.sanitize("https://example.com", taint)
      assert Bitwise.band(updated.sanitizations, 0b00000001) == 0b00000001
      assert Bitwise.band(updated.sanitizations, @bit) == @bit
    end
  end

  describe "detect/1" do
    test "public URL is safe" do
      assert {:safe, 1.0} = SSRF.detect("https://example.com/api")
    end

    test "detects localhost" do
      {:unsafe, patterns} = SSRF.detect("http://localhost/admin")
      assert "localhost" in patterns
    end

    test "detects loopback IP" do
      {:unsafe, patterns} = SSRF.detect("http://127.0.0.1/admin")
      assert "loopback_ip" in patterns
    end

    test "detects private 10.x" do
      {:unsafe, patterns} = SSRF.detect("http://10.0.0.1/internal")
      assert "private_ip_10" in patterns
    end

    test "detects private 172.16.x" do
      {:unsafe, patterns} = SSRF.detect("http://172.16.0.1/internal")
      assert "private_ip_172" in patterns
    end

    test "detects private 192.168.x" do
      {:unsafe, patterns} = SSRF.detect("http://192.168.1.1/router")
      assert "private_ip_192" in patterns
    end

    test "detects link-local" do
      {:unsafe, patterns} = SSRF.detect("http://169.254.1.1/cloud")
      assert "link_local_ip" in patterns
    end

    test "detects AWS metadata" do
      {:unsafe, patterns} = SSRF.detect("http://169.254.169.254/latest")
      assert "aws_metadata" in patterns
    end

    test "detects GCP metadata" do
      {:unsafe, patterns} = SSRF.detect("http://metadata.google.internal/v1")
      assert "gcp_metadata" in patterns
    end

    test "detects unusual schemes" do
      {:unsafe, patterns} = SSRF.detect("gopher://internal:25/")
      assert "unusual_scheme" in patterns
    end

    test "detects credentials in URL" do
      {:unsafe, patterns} = SSRF.detect("http://admin:pass@internal/")
      assert "credentials_in_url" in patterns
    end

    test "non-string returns safe" do
      assert {:safe, 1.0} = SSRF.detect(42)
    end
  end
end
