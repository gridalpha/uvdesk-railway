<?php
/**
 * Prints one configured mailbox address per line.
 *
 * uvdesk_mailbox.yaml keys each mailbox by its email address, and
 * `uvdesk:refresh-mailbox` takes those addresses as arguments, so the poller
 * needs this list rather than a flag. Prints nothing when none are configured.
 */

$path = getenv('UVDESK_MAILBOX_CONFIG') ?: '/var/www/uvdesk/config/packages/uvdesk_mailbox.yaml';

if (!is_readable($path)) {
    exit(0);
}

$autoload = (getenv('UVDESK_HOME') ?: '/var/www/uvdesk') . '/vendor/autoload.php';

if (!is_readable($autoload)) {
    exit(0);
}

require $autoload;

try {
    $config = \Symfony\Component\Yaml\Yaml::parseFile($path);
} catch (Throwable $e) {
    fwrite(STDERR, 'unreadable mailbox configuration: ' . $e->getMessage() . "\n");
    exit(1);
}

$mailboxes = $config['uvdesk_mailbox']['mailboxes'] ?? null;

if (!is_array($mailboxes)) {
    exit(0);
}

foreach ($mailboxes as $email => $mailbox) {
    if (!is_string($email) || filter_var($email, FILTER_VALIDATE_EMAIL) === false) {
        continue;
    }
    if (is_array($mailbox) && array_key_exists('enabled', $mailbox) && !$mailbox['enabled']) {
        continue;
    }
    echo $email, "\n";
}
