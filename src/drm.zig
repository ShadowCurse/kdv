const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("bindings/c.zig").c;

fn ioctl(fd: std.posix.fd_t, request: u32, arg: usize) usize {
    const r = std.os.linux.ioctl(fd, request, arg);
    const signed: isize = @bitCast(r);
    if (signed < 0) {
        std.log.info("{} failed: {any} {d}", .{ request, std.posix.errno(r), signed });
        std.os.linux.exit(-1);
    }
    return r;
}

pub fn get_magic(fd: std.posix.fd_t) c.drm_magic_t {
    const auth: c.drm_auth_t = .{};
    _ = ioctl(fd, c.DRM_IOCTL_GET_MAGIC, @intFromPtr(&auth));
    return auth.magic;
}

pub fn auth_magic(fd: std.posix.fd_t, magic: c.drm_magic_t) void {
    const auth = c.drm_auth_t{ .magic = magic };
    _ = ioctl(fd, c.DRM_IOCTL_AUTH_MAGIC, @intFromPtr(&auth));
}

pub fn drop_master(fd: std.posix.fd_t) void {
    _ = ioctl(fd, c.DRM_IOCTL_DROP_MASTER, 0);
}

pub fn set_master(fd: std.posix.fd_t) void {
    _ = ioctl(fd, c.DRM_IOCTL_SET_MASTER, 0);
}

pub fn set_client_cap(fd: std.posix.fd_t, capability: u64, value: u64) void {
    const cap = c.drm_set_client_cap{
        .capability = capability,
        .value = value,
    };

    _ = ioctl(fd, c.DRM_IOCTL_SET_CLIENT_CAP, @intFromPtr(&cap));
}

pub const Resources = struct {
    min_width: u32 = 0,
    max_width: u32 = 0,
    min_height: u32 = 0,
    max_height: u32 = 0,
    fb_ids: []u32,
    crtc_ids: []u32,
    connector_ids: []u32,
    encoder_ids: []u32,
};
pub fn get_resources(alloc: Allocator, fd: std.posix.fd_t) !Resources {
    // https://cgit.freedesktop.org/drm/libdrm/tree/xf86drmMode.c#n164
    var resources: c.drm_mode_card_res = .{};
    _ = ioctl(fd, c.DRM_IOCTL_MODE_GETRESOURCES, @intFromPtr(&resources));

    if (resources.count_fbs != 0)
        resources.fb_id_ptr = @intFromPtr((try alloc.alloc(u32, resources.count_fbs)).ptr);
    if (resources.count_crtcs != 0)
        resources.crtc_id_ptr = @intFromPtr((try alloc.alloc(u32, resources.count_crtcs)).ptr);
    if (resources.count_connectors != 0)
        resources.connector_id_ptr = @intFromPtr((try alloc.alloc(u32, resources.count_connectors)).ptr);
    if (resources.count_encoders != 0)
        resources.encoder_id_ptr = @intFromPtr((try alloc.alloc(u32, resources.count_encoders)).ptr);

    _ = ioctl(fd, c.DRM_IOCTL_MODE_GETRESOURCES, @intFromPtr(&resources));

    var result: Resources = undefined;
    result.min_width = resources.min_width;
    result.max_width = resources.max_width;
    result.min_height = resources.min_height;
    result.max_height = resources.max_height;

    if (resources.count_fbs != 0) {
        result.fb_ids.ptr = @ptrFromInt(resources.fb_id_ptr);
        result.fb_ids.len = resources.count_fbs;
        for (result.fb_ids) |id| {
            std.log.info("fb id: {}", .{id});
        }
    }

    if (resources.count_crtcs != 0) {
        result.crtc_ids.ptr = @ptrFromInt(resources.crtc_id_ptr);
        result.crtc_ids.len = resources.count_crtcs;
        for (result.crtc_ids) |id| {
            std.log.info("crt id: {}", .{id});
        }
    }

    if (resources.count_connectors != 0) {
        result.connector_ids.ptr = @ptrFromInt(resources.connector_id_ptr);
        result.connector_ids.len = resources.count_connectors;
        for (result.connector_ids) |id| {
            std.log.info("connector id: {}", .{id});
        }
    }

    if (resources.count_encoders != 0) {
        result.encoder_ids.ptr = @ptrFromInt(resources.encoder_id_ptr);
        result.encoder_ids.len = resources.count_encoders;
        for (result.encoder_ids) |id| {
            std.log.info("encoder id: {}", .{id});
        }
    }

    return result;
}

