<?php
// Minimal stand-in for Magento's dev/tests/unit/framework/bootstrap.php: composer autoload + on-the-fly
// generation of Factory / ExtensionAttributes classes, as Magento's own unit-test framework does.
declare(strict_types=1);

$root = getenv('AMZ_PLUGIN_ROOT');
require $root . '/vendor/autoload.php';

use Magento\Framework\Code\Generator\Io;
use Magento\Framework\Filesystem\Driver\File;
use Magento\Framework\TestFramework\Unit\Autoloader\ExtensionAttributesGenerator;
use Magento\Framework\TestFramework\Unit\Autoloader\ExtensionAttributesInterfaceGenerator;
use Magento\Framework\TestFramework\Unit\Autoloader\FactoryGenerator;
use Magento\Framework\TestFramework\Unit\Autoloader\GeneratedClassesAutoloader;

$io = new Io(new File(), __DIR__ . '/tmp/generated');
spl_autoload_register([new GeneratedClassesAutoloader(
    [new ExtensionAttributesGenerator(), new ExtensionAttributesInterfaceGenerator(), new FactoryGenerator()],
    $io
), 'load']);
date_default_timezone_set('UTC');
