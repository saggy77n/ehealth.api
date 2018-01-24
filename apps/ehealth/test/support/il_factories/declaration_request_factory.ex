defmodule EHealth.ILFactories.DeclarationRequestFactory do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      def declaration_request_factory do
        uuid = Ecto.UUID.generate()

        %EHealth.DeclarationRequest{
          data: %{
            employee: %{},
            legal_entity: %{
              medical_service_provider: %{}
            },
            division: %{}
          },
          status: "NEW",
          inserted_by: uuid,
          updated_by: uuid,
          authentication_method_current: %{},
          printout_content: "something",
          documents: []
        }
      end
    end
  end
end
