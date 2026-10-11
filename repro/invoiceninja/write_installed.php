<?php
// Regenerates vendor/composer/installed.json, installed.php and InstalledVersions.php from the package list in
// vendor/composer/installed.json, the way `composer install` would after downloading.
require 'phar://' . __DIR__ . '/composer.phar/vendor/autoload.php';
$io = new Composer\IO\NullIO();
$composer = Composer\Factory::create($io, null, true);
$repo = $composer->getRepositoryManager()->getLocalRepository();
echo count($repo->getPackages()), " packages in the local repository\n";
$repo->write(true, $composer->getInstallationManager());
echo "written\n";
