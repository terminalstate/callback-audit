<?php

/**
 * Reproduction: a Stripe redirect payment whose customer never comes back is never recorded.
 *
 * Stripe redirect methods (iDEAL, Bancontact, EPS, giropay, Przelewy24, Klarna,
 * FPX, Alipay, SOFORT): when the customer authorises in the banking app but the
 * browser never returns to the return URL, Stripe still captures the funds and
 * sends `payment_intent.succeeded`. The webhook job PaymentIntentWebhook only has
 * branches for the ASYNC_PAYMENT_TYPES debit methods, `card` and `promptpay`, so
 * a PaymentIntent created with payment_method_types => ['ideal'] (etc.) matches no
 * branch and no Payment row is ever written. Stripe holds the money while the
 * invoice stays unpaid.
 *
 * Only the Stripe HTTP API is faked, through the project's own
 * ApiRequestor::setHttpClient(...) seam. The webhook route, its signature
 * verification and all application logic run unmodified.
 */

namespace Tests\Feature\PaymentDrivers\Stripe;

use App\Factory\CompanyGatewayFactory;
use App\Models\CompanyGateway;
use App\Models\GatewayType;
use App\Models\Payment;
use App\Models\PaymentHash;
use App\Models\PaymentType;
use App\Models\SystemLog;
use App\PaymentDrivers\Stripe\Jobs\PaymentIntentWebhook;
use Illuminate\Foundation\Testing\DatabaseTransactions;
use Illuminate\Support\Str;
use PHPUnit\Framework\Attributes\Group;
use Stripe\ApiRequestor;
use Stripe\HttpClient\ClientInterface;
use Tests\MockAccountData;
use Tests\TestCase;

class StripeRedirectMethodWebhookStandTest extends TestCase
{
    use DatabaseTransactions;
    use MockAccountData;

    private const WEBHOOK_SECRET = 'whsec_redirect_method_stand';

    private CompanyGateway $company_gateway;

    /** @var array<int, string> Stripe API requests seen by the fake, as "METHOD path". */
    public static array $stripeCalls = [];

    protected function setUp(): void
    {
        parent::setUp();

        $this->makeTestData();

        // Stripe gateway with a webhook secret so the real route verifies a real signature.
        $this->company_gateway = CompanyGatewayFactory::create($this->company->id, $this->user->id);
        $this->company_gateway->gateway_key = 'd14dd26a37cecc30fdd65700bfb55b23';
        $this->company_gateway->accepted_credit_cards = 0;
        $this->company_gateway->fees_and_limits = new \stdClass();
        $this->company_gateway->setConfig([
            'apiKey' => 'sk_test_redirect_method_stand',
            'publishableKey' => 'pk_test_redirect_method_stand',
            'webhookSecret' => self::WEBHOOK_SECRET,
        ]);
        $this->company_gateway->save();
    }

    protected function tearDown(): void
    {
        ApiRequestor::setHttpClient(null);

        parent::tearDown();
    }

    /**
     * Current behaviour: an iDEAL payment_intent.succeeded whose browser callback
     * was never fired creates no Payment and leaves the invoice balance untouched.
     * Driven through the job directly (the route is exercised separately below).
     */
    public function test_ideal_webhook_creates_no_payment_current_behaviour(): void
    {
        $payment_hash = $this->makePaymentHash();
        $balance_before = (float) $this->invoice->fresh()->balance;

        $this->fakeStripe(
            $this->paymentIntentPayload('pi_ideal_test', 'py_ideal_test', ['ideal'], $payment_hash->hash, (string) GatewayType::IDEAL),
            $this->chargePayload('py_ideal_test'),
        );

        (new PaymentIntentWebhook(
            ['object' => ['id' => 'pi_ideal_test', 'object' => 'payment_intent', 'latest_charge' => 'py_ideal_test']],
            $this->company->company_key,
            $this->company_gateway->id,
        ))->handle();

        $this->assertFalse(
            Payment::query()->where('transaction_reference', 'pi_ideal_test')->exists(),
            'the webhook recorded no payment for the iDEAL PaymentIntent',
        );
        $this->assertEqualsWithDelta($balance_before, (float) $this->invoice->fresh()->balance, 0.001);
    }

