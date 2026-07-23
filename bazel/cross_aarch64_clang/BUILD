package(default_visibility = ["//visibility:public"])

load(":cc_toolchain_config.bzl", "cc_toolchain_config")

# Cross-compilation recipe: glibc aarch64 target on an x86_64 Linux host,
# using host clang as the cross front-end over TensorFlow's prebuilt ARM-GNU
# 11.3 aarch64-none-linux-gnu glibc sysroot (@aarch64_linux_toolchain).
#
# Same sysroot as //cross_aarch64 (gcc recipe) -> identical bundle/licensing.
# clang is used because ARM-GNU gcc-11 rejects the Clang NEON attribute
# target("dotprod") in LiteRT's aarch64 TFLite optimized kernels.
#
# Build:
#   bazel build //cross_aarch64_clang:hello \
#       --platforms=//cross_aarch64_clang:linux_aarch64 \
#       --extra_toolchains=//cross_aarch64_clang:cc_toolchain_aarch64_clang

filegroup(
    name = "wrapper_scripts",
    srcs = glob(["wrappers/*"]),
)

filegroup(
    name = "all_files",
    srcs = [
        ":wrapper_scripts",
        "@aarch64_linux_toolchain//:compiler_components",
        "@aarch64_linux_toolchain//:compiler_pieces",
    ],
)

cc_toolchain_config(
    name = "clang_aarch64_config",
)

cc_toolchain(
    name = "clang_aarch64_toolchain",
    all_files = ":all_files",
    ar_files = ":all_files",
    compiler_files = ":all_files",
    dwp_files = ":all_files",
    linker_files = ":all_files",
    objcopy_files = ":all_files",
    strip_files = ":all_files",
    supports_param_files = 1,
    toolchain_config = ":clang_aarch64_config",
    toolchain_identifier = "clang-aarch64-linux-gnu",
)

toolchain(
    name = "cc_toolchain_aarch64_clang",
    exec_compatible_with = [
        "@platforms//os:linux",
        "@platforms//cpu:x86_64",
    ],
    target_compatible_with = [
        "@platforms//os:linux",
        "@platforms//cpu:aarch64",
    ],
    toolchain = ":clang_aarch64_toolchain",
    toolchain_type = "@bazel_tools//tools/cpp:toolchain_type",
)

platform(
    name = "linux_aarch64",
    constraint_values = [
        "@platforms//os:linux",
        "@platforms//cpu:aarch64",
    ],
)

cc_binary(
    name = "hello",
    srcs = ["hello.cc"],
)
