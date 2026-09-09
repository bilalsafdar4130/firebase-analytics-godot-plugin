# Releasing a version

A game should depend on a **released tag**, not on `main`. That is the whole
reason this process exists: three games sharing one addon need to move one at a
time.

## The process

1. **Update the version in all five places.** `tests/test_versions.gd` fails if
   you miss one:
   - `addons/mobile_services/plugin.cfg`
   - `MobileServices.VERSION`
   - `MobileServicesEditorConfig.VERSION`
   - `BuildInfo.VERSION` (Android)
   - `MobileServicesCore::get_native_version()` (iOS)
2. **Write the changelog entry.** Breaking changes get a `MIGRATION.md` section.
3. **Run the headless tests.**
   ```
   godot --headless --import && godot --headless --script res://tests/run_tests.gd
   ```
4. **Build both variants.**
   ```
   addons/mobile_services/tools/build_android.sh both
   addons/mobile_services/tools/build_ios.sh release     # on a Mac
   ```
5. **Work the manual matrix** in [`testing.md`](testing.md) on a real device —
   including a **minified release build**, which is where R8 problems appear.
6. **Tag and push.**
   ```
   git tag -a v2.1.0 -m "Mobile Services 2.1.0"
   git push origin v2.1.0
   ```
7. **Create the GitHub release** and attach the built AARs (and xcframeworks, if
   you built them). CI builds the Android AARs on every tag and attaches them.
8. **Install it into one game**, run the matrix again there, and only then update
   the others.

## What is not committed

`addons/mobile_services/bin/` is generated and git-ignored. Built binaries are
release artifacts, not source: committing them would put an unreviewed binary in
the chain a signed game is built from, which is the whole thing this addon exists
to avoid.

## Semantic versioning

- **MAJOR** — a breaking change to the GDScript API or the config format.
- **MINOR** — new services, methods or config keys with safe defaults.
- **PATCH** — fixes and behaviour-preserving dependency bumps.

## Consuming a release in a game

Copy the tagged `addons/mobile_services/` folder in, or use a submodule:

```bash
git submodule add https://github.com/bilalsafdar4130/firebase-analytics-godot-plugin \
    vendor/mobile-services
git -C vendor/mobile-services checkout v2.1.0
```

then symlink or copy `vendor/mobile-services/addons/mobile_services` into
`addons/`. Record the tag in your game's own README, so "which version is this
game on" is answerable without a diff.

## Upgrading a game

1. Read the changelog between your tag and the new one.
2. Replace `addons/mobile_services/`.
3. `tools/build_android.sh both`.
4. Diff `mobile_services.cfg.template` against your `mobile_services.cfg` — new
   keys always have safe defaults, but new *warnings* may point at something.
5. Run the matrix.

Never upgrade the addon and ship the same day. The failures this SDK guards
against are the ones that are invisible for a week.
