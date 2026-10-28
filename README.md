# ukubi-ci

Reusable GitHub Actions workflows (`on: workflow_call`) and composite actions
shared by the ukubi app repos: image build, push and tag bump; Go, Bun and Rust
checks; the commit-trailer check.

App repos call them pinned by commit sha:

```yaml
uses: MohammadBnei/ukubi-ci/.github/workflows/<name>.yml@<40-char sha>
```

Each workflow documents its inputs below as it lands.
