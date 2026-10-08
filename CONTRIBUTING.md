# Contributing

Issues and pull requests are welcome. By contributing you agree that your contribution is
licensed under this repository's licence (`LICENSE`).

## Before a pull request

```sh
(cd Packages/PocketKit && swift test)
(cd Bridge/tsbridge && go vet ./... && go test ./...)
scripts/build.sh
CONFIGURATION=Release scripts/build.sh
scripts/check-license.sh
```

## Rules

- Every `swift`, `go`, `c`, `h`, `sh`, `py` and `xcconfig` file starts with the two-line SPDX
  header (`FSL-1.1-Apache-2.0`), after the shebang when there is one.
- Code, comments and commit messages are English. User-facing Chinese copy stays Chinese.
- Every runtime constant has a stated basis in `docs/constants.md`.
- A change to the Passport link changes `docs/ble-protocol.md` and the firmware together.
- Never commit host names, tailnet addresses, room names, team IDs, device IDs, credentials,
  logs or recordings. Local settings go in `Config/Signing.local.xcconfig` (gitignored).
- Debug fixtures and probes stay inside `#if DEBUG`.
