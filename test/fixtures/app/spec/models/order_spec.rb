describe Billing::Order do
  it "totals" do
    expect(order.total).to eq(0)
  end
end
