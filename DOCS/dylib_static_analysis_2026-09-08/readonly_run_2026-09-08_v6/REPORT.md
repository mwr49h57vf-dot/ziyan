# .53 Dynamic Library Gap Static Analysis, v6

Date: 2026-09-08

Scope:

1. `/Users/mac/Desktop/触动精灵deb/拆解分析/触动16版`
2. `/Users/mac/Desktop/ZiYan_副本/ZiYan学习/逆向学习/corpus/touchsprite_helpdoc`

This report is static evidence only. The v6 evidence set is authoritative. The
earlier v5 candidate index parsed fat Mach-O `file` output incorrectly and is
not used.

## Status

Observed .53 error baseline:

```text
Lua: /var/jb/usr/lib/ziyan/bin/lua5.3
missing: /usr/lib/ziyan/lib/liblua5.3.dylib
exit: 134
```

Verdict: `STATIC_REVIEW_ONLY`

Device processing eligibility: **NO**. Static analysis proves a ZiYan-owned
arm64 Lua candidate and its local build-tree closure, but does not prove that
the rootless device resolves the absolute rootful install name, has the final
payload, or reaches a successful runtime response.

Operation state: `install=0, device-write=0, unfreeze-.53=0, restore=0, restart=0`.

## File Inventory

| Input | Files | Mach-O | Archives | Result |
|---|---:|---:|---:|---|
| TouchSprite unpacked input | 178 | 13 | 2 | Rootless TouchSprite application and control material |
| TouchSprite help corpus | 37 | 0 | 0 | `.txt`, `.html`, and `.DS_Store` only |

The full path lists and one `file` result for every regular file are:

- `target1_file_list.txt`, `target1_file_types.txt`
- `target2_file_list.txt`, `target2_file_types.txt`

The two archives are `ts_control.tar.gz` and `ts_data.tar.gz`. Their `file`,
SHA-256, and `tar -tzvf` listings are in `target1_archive_listing.txt`.
Neither listing contains `ZiYan`, `lua5.3`, `liblua5.3`, or `libreadline`.

The 13 TouchSprite Mach-O candidates, each with an absolute path, `file`,
architecture, SHA-256, `otool -L`, `otool -D`, `otool -l`, extracted
`LC_ID_DYLIB`/`LC_LOAD_DYLIB`/`LC_RPATH`, `nm -gU`, and relevant `strings`,
are enumerated in `candidates/manifest.tsv`. The candidates are:

```text
Hades
OcrPlugin.dylib
TSDaemon
TSInstaller
TSLn
TSUpdate
TouchSpritePe
libs/luasql.so
libs/sz.so
model.so
paddleocr.so
unzip
TSTweak.dylib
```

## Mach-O Dependency Evidence

The .53 interpreter candidate is a ZiYan-owned arm64 executable:

```text
path: /Users/mac/Desktop/ZiYan_副本/vendor/bin/lua5.3
SHA-256: 7f73822f9fb7461e1b0e7b73911ba05210e070a19a4f51504b527f41e6fa049e
LC_LOAD_DYLIB: /usr/lib/ziyan/lib/liblua5.3.dylib
LC_LOAD_DYLIB: /usr/lib/libSystem.B.dylib
LC_LOAD_DYLIB: /usr/lib/ziyan/lib/libreadline.8.dylib
LC_RPATH: /usr/lib/ziyan/lib
```

The staged rootless copy is byte-identical and is physically located at:

```text
.theos/_/var/jb/usr/lib/ziyan/bin/lua5.3
```

`liblua5.3.dylib` is also arm64 and byte-identical in the vendor and staged
locations:

```text
SHA-256: 51ca786549e916d89a4b1264b1398c5abbe516dc3a501fc326ea4bb3f3003ae5
LC_ID_DYLIB: /usr/lib/ziyan/lib/liblua5.3.dylib
LC_LOAD_DYLIB: /usr/lib/libSystem.B.dylib
compatibility version: 5.3.0
current version: 5.3.5
```

The selected exported ABI symbols are identical in both copies:

```text
_luaL_checkversion_  _luaL_newstate  _luaL_openlibs
_lua_close           _lua_load       _lua_newstate
_lua_pcallk          _lua_resume     _lua_version  _lua_yieldk
```

`libreadline.8.dylib` is a relative symlink to `libreadline.8.0.dylib` in
both vendor and staged trees. The target file is arm64, has SHA-256
`e7e5375f077da88f6165313175b6ba51b4db81f77fc7763fe1ca3ddf1e1e8560`,
and loads `/usr/lib/libncurses.6.dylib` plus `libSystem`. Its own
`LC_ID_DYLIB` is `/usr/lib/ziyan/lib/libreadline.8.0.dylib`; this is a
static closure risk because the interpreter asks for the `.8` symlink name.

All raw evidence is in `ziyan_candidates/` and
`ziyan_candidates/path_load_extracts.txt`.

## Root Cause Classification

1. **Rootless path versus absolute install-name mismatch, high confidence.**
   The observed executable path is under `/var/jb/usr/lib/ziyan`, while the
   interpreter and `liblua5.3.dylib` encode absolute `/usr/lib/ziyan` paths.
   `DYLD_LIBRARY_PATH=/var/jb/usr/lib/ziyan/lib` is present in rootless
   scripts, but it does not prove that dyld resolves a failed absolute
   `LC_LOAD_DYLIB` request through that variable.

