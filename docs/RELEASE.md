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
6. **The Homebrew tap.** `brew install --cask <owner>/tap/juiceisland`, the README's first install line, reads `Casks/juiceisland.rb` in the public repository `<owner>/homebrew-tap`. Make it once (`gh repo create <owner>/homebrew-tap --public --add-readme`) and clone it beside this folder (`git clone https://github.com/<owner>/homebrew-tap.git ../homebrew-tap`), or name its folder in the signing file as `JUICE_TAP_DIR`. `--check` and `--publish` stop without a clean clone, so no release points visitors at a tap that does not exist.
7. **The public repository.** `PUBLIC_REPO` must exist, be public, and hold the commit you release on its `main`. Release from a clone of it in a folder of its own that nothing cleans up (`git clone https://github.com/<owner>/<name>.git`); the signing file lives there too. Its name is one line in `scripts/public-settings.sh` (`default_repo`). The environment or the signing file can name another, but README.md's links must name the same one: `--check` says when they do not.

## Each release

1. Raise `VERSION` and commit it.
2. Push that commit to `PUBLIC_REPO`'s `main`. (The maintainer works in a private copy and makes each public commit with an export script that is not part of this repository.)
3. Write what changed in a file, such as `notes.md` outside the repository. Start it with a headline that names what is new, `# Answer Copilot, Cursor and Qwen from the notch`: the release is titled `Juice <version>: <headline>` and the line leaves the notes. Then a line each for New, Better and Fixed, with one `- ` line per change under it in plain words, crediting whoever reported a fix by their GitHub handle.
4. In the public repository's folder: `zsh scripts/release.sh --publish --notes notes.md`.
5. Publish the cask: the run's last lines give the `git -C ../homebrew-tap … commit … push` that does it.

It stops before building when anything is missing, when the folder has uncommitted changes, when its commit is not `PUBLIC_REPO`'s `main`, when `v<VERSION>` exists already, or when `VERSION` is not above the last release. Then it builds, signs every part from the inside out, notarizes and staples the app, makes the DMG from it, notarizes and staples that, signs it for Sparkle and creates the release `v<VERSION>` with the DMG, the same DMG as `Juice.dmg`, and `appcast.xml`. `Juice.dmg` keeps `releases/latest/download/Juice.dmg`, the README's download link, working for every release. Last it writes the Homebrew cask, `Casks/juiceisland.rb`: the version, the DMG's SHA-256, `auto_updates` (Sparkle updates the app), a livecheck on the latest release, and a `zap` of the folders the app keeps, read from the built app. It goes into the tap's clone uncommitted, so you see the change before you push it. The notes are your file; without `--notes` they are the commit subjects since the last release, merges left out, and `--publish` refuses to go on when those say only "Update the Juice source". The first release's notes say "The first release." unless you give your own.

The DMG opens on a window of its own: the app on the left, an arrow, Applications on the right. The background is `scripts/dmg/background.png` and its `@2x` twin (`swift scripts/make-dmg-art.swift` draws both). The release lays the window out without Finder: it mounts the read-write image hidden from Finder (`hdiutil attach -nobrowse`), writes its `.DS_Store` with `scripts/dmg-layout.swift`, and compresses the image. Eject any other disk named Juice first: the image must mount at `/Volumes/Juice`, where a download mounts.

The app carries its licences in `Contents/Resources`: the GPL (`LICENSE.txt`), `NOTICE.txt` and Sparkle's (`Sparkle-LICENSE.txt`).

The build number is the commit count, so it rises with every public commit. The release makes its `v<VERSION>` tag on GitHub, at the commit it builds.

The app runs on macOS 26 or later, on Apple silicon or Intel. The release builds it universal (`build-app.sh --public --universal`): the app, its widget and its hook helper each carry an arm64 and an x86_64 slice, and Sparkle ships both. Before signing, it reads every binary in the app with `lipo -archs` and stops when one lacks either slice, naming each. A build from source is for its own Mac's chip only, which is quicker.

## Without publishing

- `zsh scripts/release.sh` builds and signs a DMG on this Mac and stops. Only the signing timestamp's request reaches Apple. Other Macs refuse that DMG until it is notarized.
- `zsh scripts/release.sh --dry-run` runs the whole release with stand-ins for every tool that reaches Apple, GitHub or the keychain (`scripts/release-fake.zsh`). It lists what would stop a real release and goes on. What it would have run is in `output/release.noindex/dry-run/dry-run-calls`.
- `zsh scripts/tests/release-script-test.zsh <new folder>` tests the script with a fake build.

Everything a run makes is in `output/release.noindex/<version>/`: the DMG, `Juice.dmg`, `appcast.xml`, `Casks/juiceisland.rb`, `notes.md` and `release.log`. The DMG's layout tool is built once into `output/release.noindex/tools/`.

## When a run stops partway

Nothing outside the Mac changes before `gh release create`, so a run that stops earlier can simply be run again. It notarizes again, because every signing makes a new signature. A published release cannot be changed, so a wrong one is fixed by raising `VERSION` and releasing again.
