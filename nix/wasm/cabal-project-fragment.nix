# Renders the `if arch(wasm32)` cabal.project stanza from forks.json.
#
# Consumers can either:
#   (a) splice the rendered string into their own cabal.project, or
#   (b) pass it as cabalProjectLocal to cabalProject'.
#
# Source of truth for revs and hashes: ./forks.json. Do not duplicate them here.
{ lib }:

let
  forks = builtins.fromJSON (builtins.readFile ./forks.json);

  renderSubdirs = subdirs:
    if subdirs == [] then ""
    else "  subdir:\n" + lib.concatMapStrings (s: "    ${s}\n") subdirs;

  renderPin = _name: pin:
    "source-repository-package\n" +
    "  type: git\n" +
    "  location: ${pin.location}\n" +
    "  tag: ${pin.rev}\n" +
    renderSubdirs pin.subdirs +
    "  --sha256: ${pin.sha256}\n";

  renderFlags = lib.concatStringsSep "" (
    lib.mapAttrsToList (pkg: flags:
      "package ${pkg}\n  flags: ${flags}\n"
    ) forks.packageFlags
  );

  renderGhcOptions = lib.concatStringsSep "" (
    lib.mapAttrsToList (pkg: opts:
      "package ${pkg}\n  ghc-options: ${opts}\n"
    ) forks.packageGhcOptions
  );

  renderConstraints =
    if forks.constraints == [] then ""
    else "constraints: " + lib.concatStringsSep ", " forks.constraints + "\n";

  renderAllowNewer =
    if forks.allowNewer == [] then ""
    else "allow-newer: " + lib.concatStringsSep ", " forks.allowNewer + "\n";

  allPins = lib.concatStringsSep "\n" (lib.mapAttrsToList renderPin forks.pins);
  allFlags = renderFlags;
  allGhcOpts = renderGhcOptions;
  allConstraints = renderConstraints;
  allAllowNewer = renderAllowNewer;

  # Body: all stanzas at column 0, suitable for cabal.project / cabal.project.local.
  bodyText =
    allPins + "\n" +
    allFlags + "\n" +
    allGhcOpts + "\n" +
    allConstraints +
    allAllowNewer;

  # Indent every line by two spaces — for splicing inside `if arch(wasm32)`.
  indentBody = text:
    lib.concatStringsSep "\n" (
      map (line: if line == "" then "" else "  " + line)
        (lib.splitString "\n" text)
    );
in
{
  # Wrapped in `if arch(wasm32)` — for splicing into an existing cabal.project
  # that builds for both native and wasm32 targets.
  stanza = "if arch(wasm32)\n" + indentBody bodyText;

  # Bare body — for callers whose project is exclusively wasm32.
  body = bodyText;

  inherit forks;
}
