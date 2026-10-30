# frozen_string_literal: true

require "rails_helper"

# Flutterwave charge.completed, from the webhook endpoint to the invoice.
#
# The `verif-hash` header is checked for real and nothing in Lago is stubbed. Only the HTTP call
# to Flutterwave's verify endpoint is answered by WebMock.
RSpec.describe WebhooksController, "Flutterwave charge.completed when verification fails" do
  let(:organization) { create(:organization) }
  let(:webhook_secret) { "flw-webhook-secret-for-tests" }
  let(:flutterwave_provider) { create(:flutterwave_provider, organization:, webhook_secret:) }
  let(:customer) do
    create(:customer, organization:, currency: "NGN", payment_provider: "flutterwave", payment_provider_code: flutterwave_provider.code)
  end
  let(:invoice) do
    create(
      :invoice,
      organization:,
      customer:,
      status: :finalized,
      payment_status: :pending,
      currency: "NGN",
      total_amount_cents: 1_000_000
    )
  end
  let(:transaction_id) { 285959875 }
  let(:verify_url) { "https://api.flutterwave.com/v3/transactions/#{transaction_id}/verify" }
  let(:verified) do
    {
      status: "success",
      data: {id: transaction_id, tx_ref: invoice.id, status: "successful", amount: 10000, currency: "NGN"}
    }.to_json
  end

  before do
    create(:flutterwave_customer, customer:, payment_provider: flutterwave_provider)
    invoice
  end

  def deliver
    post(
      "/webhooks/flutterwave/#{organization.id}?code=#{flutterwave_provider.code}",
      params: {
        event: "charge.completed",
        data: {
          id: transaction_id,
          tx_ref: invoice.id,
          status: "successful",
          amount: 10000,
          currency: "NGN",
          meta: {lago_invoice_id: invoice.id, lago_payable_type: "Invoice"}
        }
      }.to_json,
      headers: {"verif-hash" => webhook_secret, "Content-Type" => "application/json"}
    )
  end

  def drain_jobs
    5.times do
      jobs = enqueued_jobs.select { |j| j["job_class"] == "PaymentProviders::Flutterwave::HandleEventJob" }
      break if jobs.empty?

      perform_enqueued_jobs(only: PaymentProviders::Flutterwave::HandleEventJob)
    end
  end

  it "control: when the verify call succeeds, the invoice is paid" do
    stub_request(:get, verify_url).to_return(status: 200, body: verified, headers: {"Content-Type" => "application/json"})

    deliver
    expect(response).to have_http_status(:ok)
    drain_jobs

    expect(invoice.reload.payment_status).to eq("succeeded")
    expect(invoice.payments.count).to eq(1)
  end

  it "current behaviour: when the verify call answers 503 once, the paid charge is dropped and nothing is retried" do
    stub_request(:get, verify_url)
      .to_return({status: 503, body: ""}, {status: 200, body: verified, headers: {"Content-Type" => "application/json"}})

    deliver
    expect(response).to have_http_status(:ok)
    drain_jobs

    expect(invoice.reload.payment_status).to eq("pending")
    expect(invoice.payments.count).to eq(0)
    expect(enqueued_jobs.count { |j| j["job_class"] == "PaymentProviders::Flutterwave::HandleEventJob" }).to eq(0)
    expect(a_request(:get, verify_url)).to have_been_made.once
  end

  it "if fixed: a transient verify failure is retried and the invoice ends up paid" do
    pending("fails while the bug is present")

    stub_request(:get, verify_url)
      .to_return({status: 503, body: ""}, {status: 200, body: verified, headers: {"Content-Type" => "application/json"}})

    deliver
    drain_jobs

    expect(invoice.reload.payment_status).to eq("succeeded")
  end
end
