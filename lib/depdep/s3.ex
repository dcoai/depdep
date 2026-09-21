defmodule Depdep.S3 do
  @moduledoc """
  The smallest S3 client that does the job: HEAD, GET to a file, PUT from a file.

  Written out rather than taken from a library because depdep has no
  dependencies — it runs before `mix deps.get`, which is the entire point. AWS
  Signature v4 is about sixty lines, and `:httpc` and `:erl_tar` are in OTP.
  """

  # Read and send in 64 KiB pieces: large enough that the syscall overhead is
  # noise, small enough that N concurrent uploads costs megabytes rather than
  # N whole archives.
  @chunk 65_536

  # Well above the derived maximum of 32, so it never obstructs a real
  # experiment, and low enough that a stray paste cannot point a runner at the
  # shared store with thousands of sessions.
  @concurrency_ceiling 256

  @doc """
  How many transfers may be in flight at once.

  **Derived for every real run, and overridable only as an instrument.** The
  work is IO-bound — a round trip to the store and a tar extraction — so the
  derived value is a multiple of the scheduler count rather than equal to it,
  clamped so a 2-core laptop still overlaps usefully and a 96-core runner does
  not open ninety-six sessions against one MinIO.

  `DEPDEP_CONCURRENCY` overrides it, for one reason. #12's speedup was measured
  against a local socket with injected latency, and concurrency was the one
  variable in that claim that could not be varied on current code — which left
  the claim unfalsifiable, and #41 carrying it as an unmet criterion. With this,
  `DEPDEP_CONCURRENCY=1` is the serial baseline: same commit, same objects, one
  variable. Pinning a pre-#12 commit would have moved five other things at once.

  **It is not a tuning knob.** If a measurement shows the derivation is wrong,
  the fix is to change the derivation.

  **The derived clamp does not apply to an explicit value.** Putting `=1`
  through `max(8)` would run eight transfers and report the run as serial, which
  is exactly the quietly-wrong number the variable exists to prevent.

  **`start/0` has to configure `:httpc` to match, and the obvious way to do
  that is wrong** — see there. The symptom of getting it wrong is a concurrency
  change that measures as no change at all. It calls this function, so an
  override reaches httpc without a second place to keep in step.

  Raises on a value `concurrency_setting/0` refuses. Unreachable through
  `Depdep.CLI`, which reads the environment before any provider runs — so
  reaching it means that check was bypassed, and falling back to the derived
  value would hand back a run labelled with a concurrency it did not use.
  """
  def concurrency do
    case concurrency_setting() do
      {:ok, n} -> n
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc """
  `{:ok, n}`, or `{:error, message}` for a `DEPDEP_CONCURRENCY` it cannot read.

  **Unset means derived**, so every consumer that ignores this variable is
  unaffected, and empty means unset — a CI variable declared without a value is
  ordinary, and both `env/1` and `Depdep.CLI.enabled?/0` already read `""` that
  way.

  **An out-of-range value is refused, not clamped.** Clamping would substitute a
  number the operator did not ask for, which is the same defect as reading
  `one` as 16 and lands in the same place: a measurement labelled with a
  concurrency it did not use. The ceiling is there because three projects now
  share one store, and an instrument must not be the way around the limit that
  keeps a single runner from opening a session per core.
  """
  def concurrency_setting do
    case System.get_env("DEPDEP_CONCURRENCY") do
      nil -> {:ok, derived_concurrency()}
      value -> from_concurrency(String.trim(value))
    end
  end

  defp derived_concurrency, do: (System.schedulers_online() * 4) |> max(8) |> min(32)

  defp from_concurrency(""), do: {:ok, derived_concurrency()}

  defp from_concurrency(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 1 and n <= @concurrency_ceiling ->
        {:ok, n}

      {n, ""} when n > @concurrency_ceiling ->
        {:error,
         "DEPDEP_CONCURRENCY is #{n}; the ceiling is #{@concurrency_ceiling}. " <>
           "Refused rather than clamped, so a run is never labelled with a " <>
           "concurrency it did not use"}

      _ ->
        {:error,
         ~s(DEPDEP_CONCURRENCY is "#{value}"; ) <>
           "it takes a positive integer up to #{@concurrency_ceiling}"}
    end
  end

  @separate ~w(DEPDEP_ENDPOINT DEPDEP_BUCKET DEPDEP_ACCESS_KEY DEPDEP_REGION)

  @doc """
  Where the store is, from the environment, or why it cannot be reached.

  Two forms, and only one may be present (#88):

      DEPDEP_STORE=s3://ACCESS_KEY@host:9000/bucket?region=us-east-1
      DEPDEP_SECRET_KEY=…

  or the four `DEPDEP_ENDPOINT`, `DEPDEP_BUCKET`, `DEPDEP_ACCESS_KEY` and
  `DEPDEP_REGION` beside the same `DEPDEP_SECRET_KEY`. The URL carries the
  shape of the store and the access key; **the secret is never in it** — a
  URL with a password component is refused, because a URL ends up in a shell
  history and a masked variable does not. `s3` is a plain-http endpoint, as
  `DEPDEP_ENDPOINT` is usually written; `s3+https` (or `https`) is TLS.
  Both forms at once is refused rather than merged, for the reason a typo in
  `DEPDEP_ENABLED` is: a half-edited configuration must be loud.

  `{:error, reason}` here is not a failure — the caller reports it and carries on
  without a store. See `Depdep.CLI`.
  """
  def config do
    with :ok <- one_form(),
         {:ok, secret_key} <- required("DEPDEP_SECRET_KEY"),
         {:ok, shape} <- shape(),
         %URI{host: host, port: port, scheme: scheme} when is_binary(host) <-
           URI.parse(shape.endpoint) do
      {:ok,
       %{
         endpoint: String.trim_trailing(shape.endpoint, "/"),
         bucket: shape.bucket,
         access_key: shape.access_key,
         secret_key: secret_key,
         region: shape.region,
         host_header: host_header(host, port, scheme)
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "DEPDEP_ENDPOINT is not a valid URL"}
    end
  end

  defp one_form do
    case {System.get_env("DEPDEP_STORE"),
          Enum.filter(@separate, &(System.get_env(&1) not in [nil, ""]))} do
      {store, [_ | _] = set} when store not in [nil, ""] ->
        {:error,
         "DEPDEP_STORE and #{Enum.join(set, ", ")} are both set — use the URL or the " <>
           "separate variables, not both"}

      _ ->
        :ok
    end
  end

  # The store's shape from whichever form is present: endpoint, bucket,
  # access key, region.
  defp shape do
    case env("DEPDEP_STORE") do
      {:ok, url} ->
        store_url(url)

      {:error, _} ->
        with {:ok, endpoint} <- required("DEPDEP_ENDPOINT"),
             {:ok, bucket} <- required("DEPDEP_BUCKET"),
             {:ok, access_key} <- required("DEPDEP_ACCESS_KEY") do
          {:ok,
           %{
             endpoint: endpoint,
             bucket: bucket,
             access_key: access_key,
             region: System.get_env("DEPDEP_REGION") || "us-east-1"
           }}
        end
    end
  end

  defp required(name) do
    case env(name) do
      {:ok, value} -> {:ok, value}
      {:error, ^name} -> {:error, "#{name} is not set"}
    end
  end

  @doc """
  `DEPDEP_STORE` parsed: `{:ok, %{endpoint, bucket, access_key, region}}` or
  `{:error, reason}` naming what a store URL looks like.
  """
  def store_url(url) do
    uri = URI.parse(url)

    with {:ok, scheme} <- store_scheme(uri.scheme),
         {:ok, access_key} <- store_userinfo(uri.userinfo),
         :ok <- if(is_binary(uri.host) and uri.host != "", do: :ok, else: {:error, :host}),
         {:ok, bucket} <- store_bucket(uri.path) do
      # `URI.parse/1` knows no default port for `s3`, so a port is only ever
      # the one written; for `http`/`https` the scheme default is dropped.
      port =
        if uri.port && uri.port != URI.default_port(scheme), do: ":#{uri.port}", else: ""

      region = (uri.query && URI.decode_query(uri.query)["region"]) || "us-east-1"

      {:ok,
       %{
         endpoint: "#{scheme}://#{uri.host}#{port}",
         bucket: bucket,
         access_key: access_key,
         region: region
       }}
    else
      {:error, :host} ->
        {:error, "DEPDEP_STORE has no host — it looks like s3://ACCESS_KEY@host:port/bucket"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}
    end
  end

  defp store_scheme("s3"), do: {:ok, "http"}
  defp store_scheme("http"), do: {:ok, "http"}
  defp store_scheme("s3+https"), do: {:ok, "https"}
  defp store_scheme("https"), do: {:ok, "https"}

  defp store_scheme(other),
    do: {:error, "DEPDEP_STORE scheme #{inspect(other)} is not one of s3, s3+https, http, https"}

  defp store_userinfo(nil),
    do:
      {:error,
       "DEPDEP_STORE carries no access key — it looks like s3://ACCESS_KEY@host:port/bucket"}

  defp store_userinfo(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [key] when key != "" ->
        {:ok, URI.decode(key)}

      [_, _] ->
        {:error,
         "DEPDEP_STORE carries a password — the secret goes in DEPDEP_SECRET_KEY, never in a URL"}

      _ ->
        {:error,
         "DEPDEP_STORE carries no access key — it looks like s3://ACCESS_KEY@host:port/bucket"}
    end
  end

  defp store_bucket(path) do
    case String.split(path || "", "/", trim: true) do
      [bucket] ->
        {:ok, bucket}

      _ ->
        {:error,
         "DEPDEP_STORE's path must be exactly the bucket — s3://ACCESS_KEY@host:port/bucket"}
    end
  end

  # httpc derives the Host header from the URL and includes the port whenever it
  # is not the scheme default. The signature covers `host`, so this has to agree
  # exactly or every request fails with SignatureDoesNotMatch.
  defp host_header(host, port, scheme) do
    default = if scheme == "https", do: 443, else: 80
    if port in [nil, default], do: host, else: "#{host}:#{port}"
  end

  defp env(name) do
    case System.get_env(name) do
      nil -> {:error, name}
      "" -> {:error, name}
      value -> {:ok, value}
    end
  end

  def start do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    # `max_sessions` is how many connections httpc may open to one host.
    # `max_keep_alive_length` is NOT a companion to it — it is the QUEUE DEPTH
    # on a single session, and httpc prefers filling an existing session's queue
    # over opening another connection.
    #
    # So raising both, which reads like the obvious way to allow more
    # concurrency, does the opposite: every transfer queues behind one socket.
    # Measured on a local server with 20 ms of artificial latency, 100 requests
    # at concurrency 32, after one warm-up request had established a session:
    #
    #     max_sessions 32, max_keep_alive_length 32  ->  2.13 s   (fully serial)
    #     max_sessions 32, max_keep_alive_length  1  ->  0.09 s
    #     default (2 / 5)                            ->  0.13 s
    #
    # Keep the queue at 1 so a waiting request opens a connection instead of
    # joining a line. This is the whole reason the change is worth anything.
    :ok = :httpc.set_options(max_sessions: concurrency(), max_keep_alive_length: 1)

    :ok
  end

  @doc "`:hit`, `:miss`, or `{:error, reason}` — never a raise, so a flaky store degrades to a compile."
  def head(cfg, object) do
    case request(cfg, :head, object, empty_hash(), [], [], []) do
      {:ok, status, _, _} when status in 200..299 -> :hit
      {:ok, 404, _, _} -> :miss
      {:ok, status, _, _} -> {:error, "HEAD returned #{status}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The object's user metadata — every `x-amz-meta-*` header, with the prefix
  stripped — as `{:ok, %{"compile-us" => "2500000"}}`, or `:miss`, or
  `{:error, reason}`.

  One HEAD. The streamed `get/3` hands `:httpc` a file and gets back
  `:saved_to_file` with no headers, so what an object carries about itself has
  to be asked for separately (#66). Called only for a unit that was actually
  fetched, so the cost is one small request per miss-turned-hit and none for
  a unit already present.
  """
  def metadata(cfg, object) do
    case request(cfg, :head, object, empty_hash(), [], [], []) do
      {:ok, status, _, headers} when status in 200..299 -> {:ok, user_metadata(headers)}
      {:ok, 404, _, _} -> :miss
      {:ok, status, _, _} -> {:error, "HEAD returned #{status}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @meta_prefix "x-amz-meta-"

  defp user_metadata(headers) do
    for {key, value} <- headers,
        key = key |> to_string() |> String.downcase(),
        String.starts_with?(key, @meta_prefix),
        into: %{},
        do: {String.replace_prefix(key, @meta_prefix, ""), to_string(value)}
  end

  @doc "Streams to `dest` so a large object never sits in memory."
  def get(cfg, object, dest) do
    case request(cfg, :get, object, empty_hash(), [], [], stream: String.to_charlist(dest)) do
      {:ok, status, _, _} when status in 200..299 -> :ok
      {:ok, 404, _, _} -> {:error, "not found"}
      {:ok, status, _, _} -> {:error, "GET returned #{status}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Streams `source` from disk so a large object never sits in memory.

  Two passes over the file rather than one, and that is Signature v4's price:
  the signature covers a SHA-256 of the payload, so the hash must be known
  before the first byte goes out. Both passes stream.

  `:httpc` takes a body-producing function, and given an explicit
  `content-length` it sends a plain body rather than switching to chunked
  transfer-encoding. That matters — chunked would require the
  `STREAMING-AWS4-HMAC-SHA256-PAYLOAD` signature variant instead of the simple
  one below.

  `metadata` is stored with the object as `x-amz-meta-<key>` headers — signed
  like every other header, so they cannot be dropped in transit unnoticed —
  and read back by `metadata/2`. Values are strings; keep them short.
  """
  def put(cfg, object, source, metadata \\ %{}) do
    size = File.stat!(source).size
    hash = stream_sha256(source)
    body = {&read_chunk/1, File.open!(source, [:binary, :read])}

    extra =
      [{"content-length", "#{size}"}] ++
        Enum.map(metadata, fn {key, value} -> {@meta_prefix <> key, to_string(value)} end)

    case request(cfg, :put, object, hash, extra, [], [], body) do
      {:ok, status, _, _} when status in 200..299 -> :ok
      {:ok, status, body, _} -> {:error, "PUT returned #{status}: #{String.slice(body, 0, 200)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Every object in the bucket, or under `prefix`, paging until the store stops
  saying there is more.

  Used by reclamation, never by a pipeline: `--pull` and `--push` know the exact
  keys they want and never need to enumerate.
  """
  def list(cfg, prefix \\ nil), do: list_page(cfg, prefix, nil, [])

  defp list_page(cfg, prefix, token, acc) do
    query =
      [{"list-type", "2"}] ++
        if(prefix, do: [{"prefix", prefix}], else: []) ++
        if(token, do: [{"continuation-token", token}], else: [])

    case request(cfg, :get, "", empty_hash(), [], query, []) do
      {:ok, status, body, _} when status in 200..299 ->
        case parse_listing(body) do
          {:ok, objects, nil} -> {:ok, acc ++ objects}
          {:ok, objects, next} -> list_page(cfg, prefix, next, acc ++ objects)
          {:error, reason} -> {:error, reason}
        end

      {:ok, status, body, _} ->
        {:error, "LIST returned #{status}: #{String.slice(body, 0, 200)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Removes one object. Reclamation only — a pipeline identity should not be able to."
  def delete(cfg, object) do
    case request(cfg, :delete, object, empty_hash(), [], [], []) do
      {:ok, status, _, _} when status in 200..299 ->
        :ok

      {:ok, status, body, _} ->
        {:error, "DELETE returned #{status}: #{String.slice(body, 0, 200)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `:xmerl` ships with OTP, like `:inets` and `:crypto`, so this is not a
  # dependency in the sense `mix.exs` forbids. It is used rather than a regex
  # because keys are XML-escaped — a key containing `&` arrives as `&amp;` and
  # must come back out as `&`, or every subsequent request for it is for a
  # different object.
  #
  # A body that is not XML at all — an HTML error page from a proxy — is
  # rejected before parsing rather than allowed to raise.
  defp parse_listing(body) do
    if String.starts_with?(String.trim_leading(body), "<") do
      {doc, _rest} = :xmerl_scan.string(String.to_charlist(body), quiet: true)

      objects =
        doc
        |> xpath(~c"//Contents")
        |> Enum.map(fn node ->
          %{
            key: node |> xpath_text(~c"./Key/text()") |> List.first(),
            size: node |> xpath_text(~c"./Size/text()") |> List.first() |> to_integer(),
            last_modified: node |> xpath_text(~c"./LastModified/text()") |> List.first()
          }
        end)

      {:ok, objects, doc |> xpath_text(~c"//NextContinuationToken/text()") |> List.first()}
    else
      {:error, "listing was not XML: #{String.slice(body, 0, 200)}"}
    end
  end

  defp xpath(node, path), do: :xmerl_xpath.string(path, node)

  defp xpath_text(node, path) do
    node
    |> xpath(path)
    |> Enum.map(fn {:xmlText, _, _, _, value, _} -> to_string(value) end)
  end

  defp to_integer(nil), do: nil
  defp to_integer(text), do: String.to_integer(text)

  defp object_path(bucket, ""), do: "/" <> bucket
  defp object_path(bucket, object), do: "/" <> bucket <> "/" <> object

  defp query_suffix(""), do: ""
  defp query_suffix(query), do: "?" <> query

  # `:httpc` calls this with the accumulator until it answers `:eof`. The
  # accumulator is the open file itself, so nothing accrues between calls.
  defp read_chunk(device) do
    case IO.binread(device, @chunk) do
      :eof ->
        File.close(device)
        :eof

      data when is_binary(data) ->
        {:ok, data, device}
    end
  end

  defp stream_sha256(path) do
    path
    |> File.stream!(@chunk)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp empty_hash, do: :crypto.hash(:sha256, "") |> Base.encode16(case: :lower)

  defp request(cfg, method, object, payload_hash, extra, query, http_opts, body \\ nil) do
    # Encoded ONCE, and the same string is both requested and signed. Signature
    # v4 canonicalises the URI-encoded absolute path, and the request must carry
    # that same encoding — so encoding here and again inside `sign/5` made the
    # two disagree for any key holding a reserved character.
    path = encode_path(object_path(cfg.bucket, object))
    canonical_query = canonical_query(query)
    url = cfg.endpoint <> path <> query_suffix(canonical_query)
    headers = sign(cfg, method, path, canonical_query, payload_hash, extra)
    hdrs = Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    req =
      case method do
        :put -> {String.to_charlist(url), hdrs, ~c"application/octet-stream", body}
        _ -> {String.to_charlist(url), hdrs}
      end

    case :httpc.request(method, req, [timeout: 300_000, connect_timeout: 15_000], http_opts) do
      {:ok, :saved_to_file} -> {:ok, 200, "", []}
      {:ok, {{_v, status, _r}, headers, resp}} -> {:ok, status, to_string(resp), headers}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # ── AWS Signature v4 ──────────────────────────────────────────────────────

  defp sign(cfg, method, path, canonical_query, payload_hash, extra) do
    now = DateTime.utc_now()
    amz_date = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    datestamp = Calendar.strftime(now, "%Y%m%d")

    headers =
      [
        {"host", cfg.host_header},
        {"x-amz-content-sha256", payload_hash},
        {"x-amz-date", amz_date}
      ] ++ extra

    canonical =
      headers
      |> Enum.map(fn {k, v} -> {String.downcase(k), String.trim(v)} end)
      |> Enum.sort()

    signed = Enum.map_join(canonical, ";", fn {k, _} -> k end)

    canonical_request =
      Enum.join(
        [
          method |> Atom.to_string() |> String.upcase(),
          path,
          canonical_query,
          Enum.map_join(canonical, "", fn {k, v} -> "#{k}:#{v}\n" end),
          signed,
          payload_hash
        ],
        "\n"
      )

    scope = "#{datestamp}/#{cfg.region}/s3/aws4_request"

    string_to_sign =
      Enum.join(
        [
          "AWS4-HMAC-SHA256",
          amz_date,
          scope,
          :crypto.hash(:sha256, canonical_request) |> Base.encode16(case: :lower)
        ],
        "\n"
      )

    signature =
      ["AWS4" <> cfg.secret_key, datestamp, cfg.region, "s3", "aws4_request"]
      |> Enum.reduce(fn step, key -> :crypto.mac(:hmac, :sha256, key, step) end)
      |> then(&:crypto.mac(:hmac, :sha256, &1, string_to_sign))
      |> Base.encode16(case: :lower)

    auth =
      "AWS4-HMAC-SHA256 Credential=#{cfg.access_key}/#{scope}, " <>
        "SignedHeaders=#{signed}, Signature=#{signature}"

    [{"authorization", auth} | headers]
  end

  # RFC3986 per segment, leaving `/` alone. For a mix object —
  # `v2/<name>/<version>/<hex>.tar.gz`, all unreserved — this is the identity,
  # which is why every object already in a store keeps its key.
  #
  # It is NOT the identity for an apt object, and that is what this exists for.
  # The apt provider's key is the filename apt reported, and
  # `apt-get install --print-uris` gives a Debian epoch with the colon already
  # percent-encoded: `cpp_4%3a12.2.0-3_amd64.deb`. That literal `%` must reach
  # the server as `%25`, or the server decodes it to `:` and canonicalises
  # something the signature never covered. `+` is the same class of problem:
  # reserved in a path, and present in names like
  # `libx11-6_2%3a1.8.4-2+deb12u2_amd64.deb`.
  #
  # Measured before this was fixed, on `dco-tek/metresis`: 10 of 102 packages
  # failed with 403 — exactly the ten whose filename held a `%3a`.
  #
  # The caller encodes once and signs the result. Do not call this again inside
  # the signer.
  @doc """
  The canonical query string: parameters sorted by name, each name and value
  RFC3986-encoded, joined `k=v` with `&`.

  Public because it is the half of the signature that is easiest to get wrong
  and the only part testable without a store. The encoding is unforgiving in two
  ways that matter here: a space is `%20` and never `+`, and `/` must be encoded
  **in a value** even though it is left alone in a path. `continuation-token` is
  opaque base64 that routinely contains `/`, `+` and `=`, so this is not a corner
  case — it is the second page of every listing.

  An empty parameter list yields an empty string, which is what the verbs that
  take no query sign, so their signatures are unchanged.
  """
  def canonical_query([]), do: ""

  def canonical_query(params) do
    params
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.map_join("&", fn {name, value} ->
      encode_component(name) <> "=" <> encode_component(value)
    end)
  end

  defp encode_component(value), do: URI.encode("#{value}", &URI.char_unreserved?/1)

  @doc """
  RFC3986-encodes an object path, per segment, leaving `/` alone.

  Public because it is the rule the whole signature rests on, and the only part
  of it testable without a store.
  """
  def encode_path(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &URI.encode(&1, fn c -> URI.char_unreserved?(c) end))
  end
end
