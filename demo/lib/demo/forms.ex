defmodule Demo.Forms do
  @moduledoc """
  Domain for ephemeral form resources.

  These resources use ETS data layer for in-memory storage during form handling.
  They're not persisted to the database - just used for validation demos.
  """
  use Ash.Domain

  resources do
    resource Demo.Forms.Registration
  end
end
