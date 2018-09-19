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

  def insert_declaration_request(params, user_id, auxiliary_entities, headers) do
    params
    |> changeset(user_id, auxiliary_entities, headers)
    |> do_insert_declaration_request()
  end

  def changeset(attrs, user_id, auxiliary_entities, headers) do
    %{
      employee: employee,
      person_id: person_id
    } = auxiliary_entities

    overlimit = Map.get(attrs, "overlimit", false)
    channel = attrs["channel"]
    attrs = Map.drop(attrs, ~w(person_id employee_id division_id overlimit))

    id = UUID.generate()

    %DeclarationRequest{id: id}
    |> cast(%{data: attrs, overlimit: overlimit, channel: channel}, ~w(data overlimit channel)a)
    |> validate_declaration_request_changeset(auxiliary_entities, headers)
    |> put_data_changes_declaration_request_changeset(id, user_id, auxiliary_entities)
    |> unique_constraint(:declaration_number, name: :declaration_requests_declaration_number_index)
    |> determine_auth_method_for_mpi(channel, person_id)
    |> generate_printout_form(employee)
  end

  defp search_mpi_matching_person(search_params) do
    case @mpi_api.search(search_params, []) do
      {:ok, %{"data" => [person | _]}} ->
        {:ok, person}

      {:ok, %{"data" => _}} ->
        {:ok, :no_match}

      error ->
        error
    end
  end

  def determine_auth_method_for_mpi(%Changeset{valid?: false} = changeset, _, _), do: changeset

  def determine_auth_method_for_mpi(changeset, @channel_cabinet, person_id) do
    changeset
    |> put_change(:authentication_method_current, %{"type" => @auth_na})
    |> put_change(:mpi_id, person_id)
  end

  def determine_auth_method_for_mpi(changeset, _, _) do
    data = get_field(changeset, :data)
    search_params = Persons.get_search_params(data["person"])

    case search_mpi_matching_person(search_params) do
      {:ok, :no_match} ->
        authentication_method = hd(data["person"]["authentication_methods"])
        put_change(changeset, :authentication_method_current, prepare_auth_method_current(authentication_method))

      {:ok, person} ->
        do_determine_auth_method_for_mpi(person, changeset)

      {:error, %HTTPoison.Error{reason: reason}} ->
        add_error(changeset, :authentication_method_current, format_error_response("MPI", reason))

      {:error, error_response} ->
        add_error(changeset, :authentication_method_current, format_error_response("MPI", error_response))
    end
  end

  defdelegate validate_declaration_request_changeset(changeset, auxiliary_entities, headers), to: V1Creator

  defdelegate put_data_changes_declaration_request_changeset(changeset, id, user_id, auxiliary_entities),
    to: V1V1Creator

  defdelegate do_insert_declaration_request(changeset), to: V1Creator

  defdelegate do_determine_auth_method_for_mpi(person, changeset), to: V1Creator

  defdelegate prepare_auth_method_current(auth), to: V1Creator

  defdelegate finalize(declaration_request), to: V1Creator

  defdelegate prepare_urgent_data(declaration_request), to: V1Creator

  defdelegate pending_declaration_requests(person, employee_id, legal_entity_id), to: V1Creator

  defdelegate validate_employee_status(employee), to: V1Creator

  defdelegate validate_employee_speciality(employee), to: V1Creator

  defdelegate generate_printout_form(changeset, employee), to: V1Creator

  defdelegate format_error_response(microservice, result), to: V1Creator
end
