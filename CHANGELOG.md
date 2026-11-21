# Changelog

## 0.9.0 - 2026-11-21

### Features

- **dev-db:** Composite actions for disposable IntegreSQL databases (ADR-0088) (#13)

### Fixes

- Event gates read the caller's event on Forgejo (#15)

## 0.8.0 - 2026-11-20

### Features

- Run the workflows on Forgejo Actions as well as GitHub (#14)

## 0.7.0 - 2026-11-17

### Features

- **ci:** Run every workflow on the self-hosted build runner (#12)

## 0.6.0 - 2026-11-14

### Features

- **image:** Push-default-branch-only and extra-tags inputs (#11)

## 0.5.0 - 2026-11-14

### Features

- **image:** Deploy input and deploy.yml for atomic multi-image bumps (#10)

## 0.4.0 - 2026-11-14

### Features

- **checks:** Govulncheck input for go-checks, lint-script input for bun-checks (#9)

### Fixes

- **image:** Cap job runtimes and keep only the registry password (#8)

## 0.3.0 - 2026-11-14

### Features

- **image:** Version build arg, cancel-in-progress and values-files inputs (#7)

## 0.2.2 - 2026-11-14

### Fixes

- **image:** Pin pushed digest so a same-commit rebuild deploys (#6)

## 0.2.1 - 2026-10-28

### Fixes

- **standard-status:** Green CI, no leaked clones, tighter rules (#5)

## 0.2.0 - 2026-10-28

### Features

- Standard status generator for §18/§19 (#4)

## 0.1.0 - 2026-10-28

### Features

- Reusable image workflow — buildah build, push, tag bump, masked Infisical OIDC (#1)
- Reusable checks — go, bun, rust, image-build, trailers (#2)
- Reusable release workflow with git-cliff (#3)

### Other

- Bootstrap ukubi-ci with README, MIT license and gitignore

