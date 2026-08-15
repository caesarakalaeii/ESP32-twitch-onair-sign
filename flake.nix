{
  # Keep this line accurate and one line long: `nix flake metadata` prints it,
  # and it is the first thing a cold agent learns about the repo.
  description = "ESP32-WROOM firmware that drives an ON AIR pin from the Twitch API -- PlatformIO/Arduino, board esp32dev. Run `nix flake show` for the command map.";

  # nixpkgs is the only input, on purpose. flake-utils would buy exactly one
  # thing here -- eachDefaultSystem -- which the machinery below already does in
  # three lines. In exchange it costs a second lock node and a hardcoded system
  # list this repo cannot edit. Measured today:
  # `nix eval github:numtide/flake-utils#lib.defaultSystems` answers
  # ["aarch64-darwin" "aarch64-linux" "x86_64-darwin" "x86_64-linux"], and
  # x86_64-darwin throws on this nixpkgs -- see `systems` in the machinery.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    # `self` is mandatory: the machinery anchors $SRC_ROOT on it. `...` rather
    # than a closed { self, nixpkgs }: so adding a second input later does not
    # fail with "called with unexpected argument".
    { self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;

      # ======================================================================
      # PER-REPO BLOCK 1 -- the toolchain
      # ======================================================================
      # `nix flake check` realises this closure, so a typo'd attr name fails at
      # the flake gate instead of surfacing as "command not found" mid-task.
      # Explicit `pkgs.foo`, never `with pkgs; [ ... ]` -- a vanished attr then
      # names itself instead of reporting a bare undefined identifier.
      #
      # No Python here. setup-venv.sh builds a .venv and pip-installs
      # PlatformIO -- and then goes on to offer `sudo usermod` and to write
      # /etc/udev/rules.d/99-esp32.rules, behind two interactive `read -p`
      # prompts that would hang an unattended agent. nixpkgs' pio replaces the
      # pip half only. The Makefile picks `.venv/bin/pio` when that file exists
      # and otherwise falls back to `pio` on PATH, so `make build` works in this
      # shell with no .venv at all.
      #
      # `platformio` (the alias), not `platformio-core`. Measured on this
      # nixpkgs rev: on x86_64-linux the two have different drvPaths, and
      # platformio's bin/platformio is a symlink to a `-bwrap` launcher whose
      # FHS rootfs carries /usr/lib64/ld-linux-x86-64.so.2, libstdc++.so.6 and
      # libz.so.1. That is what the compiler PIO downloads needs:
      # .platformio/packages/toolchain-xtensa-esp32/bin/xtensa-esp32-elf-gcc is
      # an x86-64 ELF with a hardcoded PT_INTERP of /lib64/ld-linux-x86-64.so.2
      # and a NEEDED libstdc++.so.6. So do NOT "simplify" this to
      # platformio-core and do not hand-roll an FHS env. On aarch64-darwin the
      # two drvPaths are identical -- the alias is platformio-core there, which
      # is correct.
      toolchain = pkgs: [
        # ---- this repo's ecosystem ----
        pkgs.platformio
        # esptool 5.3.1, for the things pio does not wrap: `esptool erase-flash`,
        # `esptool read-mac`, dumping an image off a board. v5 spells its
        # subcommands with hyphens and reports its version as `esptool version`
        # -- `esptool --version` is an error. This copy is for you, not for pio:
        # pio downloads its own into .platformio/packages/tool-esptoolpy, and a
        # `nix run .#run` here announced "esptool.py v4.11.0" from that copy
        # while this attr is 5.3.1.
        pkgs.esptool

        # ---- present in every repo in the fleet ----
        pkgs.git
        pkgs.jq
        pkgs.gnumake
      ];

      # ======================================================================
      # PER-REPO BLOCK 2 -- libraries that get dlopened, not linked
      # ======================================================================
      # Empty, and that is a measurement rather than an oversight. The obvious
      # candidates would be libstdc++ and libz for the prebuilt xtensa
      # toolchain, but everything this repo compiles runs inside `pio`'s
      # bubblewrap FHS sandbox, and that rootfs already carries libstdc++.so.6,
      # libz.so.1 and the /lib64 loader those binaries ask for. Checked
      # directly: with LD_LIBRARY_PATH unset, deleting
      # .pio/build/esp32dev/src/main.cpp.o and re-running `pio run` recompiled
      # and relinked firmware.elf successfully.
      #
      # An empty list means the machinery emits no LD_LIBRARY_PATH preamble at
      # all. If some future tool really does need one, add it here: this list is
      # forced on Linux only, so Linux-only attrs are safe in it.
      nativeLibs = _: [ ];

      # ======================================================================
      # PER-REPO BLOCK 3 -- constant environment variables
      # ======================================================================
      # Constants only. This attrset is applied to BOTH surfaces (the dev shell
      # and every wrapper), so a verb cannot behave differently depending on how
      # it was invoked. PLATFORMIO_CORE_DIR is deliberately NOT here: it has to
      # be derived from $REPO_ROOT at runtime, so each command exports it.
      #
      # All three names were read out of platformio 6.1.19's own source, with
      # the exact values it compares against. app.py:239 is
      # `os.getenv("PLATFORMIO_DISABLE_PROGRESSBAR") == "true"` -- a lowercase
      # string, not a bool. __main__.py:39 reads PLATFORMIO_NO_ANSI. app.py:204
      # maps PLATFORMIO_SETTING_<NAME> onto the settings dict, and
      # sanitize_setting coerces a boolean setting with
      # `str(value).lower() in ("true", "yes", "y", "1")`, so "No" is False.
      envVars = _: {
        # Progress bars and ANSI escapes are pure noise in a captured build log.
        PLATFORMIO_DISABLE_PROGRESSBAR = "true";
        PLATFORMIO_NO_ANSI = "true";
        PLATFORMIO_SETTING_ENABLE_TELEMETRY = "No";
      };

      # ======================================================================
      # PER-REPO BLOCK 4 -- the command map
      # ======================================================================
      # THE single source of truth: it generates `apps` (so `nix run .#build`
      # works), the `dev-*` wrappers on PATH inside the shell, and `dev-help`.
      #
      # NOT HERMETIC, and the descriptions say so. PIO downloads its own xtensa
      # toolchain, the espressif32 platform, cppcheck, scons, esptool and
      # ArduinoJson on first use. Measured on this checkout after one full build
      # and one lint: `du -sh` reports 1.5G for .platformio (758M of that
      # framework-arduinoespressif32, 395M toolchain-xtensa-esp32) and 41M for
      # .pio. Both sit under $REPO_ROOT and both are gitignored, so a reset is
      # one `rm -rf` and two checkouts cannot poison each other. Do not try to
      # nixify those packages.
      #
      # Every verb here writes -- into $REPO_ROOT/.platformio, $REPO_ROOT/.pio
      # or include/secrets.h -- so every one of them opens with
      # `need_writable_checkout`. There is no read-only verb to omit it from,
      # which is also why the extraChecks probe below tests all four the same
      # way.
      #
      # PLATFORMIO_CORE_DIR is exported per command rather than once in the
      # shell hook, because the shell hook is fleet-canonical and cannot carry a
      # repo-specific line. Consequence worth knowing, and checked: inside
      # `nix develop` the variable is unset, so the dev-* verbs use
      # $REPO_ROOT/.platformio while a bare `pio` or `make build` typed at that
      # same prompt gets project/options.py's get_default_core_dir(), i.e.
      # ~/.platformio.
      #
      # `-d "$REPO_ROOT"` on every pio call is load-bearing rather than
      # tidiness: apps run in the caller's cwd on purpose, and both `pio run`
      # and `pio check` look for platformio.ini in the cwd only -- run from
      # src/, both die with "NotPlatformIOProjectError: Not a PlatformIO
      # project".
      #
      # No `test` verb: there is no test/ directory and no [test] section in
      # platformio.ini. No `fmt` verb: the repo ships no .clang-format, so any
      # formatter would rewrite all four src/*.cpp files to a style nobody
      # chose. Absence is information -- do not add a stub.
      #
      # `pio device monitor` is deliberately not a verb either: `pio device
      # --help` calls it "Monitor device (Serial/Socket)", and the house rule is
      # that a verb terminates on its own. Use it from inside `nix develop`,
      # where Ctrl-C works, or via `make monitor`.
      commands = _: {
        setup = {
          description = "(network) install the espressif32 platform + libs, and create include/secrets.h";
          text = ''
            need_writable_checkout
            export PLATFORMIO_CORE_DIR="$REPO_ROOT/.platformio"
            # The header-guard rewrite is not cosmetic: secrets.example.h opens
            # with `#ifndef SECRETS_EXAMPLE_H`, and README step 1 tells humans
            # to change that to SECRETS_H by hand after copying. Doing it here
            # removes the step people forget.
            if [ ! -f "$REPO_ROOT/include/secrets.h" ]; then
              sed 's/SECRETS_EXAMPLE_H/SECRETS_H/g' \
                "$REPO_ROOT/include/secrets.example.h" > "$REPO_ROOT/include/secrets.h"
              echo "created include/secrets.h from the example. It carries the example's" >&2
              echo "placeholders (UR_WIFI, UR_PW, UR_CLIENT_ID, UR_SECRET, UR_STREAMER)," >&2
              echo "which compile but are not credentials -- fill them in before flashing." >&2
              echo "The file is gitignored; never commit it." >&2
            fi
            pio pkg install -d "$REPO_ROOT" "$@"
          '';
        };
        build = {
          description = "(network on first run) compile the firmware for esp32dev";
          text = ''
            need_writable_checkout
            export PLATFORMIO_CORE_DIR="$REPO_ROOT/.platformio"
            # src/main.cpp does `#include "secrets.h"`, so the compile cannot
            # succeed without it.
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
            need_writable_checkout
            export PLATFORMIO_CORE_DIR="$REPO_ROOT/.platformio"
            # The suppression is what makes --fail-on-defect=high usable at all.
            # cppcheck cannot expand ArduinoJson's ARDUINOJSON_CONCAT_ and files
            # two [high:error] preprocessorErrorDirective hits at
            # .pio/libdeps/esp32dev/ArduinoJson/src/ArduinoJson/Polyfills/preprocessor.hpp:7
            # that nobody in this repo can fix, so without it lint fails on a
            # clean tree forever. Measured on this checkout: unsuppressed, 2
            # high + 9 low, FAILED; suppressed, 0 high + 9 low, PASSED. Do NOT
            # reach for --skip-packages instead -- measured, that keeps BOTH
            # high hits and returns in 0.28s instead of the 33-51s a real run
            # took here, because cppcheck loses the Arduino framework headers
            # and stops parsing properly (its low count moves from 9 to 10 over
            # the same sources).
            pio check -d "$REPO_ROOT" \
              --flags "--suppress=preprocessorErrorDirective" \
              --fail-on-defect=high "$@"
          '';
        };
        run = {
          description = "flash the board over USB (needs the ESP32 plugged in; network on first run)";
          text = ''
            need_writable_checkout
            export PLATFORMIO_CORE_DIR="$REPO_ROOT/.platformio"
            if [ ! -f "$REPO_ROOT/include/secrets.h" ]; then
              echo "include/secrets.h is missing, so the build cannot succeed." >&2
              echo "Run 'nix run .#setup' (or dev-setup) first." >&2
              exit 1
            fi
            # Flashing also needs host configuration no project flake can
            # provide: the udev rules from pkgs.platformio-core.udev (that
            # output ships lib/udev/rules.d/99-platformio-udev.rules) and the
            # invoking user in the serial group -- dialout, or uucp on Arch,
            # the same split the repo's own `make check-port` encodes.
            pio run -d "$REPO_ROOT" --target upload "$@"
          '';
        };
      };

      # ======================================================================
      # PER-REPO BLOCK 5 -- the name in the interactive dev-shell banner
      # ======================================================================
      repoName = "ESP32-twitch-onair-sign";

      # ======================================================================
      # PER-REPO BLOCK 6 -- repo-specific checks
      # ======================================================================
      # The canonical `anchoring` check proves rootPreamble and guardPreamble
      # behave; it cannot prove that THIS repo's verbs call them. Every verb
      # above writes, so every one of them must refuse a tree that is not this
      # repo -- and refuse it through the guard.
      #
      # Grepping the guard's own wording is the point of the probe, and it was
      # falsified before being trusted: with `need_writable_checkout` deleted
      # from `lint` in a scratch clone, dev-lint still exited non-zero in the
      # decoy -- pio raised `PermissionError: [Errno 13] Permission denied` on
      # `<store snapshot>/.platformio` -- so the exit code alone proves nothing,
      # and this check failed with "dev-lint failed without going through
      # need_writable_checkout" only because it greps for the refusal text.
      #
      # The decoy carries the marker files a naive anchor would accept for this
      # ecosystem -- platformio.ini, src/, include/ -- plus one filename this
      # repo does not contain. No network and no board in the nix sandbox, so a
      # probe that actually drove a verb to completion is not available here.
      extraChecks = pkgs: {
        verbAnchoring =
          pkgs.runCommand "verb-anchoring-check"
            {
              nativeBuildInputs = lib.attrValues (wrappers pkgs);
            }
            ''
              set -euo pipefail

              mkdir decoy
              cd decoy
              printf '[env:esp32dev]\nplatform = espressif32\nboard = esp32dev\n' > platformio.ini
              mkdir -p src include
              printf 'void setup() { }\nvoid loop() { }\n' > src/main.cpp
              printf '#ifndef SECRETS_EXAMPLE_H\n#define SECRETS_EXAMPLE_H\n#endif\n' > include/secrets.example.h
              printf 'decoy only\n' > decoy_only.txt
              printf '{\n  description = "a different repo";\n  outputs = _: { };\n}\n' > flake.nix
              cp -r . ../decoy.orig

              while IFS= read -r verb; do
                [ -n "$verb" ] || continue
                if "dev-$verb" > "$verb.log" 2>&1; then
                  echo "dev-$verb succeeded in a foreign tree; it must refuse" >&2
                  cat "$verb.log" >&2
                  exit 1
                fi
                if ! grep -q 'this command rewrites files' "$verb.log"; then
                  echo "dev-$verb failed without going through need_writable_checkout" >&2
                  cat "$verb.log" >&2
                  exit 1
                fi
              done <<'REPO_VERBS_EOF'
              ${lib.concatStringsSep "\n" (lib.attrNames (commands pkgs))}
              REPO_VERBS_EOF

              # `*.log`, and every log file above is named `<verb>.log`, so this
              # diff sees the whole decoy and nothing the probe itself wrote.
              diff -r --exclude='*.log' . ../decoy.orig
              touch "$out"
            '';
      };

      # >>>>> BEGIN CANONICAL MACHINERY v1 <<<<<
      # ======================================================================
      # Everything from the BEGIN sentinel above to the END sentinel on the last
      # line of this file is fleet-canonical text: the same bytes in every repo
      # that carries this flake style. That is a checkable claim, not a boast --
      #
      #   sed -n '/BEGIN CANONICAL MACHINERY v1/,$p' flake.nix | sha256sum
      #
      # prints the same digest in every repo, or one of them has been edited.
      # (`,$p`, not a range ending on the END sentinel: a range whose closing
      # pattern were spelled out here would terminate on this very comment.)
      # Nothing here names a repository, a language, a tool or a project file.
      # If you find such a name below, it is contamination: the fix is to move
      # it into the per-repo section above, never to special-case it here.
      #
      # This region READS exactly these names from the per-repo section:
      #   nixpkgs  self  lib  repoName  toolchain  nativeLibs  envVars
      #   commands  extraChecks
      # and DEFINES exactly these:
      #   systems  forAllSystems  ldPreamble  rootPreamble  guardPreamble
      #   wrappers  helpFor  anchorCheck
      # plus the four flake outputs apps / devShells / checks / formatter.
      # Anything else in scope is invisible to it. The types of those eight
      # inputs, and the shell variables this region exports into command texts,
      # are specified in INTERFACE.md, which travels with this block.
      #
      # To change behaviour here you change it in every repo at once and bump
      # the version in both sentinels. A local edit is a bug by construction:
      # the digest above stops matching, and -- because rootPreamble anchors on
      # flake.nix byte-identity -- an edited working tree also stops being
      # recognised by wrappers built from the previous revision.
      # ======================================================================

      # ---- systems policy: decided once for the whole fleet ----
      #
      # Read this list as "evaluated on three, built on one". That is what was
      # measured, and it is all it means:
      #   * `nix flake check --all-systems` passes, so every output attribute
      #     below EVALUATES on all three systems.
      #   * only x86_64-linux has ever been BUILT. The machine this was verified
      #     on has no aarch64 emulation -- no binfmt handler, and `extra-
      #     platforms` is x86-only -- so aarch64 cannot be built there at all.
      # It is not a statement that anything works on aarch64. Do not upgrade it
      # into one in a README.
      #
      # Evaluating all three is still worth its seconds, because the failure it
      # catches is an eval-time failure: a `pkgs.<attr>` that exists on Linux
      # and not on darwin (`stdenv.cc.cc.lib` is the usual one) throws during
      # evaluation, and `nix flake check` without --all-systems checks only the
      # current system and sails straight past it.
      #
      # x86_64-darwin is deliberately absent. nixpkgs 26.11 replaced that whole
      # attribute set with a `throw`. genAttrs is lazy, so plain `nix develop`
      # on Linux would not notice -- it detonates later, on the --all-systems
      # run this policy requires. Add it back only against a separate
      # nixpkgs-26.05-darwin input.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # Stand-in for flake-utils.lib.eachDefaultSystem. Passes `pkgs` rather
      # than a system string, because that is what every call site wants, and
      # keeps the system list in this file rather than in a second input's
      # hardcoded copy of it.
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Prepend, never assign: a host LD_LIBRARY_PATH may be carrying something
      # the user needs, and clobbering it breaks binaries they launch from here.
      # Linux only -- on darwin the loader variable is DYLD_*, and exporting a
      # Linux-shaped value there is at best useless.
      #
      # `&&` short-circuits in Nix, so on darwin `nativeLibs pkgs` is never
      # forced. That is load-bearing for the systems policy above: it is what
      # lets a repo list Linux-only attrs in nativeLibs and still evaluate on
      # aarch64-darwin. Do not reorder the two operands.
      ldPreamble =
        pkgs:
        lib.optionalString (pkgs.stdenv.hostPlatform.isLinux && nativeLibs pkgs != [ ]) ''
          export LD_LIBRARY_PATH="${lib.makeLibraryPath (nativeLibs pkgs)}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        '';

      # Every command gets $SRC_ROOT and $REPO_ROOT. `nix run` and `nix develop`
      # both start in whatever directory they were invoked from, and no verb may
      # act on that directory -- these two are what it acts on instead.
      #
      # $SRC_ROOT is this flake's own source, snapshotted into the store when
      # the flake was evaluated. It is the one anchor that is always available:
      # `nix run /path/to/repo#lint` tells the running program nothing whatever
      # about /path/to/repo (flake refs are location-independent by design, and
      # there is no $FLAKE_DIR to read), so without `self` a wrapper invoked
      # that way has literally no way to name the repo it belongs to. Two
      # limitations worth knowing: it is read-only, being a store path, and in a
      # git checkout it contains only TRACKED files.
      #
      # $REPO_ROOT is the writable checkout when the caller is standing in one,
      # and $SRC_ROOT when they are not. Three things this deliberately is NOT:
      #
      #   * NOT `pwd`. A fallback to the caller's directory is how `fmt`
      #     rewrites a stranger's source tree and how `lint` prints "all checks
      #     passed" having read none of this repo.
      #   * NOT `git rev-parse --show-toplevel`. Run from inside some OTHER git
      #     repo it cheerfully answers with THAT repo's top level. It also needs
      #     git on PATH and a .git directory, so it fails on an export and in
      #     any wrapper whose toolchain omits git.
      #   * NOT an inherited $REPO_ROOT from the environment. The dev shell
      #     EXPORTS this variable, so honouring it would mean that running
      #     `nix run /path/to/B#fmt` from inside repo A's dev shell points B's
      #     formatter at A. An explicit path argument is how a caller overrides
      #     a verb's target; an ambient variable is how they do it by accident.
      #
      # Instead: walk up from $PWD and take the first ancestor that IS this
      # repo, proved by carrying a byte-identical flake.nix. A single tracked
      # filename, a marker directory, or a set of them is not proof -- sibling
      # repos in a fleet share those, and a decoy can be built to carry any list
      # of names you care to publish. The whole flake.nix is what distinguishes
      # repos, because description, toolchain and command map all differ, so the
      # whole flake.nix is what gets compared. Compared with bash's own
      # `$(<file)` rather than cmp or sha256sum, so the check depends on no
      # package at all -- pure builtins, correct even in a wrapper whose PATH
      # carries nothing but the repo's own toolchain.
      #
      # Consequence worth knowing: edit flake.nix and the dev-* wrappers in an
      # already-open `nix develop` stop recognising the tree, because they were
      # built from the previous flake.nix. That is a stale shell telling you so
      # -- re-enter it. `nix run` re-evaluates every time and never sees this.
      rootPreamble = ''
        SRC_ROOT=${lib.escapeShellArg "${self}"}
        export SRC_ROOT

        _dev_find_root() {
          local dir ref
          ref=$(<"$SRC_ROOT/flake.nix") || return 1
          dir=$(
            unset CDPATH
            cd -P -- "''${1:-.}" 2>/dev/null && pwd
          ) || return 1
          while [ -n "$dir" ]; do
            if [ -f "$dir/flake.nix" ] && [ "$(<"$dir/flake.nix")" = "$ref" ]; then
              printf '%s\n' "$dir"
              return 0
            fi
            dir=''${dir%/*}
          done
          return 1
        }

        REPO_ROOT="$(_dev_find_root "$PWD" || printf '%s\n' "$SRC_ROOT")"
        export REPO_ROOT
      '';

      # Wrappers only, not the shellHook -- an interactive shell has no business
      # carrying this function around. Any command text that writes files calls
      # it first, and it is the reason a mutating verb can fail loudly instead
      # of falling back to "well, the cwd then".
      #
      # The test is $REPO_ROOT != $SRC_ROOT, i.e. "rootPreamble found a real
      # checkout", not a permission or a store-path-prefix test. Both of those
      # answer a narrower question: a checkout may be read-only for unrelated
      # reasons, and a store path is not the only tree we must refuse to write.
      guardPreamble = ''
        need_writable_checkout() {
          if [ "$REPO_ROOT" != "$SRC_ROOT" ]; then
            return 0
          fi
          echo "''${0##*/}: this command rewrites files, so it needs a writable" >&2
          echo "checkout of this repo -- and standing in $PWD there is none: no" >&2
          echo "parent directory carries this flake's flake.nix. The only tree in" >&2
          echo "reach is the read-only store snapshot $SRC_ROOT, and rewriting" >&2
          echo "$PWD instead is exactly the bug this guard exists to prevent." >&2
          echo "cd into the repo (or \`nix develop\` it), or pass an explicit path." >&2
          exit 1
        }
      '';

      # One derivation per command, reused by both `apps` and the dev shell, so
      # the two can never diverge. `dev-` prefixed because a bare `test` binary
      # earlier on PATH would shadow the POSIX shell builtin and quietly break
      # every script in the repo that uses it.
      #
      # writeShellApplication, not writeShellScriptBin: it runs shellcheck at
      # BUILD time and sets `set -euo pipefail`, so an unquoted $@ or a silently
      # ignored failure is a `nix flake check` failure rather than a surprise in
      # front of an agent.
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
              ${guardPreamble}
              ${ldPreamble pkgs}
              ${cmd.text}
            '';
          }
        ) (commands pkgs);

      # `dev-help` is generated from the same attrset as everything else, so it
      # cannot describe a verb that does not exist or miss one that does. No
      # runtimeInputs: printing the map must work with nothing installed.
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

      # The regression gate for rootPreamble and guardPreamble, which are the
      # two pieces of this flake that can silently damage a tree that is not
      # this repo. It tests the MECHANISM, not any verb, which is precisely what
      # makes it fleet-generic: it needs to know nothing about what this repo
      # does, only that the anchor resolves and the guard refuses.
      #
      # The decoy is a real directory carrying a real flake.nix that differs.
      # Marker-file anchors pass a decoy like this -- that is the whole point of
      # the probe -- and so does any anchor that trusts `pwd`. Probe 2 is the
      # other half, and without it a guard that refused everything would score a
      # perfect pass: a tree that IS byte-identical must still be adopted, or
      # every mutating verb in the repo is dead. Probe 3 pins the subdirectory
      # case, which is the normal one for an agent working inside a repo.
      #
      # A per-repo probe that drives the actual verbs is strictly better and
      # cannot live here -- it has to know which verb writes and which needs a
      # network. INTERFACE.md shows how to add one via `extraChecks`.
      anchorCheck =
        pkgs:
        pkgs.runCommand "anchor-check" { } ''
          set -euo pipefail

          # The two preambles under test, verbatim, in a file the probes source.
          # A quoted heredoc, so every $ below is the bash the wrappers see.
          cat > preamble.sh <<'CANONICAL_PREAMBLE_EOF'
          ${rootPreamble}
          ${guardPreamble}
          CANONICAL_PREAMBLE_EOF

          mkdir decoy
          printf '{\n  description = "a different repo";\n  outputs = _: { };\n}\n' > decoy/flake.nix
          printf 'do not touch me\n' > decoy/victim.txt
          cp -r decoy decoy.orig

          # ---- probe 1: a foreign tree must not be adopted ----
          if ! ( cd decoy && . ../preamble.sh && [ "$REPO_ROOT" = "$SRC_ROOT" ] ); then
            echo "anchor adopted a directory that is not this repo" >&2
            exit 1
          fi
          # In a subshell: need_writable_checkout ends in `exit`, which would
          # otherwise take this whole build down instead of failing a condition.
          if ( cd decoy && . ../preamble.sh && need_writable_checkout ) > guard.log 2>&1; then
            echo "need_writable_checkout accepted a tree that is not this repo" >&2
            exit 1
          fi
          if ! diff -r decoy decoy.orig; then
            echo "the probes modified the foreign tree" >&2
            exit 1
          fi

          # ---- probe 2: a byte-identical checkout must be adopted ----
          cp -r ${lib.escapeShellArg "${self}"} checkout
          chmod -R u+w checkout
          if ! ( cd checkout && . ../preamble.sh &&
                 [ "$REPO_ROOT" = "$(pwd -P)" ] && need_writable_checkout ); then
            echo "anchor refused a byte-identical checkout of this repo" >&2
            exit 1
          fi

          # ---- probe 3: from a subdirectory, still the checkout root ----
          mkdir -p checkout/probe3/deeper
          if ! ( cd checkout/probe3/deeper && . ../../../preamble.sh &&
                 [ "$REPO_ROOT" = "$(cd -P ../.. && pwd)" ] ); then
            echo "anchor did not walk up to the checkout root from a subdirectory" >&2
            exit 1
          fi

          touch "$out"
        '';
    in
    {
      # `nix flake show` -- the discovery entrypoint, and deliberately the whole
      # machine-facing contract: every app carries a meta.description, which
      # `nix flake show` prints inline and `nix flake show --json` exposes at
      # .apps.<system>.<name>.description. Pure evaluation, so an agent gets the
      # entire command map in one cheap call without reading a README.
      #
      # Do NOT invent a top-level output for this (`agentManifest`, `probeThing`
      # ...). Nix answers with `warning: unknown flake output '<name>'` on every
      # single `nix flake check`, forever.
      apps = forAllSystems (
        pkgs:
        lib.mapAttrs (name: cmd: {
          type = "app";
          program = "${(wrappers pkgs).${name}}/bin/dev-${name}";
          meta.description = cmd.description;
        }) (commands pkgs)
      );

      # `nix develop` -- the toolchain, plus a dev-<verb> for every app.
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = toolchain pkgs ++ lib.attrValues (wrappers pkgs) ++ [ (helpFor pkgs) ];

          env = envVars pkgs;

          # Natively-compiled extension modules are routinely built at -O0,
          # where glibc's _FORTIFY_SOURCE stops being a warning and becomes a
          # hard error.
          hardeningDisable = [ "fortify" ];

          shellHook = ''
            # mkShell inherits SOURCE_DATE_EPOCH=315532800 (1980-01-01) from
            # stdenv, and any wheel or zip built in here then dies with "ZIP does
            # not support timestamps before 1980".
            unset SOURCE_DATE_EPOCH

            # $REPO_ROOT and $SRC_ROOT are exported here as a convenience for
            # the human at the prompt. Every wrapper re-resolves them from
            # scratch and none of them reads these, on purpose: a stale value
            # exported by one repo's shell must never steer another repo's verb.
            ${rootPreamble}
            ${ldPreamble pkgs}

            # Nothing networked, nothing stateful and nothing interactive above
            # this line, and nothing below it either. No environment
            # bootstrapping, no dependency installation, no `read`, no
            # `exec $SHELL`. Bootstrapping in the hook makes a cold
            # `nix develop -c <anything>` start downloading before it runs
            # anything, on EVERY invocation -- the exact failure an unattended
            # agent cannot diagnose. That is what a `setup` verb is for.

            # The banner is interactive-only, and this guard is load-bearing:
            # shellHook output lands on the STDOUT of `nix develop -c <cmd>`, so
            # an unguarded echo corrupts anything parsing it
            # (`nix develop -c cat x.json | jq` fails to parse). $- is the only
            # reliable discriminator here -- it lacks `i` for `nix develop -c`
            # and has it at an interactive prompt. Do not test $PS1 (unset in
            # both) or $IN_NIX_SHELL (set in both). >&2 is the second layer, for
            # the case where a caller runs us on a pty.
            case $- in
              *i*) echo "${repoName} dev shell -- 'dev-help' for the command map" >&2 ;;
            esac
          '';
        };
      });

      # `nix flake check` -- honest by construction, and the only gate this
      # style has. `toolchain` realises the whole toolchain closure (so a typo'd
      # or currently-broken attr fails here, not halfway through a task) and
      # builds every wrapper, which runs shellcheck over every command text.
      # `anchoring` is the regression test described above.
      #
      # Repo-specific checks go in `extraChecks`, never here. They may not
      # shadow either canonical name: silently replacing `anchoring` with
      # something weaker is the exact failure this whole file exists to make
      # impossible, so a collision is an eval error with both names in it.
      #
      # NEVER add a check that always passes. An agent reads "all checks
      # passed!" as a signal, and a fake check makes `nix flake check` a liar.
      checks = forAllSystems (
        pkgs:
        let
          canonical = {
            toolchain =
              pkgs.runCommand "toolchain-check"
                {
                  nativeBuildInputs = toolchain pkgs ++ lib.attrValues (wrappers pkgs) ++ [ (helpFor pkgs) ];
                }
                ''
                  set -euo pipefail
                  dev-help > help.txt

                  # A while-read over a heredoc rather than `for x in <list>`,
                  # which is a bash syntax error when the list is empty -- and a
                  # repo with no verbs yet is a legitimate state.
                  while IFS= read -r verb; do
                    [ -n "$verb" ] || continue
                    command -v "dev-$verb" > /dev/null || {
                      echo "dev-$verb is not on PATH" >&2
                      exit 1
                    }
                    grep -q -- "dev-$verb" help.txt || {
                      echo "dev-$verb is missing from the dev-help map" >&2
                      exit 1
                    }
                  done <<'CANONICAL_VERBS_EOF'
                  ${lib.concatStringsSep "\n" (lib.attrNames (commands pkgs))}
                  CANONICAL_VERBS_EOF

                  touch "$out"
                '';
            anchoring = anchorCheck pkgs;
          };
          extra = extraChecks pkgs;
          clash = lib.intersectLists (lib.attrNames canonical) (lib.attrNames extra);
        in
        if clash != [ ] then
          throw "extraChecks must not redefine canonical checks: ${lib.concatStringsSep ", " clash}"
        else
          canonical // extra
      );

      # `nix fmt` -- formats the *Nix* in this repo; project code gets a `fmt`
      # verb. nixfmt-tree (the treefmt wrapper) rather than bare nixfmt, because
      # bare nixfmt tries to parse every path handed to it and fails on non-Nix
      # files. This file ships already formatted, so `nix fmt` is a no-op rather
      # than a diff across the fleet.
      #
      # This is the one verb here NOT anchored to $REPO_ROOT, and it cannot be:
      # `nix fmt` is nix's own verb, and nix -- not this flake -- decides which
      # paths the formatter receives, passing the cwd when the user names none.
      # A wrapper that overrode them would break `nix fmt path/to/one/file.nix`,
      # and it cannot tell that "." apart from the default. So `nix fmt` formats
      # where you stand, by design; the `fmt` verb is the anchored one.
      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
# >>>>> END CANONICAL MACHINERY v1 <<<<<
