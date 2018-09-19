defmodule Core.DeclarationRequests.API.V2.Creator do
  @moduledoc false

  use Confex, otp_app: :core
  use Timex

  import Ecto.Changeset
  import Ecto.Query

  alias Core.DeclarationRequests.API.Creator, as: V1Creator
  alias Core.DeclarationRequests.API.Persons
  alias Core.DeclarationRequests.DeclarationRequest
  alias Core.GlobalParameters
  alias Core.Repo
  alias Ecto.Changeset
  alias Ecto.UUID

  require Logger

  @mpi_api Application.get_env(:core, :api_resolvers)[:mpi]

  @auth_na DeclarationRequest.authentication_method(:na)

  @channel_cabinet DeclarationRequest.channel(:cabinet)

  @status_new DeclarationRequest.status(:new)

  def create(params, user_id, person, employee, division, legal_entity, headers) do
    updates = [
      status: DeclarationRequest.status(:cancelled),
      updated_at: DateTime.utc_now(),
      updated_by: user_id
    ]

    global_parameters = GlobalParameters.get_values()

    auxiliary_entities = %{
      employee: employee,
      global_parameters: global_parameters,
      division: division,
      legal_entity: legal_entity,
      person_id: person["id"]
    }

    pending_declaration_requests = pending_declaration_requests(person, employee.id, legal_entity.id)

    Repo.transaction(fn ->
      previous_request_ids =
        pending_declaration_requests
        |> Repo.all()
        |> Enum.map(&Map.get(&1, :id))

      query = where(DeclarationRequest, [dr], dr.id in ^previous_request_ids)
      Repo.update_all(query, set: updates)

      with {:ok, declaration_request} <- insert_declaration_request(params, user_id, auxiliary_entities, headers),
           {:ok, declaration_request} <- finalize(declaration_request),
           {:ok, urgent_data} <- prepare_urgent_data(declaration_request) do
        %{urgent_data: urgent_data, finalize: declaration_request}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def changeset(attrs, user_id, auxiliary_entities, headers) do
    %{
      employee: employee,
      global_parameters: global_parameters,
      division: division,
      legal_entity: legal_entity,
      person_id: person_id
    } = auxiliary_entities

    employee_speciality_officio = employee.speciality["speciality"]

    overlimit = Map.get(attrs, "overlimit", false)
    channel = attrs["channel"]
    attrs = Map.drop(attrs, ~w(person_id employee_id division_id overlimit))

    id = UUID.generate()
    declaration_id = UUID.generate()

    %DeclarationRequest{id: id}
    |> cast(%{data: attrs, overlimit: overlimit, channel: channel}, ~w(data overlimit channel)a)
    |> validate_legal_entity_employee(legal_entity, employee)
    |> validate_legal_entity_division(legal_entity, division)
    |> validate_employee_type(employee)
    |> validate_patient_birth_date()
    |> validate_patient_age(employee_speciality_officio, global_parameters["adult_age"])
    |> validate_authentication_method_phone_number(headers)
    |> validate_tax_id()
    |> validate_person_addresses()
    |> validate_confidant_persons_tax_id()
    |> validate_confidant_person_rel_type()
    |> validate_authentication_methods()
    |> put_start_end_dates(employee_speciality_officio, global_parameters)
    |> put_in_data(["employee"], prepare_employee_struct(employee))
    |> put_in_data(["division"], prepare_division_struct(division))
    |> put_in_data(["legal_entity"], prepare_legal_entity_struct(legal_entity))
    |> put_in_data(["declaration_id"], declaration_id)
    |> put_change(:id, id)
    |> put_change(:declaration_id, declaration_id)
    |> put_change(:status, @status_new)
    |> put_change(:inserted_by, user_id)
    |> put_change(:updated_by, user_id)
    |> put_declaration_number()
    |> unique_constraint(:declaration_number, name: :declaration_requests_declaration_number_index)
    |> put_party_email()
    |> determine_auth_method_for_mpi(channel, person_id)
    |> generate_printout_form(employee)
  end

  def determine_auth_method_for_mpi(%Changeset{valid?: false} = changeset, _, _), do: changeset

  def determine_auth_method_for_mpi(changeset, @channel_cabinet, person_id) do
    changeset
    |> put_change(:authentication_method_current, %{"type" => @auth_na})
    |> put_change(:mpi_id, person_id)
  end

  def determine_auth_method_for_mpi(changeset, _, _) do
    data = get_field(changeset, :data)

    case @mpi_api.search(Persons.get_search_params(data["person"]), []) do
      {:ok, %{"data" => [person | _]}} ->
        do_determine_auth_method_for_mpi(person, changeset)

      {:ok, %{"data" => _}} ->
        authentication_method = hd(data["person"]["authentication_methods"])
        put_change(changeset, :authentication_method_current, prepare_auth_method_current(authentication_method))

      {:error, %HTTPoison.Error{reason: reason}} ->
        add_error(changeset, :authentication_method_current, format_error_response("MPI", reason))

      {:error, error_response} ->
        add_error(changeset, :authentication_method_current, format_error_response("MPI", error_response))
    end
  end

  defdelegate do_determine_auth_method_for_mpi(person, changeset), to: V1Creator

  defdelegate validate_legal_entity_employee(changeset, legal_entity, employee), to: V1Creator

  defdelegate validate_legal_entity_division(changeset, legal_entity, division), to: V1Creator

  defdelegate validate_authentication_method_phone_number(changeset, headers), to: V1Creator

  defdelegate insert_declaration_request(params, user_id, auxiliary_entities, headers), to: V1Creator

  defdelegate put_party_email(changeset), to: V1Creator

  defdelegate validate_confidant_persons_tax_id(changeset), to: V1Creator

  defdelegate validate_confidant_person_rel_type(changeset), to: V1Creator

  defdelegate validate_authentication_methods(changeset), to: V1Creator

  defdelegate prepare_auth_method_current(auth), to: V1Creator

  defdelegate prepare_auth_method_current(type, auth, method), to: V1Creator

  defdelegate finalize(declaration_request), to: V1Creator

  defdelegate prepare_urgent_data(declaration_request), to: V1Creator

  defdelegate pending_declaration_requests(person, employee_id, legal_entity_id), to: V1Creator

  defdelegate validate_employee_status(employee), to: V1Creator

  defdelegate validate_employee_speciality(employee), to: V1Creator

  defdelegate validate_employee_type(changeset, employee), to: V1Creator

  defdelegate validate_patient_birth_date(changeset), to: V1Creator

  defdelegate validate_patient_age(changeset, speciality, adult_age), to: V1Creator

  defdelegate validate_tax_id(changeset), to: V1Creator

  defdelegate validate_person_addresses(changeset), to: V1Creator

  defdelegate generate_printout_form(changeset, employee), to: V1Creator

  defdelegate request_end_date(employee_speciality_officio, today, expiration, birth_date, adult_age), to: V1Creator

  defdelegate sql_get_sequence_number, to: V1Creator

  defdelegate get_sequence_number, to: V1Creator

  defdelegate prepare_legal_entity_struct(legal_entity), to: V1Creator

  defdelegate put_declaration_number(changeset), to: V1Creator

  defdelegate put_in_data(changeset, keys, value), to: V1Creator

  defdelegate format_error_response(microservice, result), to: V1Creator

  defdelegate put_start_end_dates(changeset, employee_speciality_officio, global_parameters), to: V1Creator

  defdelegate prepare_employee_struct(employee), to: V1Creator

  defdelegate prepare_division_struct(division), to: V1Creator

  defdelegate prepare_addresses(addresses), to: V1Creator
end
