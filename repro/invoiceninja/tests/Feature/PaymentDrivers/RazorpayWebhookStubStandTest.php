<?php

/**
 * Reproduction: a Razorpay payment whose browser never posts back is never recorded.
 *
 * RazorpayPaymentDriver::processWebhookRequest() is an empty stub. The webhook
 * controller returns its null, which becomes an empty HTTP 200, so every Razorpay
 * server-side event (payment.captured, payment.authorized, ...) is acknowledged and
 * dropped. The only code that records a Razorpay payment is the browser-return path,
 * Razorpay\Hosted::paymentResponse(). Razorpay captures authorised payments
 * automatically by default, so when the Checkout handler never runs (slow network,
 * closed tab) Razorpay has the money and the invoice stays unpaid.
 *
 * No provider HTTP call is faked. The control computes a genuine Razorpay payment
 * signature with the gateway's API secret exactly as the SDK verifies it
 * (hash_hmac('sha256', order_id|payment_id, secret)). The current-behaviour webhook
 * test sends no signature because the stub verifies nothing; the if-fixed test signs
 * the body with a webhook secret, as a handler that verifies X-Razorpay-Signature
 * needs (invoiceninja PR #13397 adds a webhookSecret gateway field).
 */

namespace Tests\Feature\PaymentDrivers;

use App\Factory\CompanyGatewayFactory;
use App\Http\Requests\ClientPortal\Payments\PaymentResponseRequest;
use App\Models\CompanyGateway;
use App\Models\Payment;
use App\Models\PaymentHash;
use App\PaymentDrivers\Razorpay\Hosted;
use Illuminate\Foundation\Testing\DatabaseTransactions;
use Illuminate\Support\Str;
use PHPUnit\Framework\Attributes\Group;
use Tests\MockAccountData;
use Tests\TestCase;

class RazorpayWebhookStubStandTest extends TestCase
{
    use DatabaseTransactions;
    use MockAccountData;

    private const API_SECRET = 'razorpay_secret_stand';

    private const WEBHOOK_SECRET = 'razorpay_webhook_secret_stand';

    private CompanyGateway $company_gateway;

    protected function setUp(): void
    {
        parent::setUp();

        $this->makeTestData();

        // 'hxd6gwg3ekb9tb3v9lptgx1mqyg69zu9' is the seeded Razorpay gateway key.
        $this->company_gateway = CompanyGatewayFactory::create($this->company->id, $this->user->id);
        $this->company_gateway->gateway_key = 'hxd6gwg3ekb9tb3v9lptgx1mqyg69zu9';
        $this->company_gateway->fees_and_limits = new \stdClass();
        $this->company_gateway->setConfig([
            'apiKey' => 'rzp_test_stand',
            'apiSecret' => self::API_SECRET,
        ]);
        $this->company_gateway->save();
    }

    /**
     * Current behaviour: a Razorpay payment.captured webhook (the server-side
     * settlement a customer who never returned relies on) is acknowledged 200 and
     * dropped. No payment is recorded and the invoice balance is unchanged.
     */
    public function test_captured_webhook_is_a_noop_current_behaviour(): void
    {
        $this->makeOrderPaymentHash('order_stand_webhook');
        $balance_before = (float) $this->invoice->fresh()->balance;

        $response = $this->postRazorpayWebhook('pay_captured_stand', 'order_stand_webhook');

        $response->assertStatus(200);
        $this->assertSame('', $response->getContent(), 'the stub returns an empty body');
        $this->assertFalse(
            Payment::query()->where('transaction_reference', 'pay_captured_stand')->exists(),
            'the Razorpay webhook recorded no payment',
        );
        $this->assertEqualsWithDelta($balance_before, (float) $this->invoice->fresh()->balance, 0.001);
    }