    /**
     * Same current behaviour, but posted to the real webhook route
     * /payment_webhook/{company_key}/{company_gateway_hashed_id} with a genuine
     * Stripe signature computed with the gateway's webhook secret. The route
     * answers 200 and still no payment is recorded.
     */
    public function test_ideal_webhook_via_route_creates_no_payment_current_behaviour(): void
    {
        $payment_hash = $this->makePaymentHash();
        $balance_before = (float) $this->invoice->fresh()->balance;

        $this->fakeStripe(
            $this->paymentIntentPayload('pi_ideal_route', 'py_ideal_route', ['ideal'], $payment_hash->hash, (string) GatewayType::IDEAL),
            $this->chargePayload('py_ideal_route'),
        );

        $response = $this->postStripeEvent('payment_intent.succeeded', [
            'id' => 'pi_ideal_route',
            'object' => 'payment_intent',
            'latest_charge' => 'py_ideal_route',
        ]);

        $response->assertStatus(200);

        // The job did run (QUEUE_CONNECTION=sync in phpunit.xml): it fetched the PaymentIntent and the charge
        // from Stripe and logged a gateway success for the company ...
        $this->assertContains('GET /v1/payment_intents/pi_ideal_route', self::$stripeCalls);
        $this->assertContains('GET /v1/charges/py_ideal_route', self::$stripeCalls);
        $this->assertTrue(
            SystemLog::query()
                ->where('company_id', $this->company->id)
                ->where('category_id', SystemLog::CATEGORY_GATEWAY_RESPONSE)
                ->where('event_id', SystemLog::EVENT_GATEWAY_SUCCESS)
                ->where('type_id', SystemLog::TYPE_STRIPE)
                ->exists(),
            'the webhook job logged a Stripe gateway success',
        );
        // ... and still recorded no payment.
        $this->assertFalse(
            Payment::query()->where('transaction_reference', 'pi_ideal_route')->exists(),
            'the webhook route recorded no payment for the iDEAL PaymentIntent',
        );
        $this->assertEqualsWithDelta($balance_before, (float) $this->invoice->fresh()->balance, 0.001);
    }

    /**
     * Control: an async debit type (SEPA) is one of the branches the job handles,
     * so the identical "browser missed" path does record a COMPLETED payment today.
     * This proves the webhook machinery works; only the redirect methods are missing.
     */
    public function test_sepa_webhook_creates_completed_payment_control(): void
    {
        $payment_hash = $this->makePaymentHash();

        $this->fakeStripe(
            $this->paymentIntentPayload('pi_sepa_ctrl', 'py_sepa_ctrl', ['sepa_debit'], $payment_hash->hash, (string) GatewayType::SEPA),
            $this->chargePayload('py_sepa_ctrl'),
        );

        (new PaymentIntentWebhook(
            ['object' => ['id' => 'pi_sepa_ctrl', 'object' => 'payment_intent', 'latest_charge' => 'py_sepa_ctrl']],
            $this->company->company_key,
            $this->company_gateway->id,
        ))->handle();

        $payment = Payment::query()->where('transaction_reference', 'pi_sepa_ctrl')->first();

        $this->assertNotNull($payment, 'the webhook recorded the SEPA payment');
        $this->assertSame(Payment::STATUS_COMPLETED, $payment->status_id);
        $this->assertSame(PaymentType::SEPA, $payment->type_id);
    }

    /**
     * If fixed: the iDEAL payment_intent.succeeded (no browser callback) should
     * record a COMPLETED payment, exactly as the SEPA control does. This fails at
     * 493c388 because PaymentIntentWebhook has no redirect-method branch. Excluded from
     * the default run (group if-fixed); run.sh runs it separately and expects it to fail.
     */
    #[Group('if-fixed')]
    public function test_ideal_webhook_creates_completed_payment_if_fixed(): void
    {
        $payment_hash = $this->makePaymentHash();

        $this->fakeStripe(
            $this->paymentIntentPayload('pi_ideal_fixed', 'py_ideal_fixed', ['ideal'], $payment_hash->hash, (string) GatewayType::IDEAL),
            $this->chargePayload('py_ideal_fixed'),
        );

        (new PaymentIntentWebhook(
            ['object' => ['id' => 'pi_ideal_fixed', 'object' => 'payment_intent', 'latest_charge' => 'py_ideal_fixed']],
            $this->company->company_key,
            $this->company_gateway->id,
        ))->handle();

        $payment = Payment::query()->where('transaction_reference', 'pi_ideal_fixed')->first();

        $this->assertNotNull($payment, 'after a fix the iDEAL PaymentIntent must be recorded');
        $this->assertSame(Payment::STATUS_COMPLETED, $payment->status_id);
    }

