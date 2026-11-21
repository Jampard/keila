# AGPL: the published source must build from public origins alone, so no lock may name a private one.
{ pkgs, locks }:
let
  inherit (pkgs) lib;
  hostedTypes = [
    "github"
    "gitlab"
    "sourcehut"
  ];
  publicRef =
    ref:
    builtins.elem (ref.type or null) hostedTypes
    || (
      builtins.elem (ref.type or null) [
        "git"
        "tarball"
        "file"
      ]
      && lib.hasPrefix "https://" (ref.url or "")
      && !(lib.hasInfix ".internal" (ref.url or ""))
    );
  offenders = lib.concatMap (
    lock:
    lib.mapAttrsToList (name: node: "${baseNameOf (dirOf lock)}/${baseNameOf lock}: ${name}") (
      lib.filterAttrs (
        _: node: node ? original && !(publicRef node.original && publicRef node.locked)
      ) (builtins.fromJSON (builtins.readFile lock)).nodes
    )
  ) locks;
in
pkgs.runCommand "keila-public-inputs" { } (
  if offenders == [ ] then
    "touch $out"
  else
    ''
      echo "private or non-https flake inputs: ${lib.concatStringsSep ", " offenders}" >&2
      exit 1
    ''
)
