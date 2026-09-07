<?php
/**
 * Shared DATABASE_URL -> PDO helper for the boot-time checks.
 * Never prints the connection string or the credentials it carries.
 */

function uvdesk_pdo(): PDO
{
    $url = getenv('DATABASE_URL');

    if ($url === false || $url === '') {
        throw new RuntimeException('DATABASE_URL is not set');
    }

    $parts = parse_url($url);

    if ($parts === false || empty($parts['host'])) {
        throw new RuntimeException('DATABASE_URL could not be parsed');
    }

    $dsn = sprintf(
        'mysql:host=%s;port=%d;dbname=%s;charset=utf8mb4',
        $parts['host'],
        isset($parts['port']) ? (int) $parts['port'] : 3306,
        ltrim($parts['path'] ?? '', '/')
    );

    return new PDO($dsn, rawurldecode($parts['user'] ?? ''), rawurldecode($parts['pass'] ?? ''), [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_TIMEOUT => 10,
    ]);
}
