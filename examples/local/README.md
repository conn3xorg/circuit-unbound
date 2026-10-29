# Local example

Applies circuit-unbound to a throwaway Rocky Linux 10 container with systemd. You need Conn3x and Podman.

The host container runs privileged, which is simplest with rootful Podman. On a Mac, use the Podman machine's root connection. On Linux, use `sudo podman`:

```sh
export CONTAINER_CONNECTION=podman-machine-default-root   # macOS
export PODMAN="sudo podman"                               # Linux
./up.sh
conn3x init
conn3x apply
conn3x plan
```

The second plan says `No changes.` Unbound resolves from the root servers, so the container needs outbound DNS. To ask it something:

```sh
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1
dnf -y install bind-utils
dig @127.0.0.1 nas.home.arpa
dig @127.0.0.1 example.com        # flags include ad: DNSSEC checked out
dig @127.0.0.1 dnssec-failed.org  # SERVFAIL: its signatures don't
```

To forward over TLS instead, pass forwarders: `conn3x apply -var 'forwarders=["9.9.9.9#dns.quad9.net"]'`.

`up.sh` listens on `127.0.0.1:2222`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` removes the container, its volumes, the key and the state.