pub const Connector = struct {
    encoder_id: u32 = 0,
    connector_id: u32 = 0,
    connector_type: u32 = 0,
    connector_type_id: u32 = 0,
    connection: u32 = 0,
    mm_width: u32 = 0,
    mm_height: u32 = 0,
    subpixel: u32 = 0,

    encoders: []u32,
    modes: []c.drm_mode_modeinfo,
    prop_ids: []u32,
    prop_values: []u64,
};
pub fn get_connector(alloc: Allocator, fd: std.posix.fd_t, connector_id: u32) !Connector {
    // https://cgit.freedesktop.org/drm/libdrm/tree/xf86drmMode.c#n508
    var tmp_mode: c.drm_mode_modeinfo = .{};
    var connector: c.drm_mode_get_connector = .{
        .connector_id = connector_id,
        .count_modes = 1,
        .modes_ptr = @intFromPtr(&tmp_mode),
    };
    _ = std.os.linux.ioctl(fd, c.DRM_IOCTL_MODE_GETCONNECTOR, @intFromPtr(&connector));

    if (connector.count_props != 0) {
        connector.props_ptr = @intFromPtr((try alloc.alloc(u32, connector.count_props)).ptr);
        connector.prop_values_ptr = @intFromPtr((try alloc.alloc(u64, connector.count_props)).ptr);
    }
    if (connector.count_modes != 0)
        connector.modes_ptr = @intFromPtr((try alloc.alloc(c.drm_mode_modeinfo, connector.count_modes)).ptr)
    else
        @panic("count modes == 0");
    if (connector.count_encoders != 0)
        connector.encoders_ptr = @intFromPtr((try alloc.alloc(u32, connector.count_encoders)).ptr);

    _ = std.os.linux.ioctl(fd, c.DRM_IOCTL_MODE_GETCONNECTOR, @intFromPtr(&connector));

    var result: Connector = undefined;
    result.encoder_id = connector.encoder_id;
    result.connector_id = connector.connector_id;
    result.connector_type = connector.connector_type;
    result.connector_type_id = connector.connector_type_id;
    result.connection = connector.connection;

    if (connector.count_props != 0) {
        result.prop_ids.ptr = @ptrFromInt(connector.props_ptr);
        result.prop_ids.len = connector.count_props;
        result.prop_values.ptr = @ptrFromInt(connector.prop_values_ptr);
        result.prop_values.len = connector.count_props;
        for (result.prop_ids, result.prop_values) |p, pv| {
            std.log.info("prop: {} value: {}", .{ p, pv });
        }
    }

    if (connector.count_modes != 0) {
        result.modes.ptr = @ptrFromInt(connector.modes_ptr);
        result.modes.len = connector.count_modes;
        for (result.modes) |m| {
            std.log.info("mode: {any} name: {s}", .{ m, m.name });
        }
    }

    if (connector.count_encoders != 0) {
        result.encoders.ptr = @ptrFromInt(connector.encoders_ptr);
        result.encoders.len = connector.count_encoders;
        for (result.encoders) |e| {
            std.log.info("encoder: {}", .{e});
        }
    }

    return result;
}

