# Release checklist

One command runs the automated part:

```sh
./tools/release-audit.sh        # exit code 0 = all clear
```

The same script runs in CI (`.github/workflows/ci.yml`): build → self test → offline check → this audit.

## Automated checks (8 groups, 40 items)

| Group | Items | What it verifies |
| --- | --- | --- |
| Personal info | 7 | No name, email, username, machine name, absolute local path or workspace-specific term anywhere in the tree (excluding `build/` and images) |
| Secrets | 2 | No value-shaped keys/tokens/passwords; no `.env`, `auth.json` or credential files |
| License & provenance | 4 | `LICENSE` present and MIT; copyright line carries no personal name; no third-party copyright headers in the source |
| Repo hygiene | 5 | `build/` and `.DS_Store` ignored; no TODO/FIXME; nothing unexpectedly larger than 5 MB |
| Build | 2 | `-warnings-as-errors` compiles clean; `otool -L` lists only `/System/Library` and `/usr/lib` |
| Runtime safety | 8 | Self test passes and includes the cross-cutting assertions; deletion path quoting is verified; Trash-by-default; CLI uninstall requires `--yes`; no system-permission APIs; no networking calls; offline test script present |
| Docs | 9 | README sections present, referenced screenshots exist, `--help` prints usage |
| Publish prerequisites | 5 | Repo identity is not a personal address, commit authors are clean, `build/` is not tracked, CI present |
| Full history | 3 | `git log -p --all` contains no personal info or key material, no build artifacts or credential files, commit authors are clean |

Project-specific private terms (your own name, company, machine names) belong in `tools/private-patterns.local`, which is git-ignored — the shipped script only carries generic patterns and never leaks them into a public repository.

## Manual items (a machine cannot judge these)

1. **Name & trademark** — make sure there is no conflicting product or trademark before publishing.
2. **Provenance** — confirm you own the code you are licensing (this project is written from scratch and links only system frameworks).
3. **Notarization** — builds are ad-hoc signed: users must right-click → Open the first time. With a Developer ID certificate plus notarization (`./tools/release.sh`) that step disappears.
4. **Docs** — the README is English; keep it that way or add translations next to it.

## GitHub release

```sh
./build.sh                                   # produces build/FullCleaner-<version>.dmg
git tag -a v<version> -m "FullCleaner <version>"
git push origin main --tags
gh release create v<version> build/FullCleaner-<version>.dmg \
  --title "FullCleaner <version>" --notes-file <notes>
```

Release notes should answer three questions: what it is, how to install (drag into Applications), and whether the first launch needs a right-click.

## Developer ID distribution (planned)

| Step | What | Where |
| --- | --- | --- |
| 1 | Join the Apple Developer Program (99 USD/year) | developer.apple.com/programs |
| 2 | Create a **Developer ID Application** certificate and add it to the keychain | developer.apple.com → Certificates → + (or Xcode → Settings → Accounts → Manage Certificates) |
| 3 | Create an **app-specific password** | account.apple.com → Sign-In and Security → App-Specific Passwords |
| 4 | Store the credentials: `xcrun notarytool store-credentials fullcleaner-notary --apple-id … --team-id … --password …` | local keychain |
| 5 | `./tools/release.sh` | universal build → signing → notarization → stapling → `dist/` |
