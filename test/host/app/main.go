// Test fixtures for test/host/run.sh, one static binary in two roles:
//   serve: an HTTP app answering /health with 200, or 503 when HEALTH=fail
//   probe: a stand-in for curl in pie-deploy's health checks (`probe ... URL`, last
//          argument is the URL; exit 0 on 2xx), so the tests need no registry
package main

import (
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

func main() {
	if filepath.Base(os.Args[0]) == "probe" || (len(os.Args) > 1 && os.Args[1] == "probe") {
		client := http.Client{Timeout: 5 * time.Second}
		resp, err := client.Get(os.Args[len(os.Args)-1])
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		resp.Body.Close()
		if resp.StatusCode < 200 || resp.StatusCode > 299 {
			os.Exit(22) // curl -f's exit code
		}
		return
	}
	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		if os.Getenv("HEALTH") == "fail" {
			http.Error(w, "unhealthy", http.StatusServiceUnavailable)
			return
		}
		fmt.Fprintf(w, "ok %s\n", os.Getenv("RELEASE"))
	})
	if err := http.ListenAndServe(":8080", nil); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
