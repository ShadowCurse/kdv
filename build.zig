const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "kdv",
        .root_module = exe_mod,
    });
    exe.linkLibC();
    exe.linkSystemLibrary("gbm");

    var env_map = try std.process.getEnvMap(b.allocator);
    defer env_map.deinit();

    exe.addIncludePath(.{ .cwd_relative = env_map.get("VULKAN_INCLUDE_PATH").? });
    exe.linkSystemLibrary("vulkan");

    const shader_step = compile_shaders(b);
    b.default_step.dependOn(shader_step);

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

fn compile_shaders(b: *std.Build) *std.Build.Step {
    const shader_step = b.step("shaders", "Shader compilation");

    const shaders_dir = b.build_root.handle.openDir("shaders", .{ .iterate = true }) catch
        @panic("cannot open shader dir");

    var file_it = shaders_dir.iterate();
    while (file_it.next() catch @panic("cannot iterate shader dir")) |entry| {
        if (entry.kind == .file) {
            const ext = std.fs.path.extension(entry.name);
            if (std.mem.eql(u8, ext, ".glsl")) {
                const basename = std.fs.path.basename(entry.name);
                const name = basename[0 .. basename.len - ext.len];

                std.debug.print("build: compiling shader: {s}\n", .{name});

                const shader_type = if (std.mem.endsWith(u8, name, "frag"))
                    "-fshader-stage=fragment"
                else if (std.mem.endsWith(u8, name, "vert"))
                    "-fshader-stage=vertex"
                else
                    continue;

                const source_file_path =
                    std.fmt.allocPrint(b.allocator, "shaders/{s}.glsl", .{name}) catch unreachable;
                const output_file_path =
                    std.fmt.allocPrint(b.allocator, "{s}.spv", .{name}) catch unreachable;

                const command = b.addSystemCommand(&.{
                    "glslc",
                    shader_type,
                    source_file_path,
                    "-o",
                    output_file_path,
                });
                shader_step.dependOn(&command.step);
            }
        }
    }
    return shader_step;
}
