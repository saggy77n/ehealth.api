defmodule GraphQLWeb.Middleware.Authorization do
  @moduledoc """
  This middleware performs scope-based authorization on the fields.
  """

  @behaviour Absinthe.Middleware

  alias Absinthe.{Resolution, Type}

  @forbidden_error_message "Your scope does not allow to access this resource"

  defmacro __using__(opts \\ []) do
    meta_key = Keyword.get(opts, :meta_key, :scope)
    context_key = Keyword.get(opts, :context_key, :scope)

    quote do
      def middleware(middleware, %{__private__: [meta: [{unquote(meta_key), _}]]} = field, object) do
        opts = [meta_key: unquote(meta_key), context_key: unquote(context_key)]
        [{unquote(__MODULE__), opts} | super(middleware, field, object)]
      end

      def middleware(middleware, field, object), do: super(middleware, field, object)

      defoverridable middleware: 3
    end
  end

  def call(%{state: :unresolved} = resolution, opts) do
    [meta_key: meta_key, context_key: context_key] = opts

    requested_scope = Type.meta(resolution.definition.schema_node, meta_key)
    token_scope = Map.get(resolution.context, context_key, [])

    missing_allowances =
      [requested_scope, token_scope]
      |> Enum.map(&MapSet.new/1)
      |> (&apply(&2, &1)).(&MapSet.difference/2)
      |> MapSet.to_list()

    if Enum.empty?(missing_allowances) do
      resolution
    else
      Resolution.put_result(resolution, {:error, format_forbidden_error(missing_allowances)})
    end
  end

  def call(res, _), do: res

  defp format_forbidden_error(missing_allowances) do
    %{
      message: @forbidden_error_message,
      extensions: %{code: "FORBIDDEN", exception: %{missingAllowances: missing_allowances}}
    }
  end
end
