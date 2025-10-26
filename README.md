# `dfs`
[![CI](https://github.com/charlesrocket/dfs/actions/workflows/ci.yml/badge.svg?branch=trunk)](https://github.com/charlesrocket/dfs/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/charlesrocket/dfs/branch/trunk/graph/badge.svg)](https://codecov.io/gh/charlesrocket/dfs)

This is a configuration (dotfiles) manager with a template engine and a true 2-way synchronization. It uses a `git` repository as a configuration source and mirrors its content into a destination directory (usually `$HOME`). Any changes in the rendered file are translated back into the template.

## Compilation

```sh
zig build --release=fast
```

## Usage

`dfs -h`

### Configuration

```zig
.{
    .repository = "https://github.com/charlesrocket/dotfiles",
    .source = "$HOME/src/dotfiles",
    .target = "$HOME",
    .logging = false,
    .notifications = true,
    .ignore_list = .{},
}
```

### Template syntax

```
# TEST
val="{> if SYSTEM.hostname == target <}target_val{> else <}none{> end <}"
{> if SYSTEM.os == freebsd <}
val="Foo"
{> elif SYSTEM.os == openbsd <}
val="Bar"
{> else <}
val="Zoot"
{> end <}
```

## [Roadmap](https://github.com/users/charlesrocket/projects/8)
