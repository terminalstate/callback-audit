<?php
declare(strict_types=1);

namespace Paynl\Payment\Test\Unit\Controller\Checkout;

use Magento\Framework\App\Action\Context;
use Magento\Framework\App\Request\Http;
use Magento\Framework\Controller\Result\Raw;
use Magento\Sales\Model\Order;
use Magento\Sales\Model\OrderRepository;
use Magento\Store\Model\Store;
use Paynl\Payment\Controller\Checkout\Exchange;
use Paynl\Payment\Helper\PayHelper;
use Paynl\Payment\Model\Config;
use Paynl\Payment\Model\CreateFastCheckoutOrder;
use Paynl\Payment\Model\PayPayment;
use Paynl\Payment\Model\PayProcessingRepository;
use PayNL\Sdk\Config\Config as PayConfig;
use PHPUnit\Framework\TestCase;

/**
 * An unsigned exchange call (the default) makes the module fetch the transaction status from Pay. When that request fails,
 * the answer must not start with TRUE: Pay. retries an exchange only when the answer does not begin with TRUE.
 */
class ExchangeApiFailureTest extends TestCase
{
    private ?string $contents = null;

    protected function tearDown(): void
    {
        putenv('HTTPS_PROXY');
    }

    public function testExchangeIsNotAcknowledgedWhenTheStatusRequestToPayFails(): void
    {
        // Every HTTPS request from this process goes to a closed local port: the status request fails with a connection error,
        // as it does when the Pay. API cannot be reached.
        putenv('HTTPS_PROXY=http://127.0.0.1:9');

        $this->exchange()->execute();

        $this->assertStringStartsWith('FALSE', (string) $this->contents);
    }

    private function exchange(): Exchange
    {
        $request = $this->createMock(Http::class);
        $request->method('isPost')->willReturn(true);
        $request->method('getParams')->willReturn([
            'action' => 'new_ppt',
            'order_id' => '2312345678X1a2b3',
            'payment_profile_id' => '10',
            'extra3' => '1001',
        ]);
        $context = $this->createMock(Context::class);
        $context->method('getRequest')->willReturn($request);

        $order = $this->createMock(Order::class);
        $order->method('getStore')->willReturn($this->createMock(Store::class));
        $orders = $this->createMock(OrderRepository::class);
        $orders->method('get')->willReturn($order);

        $payConfig = new PayConfig();
        $payConfig->setUsername('AT-1234-5678');
        $payConfig->setPassword('stand-api-token');
        $config = $this->createMock(Config::class);
        $config->method('getPayConfig')->willReturn($payConfig);

        $result = $this->createMock(Raw::class);
        $result->method('setContents')->willReturnCallback(function ($contents) use ($result) {
            $this->contents = $contents;
            return $result;
        });

        return new Exchange(
            $context,
            $config,
            $result,
            $orders,
            $this->createMock(PayPayment::class),
            $this->createMock(CreateFastCheckoutOrder::class),
            $this->createMock(PayHelper::class),
            $this->createMock(PayProcessingRepository::class)
        );
    }
}
