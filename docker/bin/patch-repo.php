<?php
/**
 * Build-time patches against the upstream community-skeleton checkout.
 *
 * Every patch asserts its own anchor: if upstream moves the line, the build
 * fails here instead of producing a container that silently lost the fix.
 */

$home = getenv('UVDESK_HOME') ?: '/var/www/uvdesk';

function edit(string $path, callable $fn): void
{
    if (!is_file($path)) {
        fwrite(STDERR, "patch target missing: $path\n");
        exit(1);
    }

    $before = file_get_contents($path);
    $after  = $fn($before, $path);

    if ($after === $before) {
        fwrite(STDERR, "patch made no change: $path\n");
        exit(1);
    }

    file_put_contents($path, $after);
    echo "patched $path\n";
}

// 1. DoctrineFixturesBundle ships registered for dev+test only, but the
//    helpdesk's own installer loads fixtures to create its support roles,
//    websites and email templates. Without it a prod install leaves an empty
//    schema and every page 500s.
edit($home . '/config/bundles.php', function (string $s, string $p): string {
    $needle = "Doctrine\\Bundle\\FixturesBundle\\DoctrineFixturesBundle::class => ['dev' => true, 'test' => true],";
    if (strpos($s, $needle) === false) {
        fwrite(STDERR, "DoctrineFixturesBundle registration not found in $p\n");
        exit(1);
    }
    return str_replace($needle, "Doctrine\\Bundle\\FixturesBundle\\DoctrineFixturesBundle::class => ['all' => true],", $s);
});

// 2. The Doctrine server version is hardcoded to 5.7. Make it a variable so a
//    deployer on a different MySQL/MariaDB can move it without a rebuild.
edit($home . '/config/packages/doctrine.yaml', function (string $s, string $p): string {
    $needle = "        server_version: '5.7'";
    if (strpos($s, $needle) === false) {
        fwrite(STDERR, "server_version not found in $p\n");
        exit(1);
    }
    return str_replace($needle, "        server_version: '%env(UVDESK_DB_SERVER_VERSION)%'", $s);
});


// 3. The skeleton's ExceptionSubscriber renders its own 500 page and calls
//    setResponse(), which stops event propagation before Symfony's own
//    ErrorListener gets to log the exception - so on a stock install every 500
//    is invisible in `railway logs`. Log it to stderr on the way past.
edit($home . '/src/EventListener/ExceptionSubscriber.php', function (string $s, string $p): string {
    $needle = "\t\t\t} else {\n\t\t\t\t\$template = \$this->twig->render('errors/error.html.twig', [\n\t\t\t\t\t'message'     => 'Internal Server Error',";
    if (strpos($s, $needle) === false) {
        fwrite(STDERR, "the 500 branch was not found in $p\n");
        exit(1);
    }
    $logger = "\t\t\t} else {\n"
        . "\t\t\t\terror_log(sprintf('[uvdesk] %s: %s at %s:%d', get_class(\$exception), \$exception->getMessage(), \$exception->getFile(), \$exception->getLine()));\n"
        . "\t\t\t\t\$template = \$this->twig->render('errors/error.html.twig', [\n"
        . "\t\t\t\t\t'message'     => 'Internal Server Error',";
    return str_replace($needle, $logger, $s);
});

echo "repo patches applied\n";
