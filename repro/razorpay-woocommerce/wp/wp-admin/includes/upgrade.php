<?php
// Stub for WordPress's wp-admin/includes/upgrade.php. The harness creates the plugin's table itself
// (setup.php), with the plugin's own column list.
if (!function_exists('dbDelta')) {
    function dbDelta($queries = '', $execute = true)
    {
        return [];
    }
}
