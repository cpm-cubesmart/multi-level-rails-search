class Report
  # An unrelated class with a same-named method.
  def total
    42
  end

  def grand_total
    [total, Billing::Order.paid.sum(&:total)].sum
  end
end
