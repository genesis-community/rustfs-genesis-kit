package spec_test

import (
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"

	. "github.com/genesis-community/testkit/v2/testing"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	gtypes "github.com/onsi/gomega/types"
)

var _ = BeforeSuite(func() {
	_, filename, _, _ := runtime.Caller(0)
	KitDir, _ = filepath.Abs(filepath.Join(filepath.Dir(filename), "../"))

	// Every genesis command probes the stub director, which refuses the
	// connection. Genesis arms a GENESIS_NETWORK_TIMEOUT alarm for that probe
	// and leaves it armed when the connect fails, so a command still running
	// when it fires dies with SIGALRM. The default of 10 seconds is shorter
	// than an ocfp check takes on a busy machine.
	if os.Getenv("GENESIS_NETWORK_TIMEOUT") == "" {
		os.Setenv("GENESIS_NETWORK_TIMEOUT", "600")
	}
})

// refused matches the combined output of a genesis command that printed the
// given message and then exited non-zero. testkit appends
// "process: '<command>' exited with: <code>" to that output. Genesis wraps
// long messages to the terminal width, so each space in the message matches
// any run of whitespace, line breaks and indentation included.
func refused(message string) gtypes.GomegaMatcher {
	words := strings.Fields(message)
	for i, word := range words {
		words[i] = regexp.QuoteMeta(word)
	}
	return And(
		MatchRegexp(strings.Join(words, `\s+`)),
		MatchRegexp(`exited with: [1-9][0-9]*\n`),
	)
}

