{
  description = "spirv test executor flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";
  };

  outputs = { self, nixpkgs }:
  let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in rec {
    packages.${system} = rec {
      spirv-llvm-translator = (pkgs.spirv-llvm-translator.override {
        inherit (pkgs.llvmPackages_16) llvm;
      }).overrideAttrs (old: {
        version = "16.0.0";
        src = pkgs.fetchFromGitHub {
          owner = "KhronosGroup";
          repo = "SPIRV-LLVM-Translator";
          rev = "42de1b449486edb0aa2b764e4f4f3771d3f1a4a3";
          hash = "sha256-rP7M52IDimfkF62Poa765LUL9dbIKNK5tn1FuS1k+c0=";
        };
      });

      mesa = (pkgs.mesa.override {
        galliumDrivers = [ "swrast" "radeonsi" ];
        vulkanDrivers = [ ];
        vulkanLayers = [ ];
        withValgrind = false;
        enableGalliumNine = false;
        llvmPackages_15 = pkgs.llvmPackages_16;
        inherit spirv-llvm-translator;
      }).overrideAttrs (old: {
        version = "23.11.16-git";
        src = pkgs.fetchFromGitLab {
          domain = "gitlab.freedesktop.org";
          owner = "mesa";
          repo = "mesa";
          rev = "e1cf75b411759db0c49673b89b5325fb0442d547";
          hash = "sha256-o6Exx2Ygjd+uAYze/qLycOO7IY5qq+QjXQg8fdi9cus=";
        };
        # Set some extra flags to create an extra slim build
        mesonFlags = (old.mesonFlags or [ ]) ++ [
          "-Dgallium-vdpau=disabled"
          "-Dgallium-va=disabled"
          "-Dgallium-xa=disabled"
          "-Dandroid-libbacktrace=disabled"
          "-Dvalgrind=disabled"
          "-Dlibunwind=disabled"
          "-Dlmsensors=disabled"
          "-Db_ndebug=false"
          "--buildtype=debug"
        ];
        # Dirty patch to make one of the nixos-upstream patches working.
        patches = [ ./patches/mesa-opencl.patch ./patches/mesa-disk-cache-key.patch ];
      });

      oclcpuexp-bin = pkgs.callPackage ({ stdenv, fetchurl, autoPatchelfHook, zlib, tbb_2021_8 }:
      stdenv.mkDerivation {
        pname = "oclcpuexp-bin";
        version = "2023-WW13";

        nativeBuildInputs = [ autoPatchelfHook ];

        propagatedBuildInputs = [ zlib tbb_2021_8 ];

        src = fetchurl {
          url = "https://github.com/intel/llvm/releases/download/2023-WW27/oclcpuexp-2023.16.6.0.28_rel.tar.gz";
          hash = "sha256-iJB5fRNgjSAKNishxJ0QFhIFDadwxNS1I/tbVupduRk=";
        };

        sourceRoot = ".";

        dontConfigure = true;
        dontBuild = true;

        installPhase = ''
          mkdir -p $out/lib
          mv x64/* $out/lib
          mv clbltfnshared.rtl $out/lib/
          chmod 644 $out/lib/*
          chmod 755 $out/lib/*.so.*

          mkdir -p $out/etc/OpenCL/vendors
          echo $out/lib/libintelocl.so > $out/etc/OpenCL/vendors/intelocl64.icd
        '';
      }) {};

      pocl = pkgs.callPackage ({
        stdenv,
        gcc-unwrapped,
        fetchFromGitHub,
        cmake,
        ninja,
        python3,
        llvmPackages_16,
        ocl-icd,
        rocm-runtime
      }: stdenv.mkDerivation {
        pname = "pocl";
        version = "4.0";

        nativeBuildInputs = [
          cmake
          ninja
          python3
          llvmPackages_16.clang
        ];

        buildInputs = with llvmPackages_16; [
          llvm
          clang-unwrapped
          clang-unwrapped.lib
          ocl-icd
          spirv-llvm-translator
          rocm-runtime
        ];

        src = fetchFromGitHub {
          owner = "pocl";
          repo = "pocl";
          rev = "d6ec42378fe6f618b92170d2be45f47eae22343f";
          hash = "sha256-Uo4Np4io1s/NMK+twX36PLBFP0j5j/0NkkBvS2Zv9ng=";
        };

        postPatch = ''
          substituteInPlace cmake/LLVM.cmake \
            --replace NO_CMAKE_PATH "" \
            --replace NO_CMAKE_ENVIRONMENT_PATH "" \
            --replace NO_DEFAULT_PATH ""
        '';

        cmakeFlags = [
          "-DENABLE_ICD=ON"
          "-DENABLE_TESTS=OFF"
          "-DENABLE_EXAMPLES=OFF"
          "-DENABLE_HSA=ON"
          "-DEXTRA_KERNEL_FLAGS=-L${gcc-unwrapped.lib}/lib"
          "-DHSA_RUNTIME_DIR=${rocm-runtime}"
          "-DWITH_HSA_RUNTIME_INCLUDE_DIR=${rocm-runtime}/include/hsa"
        ];
      }) {};

      shady = pkgs.callPackage ({
        stdenv,
        fetchFromGitHub,
        cmake,
        ninja,
        spirv-headers,
        llvmPackages_16,
        libxml2,
        json_c
      }: stdenv.mkDerivation {
        pname = "shady";
        version = "0.1";

        src = fetchFromGitHub {
          owner = "Hugobros3";
          repo = "shady";
          rev = "76c57516237c7ca5e4c0ed1133e99cec9a6334ea";
          sha256 = "sha256-C6LGH/DLY02lRydtHMfZ/Z/gbWR6Evuy+VExMgZaH0w=";
          fetchSubmodules = true;
        };

        nativeBuildInputs = [
          cmake
          ninja
        ];

        buildInputs = [
          spirv-headers
          llvmPackages_16.llvm
          libxml2
          json_c
        ];

        cmakeFlags = [
          "-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON"
          "-DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON"
        ];

        installPhase = ''
          ninja install
          # slim is not installed by default for some reason
          mkdir -p $out/bin
          mv bin/slim $out/bin/slim
        '';
      }) {};

      spirv2clc = pkgs.callPackage ({
        stdenv,
        fetchFromGitHub,
        cmake,
        ninja,
        python3
      }: stdenv.mkDerivation {
        pname = "spirv2clc";
        version = "0.1";

        src = fetchFromGitHub {
          owner = "kpet";
          repo = "spirv2clc";
          rev = "b7972d03a707a6ad1b54b96ab1437c5cd1594a43";
          sha256 = "sha256-IYaJRsS4VpGHPJzRhjIBXlCoUWM44t84QV5l7PKSaJk=";
          fetchSubmodules = true;
        };

        nativeBuildInputs = [ cmake ninja python3];

        installPhase = ''
          ninja install
          # not installed by default for some reason
          mkdir -p $out/bin
          mv tools/spirv2clc $out/bin/spirv2clc
        '';
      }) {};
    };

    devShells.${system} = let
      mkEnv = {
        name,
        driver,
        extraPkgs ? [],
        env ? {},
      }: pkgs.mkShell {
        inherit name;

        nativeBuildInputs = [
          pkgs.khronos-ocl-icd-loader
          pkgs.clinfo
          pkgs.opencl-headers
          pkgs.spirv-tools
          pkgs.gdb
          packages.${system}.spirv-llvm-translator
          packages.${system}.shady
          packages.${system}.spirv2clc
        ] ++ extraPkgs;

        OCL_ICD_VENDORS = "${driver}/etc/OpenCL/vendors";

        LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.khronos-ocl-icd-loader pkgs.gcc-unwrapped ];
      } // env;
    in rec {
      intel = mkEnv {
        name = "zig-spirv-intel";
        driver = packages.${system}.oclcpuexp-bin;
      };

      rusticl = mkEnv {
        name = "zig-spirv-rusticl";
        driver = packages.${system}.mesa.opencl;
        env = {
          RUSTICL_ENABLE = "swrast:0,radeonsi:0";
        };
      };

      pocl = let
        # Otherwise pocl cannot find -lgcc
        libgcc = pkgs.runCommand "libgcc" {} ''
          mkdir -p $out/lib
          cp ${pkgs.gcc-unwrapped}/lib/gcc/x86_64-unknown-linux-gnu/*/libgcc.a $out/lib/libgcc.a
        '';
      in mkEnv {
        name = "zig-spirv-pocl";
        driver = packages.${system}.pocl;
        extraPkgs = [
          pkgs.gcc-unwrapped.lib
          libgcc
        ];
      };

      default = rusticl;
    };
  };
}
