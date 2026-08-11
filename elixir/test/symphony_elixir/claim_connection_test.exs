defmodule SymphonyElixir.ClaimConnectionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ClaimConnection

  @certificate """
  -----BEGIN CERTIFICATE-----
  AA==
  -----END CERTIFICATE-----
  """

  setup do
    path = Path.join(System.tmp_dir!(), "claim-ca-#{System.unique_integer([:positive])}.crt")
    File.write!(path, @certificate)
    on_exit(fn -> File.rm(path) end)
    %{ca_path: path}
  end

  test "builds verified TLS options with SNI and HTTPS hostname matching", %{ca_path: ca_path} do
    settings = %{
      database_url: "postgresql://node:secret@aws-0.example.pooler.supabase.com:5432/postgres",
      ca_cert_file: ca_path
    }

    assert {:ok, options} = ClaimConnection.options(settings)
    assert options[:hostname] == "aws-0.example.pooler.supabase.com"
    assert options[:port] == 5432
    assert options[:database] == "postgres"
    assert options[:username] == "node"
    assert options[:password] == "secret"
    assert options[:sync_connect]
    assert options[:connect_timeout] == 10_000
    assert options[:ssl][:verify] == :verify_peer
    assert options[:ssl][:cacertfile] == String.to_charlist(ca_path)
    assert options[:ssl][:server_name_indication] == ~c"aws-0.example.pooler.supabase.com"
    assert is_function(options[:ssl][:customize_hostname_check][:match_fun], 2)
    refute inspect(options) =~ "verify_none"
  end

  test "decodes URL-escaped credentials and database names", %{ca_path: ca_path} do
    assert {:ok, options} =
             ClaimConnection.options(%{
               database_url: "postgresql://node%2Eproject:p%2Fss@pooler.example:5432/staging%2Ddb",
               ca_cert_file: ca_path
             })

    assert options[:username] == "node.project"
    assert options[:password] == "p/ss"
    assert options[:database] == "staging-db"
  end

  test "fails closed for an invalid URL", %{ca_path: ca_path} do
    assert {:error, :invalid_claim_database_url} =
             ClaimConnection.options(%{database_url: "not-a-postgres-url", ca_cert_file: ca_path})
  end

  test "fails closed when the CA is missing" do
    assert {:error, :invalid_claim_ca_cert_file} =
             ClaimConnection.options(%{
               database_url: "postgresql://node:secret@pooler.example:5432/postgres",
               ca_cert_file: Path.join(System.tmp_dir!(), "missing-claim-ca.crt")
             })
  end

  test "fails closed when the CA is not a certificate", %{ca_path: ca_path} do
    File.write!(ca_path, "not a certificate")

    assert {:error, :invalid_claim_ca_cert_file} =
             ClaimConnection.options(%{
               database_url: "postgresql://node:secret@pooler.example:5432/postgres",
               ca_cert_file: ca_path
             })
  end

  test "accepts only the exact node authentication contract" do
    authenticated =
      {:ok, %Postgrex.Result{rows: [[<<0::128>>, <<1::128>>, 3]], num_rows: 1}}

    assert :ok =
             ClaimConnection.authentication_result(authenticated)

    empty_result = {:ok, %Postgrex.Result{rows: [], num_rows: 0}}
    assert {:error, :node_authentication_rejected} = ClaimConnection.authentication_result(empty_result)

    assert {:error, :invalid_password} =
             ClaimConnection.authentication_result({:error, :invalid_password})
  end
end