var _ = Describe("RustFS Kit", func() {

	Describe("standalone", func() {
		Test(Environment{
			Name:        "base",
			CloudConfig: "aws",
			CPI:         "aws",
		})
		Test(Environment{
			Name:        "single-ip",
			CloudConfig: "aws",
			CPI:         "aws",
		})
		Test(Environment{
			Name:        "cluster-ips",
			CloudConfig: "aws",
			CPI:         "aws",
		})
	})

	// Peers verify each other's API certificate by IP address, and Genesis
	// generates it before BOSH assigns addresses from the cloud config.  The
	// blueprint therefore refuses a cluster without explicit addresses, and
	// any address list the certificate could not name.
	Describe("cluster addresses", func() {
		Test(Environment{
			Name:        "cluster-without-ips",
			CloudConfig: "aws",
			CPI:         "aws",
			OutputMatchers: OutputMatchers{
				GenesisAddSecrets: refused("to list the static IP address of every node"),
				GenesisCheck:      refused("to list the static IP address of every node"),
				GenesisManifest:   refused("to list the static IP address of every node"),
			},
		})
		Test(Environment{
			Name:        "instances-without-ips",
			CloudConfig: "aws",
			CPI:         "aws",
			OutputMatchers: OutputMatchers{
				GenesisAddSecrets: refused("to list the static IP address of every node"),
				GenesisCheck:      refused("to list the static IP address of every node"),
				GenesisManifest:   refused("to list the static IP address of every node"),
			},
		})
		Test(Environment{
			Name:        "two-ips",
			CloudConfig: "aws",
			CPI:         "aws",
			OutputMatchers: OutputMatchers{
				GenesisAddSecrets: refused("refuses to deploy exactly two nodes"),
				GenesisCheck:      refused("refuses to deploy exactly two nodes"),
				GenesisManifest:   refused("refuses to deploy exactly two nodes"),
			},
		})
		Test(Environment{
			Name:        "ips-instances-mismatch",
			CloudConfig: "aws",
			CPI:         "aws",
			OutputMatchers: OutputMatchers{
				GenesisAddSecrets: refused("lists 3 addresses, but"),
				GenesisCheck:      refused("lists 3 addresses, but"),
				GenesisManifest:   refused("lists 3 addresses, but"),
			},
		})
		Test(Environment{
			Name:        "cluster-ip-range",
			CloudConfig: "aws",
			CPI:         "aws",
			OutputMatchers: OutputMatchers{
				GenesisAddSecrets: refused("must be a single IPv4 or IPv6 address"),
				GenesisCheck:      refused("must be a single IPv4 or IPv6 address"),
				GenesisManifest:   refused("must be a single IPv4 or IPv6 address"),
			},
		})
		Test(Environment{
			Name:        "cluster-too-many-ips",
			CloudConfig: "aws",
			CPI:         "aws",
			OutputMatchers: OutputMatchers{
				GenesisAddSecrets: refused("can name at most 16 static IP addresses"),
				GenesisCheck:      refused("can name at most 16 static IP addresses"),
				GenesisManifest:   refused("can name at most 16 static IP addresses"),
			},
		})
	})

	// Under ocfp the rustfs_ip reservations decide the addresses, and
	// params.ocfp_instances decides how many to use.  The blueprint refuses
	// params.ips and params.instances there, because the ocfp fragment would
	// silently replace them.
	Describe("ocfp", func() {
		Test(Environment{
			Name:        "ocfp-mgmt",
			CloudConfig: "aws-ocfp",
			CPI:         "aws",
		})
		Test(Environment{
			Name:        "ocfp-cluster",
			CloudConfig: "aws-ocfp-cluster",
			CPI:         "aws",
		})
		Test(Environment{
			Name:        "ocfp-ips",
			CloudConfig: "aws-ocfp-ips",
			CPI:         "aws",
			OutputMatchers: OutputMatchers{
				GenesisAddSecrets: refused("reservations, so it ignores params.ips."),
				GenesisCheck:      refused("reservations, so it ignores params.ips."),
				GenesisManifest:   refused("reservations, so it ignores params.ips."),
			},
		})
		Test(Environment{
			Name:        "ocfp-instances",
			CloudConfig: "aws-ocfp-instances",
			CPI:         "aws",
			OutputMatchers: OutputMatchers{
				GenesisAddSecrets: refused("reservations, so it ignores params.instances."),
				GenesisCheck:      refused("reservations, so it ignores params.instances."),
				GenesisManifest:   refused("reservations, so it ignores params.instances."),
			},
		})
		Test(Environment{
			Name:        "ocfp-pair",
			CloudConfig: "aws-ocfp-pair",
			CPI:         "aws",
			OutputMatchers: OutputMatchers{
				GenesisAddSecrets: refused("refuses to deploy exactly two nodes"),
				GenesisCheck:      refused("refuses to deploy exactly two nodes"),
				GenesisManifest:   refused("refuses to deploy exactly two nodes"),
			},
		})
	})

	// The resolute feature moves every stemcell to ubuntu-resolute and pins
	// bpm 1.4.41. The blueprint refuses a stemcell os that disagrees with the
	// feature, so add-secrets, check, and manifest all stop before rendering.
	Describe("resolute", func() {
		Test(Environment{
			Name:        "resolute",
			CloudConfig: "aws",
			CPI:         "aws",
		})
		Test(Environment{
			Name:        "resolute-mgmt",
			CloudConfig: "aws-resolute-mgmt",
			CPI:         "aws",
		})
		Test(Environment{
			Name:        "resolute-route-registrar",
			CloudConfig: "aws",
			CPI:         "aws",
			Exodus:      "resolute-route-registrar",
		})
		Test(Environment{
			Name:        "resolute-wrong-stemcell-os",
			CloudConfig: "aws",
			CPI:         "aws",
			OutputMatchers: OutputMatchers{
				GenesisAddSecrets: refused("stemcell os to"),
				GenesisCheck:      refused("stemcell os to"),
				GenesisManifest:   refused("stemcell os to"),
			},
		})
		Test(Environment{
			Name:        "resolute-stemcell-without-feature",
			CloudConfig: "aws",
			CPI:         "aws",
			OutputMatchers: OutputMatchers{
				GenesisAddSecrets: refused("Enable the feature and remove that parameter"),
				GenesisCheck:      refused("Enable the feature and remove that parameter"),
				GenesisManifest:   refused("Enable the feature and remove that parameter"),
			},
		})
	})
})
