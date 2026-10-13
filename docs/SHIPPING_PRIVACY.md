# Shipping privacy — Harness 0.6.1

This policy covers project source, documentation, local project Git metadata and shareable exports. Personal runtime account records, screen permissions and publisher signing keys belong in OS storage outside these artifacts. Removing those stores would disconnect the installed app or invalidate updates; they are not part of a source delivery.

## 1. Allowed and excluded material

Ship reviewed source, synthetic tests, generated icons, generic builder instructions and legally required dependency/font notices. Preserve upstream copyright and public service URLs. OAuth public-client identifiers, bundle IDs and public signing certificates are public protocol/verification material; they are not embedded authentication secrets.

Exclude developer names, personal email addresses, workstation hostnames, absolute home/workspace paths, real tokens/passwords/keys, credential files, private screen images, real audit logs, account/Keychain databases, private signing identities, editor session state, compiler caches, PDB/dSYM debug artifacts, Finder metadata and ZIP owner IDs. A source ZIP intentionally omits `.git`, `.build`, `.swiftpm`, runtime data and the separately licensed Satoshi OTF. Acquire the font through an authorized license before building; the font license notice remains included.

## 2. Git identity and history

Configure identity only in this project; do not change a developer's global Git preferences:

```sh
git config user.name 'Harness Maintainers'
git config user.email 'maintainer@example.invalid'
git status --short
python3 scripts/release_privacy.py
```

The local anonymization preserved commit topology and timestamps, replaced personalized historical document text and used generic author/committer identities. Machine-specific local remotes were removed. The sanitized repository does not retain the old object database or personalized reflogs. Anonymization changes commit IDs: the previous application implementation has the equivalent anonymized baseline `6034926`. Existing signed binaries retain their original build metadata and code signature; Git cleanup alone does not modify them. The delivery's source revision and per-file/ZIP hashes identify the current sanitized snapshot.

A private backup, unrelated parent repository, global Git config, OS runtime store or old chat attachment is outside the exported project. Do not include such material in an artifact. Local cleanup cannot retract a ZIP somebody already downloaded or a previously shared immutable conversation. Do not force-push rewritten history to another person's remote without coordinating that migration.

## 3. Automated guard

`scripts/release_privacy.py` with no arguments checks reviewed tracked files, project-root identity, Git configuration/reflogs and all object-database entries, including unreachable history. With file/ZIP arguments it checks those artifacts. It discovers the current scanner machine's username, workspace owner, full account name where available and hostname at runtime; these values are not written to source or test fixtures. Generic build users are excluded from identity matching to avoid rejecting ordinary code vocabulary.

The scanner checks raw bytes and decoded UTF-16 in both byte orders, as well as archive member names. It rejects supported Unix/Windows home paths, local machine hostnames, PEM private-key headers, OpenAI API keys, JWT credentials and selected GitHub/AWS/Google key signatures. Credential extensions and `.env` files are prohibited. Git/build/SwiftPM/Finder/resource-fork containers are prohibited in archives. Archive/member comments and extra fields are scanned; Unix owner/group extra fields or malformed fields fail the check. ZIP CRC failure also fails.

Errors contain labels and entry numbers rather than the matching value or filename. Tool exceptions are suppressed at the CLI boundary. If a scan fails, privately inspect the affected artifact and regenerate it after removing the material; do not paste the original secret into a bug report. Never disable a guard to publish an actual credential. Revoke/rotate an exposed live key through its owner if one is independently discovered; no real key was found by this cleanup.

Runtime identity detection cannot identify every past developer on a different machine. Known historical identities must be reviewed before handoff; third-party legal attribution must be retained. This guard cannot recognize arbitrary opaque strings, encrypted secrets, credentials with unsupported signatures or personal information inside rasterized screenshots. Do not include private logs, captures or databases merely because they pass a pattern scan. Hashes and timestamps are integrity/provenance evidence, not proof of anonymity against all external correlation.

## 4. Export and verification

```sh
python3 -m unittest discover -s Tests/PackagingTests -p 'test_*.py'
git diff --check
python3 scripts/release_privacy.py
# Commit reviewed changes using the project-local generic identity before export.
make source
python3 scripts/release_privacy.py dist/Harness-source.zip
unzip -t dist/Harness-source.zip
```

`scripts/source.py` refuses dirty source, scans tracked data and Git metadata before archiving, omits restricted font binaries, checks the completed archive and only then writes the distributable ZIP. The clean source ZIP contains current docs and no Git metadata. Record its SHA-256 outside the archive to avoid a self-referential digest. An optional content manifest inside a handoff ZIP can record each included file's digest.

Release binaries additionally require compiler source/build prefix mapping, removal of debug information, signature verification and the staged archive scan in `scripts/package.sh`. Packaging scratch/staging uses dedicated temporary locations; a builder must not add their compiler logs or credentials to the ZIP. Archive creation omits resource forks and extended attributes. Never modify signed app resources to redact a value: rebuild with sanitized inputs and re-sign through the approved publisher workflow if binary content needs a change.

The cleanup's packaging suite has **26 tests**, including **11 release-privacy tests**. The existing Swift app was not rebuilt or reinstalled for this source/tooling cleanup. Public shipping still requires the publisher's Developer ID, notarization, Gatekeeper and supported-target runtime acceptance described in [BUILD_FROM_SOURCE.md](BUILD_FROM_SOURCE.md). A clean source delivery is not a claim that a local development certificate or the unverified legacy Windows executable is accepted for public distribution.
