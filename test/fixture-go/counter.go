// Package counter is go-checks.yml's self-test fixture: gofmt-clean, vet-clean,
// and a test that exercises a goroutine under -race.
package counter

import "sync"

// Counter is safe for concurrent use.
type Counter struct {
	mu sync.Mutex
	n  int
}

// Add adds d.
func (c *Counter) Add(d int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.n += d
}

// Value returns the current count.
func (c *Counter) Value() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.n
}
