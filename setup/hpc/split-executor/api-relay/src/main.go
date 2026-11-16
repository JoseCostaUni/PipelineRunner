// split-relay: Kubernetes API relay for the split executor. One static binary, standard library only.
//
// The login node cannot open connections to the Kubernetes side; the Kubernetes side can SSH into the
// login node. So the API calls of Argo's init/wait (which run on the login node) are pulled:
//
//	split-relay login  on the login node: HTTPS endpoint for init/wait (holds each request open)
//	                   + control port, reached from the Kubernetes side through 'ssh -L'
//	                     GET /next          the next pending request (long poll)
//	                     POST /respond/<id> the real API's response, returned to the caller
//	split-relay agent  on the Kubernetes side: pulls the requests through the tunnel, sends them to
//	                   the real API (with the caller's own credentials) and posts the responses back
//
// Only the Kubernetes side opens connections. The TLS certificate comes from make-certs.sh (openssl).
package main

import (
	"bytes"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// Headers that belong to one connection, not to the request.
var hop = map[string]bool{"connection": true, "keep-alive": true, "proxy-connection": true,
	"transfer-encoding": true, "upgrade": true, "te": true, "trailer": true, "host": true,
	"content-length": true, "accept-encoding": true}

type relayRequest struct {
	ID      string            `json:"id"`
	Method  string            `json:"method"`
	Path    string            `json:"path"`
	Headers map[string]string `json:"headers"`
	Body    string            `json:"body"`
}

type relayResponse struct {
	Status  int               `json:"status"`
	Headers map[string]string `json:"headers"`
	Body    string            `json:"body"`
}

func logf(format string, a ...any) {
	fmt.Printf("%s %s\n", time.Now().Format("2006-01-02T15:04:05"), fmt.Sprintf(format, a...))
}

func flatten(h http.Header) map[string]string {
	out := map[string]string{}
	for k, v := range h {
		if !hop[strings.ToLower(k)] {
			out[k] = strings.Join(v, ", ")
		}
	}
	return out
}

func status(code int, msg string) []byte {
	b, _ := json.Marshal(map[string]any{"kind": "Status", "apiVersion": "v1", "status": "Failure", "message": msg, "code": code})
	return b
}

// ------------------------------------------------------------------------------ login side

type relay struct {
	pending chan *relayRequest
	mu      sync.Mutex
	waiting map[string]chan *relayResponse
	timeout time.Duration
}

func (r *relay) api(w http.ResponseWriter, req *http.Request) {
	body, _ := io.ReadAll(req.Body)
	id := make([]byte, 16)
	rand.Read(id)
	rid := hex.EncodeToString(id)
	ch := make(chan *relayResponse, 1)
	r.mu.Lock()
	r.waiting[rid] = ch
	r.mu.Unlock()
	defer func() { r.mu.Lock(); delete(r.waiting, rid); r.mu.Unlock() }()
	path := req.URL.RequestURI()
	r.pending <- &relayRequest{ID: rid, Method: req.Method, Path: path, Headers: flatten(req.Header),
		Body: base64.StdEncoding.EncodeToString(body)}
	select {
	case resp := <-ch:
		data, _ := base64.StdEncoding.DecodeString(resp.Body)
		for k, v := range resp.Headers {
			if !hop[strings.ToLower(k)] {
				w.Header().Set(k, v)
			}
		}
		w.WriteHeader(resp.Status)
		w.Write(data)
		logf("%s %s -> %d", req.Method, path, resp.Status)
	case <-time.After(r.timeout):
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusGatewayTimeout)
		w.Write(status(504, "api relay: no answer from the Kubernetes side"))
		logf("%s %s -> 504 (no answer from the Kubernetes side in %s)", req.Method, path, r.timeout)
	}
}

