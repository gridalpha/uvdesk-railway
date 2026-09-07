<?php
/**
 * Anonymous liveness probe for Railway.
 *
 * Opens the same database the helpdesk is configured with and runs one query,
 * so a container that has lost MySQL fails the check instead of reporting
 * healthy while every page 500s. No credentials or connection details are ever
 * echoed back.
 */

header('Content-Type: text/plain; charset=utf-8');
header('Cache-Control: no-store');

$url = getenv('DATABASE_URL');

if ($url === false || $url === '') {
    http_response_code(503);
    echo "unconfigured\n";
    exit;
}

$parts = parse_url($url);

if ($parts === false || empty($parts['host'])) {
    http_response_code(503);
    echo "unconfigured\n";
    exit;
}

$dsn = sprintf(
    'mysql:host=%s;port=%d;dbname=%s;charset=utf8mb4',
    $parts['host'],
    isset($parts['port']) ? (int) $parts['port'] : 3306,
    ltrim($parts['path'] ?? '', '/')
);

try {
    $pdo = new PDO($dsn, rawurldecode($parts['user'] ?? ''), rawurldecode($parts['pass'] ?? ''), [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_TIMEOUT => 5,
    ]);
    $pdo->query('SELECT 1');
} catch (Throwable $e) {
    http_response_code(503);
    echo "database unavailable\n";
    exit;
}

echo "ok\n";
