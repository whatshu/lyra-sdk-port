# nix host toolchain (optional, stronger pin)

`default.nix` pins a nixpkgs snapshot and builds every host build tool as an
immutable nix store closure.  It is the "strong" reproducibility option: the
apt archive is never a source of build tools, so even if Ubuntu replaces a
binary the toolchain cannot change.

It is **not** the default because the nix binary cache (`cache.nixos.org` and
mirrors) is frequently unreachable on restricted networks.  The default
`tools/docker/Dockerfile` installs the same tools from apt inside the pinned
base image and records the exact package versions instead.

## Use it

```sh
make docker-image NIX=1        # uses Dockerfile.nix, builds the store
make docker-image              # default apt-based Dockerfile
```

Requirements: the nix binary cache must be reachable during `docker build`.

## Cache

The store is baked into the image on first build; the layer is then reused.
To carry the exact store to another machine without the network:

```sh
nix-store --export $(nix-store -qR /nix/store/*-shu-sdk-tools) > tools/nix/cache/store.closure
nix-store --import < tools/nix/cache/store.closure     # on the other machine
```

`tools/nix/cache.sh export|import` wraps the above.

## Updating the pin

```sh
git ls-remote https://github.com/NixOS/nixpkgs refs/heads/release-24.11
curl -L https://github.com/NixOS/nixpkgs/archive/<rev>.tar.gz | sha256sum
```

then update the `url`/`sha256` at the top of `default.nix`.
