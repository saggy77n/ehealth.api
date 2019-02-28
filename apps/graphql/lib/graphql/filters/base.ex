defmodule GraphQL.Filters.Base do
  @moduledoc false

  use EctoFilter
  use EctoFilter.Operators.JSON

  def apply(query, {_, nil, []}, :map, _), do: query

  def apply(query, {parent_field, nil, [{field, :like, value} | tail]}, :map = type, context) do
    query
    |> where([..., r], ilike(fragment("?->>?", field(r, ^parent_field), ^to_string(field)), ^"%#{value}%"))
    |> apply({parent_field, nil, tail}, type, context)
  end

  def apply(query, operation, type, context), do: super(query, operation, type, context)
end
