defmodule Lavash.Rx.FunctionsTest do
  use ExUnit.Case, async: true

  describe "Lavash.Rx.Functions" do
    test "module using Lavash.Rx.Functions exports __defrx_definitions__/0" do
      defmodule TestValidators do
        use Lavash.Rx.Functions

        defrx valid_email?(email) do
          String.length(email) > 0 && String.contains?(email, "@")
        end
      end

      assert function_exported?(TestValidators, :__defrx_definitions__, 0)
      defs = TestValidators.__defrx_definitions__()
      assert length(defs) == 1

      [{name, arity, params, body_ast, body_source}] = defs
      assert name == :valid_email?
      assert arity == 1
      assert params == [:email]
      assert is_binary(body_source)
      assert body_source =~ "String.length"
      assert body_source =~ "String.contains?"
      assert body_ast != nil
    end

    test "module can define multiple defrx functions" do
      defmodule MultiValidators do
        use Lavash.Rx.Functions

        defrx non_empty?(text) do
          String.length(text) > 0
        end

        defrx has_digit?(text) do
          String.match?(text, ~r/\d/)
        end

        defrx valid_password?(password) do
          non_empty?(password) && has_digit?(password)
        end
      end

      defs = MultiValidators.__defrx_definitions__()
      assert length(defs) == 3

      names = Enum.map(defs, fn {name, _, _, _, _} -> name end)
      assert :non_empty? in names
      assert :has_digit? in names
      assert :valid_password? in names
    end
  end

  describe "import_rx" do
    defmodule EmailValidators do
      use Lavash.Rx.Functions

      defrx valid_email?(email) do
        String.length(email) > 0 && String.contains?(email, "@")
      end

      defrx valid_domain?(email) do
        String.contains?(email, ".")
      end
    end

    test "imported defrx functions are expanded in rx macro" do
      defmodule ImportingModule do
        import Lavash.Rx
        import_rx Lavash.Rx.FunctionsTest.EmailValidators

        def get_rx do
          rx(valid_email?(@email))
        end
      end

      rx = ImportingModule.get_rx()

      # The source should be the expanded version
      assert rx.source =~ "String.length"
      assert rx.source =~ "String.contains?"

      # The deps should include :email
      assert :email in rx.deps
    end

    test "imported defrx functions work with :only option" do
      defmodule SelectiveImportModule do
        import Lavash.Rx
        import_rx Lavash.Rx.FunctionsTest.EmailValidators, only: [valid_email?: 1]

        def get_rx do
          rx(valid_email?(@email))
        end
      end

      rx = SelectiveImportModule.get_rx()
      assert rx.source =~ "String.length"
    end

    test "local defrx overrides imported defrx" do
      defmodule OverrideModule do
        import Lavash.Rx
        import_rx Lavash.Rx.FunctionsTest.EmailValidators

        # Local definition overrides imported one
        defrx valid_email?(email) do
          email != nil
        end

        def get_rx do
          rx(valid_email?(@email))
        end
      end

      rx = OverrideModule.get_rx()

      # Should use local definition, not imported
      assert rx.source =~ "!= nil" or rx.source =~ "!=="
      refute rx.source =~ "String.length"
    end
  end

  describe "rx evaluation with imports" do
    defmodule CardValidators do
      use Lavash.Rx.Functions

      defrx expected_length(is_amex) do
        if(is_amex, do: 15, else: 16)
      end

      defrx valid_card_length?(digits, is_amex) do
        String.length(digits) == expected_length(is_amex)
      end
    end

    test "nested defrx calls are expanded" do
      defmodule CardModule do
        import Lavash.Rx
        import_rx Lavash.Rx.FunctionsTest.CardValidators

        def get_rx do
          rx(valid_card_length?(@digits, @is_amex))
        end
      end

      rx = CardModule.get_rx()

      # Both functions should be expanded inline
      assert rx.source =~ "String.length"
      assert rx.source =~ "if"

      # Both deps should be extracted
      assert :digits in rx.deps
      assert :is_amex in rx.deps
    end
  end
end
