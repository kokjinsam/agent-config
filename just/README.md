# Kok Jin Sam's Just Workflow

This is a personal `just` command surface for polyglot monorepos. It is not a
general-purpose `just` framework.

## Install

From a consuming repository root:

```bash
curl -fsSL https://raw.githubusercontent.com/kokjinsam/agent-config/main/just/bootstrap | bash
```

Then import the managed workflow from the local `Justfile` and keep the default
recipe in that root file:

```just
import? '.just/kokjinsam.just'

default: help
```

The bootstrap installs managed workflow files under `.just/`:

```text
.just/kokjinsam.just
.just/bin/workflow
.just/commands/*
.just/lib/*
```

Regression tests for the shared workflow live only in `agent-config`:

```bash
bash just/tests/check_scripts
```

## Repository Config

Each consuming repository owns its local `just.yaml`. The shared scripts read it
to discover app paths and tool versions:

```yaml
apps:
  umber:
    path: apps/umber
  workspace:
    path: apps/workspace
  website:
    path: apps/website

tools:
  tla: "1.8.0"
  alloy: "6.2.0"
```

## Updating

Re-run the bootstrap from the consuming repository root. To install from a
specific branch, tag, or commit:

```bash
KOKJINSAM_JUST_REF=v0.1.0 \
  curl -fsSL https://raw.githubusercontent.com/kokjinsam/agent-config/main/just/bootstrap | bash
```

For local validation from a consuming repository root against a local
`agent-config` checkout:

```bash
KOKJINSAM_JUST_BASE_URL=file:///Users/sammkj/Developer/agent-config/just \
  bash /Users/sammkj/Developer/agent-config/just/bootstrap
```
