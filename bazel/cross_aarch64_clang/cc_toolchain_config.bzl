load("@bazel_tools//tools/build_defs/cc:action_names.bzl", "ACTION_NAMES")
load(
    "@bazel_tools//tools/cpp:cc_toolchain_config_lib.bzl",
    "feature",
    "flag_group",
    "flag_set",
    "tool_path",
)

_ARMGNU = "external/aarch64_linux_toolchain"

_COMPILE_ACTIONS = [
    ACTION_NAMES.c_compile,
    ACTION_NAMES.cpp_compile,
    ACTION_NAMES.linkstamp_compile,
    ACTION_NAMES.assemble,
    ACTION_NAMES.preprocess_assemble,
    ACTION_NAMES.cpp_header_parsing,
    ACTION_NAMES.cpp_module_compile,
    ACTION_NAMES.cpp_module_codegen,
    ACTION_NAMES.clif_match,
]

_LINK_ACTIONS = [
    ACTION_NAMES.cpp_link_executable,
    ACTION_NAMES.cpp_link_dynamic_library,
    ACTION_NAMES.cpp_link_nodeps_dynamic_library,
]

def _impl(ctx):
    cross_flags = [
        "--target=aarch64-linux-gnu",
        "-march=armv8.2-a+dotprod",
        "--sysroot=%s/aarch64-none-linux-gnu/libc" % _ARMGNU,
        "--gcc-toolchain=%s" % _ARMGNU,
        "-no-canonical-prefixes",
    ]

    features = [
        feature(
            name = "cross_compile_flags",
            enabled = True,
            flag_sets = [
                flag_set(
                    actions = _COMPILE_ACTIONS,
                    flag_groups = [flag_group(flags = cross_flags + [
                        "-fPIC",
                        "-U_FORTIFY_SOURCE",
                        "-fstack-protector",
                        "-Wno-unused-command-line-argument",
                    ])],
                ),
            ],
        ),
        feature(
            name = "cross_link_flags",
            enabled = True,
            flag_sets = [
                flag_set(
                    actions = _LINK_ACTIONS,
                    flag_groups = [flag_group(flags = cross_flags + [
                        "-fuse-ld=lld",
                        "-Wl,-no-as-needed",
                        "-lstdc++",
                        "-lm",
                        "-lpthread",
                        "-ldl",
                    ])],
                ),
            ],
        ),
        # Bazel enables these by name; provide no-op stubs so requests resolve.
        feature(name = "supports_dynamic_linker", enabled = True),
        feature(name = "supports_pic", enabled = True),
    ]

    tool_paths = [
        tool_path(name = "gcc", path = "wrappers/clang"),
        tool_path(name = "cpp", path = "wrappers/clang"),
        tool_path(name = "ld", path = "wrappers/clang"),
        tool_path(name = "ar", path = "wrappers/llvm-ar"),
        tool_path(name = "nm", path = "wrappers/llvm-nm"),
        tool_path(name = "objcopy", path = "wrappers/llvm-objcopy"),
        tool_path(name = "objdump", path = "wrappers/llvm-objdump"),
        tool_path(name = "strip", path = "wrappers/llvm-strip"),
    ]

    return cc_common.create_cc_toolchain_config_info(
        ctx = ctx,
        toolchain_identifier = "clang-aarch64-linux-gnu",
        host_system_name = "x86_64-unknown-linux-gnu",
        target_system_name = "aarch64-unknown-linux-gnu",
        target_cpu = "aarch64",
        target_libc = "glibc",
        compiler = "clang",
        abi_version = "aarch64",
        abi_libc_version = "glibc",
        features = features,
        tool_paths = tool_paths,
        cxx_builtin_include_directories = [
            "%s/lib/gcc/aarch64-none-linux-gnu/11.3.1/../../../../aarch64-none-linux-gnu/include/c++/11.3.1" % _ARMGNU,
            "%s/lib/gcc/aarch64-none-linux-gnu/11.3.1/../../../../aarch64-none-linux-gnu/include/c++/11.3.1/aarch64-none-linux-gnu" % _ARMGNU,
            "%s/lib/gcc/aarch64-none-linux-gnu/11.3.1/../../../../aarch64-none-linux-gnu/include/c++/11.3.1/backward" % _ARMGNU,
            "/usr/lib/llvm-21/lib/clang/21/include",
            "/usr/lib/clang/21/include",
            "%s/lib/gcc/aarch64-none-linux-gnu/11.3.1/../../../../aarch64-none-linux-gnu/include" % _ARMGNU,
            "%s/aarch64-none-linux-gnu/libc/usr/include" % _ARMGNU,
            "%s/aarch64-none-linux-gnu/include" % _ARMGNU,
        ],
    )

cc_toolchain_config = rule(
    implementation = _impl,
    attrs = {},
    provides = [CcToolchainConfigInfo],
)
