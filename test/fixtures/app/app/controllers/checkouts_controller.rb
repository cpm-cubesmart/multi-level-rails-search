class CheckoutsController < ApplicationController
  before_action :load_order

  def show
    @summary = Checkout.new(@order).summary
  end

  private

  def load_order
    @order = Billing::Order.find(params[:id])
  end
end
