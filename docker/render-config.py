#!/usr/bin/env python3
"""Render the Odoo configuration template from environment variables (prod image).

Placeholders: ${VAR} is required, ${VAR:-default} falls back to "default" when VAR is
unset or empty. Fails, listing every missing variable, instead of starting Odoo with an
incomplete configuration.

Usage: render-config.py TEMPLATE OUTPUT
"""

import os
import re
import sys

PLACEHOLDER = re.compile(r"\$\{([A-Z0-9_]+)(?::-([^}]*))?\}")


def render(text, env):
    missing, invalid = set(), set()

    def substitute(match):
        name, default = match.group(1), match.group(2)
        value = env.get(name)
        if value:
            # A line break would let a value inject other options
            if "\n" in value or "\r" in value:
                invalid.add(name)
            return value
        if default is not None:
            return default
        missing.add(name)
        return ""

    return PLACEHOLDER.sub(substitute, text), sorted(missing), sorted(invalid)


def main(argv):
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    template, output = argv[1], argv[2]
    with open(template, encoding="utf-8") as f:
        content, missing, invalid = render(f.read(), os.environ)
    if missing or invalid:
        if missing:
            print(
                "render-config: missing required environment variable(s): "
                + ", ".join(missing),
                file=sys.stderr,
            )
        if invalid:
            print(
                "render-config: line break not allowed in: " + ", ".join(invalid),
                file=sys.stderr,
            )
        return 1
    # The rendered file holds secrets (admin_passwd, smtp_password): owner only
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(content)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