2. **Static build placement is not dynamic loader proof, high confidence.**
   `Makefile` stages `vendor/bin/` and `vendor/lib/` at
   `$DEST/usr/lib/ziyan/...`; comments state Theos remaps that staging tree to
   `var/jb/...` for rootless packaging. The same Makefile explicitly rewrites
   and re-signs a separate engine dylib's rootless install name, but there is
   no corresponding static rewrite for `liblua5.3.dylib`.

3. **Readline closure is locally present but runtime-unproven, medium
   confidence.** The `.8` symlink exists in the local build/staging tree and
   closes the interpreter's filename request there. The actual .53 loader
   resolution and `libncurses.6.dylib` availability remain unobserved.

4. **`exit 134` is an abort outcome, not a localized cause.** Static evidence
   relates it to the reported missing dylib path, but does not identify the
   abort site.

## ZiYan Candidate Library Evidence

| Candidate | Source and equality | Architecture and ABI | Install-name relationship | Risk and qualification |
|---|---|---|---|---|
| `vendor/lib/liblua5.3.dylib` | ZiYan vendor input; SHA above | arm64; Lua 5.3 exports listed above | `LC_ID_DYLIB` exactly matches the missing `/usr/lib/ziyan/lib/liblua5.3.dylib` | ZiYan source, architecture, and ABI are statically proven. Rootless dyld mapping and final package payload are not. Review-only candidate; no installation authorization. |
| `.theos/_/var/jb/usr/lib/ziyan/lib/liblua5.3.dylib` | `cmp=0` with vendor copy | arm64; same exports and versions | Physical rootless staging path, but embedded ID remains rootful absolute path | Same static qualification and same runtime risk. Review-only candidate. |
| `vendor/lib/libreadline.8.0.dylib` and staged copy | `cmp=0`; `.8` symlink in both trees | arm64 | Interpreter asks for `.8`; actual file ID is `.8.0` | Supporting closure only, not the observed missing Lua library. Runtime compatibility and `ncurses` availability unproven. |

The rootless arm64 deb selected by filename for a package-content check was:

```text
packages/com.ziyan.ziyan_0.0.92-8-161-205-C-65.11-98+debug-10-38-17-142+debug_iphoneos-arm64.deb
SHA-256: d8def150412f0c23769eaea96e98d2659ce762d67bdae7b4f30b0574f80681a1
```

`dpkg-deb` is not installed on this Mac (`exit 127`), so the final deb's
runtime payload was not proven by archive inspection. Do not infer package
contents from the local staging tree.

For all 13 TouchSprite Mach-O candidates:

```text
DYLIB_SOURCE_OR_ABI_UNPROVEN
```

Their ZiYan source provenance is absent, and they are excluded as candidates
for the ZiYan missing library even where they contain an arm64 slice.

## TouchSprite and ZiYan Boundary

- TouchSprite inputs are evidence of a separate rootless application
  environment, not a ZiYan runtime payload source.
- `TSTweak.dylib` has `@rpath/TSTweakNoRoot.dylib` and rootless
  `/var/jb/Library/Frameworks` and `/var/jb/usr/lib` rpaths. This shows that
  TouchSprite uses its own rootless linking choices; it does not establish a
  ZiYan dyld mapping.
- `OcrPlugin.dylib`, `luasql.so`, `sz.so`, `TSDaemon`, and the other
  TouchSprite binaries have TouchSprite-specific IDs, dependencies, or
  application locations. None encodes the ZiYan Lua install name.
- The help corpus contains documentation only and no Mach-O or archive.

## Unresolved Questions

1. Does .53 dyld resolve `/usr/lib/ziyan/lib/liblua5.3.dylib` to the physical
   rootless `/var/jb/usr/lib/ziyan/lib/liblua5.3.dylib` location?
2. Does the final arm64 deb contain the expected rootless Lua runtime files
   and the `libreadline.8.dylib` symlink?
3. Is `/usr/lib/libncurses.6.dylib` available and ABI-compatible on .53?
4. What exact runtime path produces `exit 134` after the missing-library
   message?

Until all applicable questions have device-side evidence, the static state is
not sufficient to enter device processing.

## Commands and Output Locations

The first commands were:

```text
python3 tools/ziyan_codex_checkpoint.py show
git status --short
```

The full expanded list of 367 read-only commands is:

```text
/Users/mac/Desktop/ZiYan_副本/DOCS/dylib_static_analysis_2026-09-08/readonly_run_2026-09-08_v6/commands_expanded.txt
```

It records `find`, `file`, `tar -tzvf`, `lipo -info`, `otool -L`,
`otool -D`, `otool -l`, `nm -gU`, `strings -a`, `shasum -a 256`, `rg`,
`cmp -s`, `ls -l`, `readlink`, and the failed read-only `dpkg-deb -c`
attempt. The complete v6 output directory is:

```text
/Users/mac/Desktop/ZiYan_副本/DOCS/dylib_static_analysis_2026-09-08/readonly_run_2026-09-08_v6
```

Awaiting human review. No device action is authorized by this report.
