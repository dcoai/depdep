defmodule Depdep.S3Test do
  use ExUnit.Case, async: false

  alias Depdep.S3

  # A socket, not a mock. What matters about `put/3` is what goes out on the
  # wire — an exact content-length, a plain body rather than chunked, and every
  # byte of the file — and none of that is observable from the return value.
  # `:httpc` switching to chunked transfer-encoding would silently invalidate
  # the Signature v4 payload hash, so it is asserted here rather than assumed.
  defp capture_request(body_bytes) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: :raw])
    {:ok, port} = :inet.port(listen)
    parent = self()

    spawn_link(fn ->
      {:ok, sock} = :gen_tcp.accept(listen)
      raw = read_until(sock, "", body_bytes)
      :gen_tcp.send(sock, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
      :gen_tcp.close(sock)
      :gen_tcp.close(listen)
      send(parent, {:request, raw})
    end)

    await = fn ->
      receive do
        {:request, raw} -> raw
      after
        5000 -> flunk("the server never received a complete request")
      end
    end

    {port, await}
  end

  # Reads until the head plus the declared body length have arrived.
  defp read_until(sock, acc, body_bytes) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [_head, body] when byte_size(body) >= body_bytes ->
        acc

      _ ->
        case :gen_tcp.recv(sock, 0, 3000) do
          {:ok, chunk} -> read_until(sock, acc <> chunk, body_bytes)
          {:error, _} -> acc
        end
    end
  end

  defp config(port) do
    %{
      endpoint: "http://127.0.0.1:#{port}",
      bucket: "bucket",
      access_key: "key",
      secret_key: "secret",
      region: "us-east-1",
      host_header: "127.0.0.1:#{port}"
    }
  end

  setup do
    S3.start()
    :ok
  end

  describe "put/3" do
    test "streams the whole file with an exact content-length and no chunking" do
      # Larger than the 64 KiB read chunk, so the body genuinely spans several
      # calls to the body function rather than fitting in one.
      content = :crypto.strong_rand_bytes(200_000)
      path = Path.join(System.tmp_dir!(), "depdep-put-#{System.unique_integer([:positive])}")
      File.write!(path, content)
      on_exit(fn -> File.rm(path) end)

      {port, await} = capture_request(byte_size(content))
      assert S3.put(config(port), "v2/some/object.tar.gz", path) == :ok

      [head, body] = String.split(await.(), "\r\n\r\n", parts: 2)
      head = String.downcase(head)

      assert body == content
      assert head =~ "content-length: #{byte_size(content)}"
      refute head =~ "transfer-encoding: chunked"
    end

    # #66: what an object says about itself is a header, signed with the rest,
    # so it cannot be dropped in transit unnoticed.
    test "metadata goes out as x-amz-meta headers, and is signed" do
      content = "the archive bytes"
      path = Path.join(System.tmp_dir!(), "depdep-meta-#{System.unique_integer([:positive])}")
      File.write!(path, content)
      on_exit(fn -> File.rm(path) end)

      {port, await} = capture_request(byte_size(content))

      assert S3.put(config(port), "v2/some/object.tar.gz", path, %{"compile-us" => 2_500_000}) ==
               :ok

      head = await.() |> String.split("\r\n\r\n", parts: 2) |> hd() |> String.downcase()
      assert head =~ "x-amz-meta-compile-us: 2500000"
      assert head =~ ~r/signedheaders=[^,]*x-amz-meta-compile-us/
    end

    test "signs the streamed body with the hash of the file, not of the empty string" do
      content = "the archive bytes"
      path = Path.join(System.tmp_dir!(), "depdep-sig-#{System.unique_integer([:positive])}")
      File.write!(path, content)
      on_exit(fn -> File.rm(path) end)

      expected = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

      {port, await} = capture_request(byte_size(content))
      assert S3.put(config(port), "v2/some/object.tar.gz", path) == :ok

      head = await.() |> String.split("\r\n\r\n", parts: 2) |> hd() |> String.downcase()
      assert head =~ "x-amz-content-sha256: #{expected}"
    end
  end

  describe "concurrency/0" do
    test "is derived, and bounded at both ends" do
      assert S3.concurrency() >= 8
      assert S3.concurrency() <= 32
    end

    # The number is only real if httpc may open that many connections AND does
    # not prefer queueing over opening them. `max_keep_alive_length` is a queue
    # depth per session, not a companion to `max_sessions`: raising it
    # serialises every transfer behind one socket (measured 2.13 s vs 0.09 s).
    # This test exists to stop that being "fixed" back.
    test "httpc may open a session per transfer, and does not queue instead" do
      {:ok, options} = :httpc.get_options([:max_sessions, :max_keep_alive_length])
      assert options[:max_sessions] >= S3.concurrency()
      assert options[:max_keep_alive_length] <= 1
    end
  end

  describe "encode_path/1" do
    # Mix objects are all unreserved, so this must be the identity for them —
    # a change here would silently strand every object already in a store.
    test "leaves an unreserved key exactly as it was" do
      path = "/bucket/v2/jason/1.4.4/e3b0c44298fc1c14.tar.gz"
      assert S3.encode_path(path) == path
    end

    test "leaves the separators alone" do
      assert S3.encode_path("/a/b/c") == "/a/b/c"
    end

    # The defect this fixes. `apt-get install --print-uris` reports a Debian
    # epoch with the colon already percent-encoded, and the apt provider's key
    # IS that filename — so the key holds a literal `%`, which must reach the
    # server as `%25` or the server decodes it back to `:` and canonicalises
    # something the signature never covered.
    test "encodes a literal percent, so an apt epoch survives the round trip" do
      assert S3.encode_path("/b/cpp_4%3a12.2.0-3_amd64.deb") ==
               "/b/cpp_4%253a12.2.0-3_amd64.deb"
    end

    # The second class of key the old code got wrong for the same reason.
    test "encodes a plus" do
      assert S3.encode_path("/b/libx11-6_2%3a1.8.4-2+deb12u2_amd64.deb") ==
               "/b/libx11-6_2%253a1.8.4-2%2Bdeb12u2_amd64.deb"
    end

    test "encodes a colon and a space" do
      assert S3.encode_path("/b/a:b c.deb") == "/b/a%3Ab%20c.deb"
    end
  end

  describe "the requested path" do
    # The invariant: what goes on the wire is what was signed. `request/7`
    # encodes once and hands the SAME string to `sign/5`, so this asserts the
    # observable half — that the URL carries the encoded form — and the other
    # half holds by construction.
    test "is the encoded key, for a name with reserved characters" do
      content = "package bytes"
      path = Path.join(System.tmp_dir!(), "depdep-enc-#{System.unique_integer([:positive])}")
      File.write!(path, content)
      on_exit(fn -> File.rm(path) end)

      object = "apt/v1/debian-trixie/cpp_4%3a12.2.0-3_amd64.deb"
      {port, await} = capture_request(byte_size(content))
      assert S3.put(config(port), object, path) == :ok

      [request_line | _] = String.split(await.(), "\r\n")

      assert request_line ==
               "PUT /bucket/apt/v1/debian-trixie/cpp_4%253a12.2.0-3_amd64.deb HTTP/1.1"
    end

    test "is unchanged for a mix object" do
      content = "archive"
      path = Path.join(System.tmp_dir!(), "depdep-enc2-#{System.unique_integer([:positive])}")
      File.write!(path, content)
      on_exit(fn -> File.rm(path) end)

      object = "v2/jason/1.4.4/e3b0c44298fc1c14.tar.gz"
      {port, await} = capture_request(byte_size(content))
      assert S3.put(config(port), object, path) == :ok

      [request_line | _] = String.split(await.(), "\r\n")
      assert request_line == "PUT /bucket/#{object} HTTP/1.1"
    end
  end

  # Serves `bodies` in order on one connection, capturing each request line.
  # httpc keeps the connection alive, so paging arrives as two requests on one
  # socket rather than two connections.
  defp serve_sequence(bodies) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: :raw])
    {:ok, port} = :inet.port(listen)
    parent = self()

    spawn_link(fn ->
      {:ok, sock} = :gen_tcp.accept(listen)

      lines =
        Enum.map(bodies, fn body ->
          {:ok, raw} = :gen_tcp.recv(sock, 0, 3000)

          :gen_tcp.send(
            sock,
            "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(body)}\r\n\r\n" <> body
          )

          raw |> String.split("\r\n") |> hd()
        end)

      :gen_tcp.close(sock)
      :gen_tcp.close(listen)
      send(parent, {:lines, lines})
    end)

    await = fn ->
      receive do
        {:lines, lines} -> lines
      after
        5000 -> flunk("the server never received the expected requests")
      end
    end

    {port, await}
  end

  defp listing(keys, next \\ nil) do
    contents =
      Enum.map_join(keys, "", fn {key, size} ->
        "<Contents><Key>#{key}</Key><Size>#{size}</Size>" <>
          "<LastModified>2026-09-07T10:00:00.000Z</LastModified></Contents>"
      end)

    token = if next, do: "<NextContinuationToken>#{next}</NextContinuationToken>", else: ""

    ~s(<?xml version="1.0"?><ListBucketResult>#{contents}#{token}</ListBucketResult>)
  end

  describe "metadata/2" do
    test "reads the object's x-amz-meta headers back from one HEAD" do
      {agent, port} =
        Depdep.FakeStore.start(%{"v2/x/1/abc.tar.gz" => {"bytes", %{"compile-us" => "42"}}})

      assert S3.metadata(config(port), "v2/x/1/abc.tar.gz") == {:ok, %{"compile-us" => "42"}}
      assert S3.metadata(config(port), "v2/x/1/absent.tar.gz") == :miss
      assert [{"HEAD", _, _}, {"HEAD", _, _}] = Depdep.FakeStore.requests(agent)
    end
  end

  describe "canonical_query/1" do
    # The verbs that take no query sign an empty canonical query string, exactly
    # as they did before this existed — so their signatures do not move.
    test "no parameters is an empty string" do
      assert S3.canonical_query([]) == ""
    end

    test "sorts by name" do
      assert S3.canonical_query([{"prefix", "v2/"}, {"list-type", "2"}]) =~
               ~r/^list-type=2&prefix=/
    end

    # Unforgiving in two ways that matter: a space is %20 and never +, and `/`
    # must be encoded in a VALUE even though it is left alone in a path.
    test "a space is %20, never +" do
      assert S3.canonical_query([{"k", "a b"}]) == "k=a%20b"
    end

    test "encodes / + and = in a value" do
      assert S3.canonical_query([{"k", "a/b+c=d"}]) == "k=a%2Fb%2Bc%3Dd"
    end

    # Not a corner case: this is the second page of every listing.
    test "a realistic continuation token survives" do
      token = "eyJDb250aW51/YXRpb24rVG9rZW4="

      assert S3.canonical_query([{"continuation-token", token}]) ==
               "continuation-token=eyJDb250aW51%2FYXRpb24rVG9rZW4%3D"
    end
  end

  describe "list/2" do
    test "returns keys, sizes and modification times" do
      {port, await} = serve_sequence([listing([{"v2/a.tar.gz", 12}, {"apt/v1/b.deb", 34}])])

      assert {:ok, objects} = S3.list(config(port))
      assert Enum.map(objects, & &1.key) == ["v2/a.tar.gz", "apt/v1/b.deb"]
      assert Enum.map(objects, & &1.size) == [12, 34]
      assert Enum.all?(objects, &(&1.last_modified =~ "2026-09-07"))

      [line | _] = await.()
      assert line =~ "list-type=2"
    end

    # A key holding `&` arrives XML-escaped. Getting it back out wrong means
    # every later request is for a different object.
    test "unescapes an entity in a key" do
      {port, _await} = serve_sequence([listing([{"v2/a&amp;b.tar.gz", 1}])])
      assert {:ok, [object]} = S3.list(config(port))
      assert object.key == "v2/a&b.tar.gz"
    end

    test "pages past a continuation token, and sends it on the next request" do
      token = "tok/en+1="

      {port, await} =
        serve_sequence([
          listing([{"one", 1}], token),
          listing([{"two", 2}])
        ])

      assert {:ok, objects} = S3.list(config(port))
      assert Enum.map(objects, & &1.key) == ["one", "two"]

      [_first, second] = await.()
      assert second =~ "continuation-token=tok%2Fen%2B1%3D"
    end

    test "a prefix is passed through" do
      {port, await} = serve_sequence([listing([])])
      assert {:ok, []} = S3.list(config(port), "git/v1/")

      [line | _] = await.()
      assert line =~ "prefix=git%2Fv1%2F"
    end

    # An HTML error page from a proxy must not take the run down.
    test "a body that is not XML is an error, not a crash" do
      {port, _await} = serve_sequence(["<html>nope</html>" |> String.replace("<", "!")])
      assert {:error, reason} = S3.list(config(port))
      assert reason =~ "not XML"
    end
  end

  describe "delete/2" do
    test "removes one object" do
      {port, await} = serve_sequence([""])
      assert S3.delete(config(port), "v2/a.tar.gz") == :ok

      [line | _] = await.()
      assert line == "DELETE /bucket/v2/a.tar.gz HTTP/1.1"
    end
  end
end
