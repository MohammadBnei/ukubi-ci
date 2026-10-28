// Command standard-status reports which ukubi Code Standard mechanisms each
// repo's origin default branch has, as the markdown tables of §18 and §19.
//
//	go run github.com/MohammadBnei/ukubi-ci/standard-status@<sha> owner/repo...
//
// Needs gh authenticated for the repos (it clones with gh). Reads no token.
package main

import (
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

type rule struct {
	files func(path string) bool
	re    *regexp.Regexp
	label func(path string, m []string) string // nil: the path
}

type check struct {
	name, sec string
	rules     []rule
}

func ext(e string) func(string) bool {
	return func(p string) bool { return strings.HasSuffix(p, e) && !strings.HasSuffix(p, "_test.go") }
}

func testGo(p string) bool { return strings.HasSuffix(p, "_test.go") }

func workflow(p string) bool {
	return strings.HasPrefix(p, ".github/workflows/") && (strings.HasSuffix(p, ".yml") || strings.HasSuffix(p, ".yaml"))
}

func src(p string) bool { return !testGo(p) && !workflow(p) && !strings.HasSuffix(p, ".md") }

func r(files func(string) bool, re string) rule {
	return rule{files: files, re: regexp.MustCompile(re)}
}

var checks = []check{
	{"Env-ban test", "§5", []rule{r(testGo, `\b(TestEnvBan|TestNoEnv)\b`)}},
	{"Key-registry test", "§6", []rule{r(testGo, `\b(TestErrKeys|TestKeys)\b`)}},
	{"JSON logger", "§7", []rule{
		r(ext(".go"), `slog\.NewJSONHandler|telemetry\.NewLogger`),
		r(ext(".rs"), `(?s)tracing_subscriber.*\.json\(\)`),
	}},
	{"ErrorLog", "§7", []rule{r(ext(".go"), `ErrorLog:\s*\S`)}},
	{"Traces opt-in", "§7", []rule{r(src, `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`)}},
	{"/metrics exposition test", "§7", []rule{r(testGo, `TestMetricsExposition`)}},
	{"PR CI", "§9", []rule{r(workflow, `(?m)^on:.*\bpull_request\b|^\s*pull_request(_target)?\s*:|^\s*-\s*pull_request\s*$`)}},
	{"Trailer check", "§9", []rule{{workflow, regexp.MustCompile(`(ukubi-ci/\.github/workflows/trailers\.yml@)|noreply@anthropic\.com`),
		func(_ string, m []string) string {
			if m[1] != "" {
				return "ukubi-ci"
			}
			return "inline"
		}}}},
	{"Release workflow", "B3", []rule{r(workflow, `ukubi-ci/\.github/workflows/release\.yml@`)}},
	{"Tier line", "§19", []rule{{func(p string) bool { return p == "CLAUDE.md" }, regexp.MustCompile(`(?m)^Tier:\s*(\w+)`),
		func(_ string, m []string) string { return m[1] }}}},
}

const tierIdx = 9

// Result is one repo's outcome. Found[i] is the evidence for checks[i], "" if none.
type Result struct {
	Repo, Err, Head string
	Found           []string
}

// scan walks dir (skipping .git, vendor, node_modules, *.md except CLAUDE.md)
// and returns the first piece of evidence per check, in path order.
func scan(dir string) []string {
	found := make([]string, len(checks))
	_ = filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			switch d.Name() {
			case ".git", "vendor", "node_modules":
				return filepath.SkipDir
			}
			return nil
		}
		rel, _ := filepath.Rel(dir, p)
		rel = filepath.ToSlash(rel)
		if strings.HasSuffix(rel, ".md") && rel != "CLAUDE.md" {
			return nil
		}
		var body string
		for i, c := range checks {
			if found[i] != "" {
				continue
			}
			for _, ru := range c.rules {
				if !ru.files(rel) {
					continue
				}
				if body == "" {
					b, err := os.ReadFile(p)
					if err != nil {
						return nil
					}
					body = string(b)
				}
				if m := ru.re.FindStringSubmatch(body); m != nil {
					found[i] = rel
					if ru.label != nil {
						found[i] = ru.label(rel, m)
					}
					break
				}
			}
		}
		return nil
	})
	return found
}

func render(rs []Result) string {
	var b strings.Builder
	b.WriteString("### §18 Mechanisms\n\n| Mechanism | § | Has it | Not found |\n|---|---|---|---|\n")
	for i, c := range checks {
		var has, not []string
		for _, x := range rs {
			switch {
			case x.Err != "":
			case x.Found[i] != "":
				has = append(has, fmt.Sprintf("%s (%s)", x.Repo, x.Found[i]))
			default:
				not = append(not, x.Repo)
			}
		}
		fmt.Fprintf(&b, "| %s | %s | %s | %s |\n", c.name, c.sec, strings.Join(has, ", "), strings.Join(not, ", "))
	}
	b.WriteString("\n### §19 Repos\n\n| Repo | Tier | Head | Mechanisms |\n|---|---|---|---|\n")
	for _, x := range rs {
		if x.Err != "" {
			fmt.Fprintf(&b, "| %s | unreadable | %s | - |\n", x.Repo, x.Err)
			continue
		}
		n := 0
		for _, f := range x.Found {
			if f != "" {
				n++
			}
		}
		tier := x.Found[tierIdx]
		if tier == "" {
			tier = "-"
		}
		fmt.Fprintf(&b, "| %s | %s | %s | %d/%d |\n", x.Repo, tier, x.Head, n, len(checks))
	}
	return b.String()
}

func run(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	cmd.Stderr = nil
	out, err := cmd.Output()
	if err != nil {
		msg := err.Error()
		if ee, ok := err.(*exec.ExitError); ok {
			msg = strings.SplitN(strings.TrimSpace(string(ee.Stderr)), "\n", 2)[0]
		}
		return "", fmt.Errorf("%s", msg)
	}
	return strings.TrimSpace(string(out)), nil
}

func read(repo, tmp string) Result {
	dir := filepath.Join(tmp, strings.ReplaceAll(repo, "/", "_"))
	if _, err := run("gh", "repo", "clone", repo, dir, "--", "--depth", "1", "--single-branch", "-q"); err != nil {
		return Result{Repo: repo, Err: strings.ReplaceAll(err.Error(), "|", "/")}
	}
	br, e1 := run("git", "-C", dir, "rev-parse", "--abbrev-ref", "HEAD")
	sha, e2 := run("git", "-C", dir, "rev-parse", "HEAD")
	day, e3 := run("git", "-C", dir, "log", "-1", "--format=%cs")
	if e1 != nil || e2 != nil || e3 != nil {
		return Result{Repo: repo, Err: "git metadata unreadable"}
	}
	return Result{Repo: repo, Head: fmt.Sprintf("%s@%.12s %s", br, sha, day), Found: scan(dir)}
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: standard-status owner/repo...")
		os.Exit(2)
	}
	tmp, err := os.MkdirTemp("", "standard-status")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer os.RemoveAll(tmp)
	var rs []Result
	bad := false
	for _, repo := range os.Args[1:] {
		x := read(repo, tmp)
		bad = bad || x.Err != ""
		rs = append(rs, x)
	}
	fmt.Print(render(rs))
	if bad {
		os.Exit(1)
	}
}
