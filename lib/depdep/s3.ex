defmodule Depdep.S3 do
  @moduledoc """
  The smallest S3 client that does the job: HEAD, GET to a file, PUT from a file.

  Written out rather than taken from a library because depdep has no
  dependencies — it runs before `mix deps.get`, which is the entire point. AWS
  Signature v4 is about sixty lines, and `:httpc` and `:erl_tar` are in OTP.
  """

  @doc """
  Reads the four required environment variables, or says which one is missing.

  `{:error, reason}` here is not a failure — the caller reports it and carries on
  without a store. See `Depdep.CLI`.
  """
  def config do
    with {:ok, endpoint} <- env("DEPDEP_ENDPOINT"),
         {:ok, bucket} <- env("DEPDEP_BUCKET"),
         {:ok, access_key} <- env("DEPDEP_ACCESS_KEY"),
         {:ok, secret_key} <- env("DEPDEP_SECRET_KEY"),
         %URI{host: host, port: port, scheme: scheme} when is_binary(host) <- URI.parse(endpoint) do
      {:ok,
       %{
         endpoint: String.trim_trailing(endpoint, "/"),
         bucket: bucket,
         access_key: access_key,
         secret_key: secret_key,
         region: System.get_env("DEPDEP_REGION") || "us-east-1",
         host_header: host_header(host, port, scheme)
       }}
    else
      {:error, missing} -> {:error, "#{missing} is not set"}
      _ -> {:error, "DEPDEP_ENDPOINT is not a valid URL"}
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
    :ok
  end

  @doc "`:hit`, `:miss`, or `{:error, reason}` — never a raise, so a flaky store degrades to a compile."
  def head(cfg, object) do
    case request(cfg, :head, object, empty_hash(), [], []) do
      {:ok, status, _} when status in 200..299 -> :hit
      {:ok, 404, _} -> :miss
      {:ok, status, _} -> {:error, "HEAD returned #{status}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Streams to `dest` so a large object never sits in memory."
  def get(cfg, object, dest) do
    case request(cfg, :get, object, empty_hash(), [], stream: String.to_charlist(dest)) do
      {:ok, status, _} when status in 200..299 -> :ok
      {:ok, 404, _} -> {:error, "not found"}
      {:ok, status, _} -> {:error, "GET returned #{status}"}
      {:error, reason} -> {:error, reason}
    end
  end

  def put(cfg, object, source) do
    body = File.read!(source)
    hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

    case request(cfg, :put, object, hash, [{"content-length", "#{byte_size(body)}"}], [], body) do
      {:ok, status, _} when status in 200..299 -> :ok
      {:ok, status, body} -> {:error, "PUT returned #{status}: #{String.slice(body, 0, 200)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp empty_hash, do: :crypto.hash(:sha256, "") |> Base.encode16(case: :lower)

  defp request(cfg, method, object, payload_hash, extra, http_opts, body \\ nil) do
    path = "/" <> cfg.bucket <> "/" <> object
    url = cfg.endpoint <> path
    headers = sign(cfg, method, path, payload_hash, extra)
    hdrs = Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    req =
      case method do
        :put -> {String.to_charlist(url), hdrs, ~c"application/octet-stream", body}
        _ -> {String.to_charlist(url), hdrs}
      end

    case :httpc.request(method, req, [timeout: 300_000, connect_timeout: 15_000], http_opts) do
      {:ok, :saved_to_file} -> {:ok, 200, ""}
      {:ok, {{_v, status, _r}, _h, resp}} -> {:ok, status, to_string(resp)}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # ── AWS Signature v4 ──────────────────────────────────────────────────────

  defp sign(cfg, method, path, payload_hash, extra) do
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
          encode_path(path),
          "",
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

  # S3 canonicalises each path segment with RFC3986 encoding and does NOT
  # double-encode. Object names here are `v2/<name>/<version>/<hex>.tar.gz`, all
  # unreserved, so this is the identity in practice — written out anyway so a
  # future name containing a reserved character cannot silently break signing.
  defp encode_path(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &URI.encode(&1, fn c -> URI.char_unreserved?(c) end))
  end
end
