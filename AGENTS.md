# CLAUDE.md

## Never run the setup scripts locally

`setup.sh`, `go.sh`, `mise/setup.sh` and `claude/setup.sh` install mise into
`~/.local/bin` and overwrite `~/.claude/settings.json`. Nothing they do is worth
verifying on a workstation. A local smoke test once got within one line of
clobbering the real settings, saved only by BSD `mkdir` rejecting `--parents`.

Keep both guards: `assert-environment.sh` (requires `X_ENVIRONMENT_MINE=1`;
inlined in `go.sh`, which runs before the repo exists) and the Bash denies in
`.claude/settings.json`.

## A blocked host gets allowlisted, not routed around

When the egress proxy blocks a host (usually a 503), add it to
`network/allowed-domains/*.txt` with what needs it and its upstream source of
truth. Keep the upstream installer; the user can add hosts freely.

- Measure the hosts with `network/discover.sh -- <command>`; do not guess.
- Skip hosts already in `network/claude-defaults.txt`.
- Exact hosts only: `*.` entries do not work in the environment.
- Never hand-edit the domain block in `README.md`; run
  `python3 network/build-allowed-domains.py --update-readme`.

`network/README.md` ("Adding a host") has the full procedure, including proving
the list sufficient with `--allow-file`. Read it before touching `network/`.
