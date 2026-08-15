defmodule Demo.Accounts do
  use Ash.Domain

  resources do
    resource Demo.Accounts.User do
      define :reset_visitor, action: :reset
    end

    resource Demo.Accounts.Token
  end
end