    /**
     * Control: the browser-return path records a COMPLETED payment today. The
     * signature is a real Razorpay payment signature verified by the SDK. This is
     * the only Razorpay payment creator, and it is exactly what fails to run when
     * the customer never returns.
     */
    public function test_browser_return_records_completed_payment_control(): void
    {
        $payment_hash = $this->makeOrderPaymentHash('order_stand_ctrl');

        $driver = $this->company_gateway->driver($this->client);
        $driver->init();
        $driver->setPaymentHash($payment_hash);

        $payment_id = 'pay_stand_ctrl';
        $signature = hash_hmac('sha256', 'order_stand_ctrl|' . $payment_id, self::API_SECRET);

        $request = PaymentResponseRequest::create('/client/payments/response', 'POST', [
            'payment_hash' => $payment_hash->hash,
            'company_gateway_id' => $this->company_gateway->hashed_id,
            'razorpay_payment_id' => $payment_id,
            'razorpay_signature' => $signature,
        ]);
        $request->setContainer($this->app);

        (new Hosted($driver))->paymentResponse($request);

        $payment = Payment::query()->where('transaction_reference', $payment_id)->first();

        $this->assertNotNull($payment, 'the browser-return path records the Razorpay payment');
        $this->assertSame(Payment::STATUS_COMPLETED, $payment->status_id);
    }

    /**
     * If fixed: a payment.captured webhook should record a COMPLETED payment, the
     * way every driver with a real webhook handler does. The body is signed with
     * the gateway's webhook secret. This fails at 493c388 because
     * processWebhookRequest() is an empty stub.
     */
    #[Group('if-fixed')]
    public function test_captured_webhook_records_completed_payment_if_fixed(): void
    {
        $this->company_gateway->setConfig([
            'apiKey' => 'rzp_test_stand',
            'apiSecret' => self::API_SECRET,
            'webhookSecret' => self::WEBHOOK_SECRET,
        ]);
        $this->company_gateway->save();

        $this->makeOrderPaymentHash('order_stand_fixed');

        $this->postRazorpayWebhook('pay_fixed_stand', 'order_stand_fixed', self::WEBHOOK_SECRET)->assertStatus(200);

        $payment = Payment::query()->where('transaction_reference', 'pay_fixed_stand')->first();

        $this->assertNotNull($payment, 'after a fix the captured webhook must record the payment');
        $this->assertSame(Payment::STATUS_COMPLETED, $payment->status_id);
    }

    private function makeOrderPaymentHash(string $orderId): PaymentHash
    {
        return PaymentHash::query()->create([
            'company_id' => $this->company->id,
            'hash' => Str::random(32),
            'fee_invoice_id' => $this->invoice->id,
            'fee_total' => 0,
            'data' => [
                'amount_with_fee' => 1,
                'credits' => 0,
                'order_id' => $orderId,
                'order_amount' => 100,
                'invoices' => [[
                    'invoice_id' => $this->invoice->hashed_id,
                    'invoice_number' => $this->invoice->number,
                    'amount' => 1,
                ]],
            ],
        ]);
    }

    /**
     * POST a realistic Razorpay webhook to the real route. With a webhook secret the
     * body is signed the way Razorpay signs it (X-Razorpay-Signature, HMAC-SHA256 of
     * the raw body).
     */
    private function postRazorpayWebhook(string $paymentId, string $orderId, ?string $webhookSecret = null): \Illuminate\Testing\TestResponse
    {
        $payload = json_encode([
            'event' => 'payment.captured',
            'contains' => ['payment'],
            'payload' => [
                'payment' => [
                    'entity' => [
                        'id' => $paymentId,
                        'order_id' => $orderId,
                        'status' => 'captured',
                        'amount' => 100,
                        'currency' => 'INR',
                    ],
                ],
            ],
        ], JSON_THROW_ON_ERROR);

        $url = sprintf('/payment_webhook/%s/%s', $this->company->company_key, $this->company_gateway->hashed_id);

        $server = ['CONTENT_TYPE' => 'application/json'];

        if ($webhookSecret !== null) {
            $server['HTTP_X_RAZORPAY_SIGNATURE'] = hash_hmac('sha256', $payload, $webhookSecret);
        }

        return $this->call(
            'POST',
            $url,
            [],
            [],
            [],
            $server,
            $payload,
        );
    }
}
