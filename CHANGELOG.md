# Changelog

All notable changes to this project will be documented in this file.

## [0.6.1] - 2025-11-18

### Bug Fixes

- Fix init sequence

## [0.6.0] - 2025-11-13

### Bug Fixes

- Highlight summary
- [**breaking**] Switch to immutable strings
- [**breaking**] `ValidationError` -> `TemplateError`
- [**breaking**] Update error set
- Update validation messages
- Improve conditionals
- Fix position tracking
- Remove `splitWhitespace()`
- Optimize `parseCondition()`
- Make `sendNotification()` silent
- Gate kqueue functions
- [**breaking**] Move config/app data
- Update `bootstrap` example
- Update `daemon` description
- Check the rendered output
- Properly handle literal changes
- Reflect sync status
- Adjust registration procedure
- Fix xdg desktop string

### Documentation

- Comment main functions
- Comment `validate()`
- Update example config
- Add `tray` setting

### Features

- Add desktop notifications
- Prepare daemon
- Add `spawnTray()`
- Implement file watcher
- Add `Configuration` item
- Add `tray`
- Add sync time tooltip
- Set named icons
- Add `Tray.menu_icons`
- Add `SYSTEM.desktop`

### Operations

- Install dbus
- Add `daemon` label
- Update `daemon` label
- Add `asset` label

### Performance

- Drop redundant check
- Drop redundant `trimTag()`

### Refactor

- Utilize `parseTag()`
- Improve conditional fns
- Add `SYSTEM`
- Rewrite `evalIfGroup()`
- Update `reverseIfGroup()`
- Remove `countTrail()`
- Add `LOG_SIZE_MAX`
- Add `evalBranch()`
- Fix notifications check
- Add `scan()`
- Add `sync()`
- Move daemon

### Testing

- Update layout
- Reformat `interpret`
- Fix `parseTag`
- Update `evalIfGroup`
- Update `validate`
- Update `log`
- Add `defaultConfigPath`

### Build

- Add `libstray`
- Add `dbus` option
- Add icons
- Bump `libstray` to `9c4c412`
- Bump `libstray` to `0fba7fb`

## [0.5.1] - 2025-10-19

### Bug Fixes

- Limit log file size
- Check `git` binary
- Adjust stdout prints
- Handle symlinks

## [0.5.0] - 2025-10-17

### Bug Fixes

- Add missing counters
- Correct writing positions
- Update config errors
- Handle `ignore_list` allocations
- Clone during bootstrap
- Move stdout prints
- Fix `pathFormat()` deallocations
- Improve returns
- Purge logs
- Edit config error
- Fix `cloneRepo()` path
- Make `cloneRepo()` silent
- [**breaking**] Move `bootstrap` command
- Fix zon parser leak
- Drop `url` option
- Improve config handling

### Documentation

- Update config
- `.destination` -> `.target`

### Features

- Add `direction` option
- Add `repository`
- Migrate old formats
- Automatic config updates
- Add logger
- Use custom logger
- [**breaking**] Add `target`

### Miscellaneous tasks

- Note deallocations for path functions

### Operations

- Bump zig to 0.15.2

### Refactor

- Split `processFile()`
- Move `bootstrap()`
- Add `cloneRepo()`
- Restructure `Dotfile`/`Config`
- Add `core` module
- Improve `direction` assignment
- Move `IGNORE_LIST`

### Styling

- Fix `getUserInput()` formatting
- Fix `description`

### Testing

- Add `sync-back-forced`
- Add `sync-forward-forced`
- Update `processFile`
- Update configs
- Add `migrateConfig`
- Add `pathFormat`
- Reformat cases
- Reformat `processFile`
- Update config cases
- Add `log`
- Fix `config bad`

### Build

- Bump MSZV to 0.15.1
- Update fingerprint
- Bump `cova` to `08d92ce`

## [0.4.0] - 2025-09-30

### Bug Fixes

- Update summary
- Handle file permissions
- Set config size
- Update `example_config`
- Set initial delay
- Update `description`
- Update I/O
- Update `opt_usage`
- Update for zig 0.15
- Update arrays

### Documentation

- Add `Usage`
- Add `Configuration`

### Features

- Add validator
- Add backups
- Add `purge` command
- Add progress status

### Operations

- Bump zig to 0.15.1
- Update `coverage`

