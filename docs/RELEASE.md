# Releasing Juice

`scripts/release.sh` turns the public repository into a download: a signed, notarized DMG on GitHub Releases, plus the appcast Sparkle reads to update copies already installed.

## Once, before the first release

`zsh scripts/release.sh --check` lists whichever of these is still missing, each with the command that makes it.

1. **The Developer ID certificate.** `security find-identity -v -p codesigning` should list `Developer ID Application: <your name> (<team id>)`. If not: Xcode › Settings › Accounts › your team › Manage Certificates › + › Developer ID Application.
2. **The local signing file**, `Signing.local.xcconfig` at the top of the folder you release from. Git ignores it, so it is never committed. The public build reads the same file (`scripts/public-settings.sh`), and `Signing.example.xcconfig` lists every line.

   ```
   DEVELOPMENT_TEAM = <team id>
   CODE_SIGN_IDENTITY = Developer ID Application: <your name> (<team id>)
   SPARKLE_PUBLIC_ED_KEY = <the key from step 4>
   // Optional: JUICE_NOTARY_PROFILE (default juice-notary), JUICE_SPARKLE_ACCOUNT, JUICE_RELEASE_IDENTITY, PUBLIC_REPO
   ```

3. **Notary credentials.** Make an app-specific password at account.apple.com (Sign-In and Security › App-Specific Passwords), then:

   ```
   xcrun notarytool store-credentials juice-notary --apple-id <your Apple Account email> --team-id <team id>
   ```

4. **The Sparkle key.** Sparkle's tools come with the public build's packages (`output/*/SourcePackages/artifacts/sparkle/Sparkle/bin/`), or from `brew install --cask sparkle`. Run `generate_keys` once. It keeps the private key in your login keychain and prints the public key: put that in the signing file as `SPARKLE_PUBLIC_ED_KEY = <key>`, so the public build carries it. Back the private key up with `generate_keys -x <file>` and keep that file out of every repository. Without it, no installed copy can ever be updated again.
5. **GitHub.** `gh auth login --hostname github.com --web`.
6. **The public repository.** `PUBLIC_REPO` must exist, be public, and hold the commit you release on its `main`. Release from a clone of it in a folder of its own that nothing cleans up (`git clone https://github.com/<owner>/<name>.git`); the signing file lives there too. Its name is one line in `scripts/public-settings.sh` (`default_repo`). The environment or the signing file can name another, but README.md's links must name the same one: `--check` says when they do not.

## Each release

1. Raise `VERSION` and commit it.
2. Push that commit to `PUBLIC_REPO`'s `main`. (The maintainer works in a private copy and makes each public commit with an export script that is not part of this repository.)
3. Write what changed in a file, such as `notes.md` outside the repository, one `- ` line per change.
4. In the public repository's folder: `zsh scripts/release.sh --publish --notes notes.md`.

It stops before building when anything is missing, when the folder has uncommitted changes, when its commit is not `PUBLIC_REPO`'s `main`, when `v<VERSION>` exists already, or when `VERSION` is not above the last release. Then it builds, signs every part from the inside out, notarizes and staples the app, makes the DMG from it, notarizes and staples that, signs it for Sparkle and creates the release `v<VERSION>` with the DMG and `appcast.xml`. The notes are your file; without `--notes` they are the commit subjects since the last release, merges left out, and `--publish` refuses to go on when those say only "Update the Juice source". The first release's notes say "The first release." unless you give your own.

The app carries its licences in `Contents/Resources`: the GPL (`LICENSE.txt`), `NOTICE.txt` and Sparkle's (`Sparkle-LICENSE.txt`).

The build number is the commit count, so it rises with every public commit. The release makes its `v<VERSION>` tag on GitHub, at the commit it builds.

The app runs on macOS 26 or later, on Apple silicon or Intel. The release builds it universal (`build-app.sh --public --universal`): the app, its widget and its hook helper each carry an arm64 and an x86_64 slice, and Sparkle ships both. Before signing, it reads every binary in the app with `lipo -archs` and stops when one lacks either slice, naming each. A build from source is for its own Mac's chip only, which is quicker.

## Without publishing

- `zsh scripts/release.sh` builds and signs a DMG on this Mac and stops. Only the signing timestamp's request reaches Apple. Other Macs refuse that DMG until it is notarized.
- `zsh scripts/release.sh --dry-run` runs the whole release with stand-ins for every tool that reaches Apple, GitHub or the keychain (`scripts/release-fake.zsh`). It lists what would stop a real release and goes on. What it would have run is in `output/release.noindex/dry-run/dry-run-calls`.
- `zsh scripts/tests/release-script-test.zsh <new folder>` tests the script with a fake build.

Everything a run makes is in `output/release.noindex/<version>/`: the DMG, `appcast.xml`, `notes.md` and `release.log`.

## When a run stops partway

Nothing outside the Mac changes before `gh release create`, so a run that stops earlier can simply be run again. It notarizes again, because every signing makes a new signature. A published release cannot be changed, so a wrong one is fixed by raising `VERSION` and releasing again.
