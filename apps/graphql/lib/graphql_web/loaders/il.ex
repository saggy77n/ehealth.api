defmodule GraphQLWeb.Loaders.IL do
  @moduledoc false

  import Ecto.Query, only: [where: 2]

  alias Core.ContractRequests.{CapitationContractRequest, ReimbursementContractRequest}

  @read_repo Application.get_env(:core, :repos)[:read_repo]

  def data, do: Dataloader.Ecto.new(@read_repo, query: &query/2)

  def query(CapitationContractRequest, %{client_type: "MSP", client_id: client_id}) do
    where(CapitationContractRequest, contractor_legal_entity_id: ^client_id)
  end

  def query(CapitationContractRequest, %{client_type: "NHS"}), do: CapitationContractRequest

  def query(ReimbursementContractRequest, %{client_type: "PHARMACY", client_id: client_id}) do
    where(ReimbursementContractRequest, contractor_legal_entity_id: ^client_id)
  end

  def query(ReimbursementContractRequest, %{client_type: "NHS"}), do: ReimbursementContractRequest

  def query(queryable, _), do: queryable
end
