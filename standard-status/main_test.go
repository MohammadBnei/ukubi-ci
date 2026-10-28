package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func write(t *testing.T, dir, rel, body string) {
	t.Helper()
	p := filepath.Join(dir, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestScan(t *testing.T) {
	d := t.TempDir()
	write(t, d, "a_test.go", "func TestNoEnv(t *testing.T){}\nfunc TestKeys(t *testing.T){}\nfunc TestMetricsExposition(t *testing.T){}")
	write(t, d, "m.go", "h := slog.NewJSONHandler(w, nil)\nsrv := http.Server{ErrorLog: l}\nos.Getenv(\"OTEL_EXPORTER_OTLP_TRACES_ENDPOINT\")")
	write(t, d, ".github/workflows/ci.yml", "on:\n  pull_request:\njobs: {}")
	write(t, d, ".github/workflows/trailers.yml", "uses: MohammadBnei/ukubi-ci/.github/workflows/trailers.yml@abc")
	write(t, d, ".github/workflows/release.yml", "uses: MohammadBnei/ukubi-ci/.github/workflows/release.yml@abc")
	write(t, d, "CLAUDE.md", "# x\nTier: service. rest\n")
	want := []string{"a_test.go", "a_test.go", "m.go", "m.go", "m.go", "a_test.go",
		".github/workflows/ci.yml", "ukubi-ci", ".github/workflows/release.yml", "service"}
	if got := scan(d); !reflect.DeepEqual(got, want) {
		t.Fatalf("got %q\nwant %q", got, want)
	}

	n := t.TempDir() // near-misses and an empty-ish tree find nothing
	write(t, n, "README.md", "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT slog.NewJSONHandler")
	write(t, n, "m.go", "func TestNoEnv() {}") // test name in a non-test file
	write(t, n, "t_test.go", "slog.NewJSONHandler(")
	write(t, n, ".github/workflows/ci.yml", "on:\n  push:\n")
	write(t, n, ".github/workflows/trailers.yml", "jobs: {}")
	write(t, n, "sub/CLAUDE.md", "Tier: service")
	write(t, n, "CLAUDE.md", "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT")
	for i, g := range scan(n) {
		if g != "" {
			t.Errorf("%s: unexpected %q", checks[i].name, g)
		}
	}
}

func TestRender(t *testing.T) {
	full := make([]string, len(checks))
	for i := range full {
		full[i] = "x"
	}
	full[tierIdx] = "service"
	none := make([]string, len(checks))
	got := render([]Result{
		{Repo: "o/a", Head: "main@0123456789ab 2026-10-28", Found: full},
		{Repo: "o/b", Head: "main@ba9876543210 2026-10-27", Found: none},
		{Repo: "o/c", Err: "not found"},
	})
	want := `### §18 Mechanisms

| Mechanism | § | Has it | Not found |
|---|---|---|---|
| Env-ban test | §5 | o/a (x) | o/b |
| Key-registry test | §6 | o/a (x) | o/b |
| JSON logger | §7 | o/a (x) | o/b |
| ErrorLog | §7 | o/a (x) | o/b |
| Traces opt-in | §7 | o/a (x) | o/b |
| /metrics exposition test | §7 | o/a (x) | o/b |
| PR CI | §9 | o/a (x) | o/b |
| Trailer check | §9 | o/a (x) | o/b |
| Release workflow | B3 | o/a (x) | o/b |
| Tier line | §19 | o/a (service) | o/b |

### §19 Repos

| Repo | Tier | Head | Mechanisms |
|---|---|---|---|
| o/a | service | main@0123456789ab 2026-10-28 | 10/10 |
| o/b | - | main@ba9876543210 2026-10-27 | 0/10 |
| o/c | unreadable | not found | - |
`
	if got != want {
		t.Fatalf("got:\n%s\nwant:\n%s", got, want)
	}
}
