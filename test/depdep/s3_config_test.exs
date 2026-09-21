defmodule Depdep.S3ConfigTest do
  @moduledoc """
  `Depdep.S3.config/0` reads the environment, so this is `async: false` and
  restores every variable it touches.
  """
  use ExUnit.Case, async: false

  alias Depdep.S3

  @vars ~w(DEPDEP_STORE DEPDEP_ENDPOINT DEPDEP_BUCKET DEPDEP_ACCESS_KEY DEPDEP_SECRET_KEY DEPDEP_REGION)

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  defp separate do
    System.put_env("DEPDEP_ENDPOINT", "http://10.0.0.5:9000")
    System.put_env("DEPDEP_BUCKET", "elixir-dep-store")
    System.put_env("DEPDEP_ACCESS_KEY", "depdep")
    System.put_env("DEPDEP_SECRET_KEY", "s3cret")
  end

  describe "DEPDEP_STORE, one URL for the shape of the store (#88)" do
    test "is the same config the four variables give" do
      separate()
      {:ok, four} = S3.config()

      Enum.each(
        ~w(DEPDEP_ENDPOINT DEPDEP_BUCKET DEPDEP_ACCESS_KEY DEPDEP_REGION),
        &System.delete_env/1
      )

      System.put_env("DEPDEP_STORE", "s3://depdep@10.0.0.5:9000/elixir-dep-store")
      assert S3.config() == {:ok, four}

      System.put_env(
        "DEPDEP_STORE",
        "s3://depdep@10.0.0.5:9000/elixir-dep-store?region=eu-west-1"
      )

      assert {:ok, %{region: "eu-west-1"}} = S3.config()
    end

    test "s3+https and https are TLS; the scheme default port is dropped" do
      System.put_env("DEPDEP_SECRET_KEY", "s")
      System.put_env("DEPDEP_STORE", "s3+https://k@minio.example/b")

      assert {:ok, %{endpoint: "https://minio.example", host_header: "minio.example"}} =
               S3.config()

      System.put_env("DEPDEP_STORE", "https://k@minio.example:8443/b")

      assert {:ok, %{endpoint: "https://minio.example:8443", host_header: "minio.example:8443"}} =
               S3.config()
    end

    test "the secret is never in the URL" do
      System.put_env("DEPDEP_SECRET_KEY", "s")
      System.put_env("DEPDEP_STORE", "s3://k:s3cret@h/b")
      assert {:error, reason} = S3.config()
      assert reason =~ "password"
      assert reason =~ "DEPDEP_SECRET_KEY"
    end

    test "a URL without the secret is a store not configured, exit-0 territory" do
      System.put_env("DEPDEP_STORE", "s3://k@h/b")
      assert S3.config() == {:error, "DEPDEP_SECRET_KEY is not set"}
    end

    test "no bucket, two path segments, no host, no key, an unknown scheme: each refused by name" do
      System.put_env("DEPDEP_SECRET_KEY", "s")

      for {url, word} <- [
            {"s3://k@h", "bucket"},
            {"s3://k@h/a/b", "bucket"},
            {"s3://k@/b", "host"},
            {"s3://h/b", "access key"},
            {"ftp://k@h/b", "scheme"}
          ] do
        System.put_env("DEPDEP_STORE", url)
        assert {:error, reason} = S3.config()
        assert reason =~ word, "#{url} should be refused naming the #{word}"
      end
    end

    test "both forms at once is refused, naming both" do
      separate()
      System.put_env("DEPDEP_STORE", "s3://k@h/b")
      assert {:error, reason} = S3.config()

      assert reason =~
               "DEPDEP_STORE and DEPDEP_ENDPOINT, DEPDEP_BUCKET, DEPDEP_ACCESS_KEY are both set"
    end
  end

  describe "the four variables, as before" do
    test "read as they always did" do
      separate()

      assert {:ok,
              %{endpoint: "http://10.0.0.5:9000", bucket: "elixir-dep-store", region: "us-east-1"}} =
               S3.config()
    end

    test "a missing one is named" do
      separate()
      System.delete_env("DEPDEP_BUCKET")
      assert S3.config() == {:error, "DEPDEP_BUCKET is not set"}
    end
  end
end
