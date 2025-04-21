const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("bindings/c.zig").c;
const Gbm = @import("gbm.zig");
const drm = @import("drm.zig");
const vk = @import("bindings/vk.zig");

const vulkan = @import("vulkan.zig");

const TIMEOUT = std.math.maxInt(u64);

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    const alloc = gpa.allocator();

    const card_path = "/dev/dri/card0";
    std.log.info("open drm at: {s}", .{card_path});
    const drm_fd = try std.posix.open(card_path, .{ .ACCMODE = .RDWR }, 0);

    // Set ATOMIC cap for atomic commits.
    drm.set_client_cap(drm_fd, c.DRM_CLIENT_CAP_ATOMIC, 1);

    const resources = try drm.get_resources(alloc, drm_fd);
    const plane_ids = try drm.get_plane_resources(alloc, drm_fd);

    const planes = try alloc.alloc(drm.Plane, plane_ids.len);
    for (planes, plane_ids) |*plane, id|
        plane.* = try drm.get_plane(alloc, drm_fd, id);

    const connector = try drm.get_connector(alloc, drm_fd, resources.connector_ids[0]);
    const encoder = try drm.get_encoder(drm_fd, connector.encoder_id);

    var crtc_id: u32 = 0;
    for (resources.crtc_ids) |id| {
        if (id == encoder.crtc_id) {
            crtc_id = id;
            break;
        }
    }
    const crtc = try drm.get_crtc(drm_fd, crtc_id);
    if (crtc.fb_id == 0)
        return error.CrtcDoesNotHaveActiveFrameBuffer;

    var primary_plane: *drm.Plane = undefined;
    for (planes) |*p| {
        if (p.crtc_id == crtc.crtc_id and p.fb_id == crtc.fb_id)
            primary_plane = p;
    }

    const primary_plane_object_props = try drm.object_get_properties(
        alloc,
        drm_fd,
        primary_plane.plane_id,
        c.DRM_MODE_OBJECT_PLANE,
    );
    const primary_plane_props =
        try alloc.alloc(drm.Property, primary_plane_object_props.prop_ids.len);
    for (primary_plane_object_props.prop_ids, primary_plane_props) |id, *p| {
        p.* = try drm.get_property(alloc, drm_fd, id);
    }

    const crtc_object_props = try drm.object_get_properties(
        alloc,
        drm_fd,
        primary_plane.crtc_id,
        c.DRM_MODE_OBJECT_CRTC,
    );
    const crtc_props = try alloc.alloc(drm.Property, crtc_object_props.prop_ids.len);
    for (crtc_object_props.prop_ids, crtc_props) |id, *p| {
        p.* = try drm.get_property(alloc, drm_fd, id);
    }

    const connector_object_props = try drm.object_get_properties(
        alloc,
        drm_fd,
        connector.connector_id,
        c.DRM_MODE_OBJECT_CONNECTOR,
    );
    const connector_props = try alloc.alloc(drm.Property, connector_object_props.prop_ids.len);
    for (connector_object_props.prop_ids, connector_props) |id, *p| {
        p.* = try drm.get_property(alloc, drm_fd, id);
    }

    // Create a blob with crtc mode info inside. The id of this blob will be
    // passed with the DRM request to set crtc mode.
    const output_mode_blob_id = drm.create_property_blob(
        c.struct_drm_mode_modeinfo,
        drm_fd,
        &crtc.mode,
    );

    const gbm = Gbm.init(drm_fd, connector.modes[0]);

    const scratch_buffer = try alloc.alloc(u8, 4096 * 10);
    defer alloc.free(scratch_buffer);
    var scratch_allocator = std.heap.FixedBufferAllocator.init(scratch_buffer);
    const scratch_alloc = scratch_allocator.allocator();

    var vk_context = try vulkan.Context.init(scratch_alloc, &gbm);
    scratch_allocator.reset();

    // As a part of the Vulkan Context there is OutputImage object which corresponds to
    // the image Vulkan will render to. This OutputImage is created from gbm bo (buffer object)
    // which in turn has GEM handle associated with it. Tell DRM to create a new frame buffer
    // from thit GEM handle to send as a part of the DRM request and present it.
    const fb_id = drm.add_fb2(
        drm_fd,
        vk_context.output_image.width,
        vk_context.output_image.height,
        c.GBM_FORMAT_XRGB8888,
        vk_context.output_image.pitch,
        vk_context.output_image.gem_handle,
        0,
        0,
    );

    const command =
        try vk_context.commands.create_render_command(vk_context.logical_device.device);

    const pipeline = try vulkan.Pipeline.init(
        scratch_alloc,
        vk_context.logical_device.device,
        vk_context.descriptor_pool.pool,
        &.{},
        &.{},
        "simple_vert.spv",
        "simple_frag.spv",
        vk.VK_FORMAT_B8G8R8A8_SRGB,
        .None,
    );

    // This fd corresponds to the Vulkan render finish semaphore. It is triggered by Vulkan when
    // the rendering is finished. It is passed to the DRM with a request in order for DRM to wait
    // for Vulkan to finish the rendering. Because the DRM request call is before the
    // Vulkan queue submit call, initially there is no fd to pass, so it will be skipped during
    // request construction.
    var render_fd: ?std.posix.fd_t = null;

    // This fd corresponds to the DRM finishing painting the output. It will be imported into the
    // Vulkan semaphore for Vulkan to wait on before starting rendering.
    var output_fd: std.posix.fd_t = -1;

    while (true) {
        var commit_request: drm.CommitRequest = .{};
        construct_drm_commit_request(
            &commit_request,
            primary_plane_props,
            crtc_props,
            connector_props,
            &vk_context.output_image,
            primary_plane.plane_id,
            primary_plane.crtc_id,
            fb_id,
            connector.connector_id,
            output_mode_blob_id,
            render_fd,
            &output_fd,
        );
        const flags = c.DRM_MODE_ATOMIC_NONBLOCK | c.DRM_MODE_PAGE_FLIP_EVENT;
        drm.atomic_commit(drm_fd, &commit_request, flags);

        // Wait for DRM repainting the output and read events sent.
        var p = [_]std.posix.pollfd{
            .{
                .fd = drm_fd,
                .events = 1,
                .revents = 0,
            },
        };
        _ = try std.posix.poll(&p, -1);
        var buff: [1024]u8 = undefined;
        _ = try std.posix.read(drm_fd, &buff);

        // Close Vulkan render fd. Otherwise it will open new fds
        // each frame.
        if (render_fd) |rf|
            std.posix.close(rf);

        try vk_context.start_command(&command);

        try command.import_output_semaphore_fd(
            vk_context.instance.instance,
            vk_context.logical_device.device,
            output_fd,
        );

        try vk_context.start_rendering(&command);
        vk.vkCmdBindPipeline(
            command.cmd,
            vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
            pipeline.pipeline,
        );
        vk.vkCmdBindDescriptorSets(
            command.cmd,
            vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
            pipeline.pipeline_layout,
            0,
            1,
            &pipeline.descriptor_set,
            0,
            null,
        );
        vk.vkCmdDraw(
            command.cmd,
            3,
            1,
            0,
            0,
        );
        try vk_context.end_rendering(&command);

        try vk_context.end_command(&command);
        try vk_context.queue_command(&command);

        render_fd = try command.get_render_semaphore_fd(
            vk_context.instance.instance,
            vk_context.logical_device.device,
        );
    }
}

