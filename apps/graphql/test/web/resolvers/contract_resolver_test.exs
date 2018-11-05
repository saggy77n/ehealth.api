defmodule GraphQLWeb.ContractResolverTest do
  @moduledoc false

  use GraphQLWeb.ConnCase, async: true

  import Core.Factories, only: [insert: 2, insert: 3]
  import Core.Expectations.Mithril, only: [msp: 0, nhs: 0]
  import Mox

  alias Absinthe.Relay.Node
  alias Ecto.UUID
  alias Core.Contracts.Contract
  alias Core.ContractRequests.ContractRequest

  @contract_request_status_signed ContractRequest.status(:signed)
  @contract_status_terminated Contract.status(:terminated)

  @terminate_query """
    mutation TerminateContract($input: TerminateContractInput!) {
      terminateContract(input: $input) {
        contract {
          status
          status_reason
          external_contractors {
            legal_entity {
              id
              database_id
              name
            }
          }
        }
      }
    }
  """

  @status_reason "Period of contract is wrong"

  setup :verify_on_exit!

  setup %{conn: conn} do
    conn = put_scope(conn, "contract:terminate")

    {:ok, %{conn: conn}}
  end

  describe "terminate" do
    test "legal entity terminates verified contract", %{conn: conn} do
      msp()

      %{id: legal_entity_id} = insert(:prm, :legal_entity)
      %{id: division_id} = insert(:prm, :division)

      external_contractors = [
        %{
          "divisions" => [%{"id" => division_id, "medical_service" => "PHC_SERVICES"}],
          "contract" => %{"expires_at" => to_string(Date.add(Date.utc_today(), 50))},
          "legal_entity_id" => legal_entity_id
        }
      ]

      contract_request =
        insert(
          :il,
          :contract_request,
          status: @contract_request_status_signed,
          external_contractors: external_contractors
        )

      contract =
        insert(:prm, :contract, contract_request_id: contract_request.id, external_contractors: external_contractors)

      {resp_body, resp_entity} = call_terminate(conn, contract, contract.contractor_legal_entity_id)

      assert nil == resp_body["errors"]

      assert %{
               "status" => @contract_status_terminated,
               "status_reason" => @status_reason,
               "external_contractors" => [%{"legal_entity" => %{"database_id" => ^legal_entity_id}}]
             } = resp_entity
    end

    test "NHS terminate verified contract", %{conn: conn} do
      nhs()

      %{id: legal_entity_id} = insert(:prm, :legal_entity)
      %{id: division_id} = insert(:prm, :division)

      external_contractors = [
        %{
          "divisions" => [%{"id" => division_id, "medical_service" => "PHC_SERVICES"}],
          "contract" => %{"expires_at" => to_string(Date.add(Date.utc_today(), 50))},
          "legal_entity_id" => legal_entity_id
        }
      ]

      contract_request =
        insert(
          :il,
          :contract_request,
          status: @contract_request_status_signed,
          external_contractors: external_contractors
        )

      contract =
        insert(:prm, :contract, contract_request_id: contract_request.id, external_contractors: external_contractors)

      {resp_body, resp_entity} = call_terminate(conn, contract, contract.nhs_legal_entity_id)

      assert nil == resp_body["errors"]

      assert %{
               "status" => @contract_status_terminated,
               "status_reason" => @status_reason,
               "external_contractors" => [%{"legal_entity" => %{"database_id" => ^legal_entity_id}}]
             } = resp_entity
    end

    test "NHS terminate not verified contract", %{conn: conn} do
      nhs()
      contract = insert(:prm, :contract, status: @contract_status_terminated)

      {resp_body, _} = call_terminate(conn, contract, contract.nhs_legal_entity_id)

      assert %{"errors" => [error]} = resp_body
      assert %{"extensions" => %{"code" => "CONFLICT"}} = error
    end

    test "wrong client id", %{conn: conn} do
      nhs()
      contract = insert(:prm, :contract)

      {resp_body, _} = call_terminate(conn, contract)

      assert %{"errors" => [error]} = resp_body
      assert %{"extensions" => %{"code" => "FORBIDDEN"}} = error
    end

    test "not found", %{conn: conn} do
      nhs()
      contract = insert(:prm, :contract)

      {resp_body, _} = call_terminate(conn, %{contract | id: UUID.generate()})

      assert %{"errors" => [error]} = resp_body
      assert %{"extensions" => %{"code" => "NOT_FOUND"}} = error
    end
  end

  defp call_terminate(conn, contract, client_id \\ UUID.generate()) do
    variables = %{
      input: %{
        id: Node.to_global_id("Contract", contract.id),
        status_reason: @status_reason
      }
    }

    resp_body =
      conn
      |> put_consumer_id()
      |> put_client_id(client_id)
      |> post_query(@terminate_query, variables)
      |> json_response(200)

    resp_entity = get_in(resp_body, ~w(data terminateContract contract))

    {resp_body, resp_entity}
  end
end