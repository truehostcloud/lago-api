# frozen_string_literal: true

module Wallets
  class CreateService < BaseService
    def initialize(params:)
      @params = params
      super
    end

    activity_loggable(
      action: "wallet.created",
      record: -> { result.wallet }
    )

    def call
      return result unless valid?

      attributes = {
        organization_id: result.current_customer.organization_id,
        customer_id: result.current_customer.id,
        name: params[:name],
        rate_amount: params[:rate_amount],
        expiration_at: params[:expiration_at],
        status: :active
      }

      if params.key?(:invoice_requires_successful_payment)
        attributes[:invoice_requires_successful_payment] = ActiveModel::Type::Boolean.new.cast(params[:invoice_requires_successful_payment])
      end

      if params.key?(:applies_to)
        attributes[:allowed_fee_types] = params[:applies_to][:fee_types] if params[:applies_to].key?(:fee_types)
      end

      wallet = Wallet.new(attributes)

      ActiveRecord::Base.transaction do
        if params[:currency].present?
          Customers::UpdateCurrencyService.call!(customer: result.current_customer, currency: params[:currency])
        end

        wallet.currency = wallet.customer.currency
        wallet.save!

        if params[:recurring_transaction_rules].present?
          Wallets::RecurringTransactionRules::CreateService.call(wallet:, wallet_params: params)
        end
      end

      result.wallet = wallet

      SendWebhookJob.perform_later("wallet.created", wallet)

      WalletTransactions::CreateJob.perform_later(
        organization_id: params[:organization_id],
        params: {
          wallet_id: wallet.id,
          paid_credits: params[:paid_credits],
          granted_credits: params[:granted_credits],
          source: :manual,
          metadata: params[:transaction_metadata]
        }
      )

      result
    rescue ActiveRecord::RecordInvalid => e
      result.record_validation_failure!(record: e.record)
    rescue BaseService::FailedResult => e
      e.result
    end

    private

    attr_reader :params

    def valid?
      Wallets::ValidateService.new(result, **params).valid?
    end
  end
end
