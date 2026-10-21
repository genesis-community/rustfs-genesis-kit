package spec_test

// RustFS serves https only, so gorouter must reach it over TLS.  This spec
// reads the rendered route-registrar manifest and proves that every route
// registers tls_port with the certificate name gorouter checks, and none
// registers a plain port.

import (
	"os"
	"path/filepath"

	. "github.com/genesis-community/testkit/v2/testing"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"gopkg.in/yaml.v3"
)

var _ = Describe("route-registrar routes", func() {
	It("registers every route on tls_port with the API certificate name", func() {
		data, err := os.ReadFile(filepath.Join(KitDir, "spec", "results", "resolute-route-registrar.yml"))
		Expect(err).ToNot(HaveOccurred())

		var manifest struct {
			InstanceGroups []struct {
				Name string `yaml:"name"`
				Jobs []struct {
					Name       string `yaml:"name"`
					Properties struct {
						RouteRegistrar struct {
							Routes []map[string]interface{} `yaml:"routes"`
							Host   interface{}              `yaml:"host"`
						} `yaml:"route_registrar"`
					} `yaml:"properties"`
				} `yaml:"jobs"`
			} `yaml:"instance_groups"`
		}
		Expect(yaml.Unmarshal(data, &manifest)).To(Succeed())

		var routes []map[string]interface{}
		for _, group := range manifest.InstanceGroups {
			if group.Name != "rustfs" {
				continue
			}
			for _, job := range group.Jobs {
				if job.Name == "route_registrar" {
					routes = job.Properties.RouteRegistrar.Routes
					Expect(job.Properties.RouteRegistrar.Host).To(BeNil(), "route_registrar.host is not a property of the job")
				}
			}
		}
		Expect(routes).To(HaveLen(2))

		ports := map[string]int{"rustfs-s3-api": 9000, "rustfs-s3-console": 9001}
		for _, route := range routes {
			name, _ := route["name"].(string)
			Expect(ports).To(HaveKey(name))
			Expect(route).ToNot(HaveKey("port"), "route %s must not register a plain port", name)
			Expect(route["tls_port"]).To(Equal(ports[name]), "route %s tls_port", name)
			Expect(route["server_cert_domain_san"]).To(Equal("rustfs.bosh"), "route %s server_cert_domain_san", name)
		}
	})
})