pub const Encoder = struct {
    encoder_id: u32 = 0,
    encoder_type: u32 = 0,
    crtc_id: u32 = 0,
    possible_crtcs: u32 = 0,
    possible_clones: u32 = 0,
};
pub fn get_encoder(fd: std.posix.fd_t, encoder_id: u32) !Encoder {
    // https://cgit.freedesktop.org/drm/libdrm/tree/xf86drmMode.c#n481
    var encoder: c.drm_mode_get_encoder = .{};
    encoder.encoder_id = encoder_id;
    _ = std.os.linux.ioctl(fd, c.DRM_IOCTL_MODE_GETENCODER, @intFromPtr(&encoder));

    return .{
        .encoder_id = encoder.encoder_id,
        .encoder_type = encoder.encoder_type,
        .crtc_id = encoder.crtc_id,
        .possible_crtcs = encoder.possible_crtcs,
        .possible_clones = encoder.possible_clones,
    };
}

pub fn get_crtc(fd: std.posix.fd_t, crtc_id: u32) !c.drm_mode_crtc {
    var crtc: c.drm_mode_crtc = .{
        .crtc_id = crtc_id,
    };
    _ = std.os.linux.ioctl(fd, c.DRM_IOCTL_MODE_GETCRTC, @intFromPtr(&crtc));
    return crtc;
}

pub fn get_plane_resources(alloc: Allocator, fd: std.posix.fd_t) ![]const u32 {
    var plane_resources: c.drm_mode_get_plane_res = .{};
    _ = ioctl(fd, c.DRM_IOCTL_MODE_GETPLANERESOURCES, @intFromPtr(&plane_resources));

    std.log.info("aaa: {d}", .{plane_resources.count_planes});
    if (plane_resources.count_planes != 0)
        plane_resources.plane_id_ptr =
            @intFromPtr((try alloc.alloc(u32, plane_resources.count_planes)).ptr);

    _ = ioctl(fd, c.DRM_IOCTL_MODE_GETPLANERESOURCES, @intFromPtr(&plane_resources));

    std.log.info("aaa: {d}", .{plane_resources.count_planes});
    var result: []const u32 = &.{};
    if (plane_resources.count_planes != 0) {
        result.ptr = @ptrFromInt(plane_resources.plane_id_ptr);
        result.len = plane_resources.count_planes;
    }
    return result;
}

pub const Plane = struct {
    plane_id: u32 = 0,
    crtc_id: u32 = 0,
    fb_id: u32 = 0,
    possible_crtcs: u32 = 0,
    gamma_size: u32 = 0,
    format_types: []u32 = &.{},
};
pub fn get_plane(alloc: Allocator, fd: std.posix.fd_t, plane_id: u32) !Plane {
    var mode_get_plane: c.drm_mode_get_plane = .{
        .plane_id = plane_id,
    };
    _ = ioctl(fd, c.DRM_IOCTL_MODE_GETPLANE, @intFromPtr(&mode_get_plane));

    if (mode_get_plane.count_format_types != 0)
        mode_get_plane.format_type_ptr = @intFromPtr((try alloc.alloc(u32, mode_get_plane.count_format_types)).ptr);

    _ = ioctl(fd, c.DRM_IOCTL_MODE_GETPLANE, @intFromPtr(&mode_get_plane));

    var plane: Plane = undefined;
    plane.plane_id = mode_get_plane.plane_id;
    plane.crtc_id = mode_get_plane.crtc_id;
    plane.fb_id = mode_get_plane.fb_id;
    plane.possible_crtcs = mode_get_plane.possible_crtcs;
    if (mode_get_plane.count_format_types != 0) {
        plane.format_types.ptr = @ptrFromInt(mode_get_plane.format_type_ptr);
        plane.format_types.len = mode_get_plane.count_format_types;
    }
    return plane;
}

pub fn create_property_blob(comptime T: type, fd: std.posix.fd_t, ptr: *const T) u32 {
    var create_blob: c.drm_mode_create_blob = .{
        .length = @sizeOf(T),
        .data = @intFromPtr(ptr),
    };

    _ = ioctl(fd, c.DRM_IOCTL_MODE_CREATEPROPBLOB, @intFromPtr(&create_blob));

    return create_blob.blob_id;
}

