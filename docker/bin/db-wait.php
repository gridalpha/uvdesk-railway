<?php
/** Exits 0 once DATABASE_URL points at a MySQL server that answers SELECT 1. */
require __DIR__ . '/dsn.php';

try {
    $pdo = uvdesk_pdo();
    $pdo->query('SELECT 1');
} catch (Throwable $e) {
    fwrite(STDERR, 'database not ready: ' . $e->getMessage() . "\n");
    exit(1);
}

exit(0);
