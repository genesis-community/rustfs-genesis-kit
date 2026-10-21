package spec_test

// These specs prove that the API certificate Genesis generates names every
// static IP the blueprint assigns.  testkit replaces every vault value with
// a placeholder, so its rendered manifests cannot show a certificate's
// names.  Each spec here runs `genesis add-secrets` against a vault of its
// own and reads the certificate back.

import (
	"bytes"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	. "github.com/genesis-community/testkit/v2/testing"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"gopkg.in/yaml.v3"
)

// sandbox is a Genesis deployments repository wired to an in-memory vault
// that the sandbox started and owns.
type sandbox struct {
	env   string
	home  string
	vault *exec.Cmd
}

// newSandbox starts a vault, loads the environment's spec vault stub into
// it without the environment's own secrets, and creates a deployments
// repository that holds the environment file.
func newSandbox(env string) *sandbox {
	home, err := os.MkdirTemp("", "rustfs-api-cert-*")
	Expect(err).ToNot(HaveOccurred())
	s := &sandbox{env: env, home: home}
	DeferCleanup(s.cleanup)

	s.startVault()
	s.importStub()

	s.run("git", "config", "--global", "user.name", "Spec Runner")
	s.run("git", "config", "--global", "user.email", "spec@example.com")
	s.genesis("init", "--link-dev-kit", KitDir, "--vault", s.vaultTarget(),
		"--cwd", s.home, "--directory", "deployments", "rustfs")
	s.copyEnvironment(filepath.Join(KitDir, "spec", "deployments", env+".yml"))
	return s
}

// startVault runs `safe local --memory` on a free port in its own process
// group, so that cleanup stops exactly the processes this sandbox started.
func (s *sandbox) startVault() {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	Expect(err).ToNot(HaveOccurred())
	port := listener.Addr().(*net.TCPAddr).Port
	Expect(listener.Close()).To(Succeed())

	s.vault = exec.Command("safe", "local", "--memory", "--port", fmt.Sprintf("%d", port))
	s.vault.Env = s.environ()
	s.vault.Stdout = GinkgoWriter
	s.vault.Stderr = GinkgoWriter
	s.vault.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	Expect(s.vault.Start()).To(Succeed())

	Eventually(func() error {
		cmd := exec.Command("safe", "get", "secret/handshake")
		cmd.Env = s.environ()
		return cmd.Run()
	}, "30s", "500ms").Should(Succeed())
}

func (s *sandbox) cleanup() {
	if s.vault != nil && s.vault.Process != nil {
		_ = syscall.Kill(-s.vault.Process.Pid, syscall.SIGKILL)
		_ = s.vault.Wait()
	}
	_ = os.RemoveAll(s.home)
}

// importStub loads the environment's spec vault stub, which carries the
// director exodus and ocfp config data that the blueprint reads.  The stub's
// entries under the environment's own path are placeholders, so they are
// left out and add-secrets generates real values in their place.
func (s *sandbox) importStub() {
	raw, err := os.ReadFile(filepath.Join(KitDir, "spec", "vault", s.env+".yml"))
	if os.IsNotExist(err) {
		return
	}
	Expect(err).ToNot(HaveOccurred())

	stub := map[string]map[string]string{}
	Expect(yaml.Unmarshal(raw, &stub)).To(Succeed())
	for path := range stub {
		if strings.HasPrefix(path, s.base()+"/") {
			delete(stub, path)
		}
	}
	if len(stub) == 0 {
		return
	}

	data, err := json.Marshal(stub)
	Expect(err).ToNot(HaveOccurred())
	cmd := exec.Command("safe", "import")
	cmd.Env = s.environ()
	cmd.Stdin = bytes.NewReader(data)
	out, err := cmd.CombinedOutput()
	Expect(err).ToNot(HaveOccurred(), string(out))
}

// base is the vault path of the environment's secrets.
func (s *sandbox) base() string {
	return fmt.Sprintf("secret/%s/rustfs", strings.ReplaceAll(s.env, "-", "/"))
}

func (s *sandbox) vaultTarget() string {
	raw, err := os.ReadFile(filepath.Join(s.home, ".saferc"))
	Expect(err).ToNot(HaveOccurred())
	config := struct {
		Current string `yaml:"current"`
	}{}
	Expect(yaml.Unmarshal(raw, &config)).To(Succeed())
	Expect(config.Current).ToNot(BeEmpty())
	return config.Current
}

func (s *sandbox) copyEnvironment(source string) {
	raw, err := os.ReadFile(source)
	Expect(err).ToNot(HaveOccurred())
	s.writeEnvironment(raw)
}

func (s *sandbox) writeEnvironment(content []byte) {
	target := filepath.Join(s.home, "deployments", s.env+".yml")
	Expect(os.WriteFile(target, content, 0644)).To(Succeed())
}

func (s *sandbox) environ() []string {
	return append(os.Environ(),
		"HOME="+s.home,
		"GENESIS_TESTING=yes",
		"GENESIS_TESTING_BOSH_CPI=aws",
		"GENESIS_BOSH_VERIFIED="+s.env,
	)
}