    private function makePaymentHash(): PaymentHash
    {
        return PaymentHash::query()->create([
            'company_id' => $this->company->id,
            'hash' => Str::random(32),
            'fee_invoice_id' => $this->invoice->id,
            'fee_total' => 0,
            'data' => [
                'amount_with_fee' => 1,
                'credits' => 0,
                'invoices' => [[
                    'invoice_id' => $this->invoice->hashed_id,
                    'invoice_number' => $this->invoice->number,
                    'amount' => 1,
                ]],
            ],
        ]);
    }

    /**
     * @param  array<int, string>  $paymentMethodTypes
     * @return array<string, mixed>
     */
    private function paymentIntentPayload(string $id, string $chargeId, array $paymentMethodTypes, string $hash, string $gatewayTypeId): array
    {
        return [
            'id' => $id,
            'object' => 'payment_intent',
            'status' => 'succeeded',
            'amount' => 100,
            'currency' => 'eur',
            'latest_charge' => $chargeId,
            'payment_method' => 'pm_' . $id,
            'payment_method_types' => $paymentMethodTypes,
            'metadata' => [
                'payment_hash' => $hash,
                'gateway_type_id' => $gatewayTypeId,
            ],
        ];
    }

    /**
     * @return array<string, mixed>
     */
    private function chargePayload(string $id): array
    {
        return [
            'id' => $id,
            'object' => 'charge',
            'customer' => 'cus_redirect_stand',
            'payment_method' => 'pm_redirect_stand',
            'payment_method_details' => ['type' => 'ideal'],
        ];
    }

    /**
     * Fake only the Stripe HTTP API: answer GET /v1/payment_intents/{id} and
     * GET /v1/charges/{id} with the given payloads. Nothing else is stubbed.
     *
     * @param  array<string, mixed>  $paymentIntent
     * @param  array<string, mixed>  $charge
     */
    private function fakeStripe(array $paymentIntent, array $charge): void
    {
        self::$stripeCalls = [];
        ApiRequestor::setHttpClient(new class ($paymentIntent, $charge) implements ClientInterface {
            /**
             * @param array<string, mixed> $paymentIntent
             * @param array<string, mixed> $charge
             */
            public function __construct(private array $paymentIntent, private array $charge)
            {
            }

            public function request($method, $absUrl, $headers, $params, $hasFile, $apiMode = 'v1', $maxNetworkRetries = null): array
            {
                StripeRedirectMethodWebhookStandTest::$stripeCalls[] = strtoupper($method) . ' ' . parse_url($absUrl, PHP_URL_PATH);

                if (str_contains($absUrl, '/v1/payment_intents/')) {
                    $response = $this->paymentIntent;
                } elseif (str_contains($absUrl, '/v1/charges/')) {
                    $response = $this->charge;
                } else {
                    $response = ['id' => 'unexpected', 'object' => 'object'];
                }

                return [json_encode($response, JSON_THROW_ON_ERROR), 200, []];
            }
        });
    }

    /**
     * POST a signed Stripe event to the real webhook route, signing the raw body
     * with the gateway's webhook secret exactly as \Stripe\Webhook::constructEvent
     * verifies it.
     *
     * @param  array<string, mixed>  $object
     */
    private function postStripeEvent(string $type, array $object): \Illuminate\Testing\TestResponse
    {
        $payload = json_encode([
            'id' => 'evt_' . Str::lower(Str::random(16)),
            'object' => 'event',
            'type' => $type,
            'data' => ['object' => $object],
        ], JSON_THROW_ON_ERROR);

        $timestamp = time();
        $signature = hash_hmac('sha256', "{$timestamp}.{$payload}", self::WEBHOOK_SECRET);

        $url = sprintf('/payment_webhook/%s/%s', $this->company->company_key, $this->company_gateway->hashed_id);

        return $this->call(
            'POST',
            $url,
            [],
            [],
            [],
            [
                'CONTENT_TYPE' => 'application/json',
                'HTTP_STRIPE_SIGNATURE' => "t={$timestamp},v1={$signature}",
            ],
            $payload,
        );
    }
}
