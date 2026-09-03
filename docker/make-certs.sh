#!/usr/bin/env bash
# Make the certificates that put mutual TLS in front of the daemon.
#
#   docker/make-certs.sh nas.lan 192.168.1.20
#
# The first argument is the name you will dial the daemon by; any further
# ones are extra names or addresses it should also answer to.  Everything
# lands in ./certs:
#
#   ca.pem          the authority, the only thing both ends trust
#   server.pem      the daemon's certificate and key, for the container
#   client-key.pem  yours, for your Emacs
#   client.pem      yours, the certificate itself
#
# Copy ca.pem and server.pem to the NAS at docker/revere/certs.  Keep
# ca.pem, client.pem and client-key.pem on the machine you work from.
# ca-key.pem signs new client certificates; keep it somewhere safe or
# delete it, and never let it near the NAS.
set -euo pipefail

# Git Bash rewrites arguments that look like Unix paths into Windows ones,
# which turns -subj "/CN=..." into a directory name and openssl rejects it.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

if [ $# -lt 1 ]; then
  echo "usage: $0 HOSTNAME [MORE-NAMES-OR-ADDRESSES...]" >&2
  exit 2
fi

primary="$1"; shift
out="${CERT_DIR:-certs}"
days="${CERT_DAYS:-825}"
mkdir -p "$out"
cd "$out"

# Subject alternative names: what the client will check the daemon's
# certificate against.  An address has to be listed as an IP, a name as a
# DNS entry, or Emacs will refuse the connection.
alt() {
  local i=1 j=1 line=""
  for name in "$primary" "$@"; do
    if printf '%s' "$name" | grep -Eq '^[0-9]+(\.[0-9]+){3}$'; then
      line="${line}IP.${i} = ${name}"$'\n'; i=$((i + 1))
    else
      line="${line}DNS.${j} = ${name}"$'\n'; j=$((j + 1))
    fi
  done
  printf '%s' "$line"
}

cat > openssl.cnf <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = revere
[server]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @names
[client]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = clientAuth
[names]
$(alt "$@")
EOF

echo "== authority"
openssl req -x509 -newkey rsa:4096 -sha256 -days $((days * 4)) -nodes \
  -keyout ca-key.pem -out ca.pem \
  -subj "/CN=Revere certificate authority" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null

echo "== the daemon, answering to: $primary $*"
openssl req -newkey rsa:2048 -sha256 -nodes \
  -keyout server-key.pem -out server.csr \
  -subj "/CN=${primary}" -config openssl.cnf 2>/dev/null
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial \
  -days "$days" -sha256 -out server-cert.pem \
  -extfile openssl.cnf -extensions server 2>/dev/null
# stunnel wants the key and the certificate in one file.
cat server-key.pem server-cert.pem > server.pem

echo "== you"
openssl req -newkey rsa:2048 -sha256 -nodes \
  -keyout client-key.pem -out client.csr \
  -subj "/CN=revere-client" -config openssl.cnf 2>/dev/null
openssl x509 -req -in client.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial \
  -days "$days" -sha256 -out client.pem \
  -extfile openssl.cnf -extensions client 2>/dev/null

chmod 600 ./*-key.pem server.pem
rm -f server.csr client.csr openssl.cnf ca.srl

echo
echo "Written to $(pwd):"
ls -1
echo
echo "To the NAS, in docker/revere/certs: ca.pem server.pem"
echo "Keep here, for your Emacs:          ca.pem client.pem client-key.pem"
echo "Keep safe or delete, never on the NAS: ca-key.pem"
