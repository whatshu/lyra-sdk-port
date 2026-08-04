# Pinned host toolchain for the shu-sdk build container.
#
# All host-side build tools are provisioned from this single nixpkgs
# snapshot.  The container therefore never depends on whatever apt/Ubuntu
# happens to ship on the base image: even if upstream swaps a binary, the
# store here is immutable and reproducible.
#
# The toolchain is *not* used to build the ARM firmware — the vendor
# (Rockchip/ARM) cross-compilers are used as binary releases instead.
#
# Update the pin like this:
#   git ls-remote https://github.com/NixOS/nixpkgs refs/heads/release-24.11
#   curl -L https://github.com/NixOS/nixpkgs/archive/<rev>.tar.gz | sha256sum
{ pkgs ? import (builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/5ab036a8d97cb9476fbe81b09076e6e91d15e1b6.tar.gz";
    sha256 = "d991a2e3f55afd7afa579156ea9d1678d057c18d57b3c1bf400e5efa40e4d3da";
  }) { }
}:

let
  tools = with pkgs; [
    # compilers / build drivers
    gcc gcc_multi cmake ninja make
    bison flex pkg-config gawk bc patch gettext
    # interpreters the kernel/buildroot need at build time
    python3 perl
    # device tree / image tooling
    dtc
    # compression + archiving
    lz4 lzma zstd xz cpio unzip zip rsync tar
    # host utilities
    kmod file util-linux e2fsprogs coreutils findutils diffutils
    grep sed which gnutar gzip unifdef
    # crypto headers needed by kernel configs (CONFIG_CRYPTO*)
    openssl openssl.dev libelf
    # misc helpers used by the build scripts
    coreutils-full hostname git
  ];
in
pkgs.buildEnv {
  name = "shu-sdk-tools";
  paths = tools;
  pathsToLink = [ "/bin" "/sbin" "/lib" "/share" "/include" ];
  ignoreCollisions = true;
}
