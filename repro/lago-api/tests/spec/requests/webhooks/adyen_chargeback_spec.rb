# frozen_string_literal: true

require "rails_helper"

# Adyen CHARGEBACK, from the webhook endpoint to the invoice.
#
# The HMAC is computed with the real validator, and nothing in the chain is stubbed: controller,
# HandleIncomingWebhookService, HandleEventJob, HandleEventService, Webhooks::ChargebackService.
# The notification item is Adyen's sample from spec/fixtures/adyen/chargeback_lost_event.json:
# pspReference is the dispute's reference, originalReference the disputed payment's.
RSpec.describe WebhooksController, "Adyen CHARGEBACK" do
  let(:organization) { create(:organization) }
  let(:hmac_key) { "44782DEF547AAA06C910C43932B1EB0C71FC68D9D0C057550C48EC2ACF6BA056" }
  let(:adyen_provider) { create(:adyen_provider, organization:, hmac_key:) }
  let(:customer) { create(:customer, organization:, payment_provider: "adyen", payment_provider_code: adyen_provider.code) }
  let(:invoice) { create(:invoice, organization:, customer:, status: :finalized, payment_status: :succeeded) }
  let(:disputed_payment_reference) { "9913333333333333" }
  let(:payment) do
    create(
      :payment,
      :adyen_payment,
      payable: invoice,
      payment_provider: adyen_provider,
      provider_payment_id: disputed_payment_reference,
      status: "Authorised",
      payable_payment_status: "succeeded"
    )
  end

  let(:fixture) { JSON.parse(Rails.root.join("spec/fixtures/adyen/chargeback_lost_event.json").read) }
  let(:item) do
    item = fixture["notificationItems"].first["NotificationRequestItem"]
    item["additionalData"]["hmacSignature"] = Adyen::Utils::HmacValidator.new.calculate_webhook_hmac(item, hmac_key)
    item
  end

  before { payment }

  def deliver
    post(
      "/webhooks/adyen/#{organization.id}?code=#{adyen_provider.code}",
      params: {live: "false", notificationItems: [{NotificationRequestItem: item}]}.to_json,
      headers: {"Content-Type" => "application/json"}
    )
  end

  it "current behaviour: the delivery is accepted and queued" do
    expect { deliver }.to have_enqueued_job(PaymentProviders::Adyen::HandleEventJob)
    expect(response).to have_http_status(:ok)
    expect(response.body).to eq("[accepted]")
  end

  it "current behaviour: the queued job raises on every run, so Adyen's accepted CHARGEBACK is never recorded" do
    deliver
    job = enqueued_jobs.find { |j| j["job_class"] == "PaymentProviders::Adyen::HandleEventJob" }

    2.times do
      expect { ActiveJob::Base.execute(job) }.to raise_error(NoMethodError, /undefined method 'first' for nil/)
    end
    expect(invoice.reload.payment_dispute_lost_at).to be_nil
  end

  it "current behaviour: given the full notification, the dispute's pspReference does not find the disputed payment" do
    result = PaymentProviders::Adyen::Webhooks::ChargebackService.call(
      organization_id: organization.id,
      event_json: fixture.to_json
    )

    expect(result).not_to be_success
    expect(result.error.error_code).to eq("adyen_payment_not_found")
    expect(invoice.reload.payment_dispute_lost_at).to be_nil
  end

  it "if fixed: a lost CHARGEBACK marks the invoice's dispute as lost" do
    pending("fails while the bug is present")

    deliver
    perform_enqueued_jobs(only: PaymentProviders::Adyen::HandleEventJob)

    expect(invoice.reload.payment_dispute_lost_at).to eq(Time.zone.parse(item["eventDate"]))
  end
end
