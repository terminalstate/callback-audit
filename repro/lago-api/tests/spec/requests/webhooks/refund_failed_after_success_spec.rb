# frozen_string_literal: true

require "rails_helper"

# A refund that fails after it was reported as succeeded, from the webhook endpoint to the credit note.
#
# Stripe: charge.refund.updated with status "failed", signed with the real Stripe-Signature scheme.
# Adyen: REFUND_FAILED, signed with the real HMAC. Nothing in Lago is stubbed and no HTTP call is made.
RSpec.describe WebhooksController, "refund failed after success" do
  let(:organization) { create(:organization) }
  let(:customer) { create(:customer, organization:) }
  let(:invoice) { create(:invoice, organization:, customer:, status: :finalized, payment_status: :succeeded) }

  # Once a refund is recorded as failed, update_status returns a "refund_failed" service failure and the
  # handler job raises it (Stripe: HandleEventJob#perform, Adyen: HandleEventService). That is the path
  # working as designed, so the drain lets that one error through and the examples check the records.
  def drain_jobs(*job_classes)
    5.times do
      break if enqueued_jobs.none? { |j| job_classes.map(&:name).include?(j["job_class"]) }

      begin
        perform_enqueued_jobs(only: job_classes)
      rescue BaseService::ServiceFailure => e
        raise unless e.code == "refund_failed"
      end
    end
  end

  def refund_failure_webhooks
    enqueued_jobs.select do |j|
      j["job_class"] == "SendWebhookJob" && j["arguments"].first == "credit_note.provider_refund_failure"
    end
  end

  describe "Stripe charge.refund.updated" do
    let(:webhook_secret) { "whsec_test_secret_for_specs" }
    let(:stripe_provider) { create(:stripe_provider, organization:, webhook_secret:) }
    let(:stripe_customer) { create(:stripe_customer, customer:, payment_provider: stripe_provider) }
    let(:payment) do
      create(:payment, payable: invoice, payment_provider: stripe_provider, payment_provider_customer: stripe_customer,
        status: "succeeded", payable_payment_status: "succeeded")
    end
    let(:credit_note) { create(:credit_note, organization:, customer:, invoice:, refund_status: credit_note_refund_status) }
    let(:refund) do
      create(:refund, credit_note:, payment:, payment_provider: stripe_provider, payment_provider_customer: stripe_customer,
        provider_refund_id: "re_test_1", status: refund_status)
    end

    let(:payload) do
      {
        id: "evt_test_refund_failed",
        object: "event",
        type: "charge.refund.updated",
        livemode: false,
        api_version: "2024-06-20",
        created: Time.current.to_i,
        data: {
          object: {
            id: "re_test_1",
            object: "refund",
            status: "failed",
            failure_reason: "expired_or_canceled_card",
            metadata: {lago_credit_note_id: credit_note.id, lago_invoice_id: invoice.id}
          }
        }
      }.to_json
    end

    before { refund }

    def deliver
      timestamp = Time.current
      signature = Stripe::Webhook::Signature.compute_signature(timestamp, payload, webhook_secret)
      post(
        "/webhooks/stripe/#{organization.id}?code=#{stripe_provider.code}&type=charge.refund.updated",
        params: payload,
        headers: {
          "HTTP_STRIPE_SIGNATURE" => Stripe::Webhook::Signature.generate_header(timestamp, signature),
          "Content-Type" => "application/json"
        }
      )
      expect(response).to have_http_status(:ok)
      drain_jobs(InboundWebhooks::ProcessJob, PaymentProviders::Stripe::HandleEventJob)
    end

    context "when the refund was still pending (control)" do
      let(:credit_note_refund_status) { :pending }
      let(:refund_status) { "pending" }

      it "marks the credit note's refund as failed and sends credit_note.provider_refund_failure" do
        deliver

        expect(credit_note.reload.refund_status).to eq("failed")
        expect(refund_failure_webhooks.size).to eq(1)
      end
    end

    context "when the refund had already succeeded" do
      let(:credit_note_refund_status) { :succeeded }
      let(:refund_status) { "succeeded" }

      it "current behaviour: the failure is ignored, the credit note stays refunded and no webhook is sent" do
        deliver

        expect(credit_note.reload.refund_status).to eq("succeeded")
        expect(refund.reload.status).to eq("succeeded")
        expect(refund_failure_webhooks).to be_empty
        expect(InboundWebhook.last.status).to eq("succeeded")
      end

      it "if fixed: the credit note's refund is marked failed and credit_note.provider_refund_failure is sent" do
        pending("fails while the bug is present")

        deliver

        expect(credit_note.reload.refund_status).to eq("failed")
        expect(refund_failure_webhooks.size).to eq(1)
      end
    end
  end

  describe "Adyen REFUND_FAILED" do
    let(:hmac_key) { "44782DEF547AAA06C910C43932B1EB0C71FC68D9D0C057550C48EC2ACF6BA056" }
    let(:adyen_provider) { create(:adyen_provider, organization:, hmac_key:) }
    let(:adyen_customer) { create(:adyen_customer, customer:, payment_provider: adyen_provider) }
    let(:payment) do
      create(:payment, payable: invoice, payment_provider: adyen_provider, payment_provider_customer: adyen_customer,
        provider_payment_id: "8835511210681015", status: "Authorised", payable_payment_status: "succeeded")
    end
    let(:credit_note) { create(:credit_note, organization:, customer:, invoice:, refund_status: :succeeded) }
    let(:refund) do
      create(:refund, credit_note:, payment:, payment_provider: adyen_provider, payment_provider_customer: adyen_customer,
        provider_refund_id: "8835511210681099", status: "succeeded")
    end

    let(:item) do
      item = {
        "additionalData" => {},
        "amount" => {"currency" => "EUR", "value" => 120},
        "eventCode" => "REFUND_FAILED",
        "eventDate" => "2026-10-17T10:00:00+02:00",
        "merchantAccountCode" => "TestMerchant",
        "merchantReference" => credit_note.id,
        "originalReference" => "8835511210681015",
        "pspReference" => "8835511210681099",
        "reason" => "Refund failed",
        "success" => "true"
      }
      item["additionalData"]["hmacSignature"] = Adyen::Utils::HmacValidator.new.calculate_webhook_hmac(item, hmac_key)
      item
    end

    before { refund }

    it "current behaviour: Adyen's REFUND_FAILED after a successful REFUND is ignored" do
      post(
        "/webhooks/adyen/#{organization.id}?code=#{adyen_provider.code}",
        params: {live: "false", notificationItems: [{NotificationRequestItem: item}]}.to_json,
        headers: {"Content-Type" => "application/json"}
      )
      expect(response.body).to eq("[accepted]")
      drain_jobs(PaymentProviders::Adyen::HandleEventJob)

      expect(credit_note.reload.refund_status).to eq("succeeded")
      expect(refund.reload.status).to eq("succeeded")
      expect(refund_failure_webhooks).to be_empty
    end
  end
end
