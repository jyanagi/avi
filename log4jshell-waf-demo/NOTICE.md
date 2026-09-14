# Third-Party Notices

This project bundles or references the following third-party components. Each
retains its own license.

## Metropolis typeface
- Author: Chris Simpson
- License: The Unlicense (public domain dedication)
- Packaged via Fontsource (https://fontsource.org/fonts/metropolis)
- Bundled files: `control-plane/fonts/Metropolis-400.woff2`,
  `Metropolis-500.woff2`, `Metropolis-600.woff2`, `Metropolis-700.woff2`
- The console serves these locally over `/fonts/*.woff2`.

## Vulnerable demo application (referenced, not redistributed)
- `ghcr.io/christophetd/log4shell-vulnerable-app`
- Author: Christophe Tafani-Dereeper
- Pulled at install time by `install/install-vuln-node.sh`. This repository does
  not redistribute the image or its source; it only references the public image.

## Log4Shell
- CVE-2021-44228, a remote-code-execution vulnerability in Apache Log4j 2.
- This project demonstrates detection and blocking of the exploit pattern; it
  does not include a code-execution exploit chain.
