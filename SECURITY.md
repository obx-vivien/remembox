# Security Policy

## Supported versions

RememBox does not yet maintain parallel release branches. Only the
**latest release** is supported with security fixes. If you are running an
older build, upgrade before reporting an issue that a newer release may
already have fixed.

## Reporting a vulnerability

Please report suspected vulnerabilities using **GitHub's private
vulnerability reporting** on this repository:

<https://github.com/obx-vivien/remembox/security/advisories/new>

(Repository: `https://github.com/obx-vivien/remembox`. From the repo's
**Security** tab, choose **Report a vulnerability** if the link above does
not resolve directly.)

Do not open a public issue for a suspected vulnerability – private
reporting lets us investigate and ship a fix before details are public. We
will acknowledge reports and follow up as the investigation progresses;
there is no fixed SLA today, but reports are read promptly.

Please do not report a vulnerability by email – this project intentionally
does not publish a security contact address; use the link above instead.

## Scope

In scope:

- The `remembox` MCP server itself (stdio and the opt-in HTTP daemon /
  `--serve` mode): the tool implementations (`lib/src/memory_service.dart`),
  the MCP adapter (`lib/src/server.dart`), the HTTP transport
  (`lib/src/http_transport.dart`), store/permission/lock handling
  (`lib/src/store.dart`, `lib/src/store_gate.dart`,
  `lib/src/instance_guard.dart`), the embedding client
  (`lib/src/embedder.dart`), and the setup/build/release tooling under
  `tool/`.
- Vulnerabilities that let one local user or process read/tamper with
  another local user's memory store without authorization, that let a
  malicious or compromised dependency execute code during setup/build, or
  that let untrusted MCP tool-call input escape its intended sandbox
  (e.g. log/terminal injection, resource exhaustion via unbounded input,
  arbitrary file access outside the configured store directory).

Out of scope:

- The upstream ObjectBox C library, the `dart_mcp` package, Ollama, or any
  other third-party dependency – report those to their own maintainers.
  (We do track supply-chain integrity of how *this* project fetches them –
  see `tool/setup.sh`'s pinned-commit + checksum verification of the
  ObjectBox native library download – but a vulnerability *inside* one of
  those projects is theirs to fix.)
- Findings that require an attacker to already have arbitrary code
  execution as the same local user running RememBox (at that point the
  memory store is already fully compromised – this is a single-user local
  tool, not a privilege boundary).
- Report quality/relevance of what an LLM chooses to `remember()`/`recall`
  through the tools as intended – that is content, not a vulnerability.

## Threat model summary

RememBox is a **local-first, single-user** MCP server. The intended
deployment is one operator's own machine (or their own account on a
machine they trust), talking to their own AI assistant.

- **Local-only by default.** With no `OBX_MEMORY_SYNC_URL` set, RememBox
  has no network listener beyond the MCP stdio channel your client spawns
  (or the HTTP daemon's loopback listener in `--serve` mode – see below).
  Single-user, single machine is the default and the common case.
- **The HTTP daemon (`--serve` mode) binds to `127.0.0.1` only** and
  requires a daemon-wide bearer token (one token per running daemon
  process, shared by every session it serves – not a separate token per
  session); it also validates the `Origin`/`Host` headers of incoming
  requests, rejecting requests that do not look like they came from a
  local MCP client. Nothing outside the machine can reach it, and another
  local process cannot attach to a session without that token – do not
  port-forward or reverse-proxy the daemon onto a non-loopback interface,
  which would defeat this model entirely. `tool/install-daemon.sh` prints
  the token once, in the client registration command line it echoes to
  the terminal – that line lands in shell scrollback/history like any
  other command output, so treat it with the same care as any other
  printed secret.
- **MCP tool-call arguments are untrusted input.** The client the operator
  runs (e.g. an AI coding assistant) can itself be prompt-injected by
  content it reads elsewhere, so every argument to every tool – text,
  title, project, tags, ids, `recall.query`, and so on – is validated,
  length-capped, and never trusted to be well-formed or well-behaved. A
  crafted argument must fail loudly (an actionable `ValidationException`)
  rather than corrupt state, crash the process, or forge a log line.
- **Stored memory text is data, never instructions.** `recall`/`get`
  results are returned to whatever model consumes them framed as
  untrusted retrieved content (`_provenance_note`; hits with `sourceType`
  `url`/`file` are additionally flagged `externallySourced: true`). A
  memory that says "ignore previous instructions" is just text that got
  stored – RememBox does not execute anything it recalls, and downstream
  consumers are told not to either.
- **The store directory is private to the operating-system user that owns
  it.** The store directory and the files ObjectBox creates inside it
  (`data.mdb`, `lock.mdb`, `store.lock`, `instances.lock`) are created
  owner-only (`chmod 700`/`600`) rather than inheriting the process
  umask, since `data.mdb` is the operator's entire memory corpus. A store
  directory that already exists with looser permissions – e.g. upgraded
  in place from a build that predates this hardening – is tightened the
  next time it is opened (a cheap permission check on every open, logged
  when it actually has to tighten something), not left loose forever.
- **Optional cross-device Sync is opt-in and off by default.** Enabling it
  (`OBX_MEMORY_SYNC_URL`) without a shared secret, or over plaintext
  `ws://` to a non-loopback host, is a deliberate operator choice this
  project warns about loudly rather than silently allows – see the
  "Security model" section of `README.md` for the operational detail.
- **Setup/build supply chain.** `tool/setup.sh` fetches the ObjectBox
  native library via a commit-SHA-pinned copy of the upstream install
  script, checksum-verified before execution, with the resulting native
  library's checksum verified too where this project has been able to
  record one for the platform. This bounds (does not eliminate – the
  upstream script itself forwards to a further download) what a compromised
  upstream branch/tag could inject into a fresh developer setup.

RememBox is not designed or hardened for multi-tenant deployment (many
mutually-distrusting users sharing one daemon/store) – that is out of
scope for the current architecture, not just undocumented.
