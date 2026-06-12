# Ported from IntersectMBO/cardano-api master nix/blst.nix.
# Builds blst for wasm32-wasi. Caller supplies `src` (typically
# `nixpkgs.blst.src`) via overrideAttrs and `version`.
{
  stdenvNoCC,
  wasi-sdk,
  version,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  name = "blst-wasm32-wasi";

  nativeBuildInputs = [
    wasi-sdk
  ];

  buildPhase = ''
    runHook preBuild

    ./build.sh

    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall

    mkdir -p $out/{lib,include}
    for lib in libblst.{a,so,dylib}; do
      if [ -f $lib ]; then
        cp $lib $out/lib/
      fi
    done
    cp bindings/{blst.h,blst_aux.h} $out/include

    for lib in blst.dll; do
      if [ -f $lib ]; then
        mkdir -p $out/bin
        cp $lib $out/bin/
      fi
    done

    mkdir -p $out/lib/pkgconfig
    cat > $out/lib/pkgconfig/libblst.pc <<EOF
    prefix=$out
    exec_prefix=\''${prefix}
    libdir=\''${exec_prefix}/lib
    includedir=\''${prefix}/include

    Name: libblst
    Description: blst (pronounced 'blast') is a BLS12-381 signature library focused on performance and security. It is written in C and assembly.
    URL: https://github.com/supranational/blst
    Version: ${version}

    Cflags: -I\''${includedir}
    Libs: -L\''${libdir} -lblst
    Libs.private:
    EOF

    wasm32-wasi-clang -shared -Wl,--whole-archive $out/lib/libblst.a -o $out/lib/libblst.so

    runHook postInstall
  '';
})
