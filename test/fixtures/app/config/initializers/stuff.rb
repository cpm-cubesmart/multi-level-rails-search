Rails.application.config.after_initialize do
  Billing::Order.recent
end
