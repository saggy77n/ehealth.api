defmodule Core.ContractRequests do
  @moduledoc false

  use Core.Search, Core.Repo

  import Core.API.Helpers.Connection, only: [get_consumer_id: 1, get_client_id: 1]
  import Ecto.Changeset
  import Ecto.Query
  import Core.ContractRequests.Validator

  alias Core.API.MediaStorage
  alias Core.CapitationContractRequests
  alias Core.ContractRequests.CapitationContractRequest
  alias Core.ContractRequests.ReimbursementContractRequest
  alias Core.ContractRequests.Renderer
  alias Core.ContractRequests.Search
  alias Core.Contracts
  alias Core.Contracts.CapitationContract
  alias Core.EventManager
  alias Core.LegalEntities
  alias Core.LegalEntities.LegalEntity
  alias Core.Man.Templates.ContractRequestPrintoutForm
  alias Core.Repo
  alias Core.Utils.NumberGenerator
  alias Core.Validators.Error
  alias Core.Validators.JsonSchema
  alias Core.Validators.Preload
  alias Core.Validators.Signature, as: SignatureValidator
  alias Ecto.Adapters.SQL
  alias Ecto.Changeset
  alias Ecto.UUID
  alias Scrivener.Page

  require Logger

  @mithril_api Application.get_env(:core, :api_resolvers)[:mithril]
  @media_storage_api Application.get_env(:core, :api_resolvers)[:media_storage]
  @signature_api Application.get_env(:core, :api_resolvers)[:digital_signature]

  @capitation CapitationContractRequest.type()
  @reimbursement ReimbursementContractRequest.type()

  @forbidden_statuses_for_termination [
    CapitationContractRequest.status(:declined),
    CapitationContractRequest.status(:signed),
    CapitationContractRequest.status(:terminated)
  ]

  defmacro __using__(contract_request_schema: contract_request_schema) do
    quote do
      import Core.API.Helpers.Connection, only: [get_consumer_id: 1, get_client_id: 1]

      alias Core.ContractRequests
      alias Core.ContractRequests.Validator
      alias Core.Repo

      def get_by_id(id), do: Repo.get(unquote(contract_request_schema), id)

      def get_by_id!(id), do: Repo.get!(unquote(contract_request_schema), id)

      def fetch_by_id(id) do
        case get_by_id(id) do
          %unquote(contract_request_schema){} = contract_request -> {:ok, contract_request}
          nil -> {:error, {:not_found, "Contract Request not found"}}
        end
      end

      defp get_contract_request(_, "NHS", id) do
        with %unquote(contract_request_schema){} = contract_request <- Repo.get(unquote(contract_request_schema), id) do
          {:ok, contract_request}
        end
      end

      defp get_contract_request(client_id, "MSP", id) do
        with %unquote(contract_request_schema){} = contract_request <- Repo.get(unquote(contract_request_schema), id),
             :ok <- Validator.validate_legal_entity_id(client_id, contract_request.contractor_legal_entity_id) do
          {:ok, contract_request}
        end
      end
    end
  end

  def search(search_params) do
    with %Changeset{valid?: true} = changeset <- Search.changeset(search_params),
         %Page{} = paging <- search(changeset, search_params, CapitationContractRequest) do
      {:ok, paging}
    end
  end

  # ToDo: should be refactored
  def get_by_id(headers, client_type, id) do
    client_id = get_client_id(headers)

    with {:ok, %CapitationContractRequest{} = contract_request} <- get_contract_request(client_id, client_type, id) do
      {:ok, contract_request, preload_references(contract_request)}
    end
  end

  @deprecated "Use get_by_id/2"
  def get_by_id(id), do: get_by_id(@capitation, id)

  def get_by_id(@capitation, id), do: CapitationContractRequests.get_by_id(id)
  def get_by_id(@reimbursement, id), do: ReimbursementContractRequests.get_by_id(id)

  @deprecated "Use get_by_id!/2"
  def get_by_id!(id), do: get_by_id!(@capitation, id)

  def get_by_id!(@capitation, id), do: CapitationContractRequests.get_by_id!(id)
  def get_by_id!(@reimbursement, id), do: ReimbursementContractRequests.get_by_id!(id)

  @deprecated "Use fetch_by_id/2"
  def fetch_by_id(id), do: fetch_by_id(@capitation, id)

  def fetch_by_id(@capitation, id), do: CapitationContractRequests.fetch_by_id(id)
  def fetch_by_id(@reimbursement, id), do: ReimbursementContractRequests.fetch_by_id(id)

  def draft do
    id = UUID.generate()

    with {:ok, %{"data" => %{"secret_url" => statute_url}}} <-
           @media_storage_api.create_signed_url(
             "PUT",
             get_bucket(),
             "media/upload_contract_request_statute.pdf",
             id,
             []
           ),
         {:ok, %{"data" => %{"secret_url" => additional_document_url}}} <-
           @media_storage_api.create_signed_url(
             "PUT",
             get_bucket(),
             "media/upload_contract_request_additional_document.pdf",
             id,
             []
           ) do
      %{
        "id" => id,
        "statute_url" => statute_url,
        "additional_document_url" => additional_document_url
      }
    end
  end

  def get_document_attributes_by_status(status) do
    cond do
      Enum.any?(
        ~w(new approved in_process pending_nhs_sign terminated declined)a,
        &(CapitationContractRequest.status(&1) == status)
      ) ->
        [
          {"CONTRACT_REQUEST_STATUTE", "media/contract_request_statute.pdf"},
          {"CONTRACT_REQUEST_ADDITIONAL_DOCUMENT", "media/contract_request_additional_document.pdf"}
        ]

      Enum.any?(~w(signed nhs_signed)a, &(CapitationContractRequest.status(&1) == status)) ->
        [
          {"CONTRACT_REQUEST_STATUTE", "media/contract_request_statute.pdf"},
          {"CONTRACT_REQUEST_ADDITIONAL_DOCUMENT", "media/contract_request_additional_document.pdf"},
          {"SIGNED_CONTENT", "signed_content/signed_content"}
        ]

      true ->
        []
    end
  end

  def gen_relevant_get_links(id, status) do
    Enum.reduce(get_document_attributes_by_status(status), [], fn {name, resource_name}, acc ->
      with {:ok, %{"data" => %{"secret_url" => secret_url}}} <-
             @media_storage_api.create_signed_url("GET", get_bucket(), resource_name, id, []) do
        [%{"type" => name, "url" => secret_url} | acc]
      end
    end)
  end

  def create(headers, %{"id" => id, "type" => type} = params) do
    user_id = get_consumer_id(headers)
    client_id = get_client_id(headers)
    params = Map.drop(params, ~w(id type))

    with %LegalEntity{} = legal_entity <- LegalEntities.get_by_id(client_id),
         {:contract_request_exists, true} <- {:contract_request_exists, is_nil(get_by_id(id))},
         :ok <- JsonSchema.validate(:contract_request_sign, params),
         {:ok, %{"content" => content, "signers" => [signer]}} <- decode_signed_content(params, headers),
         :ok <- validate_contract_request_type(type, legal_entity),
         content <- Map.put(content, "type", type),
         :ok <- validate_create_content_schema(content),
         :ok <- validate_legal_entity_edrpou(legal_entity, signer),
         :ok <- validate_user_signer_last_name(user_id, signer),
         content <- Map.put(content, "contractor_legal_entity_id", client_id),
         {:ok, params, contract} <- validate_contract_number(content, headers),
         :ok <- validate_contractor_legal_entity_id(client_id, contract),
         :ok <- validate_previous_request(params, client_id),
         :ok <- validate_dates(params),
         params <- set_dates(contract, params),
         {:ok, contract_request} <- validate_contract_request_content(:create, params, client_id),
         :ok <- validate_unique_contractor_divisions(params),
         :ok <- validate_contractor_divisions(params),
         :ok <- validate_start_date(params),
         :ok <- validate_end_date(params),
         :ok <- validate_contractor_owner_id(params),
         :ok <-
           validate_document(
             id,
             "media/upload_contract_request_statute.pdf",
             params["statute_md5"],
             headers
           ),
         :ok <-
           validate_document(
             id,
             "media/upload_contract_request_additional_document.pdf",
             params["additional_document_md5"],
             headers
           ),
         :ok <- move_uploaded_documents(id, headers),
         _ <- terminate_pending_contracts(params),
         insert_params <-
           Map.merge(params, %{
             "status" => CapitationContractRequest.status(:new),
             "inserted_by" => user_id,
             "updated_by" => user_id
           }),
         %Changeset{valid?: true} = changes <- changeset(contract_request, insert_params),
         {:ok, contract_request} <- Repo.insert(changes) do
      {:ok, contract_request, preload_references(contract_request)}
    else
      {:contract_request_exists, false} -> {:error, {:conflict, "Invalid contract_request id"}}
      error -> error
    end
  end

  def update(headers, %{"id" => id} = params) do
    user_id = get_consumer_id(headers)
    client_id = get_client_id(headers)
    params = Map.delete(params, "id")

    with :ok <- JsonSchema.validate(:contract_request_update, params),
         {:ok, %{"data" => data}} <- @mithril_api.get_user_roles(user_id, %{}, headers),
         :ok <- user_has_role(data, "NHS ADMIN SIGNER"),
         %CapitationContractRequest{} = contract_request <- Repo.get(CapitationContractRequest, id),
         :ok <- validate_nhs_signer_id(params, client_id),
         :ok <- validate_status(contract_request, CapitationContractRequest.status(:in_process)),
         :ok <- validate_start_date(contract_request),
         update_params <-
           params
           |> Map.put("nhs_legal_entity_id", client_id)
           |> Map.put("updated_by", user_id),
         %Changeset{valid?: true} = changes <- update_changeset(contract_request, update_params),
         {:ok, contract_request} <- Repo.update(changes) do
      {:ok, contract_request, preload_references(contract_request)}
    end
  end

  def update_assignee(headers, %{"id" => contract_request_id} = params) do
    user_id = get_consumer_id(headers)
    client_id = get_client_id(headers)
    employee_id = params["employee_id"]

    with :ok <- JsonSchema.validate(:contract_request_assign, Map.take(params, ~w(employee_id))),
         {:ok, %{"data" => user_data}} <- @mithril_api.get_user_roles(user_id, %{}, headers),
         :ok <- user_has_role(user_data, "NHS ADMIN SIGNER"),
         %CapitationContractRequest{} = contract_request <- Repo.get(CapitationContractRequest, contract_request_id),
         {:ok, employee} <- validate_employee(employee_id, client_id),
         :ok <- validate_employee_role(employee, "NHS ADMIN SIGNER"),
         :ok <-
           validate_status(contract_request, [
             CapitationContractRequest.status(:new),
             CapitationContractRequest.status(:in_process)
           ]),
         update_params <- %{
           "status" => CapitationContractRequest.status(:in_process),
           "updated_at" => NaiveDateTime.utc_now(),
           "updated_by" => user_id,
           "assignee_id" => employee_id
         },
         %Changeset{valid?: true} = changes <- update_assignee_changeset(contract_request, update_params),
         {:ok, contract_request} <- Repo.update(changes),
         _ <- EventManager.insert_change_status(contract_request, contract_request.status, user_id) do
      {:ok, contract_request, preload_references(contract_request)}
    end
  end

  def approve(headers, %{"id" => id} = params) do
    user_id = get_consumer_id(headers)
    client_id = get_client_id(headers)
    params = Map.delete(params, "id")

    with :ok <- JsonSchema.validate(:contract_request_sign, params),
         {:ok, %{"content" => content, "signers" => [signer]}} <- decode_signed_content(params, headers),
         :ok <- JsonSchema.validate(:contract_request_approve, content),
         :ok <- validate_contract_request_id(id, content["id"]),
         %LegalEntity{} = legal_entity <- LegalEntities.get_by_id!(client_id),
         %CapitationContractRequest{} = contract_request <- get_by_id!(content["id"]),
         references <- preload_references(contract_request),
         :ok <- validate_legal_entity_edrpou(legal_entity, signer),
         :ok <- validate_user_signer_last_name(user_id, signer),
         {:ok, %{"data" => data}} <- @mithril_api.get_user_roles(user_id, %{}, headers),
         :ok <- user_has_role(data, "NHS ADMIN SIGNER"),
         :ok <- validate_contractor_legal_entity(contract_request.contractor_legal_entity_id),
         :ok <- validate_approve_content(content, contract_request, references),
         :ok <- validate_status(contract_request, CapitationContractRequest.status(:in_process)),
         :ok <-
           save_signed_content(
             contract_request.id,
             params,
             headers,
             "signed_content/contract_request_approved"
           ),
         :ok <- validate_contract_id(contract_request),
         :ok <- validate_contractor_owner_id(contract_request),
         :ok <- validate_nhs_signer_id(contract_request, client_id),
         :ok <- validate_employee_divisions(contract_request, contract_request.contractor_legal_entity_id),
         :ok <- validate_contractor_divisions(contract_request),
         :ok <- validate_start_date(contract_request),
         update_params <-
           params
           |> Map.delete("id")
           |> Map.put("updated_by", user_id)
           |> set_contract_number(contract_request)
           |> Map.put("status", CapitationContractRequest.status(:approved)),
         %Changeset{valid?: true} = changes <- approve_changeset(contract_request, update_params),
         data <- render_contract_request_data(changes),
         %Changeset{valid?: true} = changes <- put_change(changes, :data, data),
         {:ok, contract_request} <- Repo.update(changes),
         _ <- EventManager.insert_change_status(contract_request, contract_request.status, user_id) do
      {:ok, contract_request, preload_references(contract_request)}
    end
  end

  def approve_msp(headers, %{"id" => id} = params) do
    client_id = get_client_id(headers)
    user_id = get_consumer_id(headers)

    with %CapitationContractRequest{} = contract_request <- get_by_id(id),
         {_, true} <- {:client_id, client_id == contract_request.contractor_legal_entity_id},
         :ok <- validate_status(contract_request, CapitationContractRequest.status(:approved)),
         :ok <- validate_contractor_legal_entity(contract_request.contractor_legal_entity_id),
         {:contractor_owner, :ok} <- {:contractor_owner, validate_contractor_owner_id(contract_request)},
         :ok <- validate_employee_divisions(contract_request, client_id),
         :ok <- validate_contractor_divisions(contract_request),
         :ok <- validate_start_date(contract_request),
         update_params <-
           params
           |> Map.delete("id")
           |> Map.put("updated_by", user_id)
           |> Map.put("status", CapitationContractRequest.status(:pending_nhs_sign)),
         %Changeset{valid?: true} = changes <- approve_msp_changeset(contract_request, update_params),
         {:ok, contract_request} <- Repo.update(changes),
         _ <- EventManager.insert_change_status(contract_request, contract_request.status, user_id) do
      {:ok, contract_request, preload_references(contract_request)}
    else
      {:client_id, _} ->
        {:error, {:forbidden, "Client is not allowed to modify contract_request"}}

      {:contractor_owner, _} ->
        {:error, {:forbidden, "User is not allowed to perform this action"}}

      error ->
        error
    end
  end

  def decline(headers, %{"id" => id} = params) do
    user_id = get_consumer_id(headers)
    client_id = get_client_id(headers)
    params = Map.delete(params, "id")

    with :ok <- JsonSchema.validate(:contract_request_sign, params),
         {:ok, %{"content" => content, "signers" => [signer]}} <- decode_signed_content(params, headers),
         :ok <- JsonSchema.validate(:contract_request_decline, content),
         :ok <- validate_contract_request_id(id, content["id"]),
         {:ok, legal_entity} <- LegalEntities.fetch_by_id(client_id),
         %CapitationContractRequest{} = contract_request <- get_by_id(content["id"]),
         references <- preload_references(contract_request),
         :ok <- validate_legal_entity_edrpou(legal_entity, signer),
         :ok <- validate_user_signer_last_name(user_id, signer),
         {:ok, %{"data" => data}} <- @mithril_api.get_user_roles(user_id, %{}, headers),
         :ok <- user_has_role(data, "NHS ADMIN SIGNER"),
         :ok <- validate_contractor_legal_entity(contract_request.contractor_legal_entity_id),
         :ok <- validate_decline_content(content, contract_request, references),
         :ok <- validate_status(contract_request, CapitationContractRequest.status(:in_process)),
         :ok <-
           save_signed_content(
             contract_request.id,
             params,
             headers,
             "signed_content/contract_request_declined"
           ),
         update_params <-
           content
           |> Map.take(~w(status_reason))
           |> Map.put("status", CapitationContractRequest.status(:declined))
           |> Map.put("nhs_signer_id", user_id)
           |> Map.put("nhs_legal_entity_id", client_id)
           |> Map.put("updated_by", user_id),
         %Changeset{valid?: true} = changes <- decline_changeset(contract_request, update_params),
         {:ok, contract_request} <- Repo.update(changes),
         _ <- EventManager.insert_change_status(contract_request, contract_request.status, user_id) do
      {:ok, contract_request, preload_references(contract_request)}
    end
  end

  def terminate(headers, client_type, params) do
    client_id = get_client_id(headers)
    user_id = get_consumer_id(headers)

    with {:ok, %CapitationContractRequest{} = contract_request} <-
           get_contract_request(client_id, client_type, params["id"]),
         {:contractor_owner, :ok} <- {:contractor_owner, validate_contractor_owner_id(contract_request)},
         true <- contract_request.status not in @forbidden_statuses_for_termination,
         update_params <-
           params
           |> Map.put("status", CapitationContractRequest.status(:terminated))
           |> Map.put("updated_by", user_id),
         %Changeset{valid?: true} = changes <- terminate_changeset(contract_request, update_params),
         {:ok, contract_request} <- Repo.update(changes),
         _ <- EventManager.insert_change_status(contract_request, contract_request.status, user_id) do
      {:ok, contract_request, preload_references(contract_request)}
    else
      false ->
        Error.dump("Incorrect status of contract_request to modify it")

      {:contractor_owner, _} ->
        {:error, {:forbidden, "User is not allowed to perform this action"}}

      error ->
        error
    end
  end

  def sign_nhs(headers, %{"id" => id} = params) do
    client_id = get_client_id(headers)
    user_id = get_consumer_id(headers)
    params = Map.take(params, ~w(signed_content signed_content_encoding))

    with {:ok, legal_entity} <- LegalEntities.fetch_by_id(client_id),
         :ok <- JsonSchema.validate(:contract_request_sign, params),
         {:ok, %{"content" => content, "signers" => [signer], "stamps" => [stamp]}} <-
           decode_signed_content(params, headers, 1, 1),
         :ok <- validate_contract_request_id(id, content["id"]),
         {:ok, contract_request} <- fetch_by_id(id),
         :ok <- validate_client_id(client_id, contract_request.nhs_legal_entity_id, :forbidden),
         {_, false} <- {:already_signed, contract_request.status == CapitationContractRequest.status(:nhs_signed)},
         :ok <- validate_status(contract_request, CapitationContractRequest.status(:pending_nhs_sign)),
         :ok <- validate_legal_entity_edrpou(legal_entity, signer),
         :ok <- validate_legal_entity_edrpou(legal_entity, stamp),
         {:ok, employee} <- validate_employee(contract_request.nhs_signer_id, client_id),
         :ok <- check_last_name_match(employee.party.last_name, signer["surname"]),
         :ok <- validate_contractor_legal_entity(contract_request.contractor_legal_entity_id),
         :ok <- validate_contractor_owner_id(contract_request),
         {:ok, printout_content} <-
           ContractRequestPrintoutForm.render(
             %{contract_request | nhs_signed_date: Date.utc_today()},
             headers
           ),
         :ok <- validate_content(contract_request, printout_content, content),
         :ok <- validate_contract_id(contract_request),
         :ok <- validate_employee_divisions(contract_request, contract_request.contractor_legal_entity_id),
         :ok <- validate_start_date(contract_request),
         :ok <-
           save_signed_content(
             contract_request.id,
             params,
             headers,
             "signed_content/signed_content"
           ),
         update_params <-
           params
           |> Map.put("updated_by", user_id)
           |> Map.put("status", CapitationContractRequest.status(:nhs_signed))
           |> Map.put("nhs_signed_date", Date.utc_today())
           |> Map.put("printout_content", printout_content),
         %Ecto.Changeset{valid?: true} = changes <- nhs_signed_changeset(contract_request, update_params),
         {:ok, contract_request} <- Repo.update(changes),
         _ <- EventManager.insert_change_status(contract_request, contract_request.status, user_id) do
      {:ok, contract_request, preload_references(contract_request)}
    else
      {:client_id, _} -> {:error, {:forbidden, "Invalid client_id"}}
      {:already_signed, _} -> Error.dump("The contract was already signed by NHS")
      error -> error
    end
  end

  def sign_msp(headers, client_type, %{"id" => id} = params) do
    client_id = get_client_id(headers)
    user_id = get_consumer_id(headers)
    params = Map.delete(params, "id")

    with %LegalEntity{} = legal_entity <- LegalEntities.get_by_id(client_id),
         {:ok, %CapitationContractRequest{} = contract_request, _} <- get_by_id(headers, client_type, id),
         :ok <- JsonSchema.validate(:contract_request_sign, params),
         {_, true} <- {:signed_nhs, contract_request.status == CapitationContractRequest.status(:nhs_signed)},
         :ok <- validate_client_id(client_id, contract_request.contractor_legal_entity_id, :forbidden),
         {:ok, %{"content" => content, "signers" => [signer_msp, signer_nhs], "stamps" => [nhs_stamp]}} <-
           decode_signed_content(params, headers, 2, 1),
         :ok <- validate_legal_entity_edrpou(legal_entity, signer_msp),
         {:ok, employee} <- validate_employee(contract_request.contractor_owner_id, client_id),
         :ok <- check_last_name_match(employee.party.last_name, signer_msp["surname"]),
         :ok <- validate_nhs_signatures(signer_nhs, nhs_stamp, contract_request),
         :ok <- validate_content(contract_request, content),
         :ok <- validate_employee_divisions(contract_request, client_id),
         :ok <- validate_start_date(contract_request),
         :ok <- validate_contractor_legal_entity(contract_request.contractor_legal_entity_id),
         :ok <- validate_contractor_owner_id(contract_request),
         contract_id <- UUID.generate(),
         :ok <- save_signed_content(contract_id, params, headers, "signed_content/signed_content", :contract_bucket),
         update_params <-
           params
           |> Map.put("updated_by", user_id)
           |> Map.put("status", CapitationContractRequest.status(:signed))
           |> Map.put("contract_id", contract_id),
         %Ecto.Changeset{valid?: true} = changes <- msp_signed_changeset(contract_request, update_params),
         {:ok, contract_request} <- Repo.update(changes),
         contract_params <- get_contract_create_params(contract_request),
         {:create_contract, {:ok, contract}} <- {:create_contract, Contracts.create(contract_params, user_id)},
         _ <- EventManager.insert_change_status(contract_request, contract_request.status, user_id) do
      Contracts.load_contract_references(contract)
    else
      {:signed_nhs, false} ->
        Error.dump("Incorrect status for signing")

      {:create_contract, _} ->
        {:error, {:bad_gateway, "Failed to save contract"}}

      error ->
        error
    end
  end

  def get_partially_signed_content_url(headers, %{"id" => id}) do
    client_id = get_client_id(headers)

    with %CapitationContractRequest{} = contract_request <- Repo.get(CapitationContractRequest, id),
         {_, true} <- {:signed_nhs, contract_request.status == CapitationContractRequest.status(:nhs_signed)},
         :ok <- validate_client_id(client_id, contract_request.contractor_legal_entity_id, :forbidden),
         {:ok, url} <- resolve_partially_signed_content_url(contract_request.id, headers) do
      {:ok, url}
    else
      {:signed_nhs, _} ->
        Error.dump("The contract hasn't been signed yet")

      {:error, :media_storage_error} ->
        {:error, {:bad_gateway, "Fail to resolve partially signed content"}}

      error ->
        error
    end
  end

  def get_printout_content(id, client_type, headers) do
    with {:ok, contract_request, _} <- get_by_id(headers, client_type, id),
         :ok <-
           validate_status(
             contract_request,
             CapitationContractRequest.status(:pending_nhs_sign),
             "Incorrect status of contract_request to generate printout form"
           ),
         {:ok, printout_content} <-
           ContractRequestPrintoutForm.render(
             Map.put(contract_request, :nhs_signed_date, Date.utc_today()),
             headers
           ) do
      {:ok, contract_request, printout_content}
    end
  end

  defp get_contract_create_params(%CapitationContractRequest{id: id, contract_id: contract_id} = contract_request) do
    contract_request
    |> Map.take(~w(
      start_date
      end_date
      status_reason
      contractor_legal_entity_id
      contractor_owner_id
      contractor_base
      contractor_payment_details
      contractor_rmsp_amount
      external_contractor_flag
      external_contractors
      nhs_legal_entity_id
      nhgs_signed_id
      nhs_payment_method
      nhs_signer_base
      issue_city
      contract_number
      contractor_divisions
      contractor_employee_divisions
      status
      nhs_signer_id
      nhs_contract_price
      parent_contract_id
      id_form
      nhs_signed_date
    )a)
    |> Map.merge(%{
      id: contract_id,
      contract_request_id: id,
      is_suspended: false,
      is_active: true,
      inserted_by: contract_request.updated_by,
      updated_by: contract_request.updated_by,
      status: CapitationContract.status(:verified)
    })
  end

  defp save_signed_content(
         id,
         %{"signed_content" => content},
         headers,
         resource_name,
         bucket \\ :contract_request_bucket
       ) do
    case @media_storage_api.store_signed_content(content, bucket, id, resource_name, headers) do
      {:ok, _} -> :ok
      _error -> {:error, {:bad_gateway, "Failed to save signed content"}}
    end
  end

  def decode_signed_content(
        %{"signed_content" => signed_content, "signed_content_encoding" => encoding},
        headers,
        required_signatures_count \\ 1,
        required_stamps_count \\ 0
      ) do
    SignatureValidator.validate(signed_content, encoding, headers, required_signatures_count, required_stamps_count)
  end

  def decode_and_validate_signed_content(%CapitationContractRequest{id: id}, headers) do
    with {:ok, %{"data" => %{"secret_url" => secret_url}}} <-
           @media_storage_api.create_signed_url(
             "GET",
             MediaStorage.config()[:contract_request_bucket],
             "signed_content/signed_content",
             id,
             headers
           ),
         {:ok, %{body: content, status_code: 200}} <- @media_storage_api.get_signed_content(secret_url),
         {:ok, %{"data" => %{"content" => content}}} <-
           @signature_api.decode_and_validate(
             Base.encode64(content),
             "base64",
             headers
           ) do
      {:ok, content}
    end
  end

  defp set_contract_number(params, %{parent_contract_id: parent_contract_id})
       when not is_nil(parent_contract_id) do
    params
  end

  defp set_contract_number(params, _) do
    with {:ok, sequence} <- get_contract_request_sequence() do
      Map.put(params, "contract_number", NumberGenerator.generate_from_sequence(0, sequence))
    end
  end

  defp set_dates(nil, params), do: params

  defp set_dates(%{start_date: start_date, end_date: end_date}, params) do
    params
    |> Map.put("start_date", to_string(start_date))
    |> Map.put("end_date", to_string(end_date))
  end

  def changeset(%CapitationContractRequest{} = contract_request, params) do
    CapitationContractRequest.changeset(contract_request, params)
  end

  def changeset(%ReimbursementContractRequest{} = contract_request, params) do
    ReimbursementContractRequest.changeset(contract_request, params)
  end

  def update_changeset(%CapitationContractRequest{} = contract_request, params) do
    contract_request
    |> cast(
      params,
      ~w(
        nhs_legal_entity_id
        nhs_signer_id
        nhs_signer_base
        nhs_contract_price
        nhs_payment_method
        issue_city
        misc
      )a
    )
    |> validate_number(:nhs_contract_price, greater_than_or_equal_to: 0)
  end

  def approve_changeset(%CapitationContractRequest{} = contract_request, params) do
    fields_required = ~w(
      nhs_legal_entity_id
      nhs_signer_id
      nhs_signer_base
      nhs_contract_price
      nhs_payment_method
      issue_city
      status
      updated_by
      contract_number
    )a

    fields_optional = ~w(misc)a

    contract_request
    |> cast(params, fields_required ++ fields_optional)
    |> validate_required(fields_required)
  end

  defp update_assignee_changeset(%CapitationContractRequest{} = contract_request, params) do
    fields_required = ~w(
      status
      assignee_id
      updated_at
      updated_by
    )a

    contract_request
    |> cast(params, fields_required)
    |> validate_required(fields_required)
  end

  def approve_msp_changeset(%CapitationContractRequest{} = contract_request, params) do
    fields = ~w(
      status
      updated_by
    )a

    contract_request
    |> cast(params, fields)
    |> validate_required(fields)
  end

  def terminate_changeset(%CapitationContractRequest{} = contract_request, params) do
    fields_required = ~w(status updated_by)a
    fields_optional = ~w(status_reason)a

    contract_request
    |> cast(params, fields_required ++ fields_optional)
    |> validate_required(fields_required)
  end

  def nhs_signed_changeset(%CapitationContractRequest{} = contract_request, params) do
    fields = ~w(status updated_by printout_content nhs_signed_date)a

    contract_request
    |> cast(params, fields)
    |> validate_required(fields)
  end

  def msp_signed_changeset(%CapitationContractRequest{} = contract_request, params) do
    fields = ~w(status updated_by contract_id)a

    contract_request
    |> cast(params, fields)
    |> validate_required(fields)
  end

  def preload_references(%CapitationContractRequest{} = contract_request) do
    fields = [
      {:contractor_legal_entity_id, :legal_entity},
      {:nhs_legal_entity_id, :legal_entity},
      {:contractor_owner_id, :employee},
      {:nhs_signer_id, :employee},
      {:contractor_divisions, :division},
      {[:external_contractors, "$", "divisions", "$", "id"], :division},
      {[:external_contractors, "$", "legal_entity_id"], :legal_entity}
    ]

    fields =
      if is_list(contract_request.contractor_employee_divisions) do
        fields ++
          [
            {[:contractor_employee_divisions, "$", "employee_id"], :employee}
          ]
      else
        fields
      end

    Preload.preload_references(contract_request, fields)
  end

  def preload_references(%ReimbursementContractRequest{} = contract_request) do
    fields = [
      {:contractor_legal_entity_id, :legal_entity},
      {:nhs_legal_entity_id, :legal_entity},
      {:contractor_owner_id, :employee},
      {:nhs_signer_id, :employee},
      {:contractor_divisions, :division}
    ]

    Preload.preload_references(contract_request, fields)
  end

  defp render_contract_request_data(%Changeset{} = changeset) do
    structure = Changeset.apply_changes(changeset)
    Renderer.render(structure, preload_references(structure))
  end

  defp terminate_pending_contracts(params) do
    # TODO: add index here

    schema =
      case params["type"] do
        @capitation -> CapitationContractRequest
        @reimbursement -> ReimbursementContractRequest
      end

    contract_ids =
      schema
      |> select([c], c.id)
      |> where([c], c.contractor_legal_entity_id == ^params["contractor_legal_entity_id"])
      |> where([c], c.id_form == ^params["id_form"])
      |> where_medical_program(params)
      |> where(
        [c],
        c.status in ^[
          CapitationContractRequest.status(:new),
          CapitationContractRequest.status(:in_process),
          CapitationContractRequest.status(:approved),
          CapitationContractRequest.status(:nhs_signed),
          CapitationContractRequest.status(:pending_nhs_sign)
        ]
      )
      |> where([c], c.end_date >= ^params["start_date"] and c.start_date <= ^params["end_date"])
      |> Repo.all()

    CapitationContractRequest
    |> where([c], c.id in ^contract_ids)
    |> Repo.update_all(set: [status: CapitationContractRequest.status(:terminated)])
  end

  defp where_medical_program(query, %{"type" => @reimbursement, "medical_program_id" => medical_program_id}) do
    where(query, [c], c.medical_program_id == ^medical_program_id)
  end

  defp where_medical_program(query, _), do: query

  def user_has_role(data, role, reason \\ "FORBIDDEN") do
    case Enum.find(data, &(Map.get(&1, "role_name") == role)) do
      nil -> {:error, {:forbidden, reason}}
      _ -> :ok
    end
  end

  defp get_contract_request(_, "NHS", id) do
    with %CapitationContractRequest{} = contract_request <- Repo.get(CapitationContractRequest, id) do
      {:ok, contract_request}
    end
  end

  defp get_contract_request(client_id, "MSP", id) do
    with %CapitationContractRequest{} = contract_request <- Repo.get(CapitationContractRequest, id),
         :ok <- validate_legal_entity_id(client_id, contract_request.contractor_legal_entity_id) do
      {:ok, contract_request}
    end
  end

  defp resolve_partially_signed_content_url(contract_request_id, headers) do
    bucket = Confex.fetch_env!(:core, Core.API.MediaStorage)[:contract_request_bucket]
    resource_name = "contract_request_content.pkcs7"

    media_storage_response =
      @media_storage_api.create_signed_url(
        "GET",
        bucket,
        contract_request_id,
        resource_name,
        headers
      )

    case media_storage_response do
      {:ok, %{"data" => %{"secret_url" => url}}} -> {:ok, url}
      _ -> {:error, :media_storage_error}
    end
  end

  defp get_contract_request_sequence do
    case SQL.query(Repo, "SELECT nextval('contract_request');", []) do
      {:ok, %Postgrex.Result{rows: [[sequence]]}} ->
        {:ok, sequence}

      _ ->
        Logger.error("Can't get contract_request sequence")
        {:error, %{"type" => "internal_error"}}
    end
  end

  defp decline_changeset(%CapitationContractRequest{} = contract_request, params) do
    fields_required = ~w(status nhs_signer_id nhs_legal_entity_id updated_by)a
    fields_optional = ~w(status_reason)a

    contract_request
    |> cast(params, fields_required ++ fields_optional)
    |> validate_required(fields_required)
  end

  defp move_uploaded_documents(id, headers) do
    Enum.reduce_while(
      [
        {"media/upload_contract_request_statute.pdf", "media/contract_request_statute.pdf"},
        {"media/upload_contract_request_additional_document.pdf", "media/contract_request_additional_document.pdf"}
      ],
      :ok,
      fn {temp_resource_name, resource_name}, _ ->
        move_file(id, temp_resource_name, resource_name, headers)
      end
    )
  end

  defp move_file(id, temp_resource_name, resource_name, headers) do
    with {:ok, %{"data" => %{"secret_url" => url}}} <-
           @media_storage_api.create_signed_url("GET", get_bucket(), temp_resource_name, id, []),
         {:ok, %{body: signed_content}} <- @media_storage_api.get_signed_content(url),
         {:ok, _} <- @media_storage_api.save_file(id, signed_content, get_bucket(), resource_name, headers),
         {:ok, %{"data" => %{"secret_url" => url}}} <-
           @media_storage_api.create_signed_url("DELETE", get_bucket(), temp_resource_name, id, []),
         {:ok, _} <- @media_storage_api.delete_file(url) do
      {:cont, :ok}
    end
  end

  defp get_bucket do
    Confex.fetch_env!(:core, Core.API.MediaStorage)[:contract_request_bucket]
  end
end
