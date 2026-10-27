# frozen_string_literal: true

module Billing
  class Order < ApplicationRecord
    has_many :line_items
    belongs_to :customer
    scope :paid, -> { where(paid: true) }
    attr_reader :discount_code
    delegate :email, to: :customer
    before_save :normalize

    def total
      # total = line_items.sum(&:price) (old way)
      items_total = line_items.sum(&:price)
      apply_discount(items_total) if discount_code
    end

    def total?
      total.positive?
    end

    def total=(value)
      @total = value
    end

    def self.build(attrs)
      new(attrs)
    end

    class << self
      def recent
        paid.order(created_at: :desc)
      end
    end

    define_method(:summary) { "#{id}: #{total}" }

    private

    def apply_discount(amount)
      Billing::Discount.new(discount_code).apply(amount)
    end

    def normalize
      self.total = 0 unless total
    end
  end
end
