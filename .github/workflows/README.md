# CI

| Workflow | What it proves |
|---|---|
| `build.yml` → `tests` | The pure half of the SDK behaves: config parsing and validation, the `google-services.json` reader, Firebase's naming rules, the error vocabulary, and that the five places stating the SDK version agree. |
| `build.yml` → `android` | All six Android modules compile from source against the engine's own library, for both variants. Tagged pushes attach the release AARs to the GitHub release. |

**Not covered:** the iOS plugins, which need macOS and Xcode — see
[`docs/ios.md`](../../docs/ios.md) — and anything that needs a device, which is
the manual matrix in [`docs/testing.md`](../../docs/testing.md).
