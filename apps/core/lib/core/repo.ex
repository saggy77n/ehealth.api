defmodule Core.Repo do
  @moduledoc false

  use Ecto.Repo, otp_app: :core
  use Scrivener, page_size: 50, max_page_size: 500
end
