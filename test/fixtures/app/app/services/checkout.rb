class Checkout
  def initialize(order)
    @order = order
  end

  def summary
    amount = @order.total
    label = @order.try(:total)
    extra = @order.send(:total)
    tax = @order.total? ? 1 : 0
    { total: amount, label: label, extra: extra, tax: tax }
  end

  def reset
    @order.total = 0
  end
end
