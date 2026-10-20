<?php
/**
 * "Charge when order is placed" + Immediate authorization: a capture that Amazon Pay declines is still invoiced as paid,
 * and the later Declined notification is dropped as a duplicate.
 *
 * Real code under test: Model\CheckoutSessionManagement::handlePayment(), Model\Adapter\AmazonPayAdapter (response handling),
 * Model\AsyncManagement\Charge::processStateChange().
 * Faked: the Amazon Pay API client (SDK-shaped responses: ['status' => …, 'response' => json]) and Magento repositories.
 */
declare(strict_types=1);

namespace Amazon\Pay\Test\Unit\Model;

use Amazon\Pay\API\ClientInterface;
use Amazon\Pay\Client\ClientFactoryInterface;
use Amazon\Pay\Model\Adapter\AmazonPayAdapter;
use Amazon\Pay\Model\AmazonConfig;
use Amazon\Pay\Model\AsyncManagement\Charge;
use Amazon\Pay\Model\CheckoutSessionManagement;
use Amazon\Pay\Model\Config\Source\AuthorizationMode;
use Amazon\Pay\Model\Config\Source\PaymentAction;
use Magento\Framework\Api\SearchCriteria;
use Magento\Framework\Api\SearchCriteriaBuilder;
use Magento\Framework\TestFramework\Unit\Helper\ObjectManager;
use Magento\Quote\Model\Quote;
use Magento\Sales\Api\Data\InvoiceSearchResultInterface;
use Magento\Sales\Api\InvoiceRepositoryInterface;
use Magento\Sales\Api\OrderRepositoryInterface;
use Magento\Sales\Api\TransactionRepositoryInterface;
use Magento\Sales\Model\Order;
use Magento\Sales\Model\Order\Config as OrderConfig;
use Magento\Sales\Model\Order\Invoice;
use Magento\Sales\Model\Order\Payment;
use Magento\Sales\Model\Order\Payment\Transaction;
use Magento\Sales\Model\ResourceModel\Order\Invoice\Collection as InvoiceCollection;
use Magento\Sales\Model\ResourceModel\Order\Payment\Transaction\Collection as TransactionCollection;
use PHPUnit\Framework\Attributes\AllowMockObjectsWithoutExpectations;
use PHPUnit\Framework\TestCase;

#[AllowMockObjectsWithoutExpectations]
class DeclinedCaptureTest extends TestCase
{
    private const CHARGE_ID = 'S01-0000000-0000000-C000001';
    private const CHARGE_PERMISSION_ID = 'S01-0000000-0000000';

    private ObjectManager $om;
    /** @var array<string, array> API calls made through the real adapter */
    private array $apiCalls = [];

    protected function setUp(): void
    {
        $this->om = new ObjectManager($this);
    }

    private function config(): AmazonConfig
    {
        $config = $this->createStub(AmazonConfig::class);
        $config->method('getPaymentAction')->willReturn(PaymentAction::AUTHORIZE_AND_CAPTURE); // "Charge when order is placed"
        $config->method('getAuthorizationMode')->willReturn(AuthorizationMode::SYNC);          // "Immediate"
        $config->method('isVaultEnabled')->willReturn(false);
        return $config;
    }

    /** Real adapter over a fake HTTP client. */
    private function adapter(AmazonConfig $config, bool $declined = true): AmazonPayAdapter
    {
        $json = fn (array $body, int $status = 200) => ['status' => $status, 'response' => json_encode($body)];
        $declinedCharge = [
            'chargeId' => self::CHARGE_ID,
            'chargePermissionId' => self::CHARGE_PERMISSION_ID,
            'statusDetails' => $declined ? ['state' => 'Declined', 'reasonCode' => 'AmazonRejected'] : ['state' => 'Captured'],
        ];
        $client = $this->createStub(ClientInterface::class);
        $client->method('captureCharge')->willReturnCallback(function () use ($json, $declined) {
            $this->apiCalls['captureCharge'][] = func_get_args();
            if (!$declined) {
                return $json(['chargeId' => self::CHARGE_ID, 'statusDetails' => ['state' => 'Captured']]);
            }
            // https://developer.amazon.com/docs/amazon-pay-api-v2/charge.html — Capture Charge, 422 AmazonRejected
            return $json(['reasonCode' => 'AmazonRejected',
                'message' => 'Charge was declined by Amazon. The associated Charge Permission will also be canceled.'], 422);
        });
        $client->method('getCharge')->willReturnCallback(function () use ($json, $declinedCharge) {
            $this->apiCalls['getCharge'][] = func_get_args();
            return $json($declinedCharge);
        });
        $client->method('updateChargePermission')->willReturnCallback(fn () => $json(['chargePermissionId' => self::CHARGE_PERMISSION_ID]));
        $client->method('closeChargePermission')->willReturnCallback(fn () => $json(['chargePermissionId' => self::CHARGE_PERMISSION_ID]));
        $client->method('getCheckoutSession')->willReturnCallback(fn () => $json(['checkoutSessionId' => 'session-1',
            'chargePermissionId' => self::CHARGE_PERMISSION_ID,
            'statusDetails' => ['state' => 'Completed', 'reasonCode' => 'Declined']]));
        $factory = $this->createStub(ClientFactoryInterface::class);
        $factory->method('create')->willReturn($client);

        return $this->om->getObject(AmazonPayAdapter::class, ['clientFactory' => $factory, 'amazonConfig' => $config]);
    }

    private function searchCriteriaBuilder(): SearchCriteriaBuilder
    {
        $builder = $this->createStub(SearchCriteriaBuilder::class);
        $builder->method('addFilter')->willReturnSelf();
        $builder->method('create')->willReturn($this->createStub(SearchCriteria::class));
        return $builder;
    }

