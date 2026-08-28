Code.require_file("../support/claim_service_postgres_harness.exs", __DIR__)

defmodule SymphonyElixir.ClaimServicePostgresHarnessTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TestSupport.ClaimServicePostgresHarness, as: Harness

  test "accepts only a localhost postgres admin database" do
    for url <- [
          "postgresql://postgres:secret@localhost:5432/postgres",
          "postgres://postgres@127.0.0.1/postgres",
          "postgresql://postgres@[::1]:5432/postgres"
        ] do
      assert {:ok, _uri} = Harness.validate_admin_url(url)
    end

    for url <- [
          "postgresql://postgres@database.internal/postgres",
          "postgresql://postgres@localhost/production",
          "postgresql://postgres@localhost/template1",
          "https://localhost/postgres",
          "not-a-url"
        ] do
      assert {:error, :unsafe_admin_database_url} = Harness.validate_admin_url(url)
    end
  end

  test "database names require the exact current-run random token" do
    token = "0123456789abcdef0123456789abcdef"
    name = Harness.database_name(token)

    assert name == "aro287_claim_test_0123456789abcdef0123456789abcdef"
    assert :ok = Harness.validate_cleanup_target(name, token)

    for unsafe_token <- ["short", "../../postgres", "ABCDEF0123456789ABCDEF0123456789"] do
      assert_raise ArgumentError, fn -> Harness.database_name(unsafe_token) end
    end

    for unsafe <- [
          "postgres",
          "symphony_staging",
          "aro287_claim_test_#{token}_other",
          "aro287_claim_test_../../postgres",
          "aro287_claim_test_ABCDEF0123456789ABCDEF0123456789"
        ] do
      assert {:error, :unsafe_cleanup_target} = Harness.validate_cleanup_target(unsafe, token)
    end
  end

  test "cleanup statements terminate and drop only the exact validated database" do
    token = "fedcba9876543210fedcba9876543210"
    name = Harness.database_name(token)

    assert {:ok, %{terminate_sql: terminate_sql, terminate_params: [^name], drop_sql: drop_sql}} =
             Harness.cleanup_statements(name, token)

    assert terminate_sql =~ "where datname = $1"
    assert drop_sql == ~s(drop database "#{name}")
    refute terminate_sql =~ name
  end
end
