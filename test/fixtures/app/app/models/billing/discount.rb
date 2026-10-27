module Billing
  class Discount
    def initialize(code); @code = code; end

    def apply(amount)
      amount - 1
    end
  end
end