### Testing

- Improve `validate`
- Fix config
- Update runner
- Fix `sync-back`

### Build

- Update `cova` + `ghext`
- Add `integration_tests_mod`
- Fix coverage

## [0.3.0] - 2025-09-21

### Bug Fixes

- [**breaking**] Rename errors
- Switch to gpa
- Catch template errors
- Fix meta file path
- Switch to `std.fs.Dir.walk()`
- Fix `dotfile.lastMod()`
- Fix file errors
- Get stderr
- Use absolute template path
- Fix `lastMod()`
- Keep relative source string
- Improve write ops
- Improve change detection
- Drop `fs.realpathAlloc()`
- Properly handle first sync
- Catch empty templates

### Features

- Support env vars

### Miscellaneous tasks

- Ignore `dest*`

### Refactor

- Fix signatures
- Define tag
- Drop redundant `len`

### Styling

- Fix formatting

### Testing

- Add token tests
- Ignore `dest`
- Add `processFile`
- Fix unit cases
- Fix `sync`
- Fix merge step
- Add `sync-dry`
- Add config cases
- Fix `processFile`
- Add `sync-back`
- Add binary file
- Fix `sync-dry`
- Add `blocks-mixed`
- Add `parseTag`
- Add `parseBody`
- Add trimming cases
- Add `indexOfTag`
- Add `nextTag`
- Add `splitWhitespace`
- Add `extractChangeChunk`
- Add `findAnchorLiteral`
- Fix `sync` cases
- Add `copyWithWhitespace`
- Add `normalizeTrailing`
- Add `evalIfGroup`
- Add `evalCondition`
- Merge cases

## [0.2.0] - 2025-09-12

### Bug Fixes

- Handle relative paths
- Fix linux paths
- Change json options
- Add newline to stdout

### Features

- Add `json` option
- Add `bootstrap` command
- Add platform-specific ignore list
- [**breaking**] Add ignore list

### Miscellaneous tasks

- Ignore kcov

### Operations

- Fix `release` name
- Update label list

### Refactor

- `rendered` -> `render`

### Testing

- Add `sync`

### Build

- Fix coverage

## [0.1.0] - 2025-09-09

### Bug Fixes

- Handle missing meta
- Indicate `dry-run`
- Increase template file buffer
- Correct input enum
- Move sync files to datadir
- Add separator
- Clone submodules
- Drop `evalIfBlock()`
- Set stdout prints
- Improve stdout prints
- Ignore changelog
- Set file size
- Enforce file size type
- Improve diff/raw format
- Improve copy output
- Handle rendered conflicts
- Handle multiblocks

### Documentation

- Add readme
- Add roadmap
- Fix md
- Update `Conditionals`
- Update roadmap
- Update example
- Update `init` description
- Roadmap backups
- Update description
- Add header
- Close roadmap items
- Move roadmap

### Features

- Add directory scanner
- Template mechanics
- Add `recordLastSync()`
- Process sync records
- Add `lastMod()`
- Add `reverseTemplate()`
- Expose template functions
- Add `cli`
- Add assets
- Add config infrastructure
- Add options
- Add `dry-run`
- Check binary data
- Add `init` subcommand
- Change template syntax
- Rewrite engine
- Handle inlined templates
- Add file count
- Add `SYSTEM.hostname`
- Add `SYSTEM.arch`
- Add `config` option
- Add colors
- Add verbose mode

### Miscellaneous tasks

- Add license
- Add gitignore
- Ignore docs
- Move library
- Add changelog

### Operations

- Add integration files
- Enable test coverage
- Bump actions/attest-build-provenance from 2 to 3
- Add library label
- Deploy docs
- Fix ghp permissions
- Bump actions/labeler from 5 to 6
- Update labels
- Add `cli` label

### Refactor

- Optimize template functions
- Move `Config`
- Move `Dotfile`
- Move `main` functions
- Move `getUserInput()`
- Move `dotfile` functions

### Styling

- Fix formatting
- Fix formatting
- Fix missing newline
- Fix print formatting

### Testing

- Add linux cases
- Add `mixed`
- Add inline cases
- Add `reverseTemplate`
- Add block cases

### Build

- Add dependencies
- Add `clean` step
- Fix man page section
- Add `docs` step
- Edit `docs` step
- Update fingerprint