// run executes a command in the sandbox and fails the spec when it exits
// non-zero.  It returns the combined output.
func (s *sandbox) run(name string, args ...string) string {
	out, code := s.try(name, args...)
	Expect(code).To(Equal(0), "%s %s failed:\n%s", name, strings.Join(args, " "), out)
	return out
}

// try executes a command in the sandbox and returns its combined output and
// exit code.
func (s *sandbox) try(name string, args ...string) (string, int) {
	cmd := exec.Command(name, args...)
	cmd.Env = s.environ()
	cmd.Dir = s.home
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	err := cmd.Run()
	if _, exited := err.(*exec.ExitError); err != nil && !exited {
		Fail(fmt.Sprintf("could not run %s: %s", name, err))
	}
	fmt.Fprintf(GinkgoWriter, "[%s] %s %s\n%s", s.env, name, strings.Join(args, " "), buf.String())
	return buf.String(), cmd.ProcessState.ExitCode()
}

func (s *sandbox) genesis(args ...string) string {
	return s.run("genesis", args...)
}

func (s *sandbox) deployments() string {
	return filepath.Join(s.home, "deployments")
}

// apiCertificate reads the API certificate back from the vault.
func (s *sandbox) apiCertificate() *x509.Certificate {
	out := s.run("safe", "get", s.base()+"/certs/api:certificate")
	block, _ := pem.Decode([]byte(out))
	Expect(block).ToNot(BeNil(), "certs/api holds no PEM certificate:\n%s", out)
	cert, err := x509.ParseCertificate(block.Bytes)
	Expect(err).ToNot(HaveOccurred())
	return cert
}

// names lists a certificate's DNS and IP subject alternative names, sorted.
func names(cert *x509.Certificate) []string {
	all := append([]string{}, cert.DNSNames...)
	for _, ip := range cert.IPAddresses {
		all = append(all, ip.String())
	}
	sort.Strings(all)
	return all
}

// sorted returns a sorted copy, so expectations can list names in any order.
func sorted(in ...string) []string {
	out := append([]string{}, in...)
	sort.Strings(out)
	return out
}

func apiCertNamesFor(env string, expected ...string) {
	It(fmt.Sprintf("names %s in the API certificate of %s", strings.Join(expected, ", "), env), func() {
		s := newSandbox(env)
		s.genesis("add-secrets", "--cwd", s.deployments(), env)
		cert := s.apiCertificate()
		Expect(cert.Subject.CommonName).To(Equal("rustfs.bosh"))
		Expect(names(cert)).To(Equal(sorted(expected...)))
	})
}

var _ = Describe("API certificate names", func() {
	apiCertNamesFor("base", "rustfs.bosh", "127.0.0.1")
	apiCertNamesFor("single-ip", "rustfs.bosh", "127.0.0.1", "10.99.1.40")
	apiCertNamesFor("cluster-ips", "rustfs.bosh", "127.0.0.1",
		"10.99.1.30", "10.99.2.30", "10.99.3.30")
	apiCertNamesFor("ocfp-mgmt", "rustfs.bosh", "127.0.0.1",
		"10.0.2.190", "10.0.3.190", "10.0.4.190")
	apiCertNamesFor("resolute-mgmt", "rustfs.bosh", "127.0.0.1",
		"10.0.2.190", "10.0.3.190", "10.0.4.190")

	// The IP list can grow after the certificate exists.  check-secrets
	// reports the missing address, and rotating the certificate renews it
	// with the full list on its existing key.
	It("brings the API certificate up to date after params.ips changes", func() {
		s := newSandbox("cluster-ips")
		s.genesis("add-secrets", "--cwd", s.deployments(), "cluster-ips")
		before := s.apiCertificate()

		raw, err := os.ReadFile(filepath.Join(KitDir, "spec", "deployments", "cluster-ips.yml"))
		Expect(err).ToNot(HaveOccurred())
		grown := strings.Replace(string(raw), "  - 10.99.3.30\n", "  - 10.99.3.30\n  - 10.99.1.31\n", 1)
		Expect(grown).ToNot(Equal(string(raw)))
		s.writeEnvironment([]byte(grown))

		out, _ := s.try("genesis", "check-secrets", "--no-color", "--cwd", s.deployments(), "cluster-ips")
		Expect(out).To(MatchRegexp(`missing:\s+10\.99\.1\.31`))

		s.genesis("rotate-secrets", "--cwd", s.deployments(), "-y", "cluster-ips", "certs/api")
		after := s.apiCertificate()
		Expect(names(after)).To(Equal(sorted("rustfs.bosh", "127.0.0.1",
			"10.99.1.30", "10.99.2.30", "10.99.3.30", "10.99.1.31")))
		Expect(after.RawSubjectPublicKeyInfo).To(Equal(before.RawSubjectPublicKeyInfo))
		Expect(after.NotAfter.After(time.Now())).To(BeTrue())
	})
})
