# frozen_string_literal: true

module Invoices
  class FinalizeOpenCreditService < BaseService
    def initialize(invoice:)
      @invoice = invoice
      super
    end

    def call
      return result.not_found_failure!(resource: "invoice") if invoice.nil?

      result.invoice = invoice
      return result if invoice.finalized?

      ActiveRecord::Base.transaction do
        invoice.issuing_date = today_in_tz
        invoice.payment_due_date = today_in_tz
        invoice.status = :finalized
        invoice.save!
      end

      SendWebhookJob.perform_later("invoice.paid_credit_added", result.invoice)
      Utils::ActivityLog.produce(invoice, "invoice.paid_credit_added")
      GeneratePdfAndNotifyJob.perform_later(invoice:, email: should_deliver_email?)
      Integrations::Aggregator::Invoices::CreateJob.perform_later(invoice:) if invoice.should_sync_invoice?
      Integrations::Aggregator::Invoices::Hubspot::CreateJob.perform_later(invoice:) if invoice.should_sync_hubspot_invoice?
      Utils::SegmentTrack.invoice_created(result.invoice)

      result
    end

    private

    attr_accessor :invoice, :result

    def today_in_tz
      @today_in_tz ||= Time.current.in_time_zone(invoice.customer.applicable_timezone).to_date
    end

    def should_deliver_email?
      License.premium? &&
        invoice.billing_entity.email_settings.include?("invoice.finalized")
    end
  end
end
