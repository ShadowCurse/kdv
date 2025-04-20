const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("bindings/c.zig").c;

dev: *c.struct_gbm_device,
surface: *c.struct_gbm_surface,
width: u32,
height: u32,

const Self = @This();
pub fn init(fd: std.posix.fd_t, mode: c.drm_mode_modeinfo) Self {
    const dev = c.gbm_create_device(fd).?;
    const surface = c.gbm_surface_create(
        dev,
        mode.hdisplay,
        mode.vdisplay,
        c.GBM_FORMAT_XRGB8888,
        c.GBM_BO_USE_SCANOUT | c.GBM_BO_USE_RENDERING,
    ).?;

    return .{
        .dev = dev,
        .surface = surface,
        .width = mode.hdisplay,
        .height = mode.vdisplay,
    };
}
