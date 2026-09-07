<?php
/**
 * Fail-closed installation check.
 *
 * A UVdesk instance with no privileged account serves its installation wizard
 * to anonymous visitors, and whoever reaches it first becomes the owner. The
 * entrypoint refuses to start Apache unless this exits 0.
 */
require __DIR__ . '/dsn.php';

try {
    $pdo = uvdesk_pdo();

    $count = (int) $pdo->query(
        "SELECT COUNT(*)
           FROM uv_user_instance ui
           JOIN uv_support_role sr ON sr.id = ui.supportRole_id
          WHERE sr.code IN ('ROLE_SUPER_ADMIN', 'ROLE_ADMIN')"
    )->fetchColumn();
} catch (Throwable $e) {
    fwrite(STDERR, 'installation check failed: ' . $e->getMessage() . "\n");
    exit(1);
}

if ($count < 1) {
    fwrite(STDERR, "no account with ROLE_SUPER_ADMIN or ROLE_ADMIN exists\n");
    exit(1);
}

exit(0);