    private function transactionRepository(): TransactionRepositoryInterface
    {
        $transaction = $this->createStub(Transaction::class);
        $transaction->method('getOrderId')->willReturn(42);
        $collection = $this->createStub(TransactionCollection::class);
        $collection->method('count')->willReturn(1);
        $collection->method('getFirstItem')->willReturn($transaction);
        $repository = $this->createStub(TransactionRepositoryInterface::class);
        $repository->method('getList')->willReturn($collection);
        return $repository;
    }

    /** @return array{0: array, 1: array, 2: array} [result, invoiced, states] */
    private function placeWithCapture(bool $declined): array
    {
        $config = $this->config();

        $order = $this->createStub(Order::class);
        $payment = $this->createStub(Payment::class);
        $payment->method('getOrder')->willReturn($order);
        $order->method('getPayment')->willReturn($payment);
        $order->method('getStoreId')->willReturn(1);
        $order->method('getGrandTotal')->willReturn(100.0);
        $order->method('getOrderCurrencyCode')->willReturn('EUR');
        $order->method('getIncrementId')->willReturn('000000042');
        $invoices = $this->createStub(InvoiceCollection::class);
        $invoices->method('getItems')->willReturn([]);
        $invoices->method('getIterator')->willReturn(new \ArrayIterator([]));
        $order->method('getInvoiceCollection')->willReturn($invoices);
        $order->method('getAllItems')->willReturn([]);
        $orderConfig = $this->createStub(OrderConfig::class);
        $orderConfig->method('getStateDefaultStatus')->willReturn('processing');
        $order->method('getConfig')->willReturn($orderConfig);
        $states = [];
        $order->method('setState')->willReturnCallback(function ($state) use (&$states, $order) {
            $states[] = $state;
            return $order;
        });
        $order->method('setStatus')->willReturn($order);

        // Magento side of the capture: Charge::capture() invoices the order and calls Invoice::pay()
        $invoiced = [];
        $asyncCharge = $this->createStub(Charge::class);
        $asyncCharge->method('capture')->willReturnCallback(function ($order, $chargeId, $amount) use (&$invoiced) {
            $invoiced[] = [$chargeId, $amount];
        });

        $management = $this->om->getObject(CheckoutSessionManagement::class, [
            'amazonConfig' => $config,
            'amazonAdapter' => $this->adapter($config, $declined),
            'asyncCharge' => $asyncCharge,
            'transactionRepository' => $this->transactionRepository(),
            'searchCriteriaBuilder' => $this->searchCriteriaBuilder(),
        ]);

        $handlePayment = new \ReflectionMethod($management, 'handlePayment');
        $result = $handlePayment->invoke(
            $management,
            'session-1',
            ['success' => true, 'amazonCompleteCheckoutResult' => [
                'status' => 200, // Immediate: CompleteCheckoutSession answered 200, the charge is Authorized
                'checkoutSessionId' => 'session-1',
                'chargeId' => self::CHARGE_ID,
                'chargePermissionId' => self::CHARGE_PERMISSION_ID,
            ]],
            $order,
            $this->createStub(Quote::class)
        );

        return [$result, $invoiced, $states];
    }

    public function testDeclinedCaptureIsNotInvoicedAsPaid(): void
    {
        [$result, $invoiced, $states] = $this->placeWithCapture(true);
        $this->assertCount(1, $this->apiCalls['captureCharge'] ?? [], 'the capture was requested');
        $this->assertSame([], $invoiced, 'Amazon answered 422 AmazonRejected and the charge is Declined, but the order was invoiced as paid');
        $this->assertFalse($result['success'], 'checkout reported success for a declined charge');
        $this->assertSame(Order::STATE_CANCELED, end($states));
    }

    public function testSuccessfulCaptureIsInvoiced(): void
    {
        [$result, $invoiced] = $this->placeWithCapture(false);
        $this->assertSame([[self::CHARGE_ID, 100.0]], $invoiced);
        $this->assertTrue($result['success']);
    }

    /**
     * Characterization (passes before and after the fix): once the order carries a PAID invoice for the charge, the later
     * Declined notification returns early as a duplicate, without fetching the charge — so nothing corrects the order later.
     */
    public function testLaterDeclinedNotificationIsDroppedOnceInvoiced(): void
    {
        $config = $this->config();
        $order = $this->createStub(Order::class);
        $order->method('getEntityId')->willReturn(42);
        $order->method('getStoreId')->willReturn(1);
        $order->method('getIncrementId')->willReturn('000000042');
        $orderRepository = $this->createStub(OrderRepositoryInterface::class);
        $orderRepository->method('get')->willReturn($order);

        // the invoice created at checkout for this charge (state PAID)
        $invoice = $this->createStub(Invoice::class);
        $invoice->method('getState')->willReturn(Invoice::STATE_PAID);
        $result = $this->createStub(InvoiceSearchResultInterface::class);
        $result->method('getItems')->willReturn([7 => $invoice]);
        $invoiceRepository = $this->createStub(InvoiceRepositoryInterface::class);
        $invoiceRepository->method('getList')->willReturn($result);

        $charge = $this->om->getObject(Charge::class, [
            'amazonAdapter' => $this->adapter($config),
            'amazonConfig' => $config,
            'orderRepository' => $orderRepository,
            'transactionRepository' => $this->transactionRepository(),
            'searchCriteriaBuilder' => $this->searchCriteriaBuilder(),
            'invoiceRepository' => $invoiceRepository,
        ]);

        // CHARGE notification for the Declined charge → IPN controller → processStateChange()
        $charge->processStateChange(self::CHARGE_ID);

        $this->assertSame([], $this->apiCalls['getCharge'] ?? [], 'dropped as "Duplicate IPN received after capture"');
    }
}
