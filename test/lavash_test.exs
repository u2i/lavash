defmodule LavashTest do
  use ExUnit.Case

  test "Lavash module exists" do
    assert Code.ensure_loaded?(Lavash)
  end
end
