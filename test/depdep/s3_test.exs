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

  defp tmp_path do
    path = Path.join(System.tmp_dir!(), "s3-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  # Serves one object, sending the head and the body as separate writes. The
  # separation is the point: concatenating them would allocate a second binary
  # the size of the object inside the test, which is exactly what the streaming
  # measurement in `get/3` is watching for.
  defp serve_object(bytes) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: :raw])
    {:ok, port} = :inet.port(listen)

    spawn_link(fn ->
      {:ok, sock} = :gen_tcp.accept(listen)
      {:ok, _request} = :gen_tcp.recv(sock, 0, 3000)
      :gen_tcp.send(sock, "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(bytes)}\r\n\r\n")
      :gen_tcp.send(sock, bytes)
      :gen_tcp.close(sock)
      :gen_tcp.close(listen)
    end)

    port
  end

  # Runs `fun` and returns `{its result, the most the BEAM's refc-binary memory
  # grew while it ran}`. Sampled from another process: the memory a buffering
  # implementation holds is garbage the moment the call returns, so a reading
  # taken after it cannot see the peak.
  defp peak_binary_growth(fun) do
    :erlang.garbage_collect()
    base = :erlang.memory(:binary)
    parent = self()
    sampler = spawn(fn -> sample(base) end)

    result = fun.()
    send(sampler, {:peak, parent})

    peak =
      receive do
        {:peak, peak} -> peak
      after
        5000 -> flunk("the memory sampler never answered")
      end

    {result, peak - base}
  end

  defp sample(peak) do
    receive do
      {:peak, from} -> send(from, {:peak, peak})
    after
      2 -> sample(max(peak, :erlang.memory(:binary)))
    end
  end

  setup do
    S3.start()
    :ok
  end

  describe "put/3" do
    @tag verifies: "spec/04-store-layout.md#s3-surface/Depdep.S3.put"
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
    @tag verifies: "spec/04-store-layout.md#s3-surface/Depdep.S3.put"
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

  describe "get/3" do
    @tag verifies: "spec/04-store-layout.md#s3-surface/Depdep.S3.get/3"
    test "writes the object's exact bytes to the destination, and never the file on an error" do
      {_agent, port} = Depdep.FakeStore.start(%{"v2/x/1/abc.tar.gz" => {"bytes", %{}}})
      dest = tmp_path()

      assert S3.get(config(port), "v2/x/1/abc.tar.gz", dest) == :ok
      assert File.read!(dest) == "bytes"

      # A miss, a bad status and an unreachable store each travel as
      # `{:error, reason}` — `get/3` is on the restore path, where the caller
      # degrades to a compile, so a raise here is the failure the row's sibling
      # claim ("never a raise, so a flaky store degrades to a compile") forbids.
      # None of the three may leave a destination file behind: a half-written or
      # empty archive that a later run mistakes for a restored one is worse than
      # no file at all.
      absent = tmp_path()
      assert S3.get(config(port), "v2/x/1/absent.tar.gz", absent) == {:error, "not found"}
      refute File.exists?(absent)

      failed = tmp_path()

      assert S3.get(config(serve_status(503)), "v2/x/1/abc.tar.gz", failed) ==
               {:error, "GET returned 503"}

      refute File.exists?(failed)

      unreachable = tmp_path()
      assert {:error, _reason} = S3.get(config(1), "v2/x/1/abc.tar.gz", unreachable)
      refute File.exists?(unreachable)
    end

    # **The measurement, not a call.** The row claims `get/3` "streams to a
    # destination path, so a large object never sits in memory", and a test that
    # only asserted the bytes arrive would pass just as well against an
    # implementation that read the whole response into a binary and wrote it out
    # — which is the implementation this claim exists to forbid. So the object's
    # size is the assertion: 48 MiB is served, and the BEAM's binary memory is
    # required never to grow by anything close to it while the transfer runs.
    #
    # Proven red before it was trusted, and it took two tries to prove the right
    # thing. Replacing `stream:` with a plain GET first failed on the size
    # assertion above instead — `request/8` runs the response through
    # `to_string/1`, so a buffering `get/3` cannot even round-trip binary data —
    # which left the memory assertion itself never reached. The mutation that
    # tests it is `body_format: :binary` plus `File.write!(dest, body)`: the file
    # is then written correctly and **peak binary growth goes from 3.0 MiB to
    # 48 MiB**, the whole object. The bound below sits clear of both.
    #
    # The peak is sampled from another process because the memory is released as
    # soon as `get/3` returns — a reading taken afterwards cannot see it.
    @tag verifies: "spec/04-store-layout.md#s3-surface/Depdep.S3.get/3"
    test "streams a large object rather than holding it in memory" do
      bytes = :crypto.strong_rand_bytes(48 * 1024 * 1024)
      port = serve_object(bytes)
      dest = tmp_path()

      {result, growth} =
        peak_binary_growth(fn -> S3.get(config(port), "v2/x/1/big.tar.gz", dest) end)

      assert result == :ok
      assert File.stat!(dest).size == byte_size(bytes)

      assert growth < 16 * 1024 * 1024,
             "peak binary memory grew by #{div(growth, 1024 * 1024)} MiB transferring a " <>
               "#{div(byte_size(bytes), 1024 * 1024)} MiB object: the response is being held " <>
               "in memory rather than streamed to #{dest}"
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
    #
    # **httpc is put into the wrong state first, and `start/0` called from the
    # test body, so that the assertions can fail.** `setup` calls `start/0`
    # before every test here, so reading the options straight back would pass
    # against a `start/0` that had been emptied out — a check that cannot fail,
    # which is the defect this project has hit three times. The values restored
    # below (2 and 5) are httpc's own defaults, which `start/0`'s measurement
    # table records at 0.13 s against 0.09 s.
    @tag verifies: "spec/04-store-layout.md#s3"
    test "httpc may open a session per transfer, and does not queue instead" do
      :ok = :httpc.set_options(max_sessions: 2, max_keep_alive_length: 5)

      assert S3.start() == :ok

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
    @tag verifies: "spec/04-store-layout.md#s3"
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
    @tag verifies: "s3-reserved-characters"
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
    @tag verifies: "spec/04-store-layout.md#s3-surface/Depdep.S3.metadata/2"
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

    @tag verifies: "spec/04-store-layout.md#s3"
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

    @tag verifies: "spec/04-store-layout.md#s3-surface/Depdep.S3.list"
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

    @tag verifies: "spec/04-store-layout.md#s3-surface/Depdep.S3.list"
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
    # The one call in depdep that destroys anything, and it is reached only for what
    # Depdep.Sweep.plan/3 dooms. The key is spelled with the CURRENT schema: it was `v2`,
    # which #166 retired, and a retired schema is a misleading example in the test for the
    # delete path (#170).
    @tag verifies: [
           "spec/08-reclamation.md#rails",
           "spec/04-store-layout.md#s3-surface/Depdep.S3.delete/2"
         ]
    test "removes one object" do
      {port, await} = serve_sequence([""])
      key = "#{Depdep.Key.schema()}/a.tar.gz"

      assert S3.delete(config(port), key) == :ok

      [line | _] = await.()
      assert line == "DELETE /bucket/#{key} HTTP/1.1"
    end
  end

  # `Depdep.FakeStore` answers 200 or 404 and nothing else, but `head/2`'s third
  # branch is the one an operator meets when a store misbehaves. One socket that
  # answers a chosen status, in the shape of `serve_sequence/1` above.
  defp serve_status(status) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: :raw])
    {:ok, port} = :inet.port(listen)

    spawn_link(fn ->
      {:ok, sock} = :gen_tcp.accept(listen)
      {:ok, _request} = :gen_tcp.recv(sock, 0, 3000)
      :gen_tcp.send(sock, "HTTP/1.1 #{status} Oh No\r\nContent-Length: 0\r\n\r\n")
      :gen_tcp.close(sock)
      :gen_tcp.close(listen)
    end)

    port
  end

  # `spec/04-store-layout.md#s3` states this contract in one line: ":hit, :miss or
  # {:error, reason} — never a raise, so a flaky store degrades to a compile". The
  # last clause is the one that matters and nothing checked it (#201, for #160): a
  # raise here would abort the run rather than fall back to building, which is
  # depdep's whole failure posture.
  describe "head/2" do
    @tag verifies: "spec/04-store-layout.md#s3-surface/Depdep.S3.head/2"
    test "an object the store holds is :hit, one it lacks is :miss, by one HEAD each" do
      {agent, port} = Depdep.FakeStore.start(%{"v3/x/1/abc.tar.gz" => {"bytes", %{}}})

      assert S3.head(config(port), "v3/x/1/abc.tar.gz") == :hit
      assert S3.head(config(port), "v3/x/1/absent.tar.gz") == :miss

      # A HEAD, never a GET: asking whether an object exists must not pull its body.
      assert [{"HEAD", _, _}, {"HEAD", _, _}] = Depdep.FakeStore.requests(agent)
    end

    @tag verifies: "spec/04-store-layout.md#s3-surface/Depdep.S3.head/2"
    test "any other status is an error naming it, and an unreachable store is one too" do
      assert S3.head(config(serve_status(503)), "v3/x/1/abc.tar.gz") ==
               {:error, "HEAD returned 503"}

      # Nothing listening at all. The transport failure has to travel as
      # `{:error, reason}` for the caller to degrade to a compile; a raise here is
      # the failure the spec's "never a raise" forbids.
      assert {:error, _reason} = S3.head(config(1), "v3/x/1/abc.tar.gz")
    end
  end
end
