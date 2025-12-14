defmodule LavashTest do
  use ExUnit.Case
  doctest Lavash

  test "greets the world" do
    assert Lavash.hello() == :world
  end
end
