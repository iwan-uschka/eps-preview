REPO_DIR: /Users/iwanuschka/projekte/_github/eps-preview
SANDBOX_PROBE: pass (haiku subagent read skill-dir file + wrote/read /tmp file) → REVIEW_MODE: delegated
PROBE_TIMEOUT_BIN: timeout

== 1. FORGE & CLI ==
GIT_REMOTES:
  origin	git@github.com:iwan-uschka/eps-preview.git (fetch)
  upstream	git@github.com:Zhangyanbo/eps-preview.git (fetch)
ORIGIN_URL: git@github.com:iwan-uschka/eps-preview.git
FORGE: github
GLAB_CLI: /opt/homebrew/bin/glab
GLAB_AUTH_EXIT: 0 (0 = authenticated)
GLAB_AUTH_OUTPUT:
  gitlab.toto.io
    ✓ Logged in to gitlab.toto.io as iwanuschka (keyring)
    ✓ Git operations for gitlab.toto.io configured to use ssh protocol.
    ✓ API calls for gitlab.toto.io are made over https protocol.
    ✓ REST API Endpoint: https://gitlab.toto.io/api/v4/
    ✓ GraphQL Endpoint: https://gitlab.toto.io/api/graphql/
    ✓ Token found in operating system keyring: **************************
  gitlab.oo.bitgrip.berlin
    ✓ Logged in to gitlab.oo.bitgrip.berlin as christoph.wanja (/Users/iwanuschka/Library/Application Support/glab-cli/config.yml)
    ✓ Git operations for gitlab.oo.bitgrip.berlin configured to use ssh protocol.
    ✓ API calls for gitlab.oo.bitgrip.berlin are made over https protocol.
    ✓ REST API Endpoint: https://gitlab.oo.bitgrip.berlin/api/v4/
    ✓ GraphQL Endpoint: https://gitlab.oo.bitgrip.berlin/api/graphql/
    ✓ Token found in configuration file (plaintext): **************************
    ! To store this token more securely, run glab auth login --hostname gitlab.oo.bitgrip.berlin to move it into the operating system keyring.
  Could not send telemetry data: POST https://gitlab.com/api/v4/usage_data/track_event: 401 {message: 401 Unauthorized}
GH_CLI: /opt/homebrew/bin/gh
GH_AUTH_EXIT: 0 (0 = authenticated)
GH_AUTH_OUTPUT:
  github.com
    ✓ Logged in to github.com account iwan-uschka (keyring)
    - Active account: true
    - Git operations protocol: ssh
    - Token: gho_************************************
    - Token scopes: 'gist', 'read:org', 'repo'

== 2. CI AVAILABILITY (config evidence exact; run history best-effort) ==
CI_CONFIG_FILES:
  (none)
CI_RECENT_RUNS_EXIT: 0 (nonzero = could not reach the forge; treat run history as UNKNOWN, not as 'no CI')
CI_RECENT_RUNS:
  (none)

== 3. NODE / TOOLCHAIN PIN ==
PIN_FILE_.nvmrc: absent
PIN_FILE_.node-version: absent
PIN_FILE_.tool-versions: absent
PIN_FILE_mise.toml: absent
PIN_FILE_.mise.toml: absent
NODE_MANAGER_FNM: /opt/homebrew/bin/fnm
NODE_MANAGER_VOLTA: not installed
NODE_MANAGER_ASDF: not installed
NODE_MANAGER_MISE: not installed
NODE_MANAGER_NODENV: not installed
NODE_MANAGER_NVM: not detectable from a script (nvm is a shell function, not a binary) — check ~/.nvm or the owner's shell rc if the pin matters
SYSTEM_NODE_VERSION: v24.14.1
SYSTEM_NPM_VERSION: 11.11.0
SYSTEM_PNPM_VERSION: 10.33.0
SYSTEM_YARN_VERSION: not on PATH
FNM_PREFIX_CHECK: skipped (no .nvmrc version, or fnm not installed)

== 4 + 6. PACKAGE.JSON: ENGINES, LIFECYCLE SCRIPTS, VERIFICATION COMMANDS ==
PACKAGE_JSON: absent — not a node repo. This is a Swift/macOS app (XcodeGen +
xcodebuild). Node manager prefix is N/A for this run.
LOCKFILES_PRESENT:
  (none — N/A, not node)
TASK_RUNNER_FILES:
  (none — build orchestrated via scripts/*.sh + project.yml, not a JS task runner)

MANUAL — toolchain: Xcode 26.6 (xcodebuild present at /usr/bin/xcodebuild).
No .nvmrc/node relevance.

MANUAL — verification commands (no test target/scheme exists in project.yml;
no CI config in repo):
  - Build (authoritative — plain `xcodebuild build` is insufficient per
    README.md, ad-hoc signing in scripts/build.sh is load-bearing):
      bash scripts/build.sh
  - Lint: swiftlint is installed (/opt/homebrew/bin/swiftlint) but there is
    no .swiftlint.yml in the repo — running it would apply default rules
    only, not a repo-endorsed config. Treat swiftlint output as advisory,
    not a gate, unless the owner wants a config added.
  - Unit/UI tests: NONE — no test target in project.yml, no XCTest files
    found anywhere in the repo. This is itself a Tests & CI dimension
    finding, not a runnable gate.
  - Secret scan: no tool configured; not runnable without adding one.
  - E2E: N/A (desktop app, no E2E harness).

== 5. HOOKS LAYOUT ==
CORE_HOOKS_PATH: unset (default: $GIT_COMMON_DIR/hooks — shared across all worktrees of this repo)
EFFECTIVE_HOOKS_DIR: /Users/iwanuschka/projekte/_github/eps-preview/.git/hooks
INSTALLED_HOOKS:
  (none)
HUSKY_DIR: absent
LEFTHOOK_CONFIG: absent
PRE_COMMIT_CONFIG: absent

== 7. CONVENTIONS DOCS ==
DOC_AGENTS.md: absent
DOC_CLAUDE.md: absent
DOC_CONTEXT.md: absent
DOC_CONTRIBUTING.md: absent
DOC_README.md: present
ADR_DIR_adr: absent
ADR_DIR_docs/adr: absent
ADR_DIR_docs/adrs: absent
ADR_DIR_doc/adr: absent
ADR_DIR_architecture/decisions: absent
DOCS_TOPLEVEL_MD:
  (no docs/ directory)

MANUAL — required reading before any agent codes in this repo: README.md
(explains the XPC signature-based peer validation, the 100 MB / 20 s render
limits in Sources/RenderService/RenderService.swift, and why build must go
through scripts/build.sh, not bare xcodebuild). No AGENTS.md/CLAUDE.md exists
— nothing else to read.
