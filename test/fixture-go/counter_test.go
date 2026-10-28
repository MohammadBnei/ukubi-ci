package counter

import (
	"sync"
	"testing"
)

func TestAddConcurrent(t *testing.T) {
	var c Counter
	var wg sync.WaitGroup
	for range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			c.Add(1)
		}()
	}
	wg.Wait()
	if got := c.Value(); got != 8 {
		t.Fatalf("Value() = %d, want 8", got)
	}
}
