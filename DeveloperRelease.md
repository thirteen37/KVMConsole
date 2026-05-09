# Developer Release Guide

This repo uses three separate GitHub Actions workflows for macOS distribution:

- `Test`: runs unit tests on pull requests, pushes to `main`, and manual dispatch. It does not require signing secrets.
- `Build Developer ID App`: manually creates a Developer ID signed zip without notarization. Use this for release candidate validation.
- `Release Notarized App`: runs only when a GitHub Release is published, or when manually dispatched for an existing release tag. It builds, notarizes, staples, and uploads the final zip to the GitHub Release page.

## Required Apple Setup

Install a `Developer ID Application` certificate for team `9URLHJ84PY`. The certificate must include its private key.

In Keychain Access:

1. Select `login`.
2. Select `My Certificates`.
3. Find the `Developer ID Application` certificate for team `9URLHJ84PY`.
4. Expand it and confirm there is a private key underneath.
5. Export the certificate and private key as a `.p12` file.
6. Set an export password and keep it available for the GitHub secret.

Create an Apple ID app-specific password at `https://appleid.apple.com`. Use that for notarization, not your normal Apple ID password.

## GitHub Secrets

Add these repository or environment secrets:

- `APPLE_TEAM_ID`: `9URLHJ84PY`
- `DEVELOPER_ID_APPLICATION_P12_BASE64`: base64-encoded exported `.p12`
- `DEVELOPER_ID_APPLICATION_P12_PASSWORD`: password used when exporting the `.p12`
- `NOTARY_APPLE_ID`: Apple ID email used for notarization
- `NOTARY_APP_PASSWORD`: Apple ID app-specific password

Create the base64 value with:

```sh
base64 -i DeveloperIDApplication.p12 | pbcopy
```

Paste the copied value into `DEVELOPER_ID_APPLICATION_P12_BASE64`.

## Local Commands

Run tests locally without signing:

```sh
xcodegen generate
xcodebuild test \
  -project NanoKVM.xcodeproj \
  -scheme NanoKVM \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  DEVELOPMENT_TEAM=
```

Build a signed but not notarized app:

```sh
NOTARIZE=0 FINAL_ZIP_PATH=build/developer-id/NanoKVM-DeveloperID-signed.zip Scripts/build-developer-id.sh
```

Build, notarize, staple, and package locally:

```sh
xcrun notarytool store-credentials NanoKVM-DeveloperID \
  --apple-id "you@example.com" \
  --team-id 9URLHJ84PY \
  --password "app-specific-password"

Scripts/build-developer-id.sh
```

## GitHub Release Flow

1. Merge the release commit to `main`.
2. Create and publish a GitHub Release for the desired tag.
3. The `Release Notarized App` workflow checks out that tag.
4. The workflow imports the Developer ID certificate from GitHub Secrets.
5. The workflow stores notarization credentials in the temporary signing keychain.
6. The workflow runs `Scripts/build-developer-id.sh` with notarization enabled.
7. The workflow uploads `NanoKVM-<tag>-DeveloperID-notarized.zip` to the release page.

The release page asset is the final user-downloadable app zip.

## Manual Release Retry

If a release workflow fails after the GitHub Release exists, rerun it from Actions with `workflow_dispatch` and the existing release tag. The upload step uses `--clobber`, so a successful retry replaces the previous release asset with the same name.
