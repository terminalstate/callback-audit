<?php

/**
 * Reproduction: a subscription paid with a delayed-settlement method is never completed.
 *
 * A billing portal purchase paid with Stripe SEPA (or BACS, ACH, BECS, ACSS, bank
 * transfer, GoCardless, ...) books the payment PENDING on return and applies it to
 * the invoice. SubscriptionService::completePurchase(), which creates the
 * RecurringInvoice, runs only inside BaseDriver::createPayment() and only when the
 * payment is created COMPLETED. When the debit settles, payment_intent.succeeded
 * finds the existing payment and only sets it COMPLETED, so no RecurringInvoice is
 * created and the subscription never bills again. A card purchase of the same plan
 * works, because the card payment is created COMPLETED.
 *
 * Nothing is faked: completing an existing payment makes no Stripe API call. The
 * webhook route verifies a real signature computed with the gateway's webhook
 * secret.
 */

namespace Tests\Feature\PaymentDrivers\Stripe;

use App\Factory\CompanyGatewayFactory;
use App\Models\CompanyGateway;
use App\Models\GatewayType;
use App\Models\Payment;
use App\Models\PaymentHash;
use App\Models\PaymentType;
use App\Models\Product;
use App\Models\RecurringInvoice;
use App\Models\Subscription;
use Illuminate\Foundation\Testing\DatabaseTransactions;
use Illuminate\Support\Str;
use PHPUnit\Framework\Attributes\Group;
use Tests\MockAccountData;
use Tests\TestCase;

class SubscriptionDelayedSettlementStandTest extends TestCase
{
    use DatabaseTransactions;
    use MockAccountData;

    private const WEBHOOK_SECRET = 'whsec_subscription_settlement_stand';

    private CompanyGateway $company_gateway;

    private Subscription $subscription;

    private Product $plan_product;

    protected function setUp(): void
    {
        parent::setUp();

        $this->makeTestData();

        $this->plan_product = Product::factory()->create([
            'company_id' => $this->company->id,
            'user_id' => $this->user->id,
            'product_key' => 'stand-recurring-plan',
            'notes' => 'Monthly plan',
            'price' => 10,
        ]);

        $this->subscription = Subscription::factory()->create([
            'company_id' => $this->company->id,
            'user_id' => $this->user->id,
            'recurring_product_ids' => $this->plan_product->hashed_id,
            // Empty configuration => triggerWebhook / post_purchase_url returns early.
            'webhook_configuration' => [],
        ]);

        $this->company_gateway = CompanyGatewayFactory::create($this->company->id, $this->user->id);
        $this->company_gateway->gateway_key = 'd14dd26a37cecc30fdd65700bfb55b23';
        $this->company_gateway->accepted_credit_cards = 0;
        $this->company_gateway->fees_and_limits = new \stdClass();
        $this->company_gateway->setConfig([
            'apiKey' => 'sk_test_subscription_settlement_stand',
            'publishableKey' => 'pk_test_subscription_settlement_stand',
            'webhookSecret' => self::WEBHOOK_SECRET,
        ]);
        $this->company_gateway->save();
    }

    /**
     * Current behaviour: a SEPA purchase is booked PENDING, then later settled by
     * payment_intent.succeeded. The payment ends COMPLETED, but no RecurringInvoice
     * is ever created for the subscription, so it never bills again.
     */
    public function test_pending_subscription_payment_never_completes_purchase_current_behaviour(): void
    {
        $payment_hash = $this->makeSubscriptionPaymentHash();

        $payment = $this->createStripePayment($payment_hash, 'pi_sepa_pending', Payment::STATUS_PENDING);

        // The pending payment applied, but the purchase did not complete.
        $this->assertSame(Payment::STATUS_PENDING, $payment->fresh()->status_id);
        $this->assertSame(
            0,
            RecurringInvoice::query()->where('subscription_id', $this->subscription->id)->count(),
            'a pending subscription payment must not have completed the purchase',
        );

        // Stripe settles it days later. The real route + inline job flips the row to COMPLETED.
        $response = $this->postStripeEvent('payment_intent.succeeded', [
            'id' => 'pi_sepa_pending',
            'object' => 'payment_intent',
            'latest_charge' => 'py_sepa_pending',
        ]);

        $response->assertStatus(200);
        $this->assertSame(Payment::STATUS_COMPLETED, $payment->fresh()->status_id, 'the webhook completed the payment');
        $this->assertSame(
            0,
            RecurringInvoice::query()->where('subscription_id', $this->subscription->id)->count(),
            'settlement completed the payment but still created no RecurringInvoice',
        );
    }

    /**
     * Control: the same subscription paid by a method created COMPLETED (as a card
     * purchase is) does create the RecurringInvoice today.
     */
    public function test_completed_subscription_payment_creates_recurring_invoice_control(): void
    {
        $payment_hash = $this->makeSubscriptionPaymentHash();

        $payment = $this->createStripePayment($payment_hash, 'pi_card_completed', Payment::STATUS_COMPLETED);

        $this->assertSame(Payment::STATUS_COMPLETED, $payment->fresh()->status_id);

        $recurring = RecurringInvoice::query()->where('subscription_id', $this->subscription->id)->get();

        $this->assertCount(1, $recurring, 'a completed subscription payment creates exactly one RecurringInvoice');
        $this->assertSame($this->subscription->id, $recurring->first()->subscription_id);
    }

    /**
     * If fixed: once the delayed payment settles (COMPLETED), the subscription
     * purchase should complete and a RecurringInvoice should exist. This fails at
     * 493c388 because the PENDING -> COMPLETED transition never runs completePurchase.
     */
    #[Group('if-fixed')]
    public function test_pending_then_settled_subscription_payment_completes_purchase_if_fixed(): void
    {
        $payment_hash = $this->makeSubscriptionPaymentHash();

        $this->createStripePayment($payment_hash, 'pi_sepa_fixed', Payment::STATUS_PENDING);

        $this->postStripeEvent('payment_intent.succeeded', [
            'id' => 'pi_sepa_fixed',
            'object' => 'payment_intent',
            'latest_charge' => 'py_sepa_fixed',
        ])->assertStatus(200);

        $this->assertSame(
            1,
            RecurringInvoice::query()->where('subscription_id', $this->subscription->id)->count(),
            'after a fix the settled subscription payment must create the RecurringInvoice',
        );
    }

    private function createStripePayment(PaymentHash $payment_hash, string $reference, int $status): Payment
    {
        $driver = $this->company_gateway->driver($this->client)->init()->setPaymentMethod(GatewayType::SEPA);
        $driver->setPaymentHash($payment_hash);

        return $driver->createPayment([
            'payment_method' => 'pm_' . $reference,
            'payment_type' => PaymentType::SEPA,
            'amount' => $payment_hash->amount_with_fee(),
            'transaction_reference' => $reference,
            'gateway_type_id' => GatewayType::SEPA,
        ], $status);
    }

    private function makeSubscriptionPaymentHash(): PaymentHash
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
                'billing_context' => [
                    'subscription_id' => $this->subscription->hashed_id,
                    'context' => 'purchase',
                    'client_id' => $this->client->hashed_id,
                    'invoice_id' => $this->invoice->hashed_id,
                ],
            ],
        ]);
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