pub fn construct_drm_commit_request(
    request: *drm.CommitRequest,
    primary_plane_p: []drm.Property,
    crtc_p: []drm.Property,
    connector_p: []drm.Property,
    output_image: *const vulkan.Context.OutputImage,
    primary_plane_id: u32,
    crtc_id: u32,
    fb_id: u32,
    connector_id: u32,
    output_mode_blob_id: u32,
    render_fd: ?std.posix.fd_t,
    output_fd: *std.posix.fd_t,
) void {
    const Pair = struct { []const u8, u64 };
    {
        request.add_object(primary_plane_id);
        for ([_]Pair{
            .{ "CRTC_ID", crtc_id },
            .{ "FB_ID", fb_id },
            .{ "SRC_X", 0 },
            .{ "SRC_Y", 0 },
            // SRC_W and SRC_H are represented by a fixed point number
            // in the kernel. The layout is 16.16 for the fixed point, so
            // widht and height need to be shifted up 16 bits.
            .{ "SRC_W", output_image.width << 16 },
            .{ "SRC_H", output_image.height << 16 },
            .{ "CRTC_X", 0 },
            .{ "CRTC_Y", 0 },
            .{ "CRTC_W", output_image.width },
            .{ "CRTC_H", output_image.height },
        }) |p| {
            for (primary_plane_p) |*pp| {
                const a: [*c]u8 = &pp.name;
                const pp_name = std.mem.span(a);
                if (std.mem.eql(u8, pp_name, p[0])) {
                    request.add_prop_id_value(pp.prop_id, p[1]);
                }
            }
        }

        if (render_fd) |rfd| {
            const p = Pair{ "IN_FENCE_FD", @intCast(rfd) };
            for (primary_plane_p) |*pp| {
                const a: [*c]u8 = &pp.name;
                const pp_name = std.mem.span(a);
                if (std.mem.eql(u8, pp_name, p[0])) {
                    request.add_prop_id_value(pp.prop_id, p[1]);
                }
            }
        }
    }
    {
        request.add_object(crtc_id);
        for ([_]Pair{
            .{ "MODE_ID", output_mode_blob_id },
            .{ "ACTIVE", 1 },
            .{ "OUT_FENCE_PTR", @intFromPtr(output_fd) },
        }) |p| {
            for (crtc_p) |*pp| {
                const a: [*c]u8 = &pp.name;
                const pp_name = std.mem.span(a);
                if (std.mem.eql(u8, pp_name, p[0])) {
                    request.add_prop_id_value(pp.prop_id, p[1]);
                }
            }
        }
    }
    {
        request.add_object(connector_id);
        for ([_]Pair{
            .{ "CRTC_ID", crtc_id },
        }) |p| {
            for (connector_p) |*pp| {
                const a: [*c]u8 = &pp.name;
                const pp_name = std.mem.span(a);
                if (std.mem.eql(u8, pp_name, p[0])) {
                    request.add_prop_id_value(pp.prop_id, p[1]);
                }
            }
        }
    }
}
