class OrderTest < ActiveSupport::TestCase
  def test_total
    assert_equal 0, order.total
  end
end
