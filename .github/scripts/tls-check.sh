#!/usr/bin/env bash
# Prove the TLS story against the image that is about to ship:
#   - the proxy is running and presents a certificate we trust
#   - a certificate holder is served, and a caller without one is not
#   - several clients are served at once
#   - emacsclient reaches the daemon through a client-side proxy, which is
#     what makes a real frame on the daemon possible
#
# Usage: .github/scripts/tls-check.sh IMAGE
set -euo pipefail

IMAGE="${1:-revere:candidate}"
here="$PWD"

cleanup() {
  docker rm -f clientproxy >/dev/null 2>&1 || true
  docker rm -f tls >/dev/null 2>&1 || true
}
fail() {
  echo "FAIL: $*" >&2
  echo "--- daemon log:"; docker logs tls 2>&1 | tail -40 || true
  echo "--- client proxy log:"; docker logs clientproxy 2>&1 | tail -20 || true
  cleanup
  exit 1
}

# The client Emacs, told where to dial and what to present.  CERT is the
# certificate pair, or the empty string to present none.
client_setup() {
  local cert="$1"
  cat <<ELISP
(progn
  (require (quote revere-client))
  (setq revere-client-auth-dir "/config/server/"
        revere-client-tls t
        revere-client-host "127.0.0.1"
        revere-client-port 9999
        revere-client-timeout 20
        revere-client-ca "/certs/ca.pem"
        revere-client-certificate ${cert})
ELISP
}

run_client() {
  # $1 elisp body, run in a throwaway container with the certificates.
  docker run --rm --network host --entrypoint emacs \
    -e "N=${N:-0}" \
    -v "$here/certs:/certs:ro" -v "$here/config:/config:ro" \
    "$IMAGE" -Q --batch -L /opt/revere/lisp --eval "$1"
}

echo "== certificates"
bash client/make-certs.sh localhost 127.0.0.1

echo "== the daemon, behind TLS"
docker run -d --name tls -p 9999:9999 \
  -e REVERE_SERVER_TCP=1 -e REVERE_TLS=1 \
  -v "$here/certs:/certs:ro" -v "$here/config:/config" \
  "$IMAGE" >/dev/null

ready=""
for _ in $(seq 1 30); do
  if docker exec tls test -f /config/server/revere 2>/dev/null; then ready=yes; break; fi
  sleep 1
done
[ -n "$ready" ] || fail "the daemon never wrote its server file"
sudo chmod -R a+rX config

echo "== the proxy is running, not merely configured"
docker exec tls pgrep -f stunnel >/dev/null || fail "stunnel is not running"

echo "== it presents a certificate we trust"
openssl s_client -connect 127.0.0.1:9999 -CAfile certs/ca.pem \
  -cert certs/client.pem -key certs/client-key.pem </dev/null 2>&1 \
  | tee openssl.log | grep -q "Verify return code: 0" \
  || { tail -20 openssl.log; fail "could not verify the daemon against our authority"; }

# The real tests are at the application layer.  Under TLS 1.3 a client with
# no certificate still sees a clean handshake and is only turned away after,
# so the handshake alone proves nothing.
echo "== the certificate holder gets an answer"
run_client "$(client_setup '(list "/certs/client-key.pem" "/certs/client.pem")')
  (let ((answer (revere-client-eval (quote (list emacs-version (length revere-job-list))))))
    (message \"answered over TLS: %S\" answer)
    (unless (consp answer) (kill-emacs 1))))" \
  || fail "the certificate holder was not served"

echo "== without a certificate, nothing"
run_client "$(client_setup 'nil')
  (condition-case nil
      (progn (revere-client-eval (quote (length revere-job-list)))
             (message \"served a client with no certificate\")
             (kill-emacs 1))
    (error (message \"refused, as it should be\"))))" \
  || fail "a client with no certificate got through"

echo "== several certificate holders at once"
pids=""
for n in 1 2 3 4 5 6; do
  N="$n" run_client "$(client_setup '(list "/certs/client-key.pem" "/certs/client.pem")')
    (let* ((mine (string-to-number (getenv \"N\")))
           (answer (revere-client-eval (list (quote list) mine (quote (emacs-pid))))))
      (message \"client %d got %S\" mine answer)
      (unless (equal (car answer) mine) (kill-emacs 1))))" &
  pids="$pids $!"
done
for p in $pids; do wait "$p" || fail "concurrent clients were not all served"; done
echo "all six were served, each its own answer"

# emacsclient has no TLS of its own, so a proxy on this side carries it and
# emacsclient speaks plain TCP to the loopback.  This is the path that makes
# a real frame on the daemon work.  The config is the one shipped for people
# to copy, with its paths pointed at the test certificates.
echo "== emacsclient reaches the daemon through a client-side proxy"
sed -e "s#/home/you/revere#/certs#g" -e "s#nas.lan#127.0.0.1#" \
  client/stunnel.conf > client.conf
docker run -d --name clientproxy --network host \
  -v "$here/certs:/certs:ro" -v "$here/client.conf:/tmp/client.conf:ro" \
  --entrypoint stunnel "$IMAGE" /tmp/client.conf >/dev/null
sleep 2
docker exec clientproxy pgrep -f stunnel >/dev/null || fail "the client proxy did not start"

# The daemon records 127.0.0.1:9998 in its server file, which is exactly
# where the proxy listens, so the file is usable as it stands.
docker run --rm --network host --entrypoint emacsclient \
  -v "$here/config:/config:ro" "$IMAGE" \
  --server-file=/config/server/revere \
  -e '(list "emacsclient reached the daemon" emacs-version)' \
  || fail "emacsclient could not reach the daemon through the proxy"
echo "emacsclient got through, so a frame would too"

docker logs tls 2>&1 | tail -10
cleanup
echo "== all of it holds"
