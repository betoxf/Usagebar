# Releasing Usagebar

Releases should start from a clean, validated `main` branch.

## 1. Prepare the version

Update `MARKETING_VERSION` and the monotonically increasing `CURRENT_PROJECT_VERSION` in the Xcode project. Confirm the planned version is newer than the latest GitHub release.

## 2. Validate locally

```bash
./script/build_and_run.sh --verify
make release
```

Confirm `build/Usagebar.zip` exists, the app launches, the app icon is present in bundle metadata, relevant provider states render, and no credentials appear in logs or artifacts.

## 3. Tag the release

```bash
git tag -a vX.Y.Z -m "Usagebar X.Y.Z"
git push origin vX.Y.Z
```

The `Release` workflow builds `Usagebar.zip`, creates the GitHub release, and generates release notes.

## 4. Verify the published artifact

Download the GitHub artifact, inspect it, launch it on a clean account when possible, and calculate its published hash:

```bash
shasum -a 256 Usagebar.zip
```

## 5. Update Homebrew

Update `version` and `sha256` in `Casks/usagebar.rb` and `Casks/justausagebar.rb`. Use the hash of the artifact downloaded from GitHub, not a separately built local archive.

Verify `brew upgrade --cask usagebar`, review release notes for accuracy and secret leakage, and never move an existing version tag after publication.
