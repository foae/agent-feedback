package envutil

import (
	"log"
	"log/slog"
	"net"
	"net/url"
	"os"
)

// ReplaceHost checks for a companion environment variable named envName+"_HOST".
// If set, it parses value as a URL and replaces only the hostname portion,
// preserving scheme, credentials, port, path, and query parameters.
// The _HOST value must be a bare hostname (no port). If the operator accidentally
// includes a port (e.g. "host:5432"), the port portion is stripped to avoid
// producing an invalid double-port like "host:5432:5432".
// If the companion variable is not set or empty, value is returned unchanged.
// If the override is set but the URL cannot be parsed, the process exits
// (fail-closed: a configured override that can't be applied is a deploy error).
func ReplaceHost(envName, value string) string {
	newHost := os.Getenv(envName + "_HOST")
	if newHost == "" {
		return value
	}

	u, err := url.Parse(value)
	if err != nil {
		log.Fatalf("envutil: %s_HOST is set but %s value cannot be parsed as URL", envName, envName)
	}

	if h, _, err := net.SplitHostPort(newHost); err == nil {
		newHost = h
	}

	oldHost := u.Hostname()
	port := u.Port()

	if port != "" {
		u.Host = newHost + ":" + port
	} else {
		u.Host = newHost
	}

	replaced := u.String()

	slog.Info("envutil: replaced hostname in env var",
		"env", envName, "old_host", oldHost, "new_host", newHost)

	return replaced
}
