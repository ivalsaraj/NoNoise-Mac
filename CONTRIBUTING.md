# Contributing to NoNoise Mac

Thanks for helping make on-device noise cancellation better! NoNoise Mac is **AI-native** —
both humans and AI agents are first-class contributors.

## Before you start
1. Read [`AGENTS.md`](AGENTS.md) — architecture, build/test, and the non-negotiable DSP /
   real-time invariants.
2. Skim [`docs/knowledge/critical-patterns.md`](docs/knowledge/critical-patterns.md) — the
   shipped-and-broke failure modes. **Do not** reintroduce them.
3. Glossary: [`CONCEPTS.md`](CONCEPTS.md). Agent catalog: [`docs/agents/README.md`](docs/agents/README.md).

## Dev loop
```bash
swift build          # compile
swift test           # 30 pure DSP/preset/voice-chain tests (headless)
./install-app.sh     # optimized arm64 build + install to /Applications
```

## Ground rules
- **No DSP/model behavior changes** unless that is explicitly the task; the default audio
  path must stay byte-for-byte identical (a test enforces this).
- Keep new DSP math in **pure, testable** helpers (no CoreML dependency) and add tests.
- The render thread is **allocation-free** — see the real-time rules in `AGENTS.md`.
- **Branding:** never reintroduce the previous project's brand names (see `AGENTS.md` →
  Branding conventions) outside the provenance allowlist (`README.md`, `LICENSE`,
  `AGENTS.md`, `docs/`).
- Don't commit build artifacts (`.build/`, `NoNoiseMac.app/`, binaries) — see `.gitignore`.

## Pull requests
- Describe the *why*; link the relevant `AGENTS.md` invariant or knowledge entry.
- Ensure `swift build` and `swift test` are green.
- If you solved something non-obvious, add a `[GOTCHA]`/`[DECISION]` to
  [`docs/knowledge/knowledge1.md`](docs/knowledge/knowledge1.md) so the knowledge compounds.

## Credits
NoNoise Mac stands on prior open-source work — see the **Credits & acknowledgements**
section of the [README](README.md) for full attributions.
