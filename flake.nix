{
  # Keep this line accurate and one line long: `nix flake metadata` prints it,
  # and it is the first thing a cold agent learns about the repo.
  description = "ESP32-WROOM firmware that drives an ON AIR pin from the Twitch API -- PlatformIO/Arduino, board esp32dev. Run `nix flake show` for the command map.";

  # nixpkgs is the only input, on purpose.
  #
  # flake-utils would buy exactly one thing here -- eachDefaultSystem -- which is
  # the three-line genAttrs below. In exchange it costs a second lock node, a
  # second upstream that can break, and a hardcoded system list this repo cannot
  # edit. That list is currently broken: it still contains x86_64-darwin, which
  # now throws (see `systems` below).
  #
  # nixos-unstable is the same channel the author's own NixOS config tracks, so
  # `nix develop` here and `nixos-rebuild` there resolve the same store paths and
  # share one cache.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    # `...` rather than a closed { self, nixpkgs }: adding a second input later
    # would otherwise fail with "called with unexpected argument 'self'".
    { nixpkgs, ... }:
    let
      lib = nixpkgs.lib;

      # x86_64-darwin is deliberately absent: nixpkgs 26.11 replaced that whole
      # attribute set with a `throw`. genAttrs is lazy, so plain `nix develop` on
      # Linux would not notice -- it detonates on `nix flake check --all-systems`.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # Stand-in for flake-utils.lib.eachDefaultSystem. Passes `pkgs` rather than
      # a system string, because that is what every call site below wants.
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # ======================================================================
      # PER-REPO BLOCK 1 -- the toolchain
      # ======================================================================
      # `nix flake check` realises this closure, so a typo'd attr name fails at
      # the flake gate instead of surfacing as "command not found" mid-task.
      # Explicit `pkgs.foo`, never `with pkgs; [ ... ]` -- a vanished attr then
      # names itself instead of reporting a bare undefined identifier.
      #
      # This repo needs no Python of its own: setup-venv.sh exists only to pip
      # install PlatformIO into .venv, which is exactly the job nixpkgs' pio does
      # here. The Makefile prefers .venv/bin/pio and falls back to `pio` on PATH,
      # so `make build` keeps working inside this shell with no .venv at all.
      #
      # `platformio` (the alias), not `platformio-core`: on Linux the alias is a
      # bwrap FHS wrapper -- verified `platformio.drvPath != platformio-core.drvPath`
      # and the built launcher is a bwrap script. That wrapper is what lets the
      # xtensa binaries PIO downloads at build time find /lib64/ld-linux, so do
      # NOT "simplify" it to platformio-core and do not hand-roll an FHS env.
      # On darwin the alias maps to plain platformio-core, which is correct there.
      toolchain = pkgs: [
        # ---- this repo's ecosystem ----
        pkgs.platformio
        # esptool for the things pio does not wrap: erase_flash, read_mac,
        # dumping an image off a board. `pio run --target upload` uses PIO's own
        # copy, not this one.
        pkgs.esptool

        # ---- present in every repo in the fleet ----
        pkgs.git
        pkgs.jq
        pkgs.gnumake
      ];

      # ======================================================================
      # PER-REPO BLOCK 2 -- libraries that get dlopened, not linked
      # ======================================================================
      # PIO ships prebuilt Python wheels and tools whose .so files are dlopened,
      # so neither patchelf nor the nix linker ever sees them and NixOS has no
      # /usr/lib for them to find. libusb1 is here for pyserial/esptool on boards
      # that expose USB-CDC/JTAG rather than a CP210x-style UART bridge. Keep the
      # list minimal -- LD_LIBRARY_PATH is a blunt instrument.
      #
      # This fixes shared libraries only. The xtensa gcc that PIO downloads is a
      # prebuilt *executable* with a hardcoded PT_INTERP of
      # /lib64/ld-linux-x86-64.so.2, which no flake can supply -- stock NixOS
      # ships a stub there that exits 127. Here that is handled by running those
      # binaries inside pio's bwrap wrapper, which is why every command below
      # goes through `pio` and never invokes .platformio/packages/*/bin/* directly.
      nativeLibs = pkgs: [
        pkgs.stdenv.cc.cc.lib
        pkgs.zlib
        pkgs.libusb1
      ];

      # ======================================================================
      # PER-REPO BLOCK 3 -- constant environment variables
      # ======================================================================
      # Only constants belong here; this attrset is applied to BOTH surfaces (the
      # dev shell and every `nix run` wrapper) so a command cannot behave
      # differently depending on how it was invoked. PLATFORMIO_CORE_DIR is NOT
      # here on purpose: it has to be derived from $REPO_ROOT at runtime, so each
      # command exports it itself (and so does the shellHook).
      #
      # All four names were read out of platformio 6.1.19's own source, including
      # the exact values it compares against -- app.py checks
      # PLATFORMIO_DISABLE_PROGRESSBAR == "true" (lowercase string, not a bool)
      # and maps PLATFORMIO_SETTING_<NAME> onto its settings dict.
      envVars = pkgs: {
        # Progress bars and ANSI escapes are pure noise in a captured build log.
        PLATFORMIO_DISABLE_PROGRESSBAR = "true";
        PLATFORMIO_NO_ANSI = "true";
        PLATFORMIO_SETTING_ENABLE_TELEMETRY = "No";
        # Not cosmetic. Every `check_platformio_interval` days, maintenance.py
        # calls ensure_internet_on(raise_exception=True) before a normal command
        # and hard-fails offline -- so an untouched checkout that built fine last
        # week starts erroring on `pio run` with no local change. nix owns the pio
        # version anyway, so an upgrade notice here is unactionable.
        PLATFORMIO_SETTING_CHECK_PLATFORMIO_INTERVAL = "36500";
      };

      # ======================================================================
      # PER-REPO BLOCK 4 -- the command map
      # ======================================================================
      # THE single source of truth: it generates `apps` (so `nix run .#build`
      # works), the `dev-*` wrappers on PATH inside the shell, and `dev-help`.
      #
      # NOT HERMETIC, and the descriptions say so. PIO downloads its own xtensa
      # toolchain, the espressif32 platform and ArduinoJson on first use -- about
      # a gigabyte of foreign binaries. Those land in $REPO_ROOT/.platformio
      # (gitignored) rather than $HOME so that a reset is one `rm -rf` and so two
      # checkouts cannot poison each other. Do not try to nixify those packages.
      #
      # `test` is absent because this repo has no test/ directory and no [test]
      # config; `pio test` would only ever print "Nothing to test". Absence is
      # information -- do not add a stub. There is no `fmt` either: the repo
      # ships no .clang-format, so any formatter would rewrite all four .cpp
      # files to a style nobody chose.
      #
      # Every command is anchored with `-d "$REPO_ROOT"`, and that is load-bearing
      # rather than tidiness: apps run in the caller's cwd on purpose, and `pio
      # run` looks for platformio.ini in the cwd only -- from src/ it dies with
      # "NotPlatformIOProjectError: Not a PlatformIO project". (`pio check` does
      # walk upwards, so the two subcommands disagree; anchor both.)
      #
      # `pio device monitor` is deliberately not a verb: it never exits, and an
      # app that never exits burns an agent's whole timeout. Use it from inside
      # `nix develop`, where Ctrl-C works, or `make monitor`.
      commands = pkgs: {
        setup = {
          description = "(network) install the espressif32 platform + libs, and create include/secrets.h";
          text = ''
            export PLATFORMIO_CORE_DIR="$REPO_ROOT/.platformio"
            # The header guard rename is not cosmetic: secrets.example.h guards on
            # SECRETS_EXAMPLE_H, so a straight copy leaves both files claiming
            # different guards and the README tells humans to fix it by hand.
            if [ ! -f "$REPO_ROOT/include/secrets.h" ]; then
              sed 's/SECRETS_EXAMPLE_H/SECRETS_H/g' \
                "$REPO_ROOT/include/secrets.example.h" > "$REPO_ROOT/include/secrets.h"
              echo "created include/secrets.h from the example. Its placeholder WiFi and" >&2
              echo "Twitch credentials compile, but the board will not connect until you" >&2
              echo "fill them in. The file is gitignored -- never commit it." >&2
            fi
            pio pkg install -d "$REPO_ROOT" "$@"
          '';
        };
        build = {
          description = "(network on first run) compile the firmware for esp32dev";
          text = ''
            export PLATFORMIO_CORE_DIR="$REPO_ROOT/.platformio"
            if [ ! -f "$REPO_ROOT/include/secrets.h" ]; then
              echo "include/secrets.h is missing, so the build cannot succeed." >&2
              echo "Run 'nix run .#setup' (or dev-setup) first." >&2
              exit 1
            fi
            pio run -d "$REPO_ROOT" "$@"
          '';
        };
        lint = {
          description = "(network on first run) cppcheck over src/ and include/ via pio check";
          text = ''
            export PLATFORMIO_CORE_DIR="$REPO_ROOT/.platformio"
            # The suppression is what makes --fail-on-defect=high usable at all:
            # cppcheck cannot expand ArduinoJson's ARDUINOJSON_CONCAT_ macros and
            # files two [high:error] preprocessorErrorDirective hits inside
            # .pio/libdeps that nobody in this repo can fix, so without it lint
            # exits 1 on a clean tree forever. Do NOT reach for --skip-packages
            # instead: that only drops packages_dir from the include list (not
            # .pio/libdeps), so the two hits survive AND cppcheck loses the
            # Arduino framework headers, finishing in 0.2s instead of ~50s
            # because it can no longer parse anything properly.
            # With this, low/medium findings still print but only a genuine
            # high-severity defect in src/ or include/ fails the command.
            pio check -d "$REPO_ROOT" \
              --flags "--suppress=preprocessorErrorDirective" \
              --fail-on-defect=high "$@"
          '';
        };
        run = {
          description = "flash the board over USB (needs the ESP32 plugged in; network on first run)";
          text = ''
            export PLATFORMIO_CORE_DIR="$REPO_ROOT/.platformio"
            if [ ! -f "$REPO_ROOT/include/secrets.h" ]; then
              echo "include/secrets.h is missing, so the build cannot succeed." >&2
              echo "Run 'nix run .#setup' (or dev-setup) first." >&2
              exit 1
            fi
            # Flashing also needs the udev rules from pkgs.platformio-core.udev in
            # the host's NixOS config and the user in dialout (uucp on Arch) --
            # host configuration, which no project flake can provide.
            pio run -d "$REPO_ROOT" --target upload "$@"
          '';
        };
      };

      # ======================================================================
      # GENERIC MACHINERY -- byte-identical across the fleet, do not edit
      # ======================================================================

      # Prepend, never assign: a host LD_LIBRARY_PATH may be carrying something
      # the user needs. Linux only -- on darwin the loader variable is DYLD_*.
      ldPreamble =
        pkgs:
        lib.optionalString (pkgs.stdenv.hostPlatform.isLinux && nativeLibs pkgs != [ ]) ''
          export LD_LIBRARY_PATH="${lib.makeLibraryPath (nativeLibs pkgs)}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        '';

      # Every command gets $REPO_ROOT. `nix run` and `nix develop` both start in
      # whatever directory they were invoked from, so a bare `.platformio` would
      # silently fork a second gigabyte-sized core dir per subdirectory. Note we
      # do NOT cd there: commands act on the caller's cwd on purpose.
      rootPreamble = ''
        REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
        export REPO_ROOT
      '';

      # One derivation per command, reused by both `apps` and the dev shell, so
      # the two can never diverge. `dev-` prefixed because a bare `test` binary
      # earlier on PATH would shadow the POSIX shell builtin and quietly break
      # every script in the repo that uses it.
      wrappers =
        pkgs:
        lib.mapAttrs (
          name: cmd:
          pkgs.writeShellApplication {
            name = "dev-${name}";
            runtimeInputs = toolchain pkgs;
            runtimeEnv = envVars pkgs;
            meta.description = cmd.description;
            text = ''
              ${rootPreamble}
              ${ldPreamble pkgs}
              ${cmd.text}
            '';
          }
        ) (commands pkgs);

      helpFor =
        pkgs:
        let
          cmds = commands pkgs;
          names = lib.attrNames cmds;
          width = lib.foldl' (a: n: lib.max a (builtins.stringLength n)) 0 names;
          pad = n: n + lib.concatStrings (lib.genList (_: " ") (width - builtins.stringLength n));
          line = n: c: "  dev-${pad n}  ${c.description}";
        in
        pkgs.writeShellApplication {
          name = "dev-help";
          meta.description = "print this repo's command map (works offline)";
          text = ''
            cat <<'EOF'
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList line cmds)}
            EOF
          '';
        };
    in
    {
      # `nix flake show` -- the discovery entrypoint, and deliberately the whole
      # machine-facing contract: every app carries a meta.description, which
      # `nix flake show` prints inline and `nix flake show --json` exposes at
      # .apps.<system>.<name>.description. Pure evaluation, so an agent gets the
      # entire command map in one cheap call without reading a README.
      #
      # Do NOT invent a top-level output for this (`agentManifest` and friends):
      # Nix answers `warning: unknown flake output '<name>'` on every single
      # `nix flake check`, forever.
      apps = forAllSystems (
        pkgs:
        lib.mapAttrs (name: cmd: {
          type = "app";
          program = "${(wrappers pkgs).${name}}/bin/dev-${name}";
          meta.description = cmd.description;
        }) (commands pkgs)
      );

      # `nix develop` -- the toolchain, plus a dev-<verb> for every app. No
      # `packages` output: the artifact here is an .elf/.bin that only PIO's own
      # downloaded xtensa toolchain can produce, so a derivation claiming to
      # build it would need network in the sandbox and would be a lie.
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = toolchain pkgs ++ lib.attrValues (wrappers pkgs) ++ [ (helpFor pkgs) ];

          env = envVars pkgs;

          # Some C extensions compile at -O0, where glibc's _FORTIFY_SOURCE
          # becomes a hard error instead of a warning.
          hardeningDisable = [ "fortify" ];

          shellHook = ''
            # mkShell inherits SOURCE_DATE_EPOCH=315532800 (1980-01-01) from
            # stdenv, and any wheel or zip built in here then dies with "ZIP does
            # not support timestamps before 1980".
            unset SOURCE_DATE_EPOCH

            ${rootPreamble}
            ${ldPreamble pkgs}

            # Keeps the ~1 GB of toolchains PIO downloads inside the work tree
            # instead of $HOME, so a reset is `rm -rf .platformio` and two
            # checkouts cannot poison each other. The variable passes through
            # into pio's bwrap sandbox. Mirrored at the top of every command
            # above, because wrappers do not run this hook -- if you change the
            # path here, change it there too.
            export PLATFORMIO_CORE_DIR="$REPO_ROOT/.platformio"

            # Nothing networked, stateful or interactive above this line, and
            # nothing below it either. No `pio pkg install`, no venv creation.
            # Bootstrapping in the hook would make a cold `nix develop -c pio run`
            # start downloading before it runs anything, on EVERY invocation --
            # the exact failure an unattended agent cannot diagnose. That is what
            # `dev-setup` is for, and its description says (network) so an agent
            # knows not to retry it offline.

            # The banner is interactive-only, and this guard is load-bearing:
            # shellHook output lands on the STDOUT of `nix develop -c <cmd>`, so
            # an unguarded echo corrupts anything parsing it. $- is the only
            # reliable discriminator -- it lacks `i` under `nix develop -c` and
            # has it at an interactive prompt. Do not switch to `[ -t 1 ]`: that
            # leaks the moment a caller allocates a pty, which agent harnesses
            # do. Do not test $PS1 (unset in both) or $IN_NIX_SHELL (set in both).
            case $- in
              *i*) echo "ESP32-twitch-onair-sign dev shell -- 'dev-help' for the command map" >&2 ;;
            esac
          '';
        };
      });

      # `nix flake check` -- honest by construction. It realises the toolchain
      # closure (so a typo'd or currently-broken attr fails here) and builds
      # every wrapper, which runs shellcheck over every command text. It does
      # NOT compile the firmware: that needs PIO's runtime downloads, which the
      # build sandbox has no network for. NEVER add a check that always passes --
      # an agent reads "all checks passed!" as a signal.
      checks = forAllSystems (pkgs: {
        toolchain =
          pkgs.runCommand "toolchain-check"
            {
              nativeBuildInputs = toolchain pkgs ++ lib.attrValues (wrappers pkgs);
            }
            ''
              for verb in ${lib.escapeShellArgs (lib.attrNames (commands pkgs))}; do
                command -v "dev-$verb" > /dev/null || {
                  echo "dev-$verb is not on PATH" >&2
                  exit 1
                }
              done
              touch "$out"
            '';
      });

      # `nix fmt` -- formats the *Nix* in this repo; C++ is not touched (see the
      # note about .clang-format above). nixfmt-tree rather than bare nixfmt,
      # because bare nixfmt tries to parse every path handed to it and fails on
      # non-Nix files. This file ships already formatted, so `nix fmt` is a no-op.
      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