pub const ObjectProperties = struct {
    prop_ids: []u32 = &.{},
    prop_values: []u64 = &.{},
    obj_id: u32 = 0,
    obj_type: u32 = 0,
};
pub fn object_get_properties(
    alloc: Allocator,
    fd: std.posix.fd_t,
    object_id: u32,
    object_type: u32,
) !ObjectProperties {
    var get_prop: c.drm_mode_obj_get_properties = .{
        .obj_id = object_id,
        .obj_type = object_type,
    };

    _ = ioctl(fd, c.DRM_IOCTL_MODE_OBJ_GETPROPERTIES, @intFromPtr(&get_prop));

    if (get_prop.count_props != 0) {
        get_prop.props_ptr = @intFromPtr(
            (try alloc.alloc(u32, get_prop.count_props)).ptr,
        );
        get_prop.prop_values_ptr = @intFromPtr(
            (try alloc.alloc(u64, get_prop.count_props)).ptr,
        );
    }

    _ = ioctl(fd, c.DRM_IOCTL_MODE_OBJ_GETPROPERTIES, @intFromPtr(&get_prop));

    var prop: ObjectProperties = undefined;
    prop.obj_id = get_prop.obj_id;
    prop.obj_type = get_prop.obj_type;

    if (get_prop.count_props != 0) {
        prop.prop_ids.ptr = @ptrFromInt(get_prop.props_ptr);
        prop.prop_ids.len = get_prop.count_props;
        prop.prop_values.ptr = @ptrFromInt(get_prop.prop_values_ptr);
        prop.prop_values.len = get_prop.count_props;
    }

    return prop;
}

pub const Property = struct {
    values: Values = undefined,
    enum_blobs: EnumBlobs = undefined,
    prop_id: u32 = 0,
    flags: u32 = 0,
    name: [32]u8 = .{0} ** 32,

    pub const Values = union(enum) {
        _u32: []u32,
        _u64: []u64,
    };

    pub const EnumBlobs = union(enum) {
        _u32: []u32,
        drm_mode_property_enum: []c.drm_mode_property_enum,
    };
};
pub fn get_property(
    alloc: Allocator,
    fd: std.posix.fd_t,
    property_id: u32,
) !Property {
    var get_prop: c.drm_mode_get_property = .{
        .prop_id = property_id,
    };

    _ = ioctl(fd, c.DRM_IOCTL_MODE_GETPROPERTY, @intFromPtr(&get_prop));

    if (get_prop.count_enum_blobs != 0 and (get_prop.flags & c.DRM_MODE_PROP_BLOB) != 0) {
        get_prop.values_ptr = @intFromPtr(
            (try alloc.alloc(u32, get_prop.count_enum_blobs)).ptr,
        );
        get_prop.enum_blob_ptr = @intFromPtr(
            (try alloc.alloc(u32, get_prop.count_enum_blobs)).ptr,
        );
    } else {
        if (get_prop.count_values != 0) {
            get_prop.values_ptr = @intFromPtr(
                (try alloc.alloc(u64, get_prop.count_values)).ptr,
            );
        }
        if (get_prop.count_enum_blobs != 0 and
            (get_prop.flags & (c.DRM_MODE_PROP_ENUM | c.DRM_MODE_PROP_BITMASK)) != 0)
        {
            get_prop.enum_blob_ptr = @intFromPtr(
                (try alloc.alloc(c.drm_mode_property_enum, get_prop.count_enum_blobs)).ptr,
            );
        }
    }

    _ = ioctl(fd, c.DRM_IOCTL_MODE_GETPROPERTY, @intFromPtr(&get_prop));

    var prop: Property = undefined;
    prop.prop_id = get_prop.prop_id;
    prop.flags = get_prop.flags;
    @memcpy(&prop.name, &get_prop.name);

    if (get_prop.count_enum_blobs != 0 and (get_prop.flags & c.DRM_MODE_PROP_BLOB) != 0) {
        var values: []u32 = undefined;
        values.ptr = @ptrFromInt(get_prop.values_ptr);
        values.len = get_prop.count_enum_blobs;
        prop.values = .{ ._u32 = values };
        var enum_blobs: []u32 = undefined;
        enum_blobs.ptr = @ptrFromInt(get_prop.enum_blob_ptr);
        enum_blobs.len = get_prop.count_enum_blobs;
        prop.enum_blobs = .{ ._u32 = enum_blobs };
    } else {
        if (get_prop.count_values != 0) {
            var values: []u64 = undefined;
            values.ptr = @ptrFromInt(get_prop.values_ptr);
            values.len = get_prop.count_values;
            prop.values = .{ ._u64 = values };
        }
        if (get_prop.count_enum_blobs != 0 and
            (get_prop.flags & (c.DRM_MODE_PROP_ENUM | c.DRM_MODE_PROP_BITMASK)) != 0)
        {
            var enum_blobs: []c.drm_mode_property_enum = undefined;
            enum_blobs.ptr = @ptrFromInt(get_prop.enum_blob_ptr);
            enum_blobs.len = get_prop.count_enum_blobs;
            prop.enum_blobs = .{ .drm_mode_property_enum = enum_blobs };
        }
    }

    return prop;
}

