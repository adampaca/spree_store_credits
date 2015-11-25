Spree::Order.class_eval do
  attr_accessor :store_credit_amount, :remove_store_credits

  # the check for user? below is to ensure we don't break the
  # admin app when creating a new order from the admin console
  # In that case, we create an order before assigning a user
  before_save :process_store_credit, if: :store_credit_processing_required?
  after_save :ensure_sufficient_credit, if: proc { |order| order.user.present? && !order.completed? }

  validates_with StoreCreditMinimumValidator

  def process_payments_with_credits!
    if total > 0 && unprocessed_payments.empty?
      false
    else
      process_payments_without_credits!
    end
  end
  alias_method_chain :process_payments!, :credits

  def store_credit_amount
    @store_credit_amount || adjustments.store_credits.sum(:amount).abs.to_f
  end

  # in case of paypal payment, item_total cannot be 0
  def store_credit_maximum_amount
    item_total - 0.01
  end

  # returns the maximum usable amount of store credits
  def store_credit_maximum_usable_amount
    [store_credit_maximum_amount, [user.store_credits_total, 0].max].min
  end

  private

  def store_credit_processing_required?
    user.present? && (@store_credit_amount || @remove_store_credits)
  end

  # credit or update store credit adjustment to correct value if amount specified
  def process_store_credit
    @store_credit_amount = BigDecimal.new(@store_credit_amount.to_s).round(2)

    # store credit can't be greater than order total (not including existing credit), or the user's available credit
    @store_credit_amount = [@store_credit_amount, user.store_credits_total, (total + store_credit_amount.abs)].min

    if @store_credit_amount <= 0 || @remove_store_credits
      adjustments.store_credits.destroy_all
    else
      sca = adjustments.store_credits.first
      if sca
        sca.update_attributes(amount: -(@store_credit_amount))
      else
        # create adjustment off association to prevent reload
        adjustments.store_credits.create(
          label: Spree.t(:store_credit),
          amount: -(@store_credit_amount),
          source_type: 'Spree::StoreCredit',
          order: self,
          adjustable: self
        )
      end
    end

    # recalculate totals and ensure payment is set to new amount
    updater.update unless new_record?
    return unless unprocessed_payments.first
    unprocessed_payments.first.amount = total
    unprocessed_payments.first.amount
  end

  def consume_users_credit
    return unless completed? && user.present?
    credit_used = store_credit_amount

    user.store_credits.each do |store_credit|
      break if credit_used == 0
      next unless store_credit.remaining_amount > 0
      if store_credit.remaining_amount > credit_used
        store_credit.remaining_amount -= credit_used
        store_credit.save
        credit_used = 0
      else
        credit_used -= store_credit.remaining_amount
        store_credit.update_attribute(:remaining_amount, 0)
      end
    end
  end

  # consume users store credit once the order has completed.
  state_machine.after_transition to: :complete, do: :consume_users_credit

  # ensure that user has sufficient credits to cover adjustments
  #
  def ensure_sufficient_credit
    return unless user.store_credits_total < store_credit_amount
    # user's credit does not cover all adjustments.
    adjustments.store_credits.destroy_all
    update!
    updater.update_payment_state
    update!
  end
end