func (r *relay) ctl(w http.ResponseWriter, req *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	switch {
	case req.Method == http.MethodGet && req.URL.Path == "/next":
		deadline := time.After(20 * time.Second)
		for {
			select {
			case p := <-r.pending:
				r.mu.Lock()
				_, live := r.waiting[p.ID]
				r.mu.Unlock()
				if !live { // its caller already gave up: do not send it to the API late
					continue
				}
				json.NewEncoder(w).Encode(p)
			case <-deadline:
				w.WriteHeader(http.StatusNoContent)
			case <-req.Context().Done():
			}
			return
		}
	case req.Method == http.MethodGet && req.URL.Path == "/health":
		r.mu.Lock()
		n := len(r.waiting)
		r.mu.Unlock()
		json.NewEncoder(w).Encode(map[string]int{"pending": len(r.pending), "waiting": n})
	case req.Method == http.MethodPost && strings.HasPrefix(req.URL.Path, "/respond/"):
		var resp relayResponse
		if err := json.NewDecoder(req.Body).Decode(&resp); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		rid := strings.TrimPrefix(req.URL.Path, "/respond/")
		r.mu.Lock()
		ch, ok := r.waiting[rid]
		r.mu.Unlock()
		if !ok {
			w.WriteHeader(http.StatusGone) // the caller gave up already
			return
		}
		select {
		case ch <- &resp:
		default:
		}
		w.Write([]byte("{}"))
	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

func runLogin(args []string) error {
	fs := flag.NewFlagSet("login", flag.ExitOnError)
	apiPort := fs.Int("api-port", 16443, "HTTPS port for Argo's init/wait (127.0.0.1)")
	ctlPort := fs.Int("ctl-port", 16444, "control port for the agent, through ssh -L (127.0.0.1)")
	cert := fs.String("cert", "", "server certificate (make-certs.sh)")
	key := fs.String("key", "", "server key (make-certs.sh)")
	timeout := fs.Duration("timeout", 120*time.Second, "how long a request waits for the Kubernetes side")
	fs.Parse(args)
	if *cert == "" || *key == "" {
		return fmt.Errorf("--cert and --key are required")
	}
	r := &relay{pending: make(chan *relayRequest, 1024), waiting: map[string]chan *relayResponse{}, timeout: *timeout}
	ctl := &http.Server{Addr: fmt.Sprintf("127.0.0.1:%d", *ctlPort), Handler: http.HandlerFunc(r.ctl)}
	api := &http.Server{
		Addr:    fmt.Sprintf("127.0.0.1:%d", *apiPort),
		Handler: http.HandlerFunc(r.api),
		// HTTP/1.1 only: keeps the relay simple; client-go falls back to it.
		TLSNextProto: map[string]func(*http.Server, *tls.Conn, http.Handler){},
		TLSConfig:    &tls.Config{MinVersion: tls.VersionTLS12},
	}
	errc := make(chan error, 2)
	go func() { errc <- ctl.ListenAndServe() }()
	go func() { errc <- api.ListenAndServeTLS(*cert, *key) }()
	logf("api relay: API on https://%s, control on %s", api.Addr, ctl.Addr)
	return <-errc
}

// ------------------------------------------------------------------------------ Kubernetes side

func runAgent(args []string) error {
	fs := flag.NewFlagSet("agent", flag.ExitOnError)
	ctl := fs.String("ctl", "http://127.0.0.1:16444", "control port of the login side, through ssh -L")
	api := fs.String("api", "", "real Kubernetes API, e.g. https://192.168.104.4:6443")
	ca := fs.String("ca", "", "CA of the real API")
	fs.Parse(args)
	if *api == "" || *ca == "" {
		return fmt.Errorf("--api and --ca are required")
	}
	pem, err := os.ReadFile(*ca)
	if err != nil {
		return err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem) {
		return fmt.Errorf("no certificate in %s", *ca)
	}
	apiClient := &http.Client{Timeout: 60 * time.Second,
		Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}}}
	ctlClient := &http.Client{Timeout: 30 * time.Second}
	logf("api relay agent: %s -> %s", *ctl, *api)
	for {
		resp, err := ctlClient.Get(*ctl + "/next")
		if err != nil {
			logf("control port not reachable (%v); retrying in 3 s", err)
			time.Sleep(3 * time.Second)
			continue
		}
		if resp.StatusCode != http.StatusOK {
			resp.Body.Close()
			continue
		}
		var req relayRequest
		err = json.NewDecoder(resp.Body).Decode(&req)
		resp.Body.Close()
		if err != nil {
			logf("bad request from the control port: %v", err)
			continue
		}
		go handle(&req, *api, *ctl, apiClient, ctlClient)
	}
}

func handle(req *relayRequest, api, ctl string, apiClient, ctlClient *http.Client) {
	body, _ := base64.StdEncoding.DecodeString(req.Body)
	out := relayResponse{Headers: map[string]string{}}
	hr, err := http.NewRequest(req.Method, api+req.Path, bytes.NewReader(body))
	if err == nil {
		for k, v := range req.Headers {
			if !hop[strings.ToLower(k)] {
				hr.Header.Set(k, v)
			}
		}
		var resp *http.Response
		if resp, err = apiClient.Do(hr); err == nil {
			data, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			out.Status, out.Headers, out.Body = resp.StatusCode, flatten(resp.Header), base64.StdEncoding.EncodeToString(data)
		}
	}
	if err != nil { // API unreachable: tell the caller instead of letting it hang
		out.Status = http.StatusBadGateway
		out.Headers = map[string]string{"Content-Type": "application/json"}
		out.Body = base64.StdEncoding.EncodeToString(status(502, "api relay agent: "+err.Error()))
	}
	b, _ := json.Marshal(out)
	if r, err := ctlClient.Post(ctl+"/respond/"+req.ID, "application/json", bytes.NewReader(b)); err == nil {
		r.Body.Close()
	}
	logf("%s %s -> %d", req.Method, req.Path, out.Status)
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: split-relay login|agent [flags]   (split-relay <cmd> -h for the flags)")
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "login":
		err = runLogin(os.Args[2:])
	case "agent":
		err = runAgent(os.Args[2:])
	default:
		err = fmt.Errorf("unknown command %q (login or agent)", os.Args[1])
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "split-relay:", err)
		os.Exit(1)
	}
}