pub const CommitRequest = struct {
    objects_count: u32 = 0,
    objects: [32]u32 = .{0} ** 32,
    object_prop_counts: [32]u32 = .{0} ** 32,
    props_count: u32 = 0,
    prop_ids: [32]u32 = .{0} ** 32,
    prop_values: [32]u64 = .{0} ** 32,

    const Self = @This();

    pub fn add_object(self: *Self, object_id: u32) void {
        self.objects[self.objects_count] = object_id;
        self.objects_count += 1;
    }

    pub fn add_prop_id_value(self: *Self, prop_id: u32, prop_value: u64) void {
        self.object_prop_counts[self.objects_count - 1] += 1;
        self.prop_ids[self.props_count] = prop_id;
        self.prop_values[self.props_count] = prop_value;
        self.props_count += 1;
    }
};
pub fn atomic_commit(
    fd: std.posix.fd_t,
    commit_request: *const CommitRequest,
    flags: u32,
) void {
    const atomic = c.drm_mode_atomic{
        .flags = flags,
        .count_objs = @intCast(commit_request.objects_count),
        .objs_ptr = @intFromPtr(&commit_request.objects),
        .count_props_ptr = @intFromPtr(&commit_request.object_prop_counts),
        .props_ptr = @intFromPtr(&commit_request.prop_ids),
        .prop_values_ptr = @intFromPtr(&commit_request.prop_values),
        .reserved = 0,
        .user_data = 0,
    };
    _ = ioctl(fd, c.DRM_IOCTL_MODE_ATOMIC, @intFromPtr(&atomic));
}

pub fn add_fb(
    fd: std.posix.fd_t,
    width: u32,
    height: u32,
    depth: u8,
    bpp: u32,
    pitch: u32,
    bo_handle: u32,
) u32 {
    var fb_cmd = c.drm_mode_fb_cmd{
        .width = width,
        .height = height,
        .depth = depth,
        .pitch = pitch,
        .bpp = bpp,
        .handle = bo_handle,
    };
    _ = ioctl(fd, c.DRM_IOCTL_MODE_ADDFB, @intFromPtr(&fb_cmd));
    return fb_cmd.fb_id;
}

pub fn add_fb2(
    fd: std.posix.fd_t,
    width: u32,
    height: u32,
    pixel_format: u32,
    pitch: u32,
    bo_handle: u32,
    modifier: u32,
    flags: u32,
) u32 {
    var fb_cmd = c.drm_mode_fb_cmd2{
        .width = width,
        .height = height,
        .pixel_format = pixel_format,
        .flags = flags,
        .handles = .{ bo_handle, 0, 0, 0 },
        .pitches = .{ pitch, 0, 0, 0 },
        .offsets = .{ 0, 0, 0, 0 },
        .modifier = .{ modifier, 0, 0, 0 },
    };
    _ = ioctl(fd, c.DRM_IOCTL_MODE_ADDFB2, @intFromPtr(&fb_cmd));
    return fb_cmd.fb_id;
}
