#!/usr/bin/env python3
"""Collect the license files of everything litert-lm-server (musl) links into <out>/.

Every component listed in INDEX.md has at least one file copied from the fetched sources; a
component whose files cannot be found is listed under "Gaps" instead and makes the script exit
non-zero unless --allow-gaps is given.
"""
import argparse
import fnmatch
import json
import os
import shutil
import subprocess
import sys

LICENSE_GLOBS = ["license*", "licence*", "copying*", "copyright*", "notice*", "unlicense*", "patents*"]


def git_rev(path):
    try:
        return subprocess.run(["git", "-C", path, "rev-parse", "HEAD"], check=True,
                              capture_output=True, text=True).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""


def git_describe(path):
    try:
        return subprocess.run(["git", "-C", path, "describe", "--tags", "--exact-match"], check=True,
                              capture_output=True, text=True).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""


def root_license_files(root):
    found = []
    try:
        names = sorted(os.listdir(root))
    except FileNotFoundError:
        return found
    for n in names:
        p = os.path.join(root, n)
        if os.path.isfile(p) and any(fnmatch.fnmatch(n.lower(), g) for g in LICENSE_GLOBS):
            found.append(p)
    return found


class Collector:
    def __init__(self, out):
        self.out = out
        self.rows = []
        self.gaps = []
        self.flags = []

    def add(self, name, slug, root, license_id, version="", files=None, extra=None, note=""):
        """files: explicit paths relative to root; default = root-level license files.
        extra: additional (relative) paths to copy when present."""
        if not os.path.isdir(root):
            self.gaps.append((name, f"source dir not found: {root}"))
            return
        if files:
            paths = [os.path.join(root, f) for f in files if os.path.isfile(os.path.join(root, f))]
        else:
            paths = root_license_files(root)
        for f in extra or []:
            p = os.path.join(root, f)
            if os.path.isfile(p):
                paths.append(p)
        if not paths:
            self.gaps.append((name, f"no license file found under {root}"))
            return
        dest = os.path.join(self.out, slug)
        os.makedirs(dest, exist_ok=True)
        copied = []
        for p in paths:
            rel = os.path.relpath(p, root).replace(os.sep, "__")
            shutil.copyfile(p, os.path.join(dest, rel))
            copied.append(f"{slug}/{rel}")
        if not version:
            rev = git_rev(root)
            tag = git_describe(root)
            version = f"{tag} ({rev[:12]})" if tag and rev else rev[:12]
        self.rows.append((name, version or "?", license_id, copied, note))

    def add_file(self, name, dest_name, src, license_id, version, note=""):
        if not os.path.isfile(src):
            self.gaps.append((name, f"file not found: {src}"))
            return
        shutil.copyfile(src, os.path.join(self.out, dest_name))
        self.rows.append((name, version, license_id, [dest_name], note))

    def add_header_notice(self, name, slug, header, license_id, version):
        """Copy the leading /* ... */ comment of a source header verbatim, for projects whose license
        terms live only there."""
        if not os.path.isfile(header):
            self.gaps.append((name, f"file not found: {header}"))
            return
        text = open(header, encoding="utf-8", errors="replace").read()
        if not text.startswith("/*") or "*/" not in text:
            self.gaps.append((name, f"no leading comment in {header}"))
            return
        dest = os.path.join(self.out, slug)
        os.makedirs(dest, exist_ok=True)
        fname = os.path.basename(header) + ".license-notice.txt"
        with open(os.path.join(dest, fname), "w") as f:
            f.write(text[: text.index("*/") + 2] + "\n")
        self.rows.append((name, version, license_id, [f"{slug}/{fname}"],
                          f"verbatim leading comment of {os.path.basename(header)}"))

    def rust_crates(self, label, manifest, target):
        cmd = ["cargo", "metadata", "--format-version", "1", "--locked", "--offline",
               "--filter-platform", target, "--manifest-path", manifest]
        try:
            meta = json.loads(subprocess.run(cmd, check=True, capture_output=True, text=True).stdout)
        except subprocess.CalledProcessError as e:
            self.gaps.append((f"Rust crates of {label}", f"cargo metadata failed: {e.stderr.strip()[:300]}"))
            return set()
        pkgs = {p["id"]: p for p in meta["packages"]}
        nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}
        root = meta["resolve"]["root"]
        seen, stack = set(), [root]
        while stack:
            pid = stack.pop()
            if pid in seen:
                continue
            seen.add(pid)
            for d in nodes[pid]["deps"]:
                kinds = {k["kind"] for k in d["dep_kinds"]}
                if None not in kinds:
                    continue  # build- or dev-only edge: not linked into the staticlib
                dp = pkgs[d["pkg"]]
                if any("proc-macro" in t["kind"] for t in dp["targets"]):
                    continue  # runs in the compiler, not linked
                stack.append(d["pkg"])
        return {pid for pid in seen}, pkgs

    def rust(self, sets):
        crates = {}
        for pids, pkgs in sets:
            for pid in pids:
                p = pkgs[pid]
                if p["source"] is None:
                    continue  # workspace/path crates are covered by their parent project
                crates[(p["name"], p["version"])] = p
        for (name, ver), p in sorted(crates.items()):
            root = os.path.dirname(p["manifest_path"])
            files = root_license_files(root)
            if p.get("license_file"):
                lf = os.path.join(root, p["license_file"])
                if os.path.isfile(lf) and lf not in files:
                    files.append(lf)
            extra = []
            if name == "onig_sys":
                extra = [os.path.join(root, "oniguruma", "COPYING")]
            if not files:
                self.gaps.append((f"Rust crate {name} {ver} ({p.get('license')})",
                                  f"no license file in {root}"))
                continue
            slug = f"rust/{name}-{ver}"
            dest = os.path.join(self.out, slug)
            os.makedirs(dest, exist_ok=True)
            copied = []
            for f in files + [e for e in extra if os.path.isfile(e)]:
                rel = os.path.relpath(f, root).replace(os.sep, "__")
                shutil.copyfile(f, os.path.join(dest, rel))
                copied.append(f"{slug}/{rel}")
            label = f"Rust crate {name}"
            if name == "onig_sys":
                label += " (bundles oniguruma C library)"
            self.rows.append((label, ver, p.get("license") or "see file", copied, ""))

    def write_index(self, header):
        with open(os.path.join(self.out, "INDEX.md"), "w") as f:
            f.write(header)
            f.write("| Component | Version / commit | License | Files | Note |\n|---|---|---|---|---|\n")
            for name, ver, lic, files, note in self.rows:
                f.write(f"| {name} | {ver} | {lic} | {'<br>'.join(files)} | {note} |\n")
            f.write("\n## Flags for review\n\n")
            if self.flags:
                for fl in self.flags:
                    f.write(f"- {fl}\n")
            else:
                f.write("None.\n")
            f.write("\n## Gaps\n\n")
            if self.gaps:
                for name, why in self.gaps:
                    f.write(f"- {name}: {why}\n")
            else:
                f.write("None: every component above has at least one license file copied from its fetched source.\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--src", required=True, help="LiteRT-LM source tree")
    ap.add_argument("--build", required=True, help="superbuild dir")
    ap.add_argument("--lockfile", required=True, help="pinned tokenizers-c Cargo.lock")
    ap.add_argument("--out", required=True)
    ap.add_argument("--rust-target", default="x86_64-unknown-linux-musl")
    ap.add_argument("--allow-gaps", action="store_true")
    a = ap.parse_args()

    inner = os.path.join(a.build, "litert_lm", "build")
    ext = os.path.join(inner, "external")
    tfb = os.path.join(ext, "tensorflow", "src", "tflite_external-build")
    tp = os.path.join(inner, "third_party")
    lrb = os.path.join(ext, "litert", "src", "litert_external-build", "_deps")
    shutil.rmtree(a.out, ignore_errors=True)
    os.makedirs(a.out)
    c = Collector(a.out)

    # Our own code.
    c.add_file("litert-lm-server", "LICENSE.litert-lm-server", os.path.join(a.repo, "LICENSE"), "Apache-2.0",
               git_rev(a.repo)[:12])
    c.add_file("litert-lm-server NOTICE", "NOTICE", os.path.join(a.repo, "NOTICE"), "-", git_rev(a.repo)[:12])
    c.add_file("cpp-httplib (server third_party/httplib.h)", "LICENSE.cpp-httplib",
               os.path.join(a.repo, "third_party", "LICENSE.cpp-httplib"), "MIT", "v0.18.3")
    c.add_file("nlohmann/json (server third_party/json.hpp)", "LICENSE.nlohmann-json",
               os.path.join(a.repo, "third_party", "LICENSE.nlohmann-json"), "MIT", "v3.11.3")

    # LiteRT-LM and the projects its superbuild fetches.
    c.add("LiteRT-LM", "litert-lm", a.src, "Apache-2.0")
    c.add("LiteRT", "litert", os.path.join(ext, "litert", "src", "litert_external"), "Apache-2.0")
    c.add("TensorFlow Lite (tensorflow)", "tensorflow", os.path.join(ext, "tensorflow", "src", "tflite_external"),
          "Apache-2.0")
    c.add("Abseil", "abseil-cpp", os.path.join(ext, "abseil-cpp", "src", "absl_external"), "Apache-2.0")
    c.add("Protocol Buffers (incl. upb, utf8_range)", "protobuf",
          os.path.join(ext, "protobuf", "src", "protobuf_external"), "BSD-3-Clause",
          extra=["third_party/utf8_range/LICENSE"])
    c.add("FlatBuffers", "flatbuffers", os.path.join(ext, "flatbuffers", "src", "flatbuffers_external"), "Apache-2.0")
    c.add("RE2", "re2", os.path.join(ext, "re2", "src", "re2_external"), "BSD-3-Clause")
    c.add("SentencePiece", "sentencepiece", os.path.join(ext, "sentencepiece", "src", "sentencepiece_external"),
          "Apache-2.0", extra=["third_party/darts_clone/LICENSE", "third_party/esaxx/LICENSE"])
    tok = os.path.join(ext, "tokenizers-cpp", "src", "tokenizers-cpp_external")
    c.add("tokenizers-cpp", "tokenizers-cpp", tok, "Apache-2.0")
    c.add("SentencePiece (tokenizers-cpp submodule)", "tokenizers-cpp-sentencepiece",
          os.path.join(tok, "sentencepiece"), "Apache-2.0",
          extra=["third_party/darts_clone/LICENSE", "third_party/esaxx/LICENSE"])
    c.add("msgpack-c (tokenizers-cpp submodule)", "tokenizers-cpp-msgpack", os.path.join(tok, "msgpack"), "BSL-1.0")
    c.add("OpenCL headers", "opencl-headers", os.path.join(ext, "opencl_headers", "src", "opencl_headers_external"),
          "Apache-2.0", note="headers")
    c.add("ANTLR4 C++ runtime", "antlr4-runtime", os.path.join(inner, "_deps", "antlr_lib-src"), "BSD-3-Clause")
    c.add("kissfft", "kissfft", os.path.join(tp, "kissfft"), "BSD-3-Clause",
          extra=["LICENSES/BSD-3-Clause", "LICENSES/Unlicense"], note="shipped as lib/libkissfft-float.so.131")
    c.add("nlohmann/json (LiteRT-LM)", "nlohmann-json", os.path.join(tp, "json"), "MIT")
    # domoticz/minizip ships no LICENSE file; its zlib-style terms are the leading comment of unzip.h.
    c.add_header_notice("minizip (domoticz/minizip, zlib contrib)", "minizip",
                        os.path.join(tp, "minizip", "minizip", "unzip.h"), "Zlib", git_rev(os.path.join(tp, "minizip"))[:12])
    c.add("minja", "minja", os.path.join(tp, "minja"), "MIT")
    c.add("llguidance", "llguidance", os.path.join(tp, "llguidance"), "MIT")
    c.add("stb", "stb", os.path.join(tp, "stb_lib"), "MIT OR Unlicense")
    c.add("zlib (static, LiteRT-LM third_party)", "zlib", os.path.join(tp, "zlib"), "Zlib")
    c.add("libpng", "libpng", os.path.join(tp, "libpng"), "libpng-2.0")
    c.add("miniaudio", "miniaudio", os.path.join(tp, "miniaudio"), "Unlicense OR MIT-0")

    # TensorFlow Lite's own fetched dependencies.
    for name, d, lic, note, extra in [
        ("XNNPACK", "xnnpack", "BSD-3-Clause", "", None),
        ("pthreadpool", "pthreadpool-source", "BSD-2-Clause", "", None),
        ("cpuinfo", "cpuinfo", "BSD-2-Clause", "", None),
        ("FP16", "FP16-source", "MIT", "headers", None),
        ("FXdiv", "FXdiv-source", "MIT", "headers", None),
        ("ruy", "ruy", "Apache-2.0", "", None),
        ("gemmlowp", "gemmlowp", "Apache-2.0", "", None),
        ("Eigen", "eigen", "MPL-2.0 (+ BSD/Apache/MINPACK notices)", "headers", None),
        ("farmhash", "farmhash", "MIT", "", None),
        ("NEON_2_SSE", "neon2sse", "BSD-2-Clause", "headers", None),
        ("ml_dtypes", "ml_dtypes", "Apache-2.0", "headers", None),
    ]:
        c.add(name, f"tflite-deps/{d.replace('-source', '')}", os.path.join(tfb, d), lic, note=note, extra=extra)
    c.add("fft2d (Ooura)", "tflite-deps/fft2d", os.path.join(tfb, "fft2d"), "Ooura (permissive)",
          files=[f for f in ("readme2d.txt", "readme.txt", "LICENSE") if os.path.isfile(os.path.join(tfb, "fft2d", f))])

    # CPU-only build: patch 08 keeps LiteRT from configuring its NPU vendor tree, so no vendor SDK
    # (Qualcomm QAIRT, Samsung LiteCore, MediaTek NeuroPilot) is fetched or compiled in.
    for d in ("qnn_headers", "litecore_headers", "neuropilot_headers"):
        if os.path.exists(os.path.join(lrb, d)):
            c.gaps.append((f"vendor SDK {d}", f"{os.path.join(lrb, d)} exists: the NPU vendor tree was built"))

    # Rust: liblitert_lm_deps.a (LiteRT-LM Cargo.toml, via corrosion) and libtokenizers_c.a.
    sets = []
    r = c.rust_crates("LiteRT-LM (litert_lm_deps)", os.path.join(a.src, "Cargo.toml"), a.rust_target)
    if r:
        sets.append(r)
    tok_manifest = os.path.join(tok, "rust", "Cargo.toml")
    if not os.path.isfile(os.path.join(tok, "rust", "Cargo.lock")):
        shutil.copyfile(a.lockfile, os.path.join(tok, "rust", "Cargo.lock"))
    r = c.rust_crates("tokenizers-cpp (tokenizers-c)", tok_manifest, a.rust_target)
    if r:
        sets.append(r)
    c.rust(sets)
    sysroot = subprocess.run(["rustc", "--print", "sysroot"], capture_output=True, text=True).stdout.strip()
    rustver = subprocess.run(["rustc", "--version"], capture_output=True, text=True).stdout.strip()
    rdoc = os.path.join(sysroot, "share", "doc", "rust")
    rfiles = ["COPYRIGHT-library.html"]
    if os.path.isdir(os.path.join(rdoc, "licenses")):
        rfiles += [os.path.join("licenses", n) for n in sorted(os.listdir(os.path.join(rdoc, "licenses")))]
    c.add("Rust standard library (std/core/alloc, linked into the Rust staticlibs)", "rust-std", rdoc,
          "MIT OR Apache-2.0 (+ notices in COPYRIGHT-library.html)", version=rustver, files=rfiles)

    header = (
        "# Third-party licenses — litert-lm-server x86_64 musl\n\n"
        "Components statically linked into bin/litert-lm-server (or shipped in lib/), with the license\n"
        "files copied from the exact sources the build fetched. Generated by musl/collect-licenses.py.\n\n"
        "Not bundled (dynamically linked from the prplOS system): musl libc (MIT), libstdc++ and libgcc_s\n"
        "(GPL-3.0 WITH GCC-exception-3.1), zlib libz.so.1 (Zlib). The GCC runtime pieces linked statically\n"
        "(crt objects, libgcc.a, libstdc++ templates) are covered by the GCC Runtime Library Exception.\n\n"
    )
    c.write_index(header)
    print(f"{len(c.rows)} components, {len(c.gaps)} gaps, {len(c.flags)} flags")
    for g in c.gaps:
        print("GAP:", *g)
    if c.gaps and not a.allow_gaps:
        sys.exit(1)


if __name__ == "__main__":
    main()
