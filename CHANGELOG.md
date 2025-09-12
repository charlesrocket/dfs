# Changelog

All notable changes to this project will be documented in this file.

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


