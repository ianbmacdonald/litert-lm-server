package(default_visibility = ["//visibility:public"])

# Cross-compilation recipe: glibc aarch64 target on an x86_64 Linux host.
#
# Binds TensorFlow's prebuilt ARM-GNU 11.3 aarch64-none-linux-gnu cc_toolchain
# (@local_config_embedded_arm//:cc-compiler-aarch64, provisioned by the
# elinux_aarch64 machinery) to @platforms//cpu:aarch64 via a modern toolchain()
# rule so Bazel platform resolution selects it under --platforms.
#
# Build:
#   bazel build //cross_aarch64:hello \
#       --platforms=//cross_aarch64:linux_aarch64 \
#       --extra_toolchains=//cross_aarch64:cc_toolchain_aarch64_linux_gnu

platform(
    name = "linux_aarch64",
    constraint_values = [
        "@platforms//os:linux",
        "@platforms//cpu:aarch64",
    ],
)

toolchain(
    name = "cc_toolchain_aarch64_linux_gnu",
    exec_compatible_with = [
        "@platforms//os:linux",
        "@platforms//cpu:x86_64",
    ],
    target_compatible_with = [
        "@platforms//os:linux",
        "@platforms//cpu:aarch64",
    ],
    toolchain = "@local_config_embedded_arm//:cc-compiler-aarch64",
    toolchain_type = "@bazel_tools//tools/cpp:toolchain_type",
)

cc_binary(
    name = "hello",
    srcs = ["hello.cc"],
)
