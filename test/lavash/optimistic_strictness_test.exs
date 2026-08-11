defmodule Lavash.OptimisticStrictnessTest do
  @moduledoc """
  Issue #46: untranspilable optimistic code — and optimistic calcs with
  deps that never exist in client state (the #41/#45 bug class) — fail
  the build by default, with `config :lavash, :untranspilable_optimistic,
  :warn` as the transitional demote-and-warn escape hatch.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  test "untranspilable optimistic calc is a compile error" do
    assert_raise Spark.Error.DslError, ~r/is not transpilable/, fn ->
      defmodule UntranspilableCalc do
        use Lavash.LiveView

        state :count, :integer, default: 0, optimistic: true
        calculate :slow, rx(some_server_fn(@count))

        def some_server_fn(c), do: c

        template do
          ~H"<div>{@slow}</div>"
        end
      end
    end
  end

  test "optimistic calc depending on non-client state is a compile error" do
    assert_raise Spark.Error.DslError,
                 ~r/depends on :server_only, which is not client state/,
                 fn ->
                   defmodule DepGapCalc do
                     use Lavash.LiveView

                     state :server_only, :integer, default: 0
                     calculate :derived, rx(@server_only + 1)

                     template do
                       ~H"<div>{@derived}</div>"
                     end
                   end
                 end
  end

  test "untranspilable rx set in an optimistic action is a compile error" do
    assert_raise Spark.Error.DslError,
                 ~r/set :items in an optimistic action.*not.*transpilable/s,
                 fn ->
                   defmodule UntranspilableSet do
                     use Lavash.LiveView

                     state :items, {:array, :string}, default: [], optimistic: true

                     actions do
                       action :add do
                         set :items, rx(["x-" <> Integer.to_string(length(@items)) | @items])
                       end
                     end

                     template do
                       ~H"<div>{inspect(@items)}</div>"
                     end
                   end
                 end
  end

  test "the :warn escape hatch restores demote-and-warn" do
    Application.put_env(:lavash, :untranspilable_optimistic, :warn)
    on_exit(fn -> Application.delete_env(:lavash, :untranspilable_optimistic) end)

    log =
      capture_log(fn ->
        defmodule WarnModeCalc do
          use Lavash.LiveView

          state :count, :integer, default: 0, optimistic: true
          calculate :slow, rx(some_server_fn(@count))

          def some_server_fn(c), do: c

          template do
            ~H"<div>{@slow}</div>"
          end
        end
      end)

    assert log =~ "calculate :slow is marked optimistic"
    assert log =~ "not transpilable"
  end

  test "injected async_ready calcs are exempt from the dep-gap check" do
    # ModalAsyncComponent's :item is optimistic: false, yet the injected
    # :item_id_async_ready calc depends on it — and compiles.
    calcs = Lavash.Test.Magic.ModalAsyncComponent.__lavash__(:calculations)
    ready = Enum.find(calcs, &(&1.name == :item_id_async_ready))

    assert ready
    assert ready.injected
  end
end
