const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("bindings/c.zig").c;
const Gbm = @import("gbm.zig");
const drm = @import("drm.zig");
const vk = @import("bindings/vk.zig");

const TIMEOUT = std.math.maxInt(u64);

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    const alloc = gpa.allocator();

    std.log.info("open card0", .{});
    const fd = try std.posix.open("/dev/dri/card0", .{ .ACCMODE = .RDWR }, 0);
    defer std.posix.close(fd);

    // drm_drop_master(fd);
    // drm_set_master(fd);

    // const magic = drm_get_magic(fd);
    // drm_auth_magic(fd, magic);

    std.log.info("set caps", .{});
    drm.set_client_cap(fd, c.DRM_CLIENT_CAP_ATOMIC, 1);

    const resources = try drm.get_resources(alloc, fd);
    const plane_ids = try drm.get_plane_resources(alloc, fd);
    std.log.info("plane ids: {any}", .{plane_ids});

    const planes = try alloc.alloc(drm.Plane, plane_ids.len);
    for (planes, plane_ids) |*plane, id|
        plane.* = try drm.get_plane(alloc, fd, id);

    const connector = try drm.get_connector(alloc, fd, resources.connector_ids[0]);
    const encoder = try drm.get_encoder(fd, connector.encoder_id);
    std.log.info("encoder: {any}", .{encoder});

    var crtc_id: u32 = 0;
    for (resources.crtc_ids) |id| {
        if (id == encoder.crtc_id) {
            crtc_id = id;
            break;
        }
    }
    std.log.info("crt_id: {d}", .{crtc_id});
    const crtc = try drm.get_crtc(fd, crtc_id);
    if (crtc.fb_id == 0)
        @panic("the crtc does not have active frame buffer");

    var primary_plane: *drm.Plane = undefined;
    for (planes) |*p| {
        if (p.crtc_id == crtc.crtc_id and p.fb_id == crtc.fb_id)
            primary_plane = p;
    }

    std.log.info("selected plane: {any}", .{primary_plane});

    const primary_plane_props = try drm.object_get_properties(
        alloc,
        fd,
        primary_plane.plane_id,
        c.DRM_MODE_OBJECT_PLANE,
    );
    std.log.info("primary_plane_props: {any}", .{primary_plane_props});
    const primary_plane_p = try alloc.alloc(drm.Property, primary_plane_props.prop_ids.len);
    for (primary_plane_props.prop_ids, primary_plane_p) |id, *p| {
        p.* = try drm.get_property(alloc, fd, id);
        std.log.info("primary_plane prop_id: {d}: prop name: {s}", .{ id, p.name });
    }

    const crtc_props = try drm.object_get_properties(
        alloc,
        fd,
        primary_plane.crtc_id,
        c.DRM_MODE_OBJECT_CRTC,
    );
    std.log.info("crtc_props: {any}", .{crtc_props});
    const crtc_p = try alloc.alloc(drm.Property, crtc_props.prop_ids.len);
    for (crtc_props.prop_ids, crtc_p) |id, *p| {
        p.* = try drm.get_property(alloc, fd, id);
        std.log.info("crtc prop_id: {d}: prop name: {s}", .{ id, p.name });
    }

    const connector_props = try drm.object_get_properties(
        alloc,
        fd,
        connector.connector_id,
        c.DRM_MODE_OBJECT_CONNECTOR,
    );
    std.log.info("connector_props: {any}", .{connector_props});
    const connector_p = try alloc.alloc(drm.Property, connector_props.prop_ids.len);
    for (connector_props.prop_ids, connector_p) |id, *p| {
        p.* = try drm.get_property(alloc, fd, id);
        std.log.info("connector prop_id: {d}: prop name: {s}", .{ id, p.name });
    }

    const output_mode_blob_id = drm.create_property_blob(
        c.struct_drm_mode_modeinfo,
        fd,
        &crtc.mode,
    );

    const gbm = Gbm.init(fd, connector.modes[0]);
    std.log.info("gbm: {any}", .{gbm});

    const scratch_buffer = try alloc.alloc(u8, 4096 * 10);
    defer alloc.free(scratch_buffer);

    var scratch_allocator = std.heap.FixedBufferAllocator.init(scratch_buffer);
    const scratch_alloc = scratch_allocator.allocator();

    var vk_context = try VulkanContext.init(scratch_alloc);
    scratch_allocator.reset();
    try vk_context.create_output_attachment(scratch_alloc, fd, &gbm);
    scratch_allocator.reset();

    std.log.info("adding frame buffer", .{});
    const fb_id = drm.add_fb2(
        fd,
        vk_context.output_image.width,
        vk_context.output_image.height,
        c.GBM_FORMAT_XRGB8888,
        vk_context.output_image.pitch,
        vk_context.output_image.gem_handle,
        0,
        0,
    );

    std.log.info("vk_context created with fb_id: {d}", .{fb_id});

    const command =
        try vk_context.commands.create_render_command(vk_context.logical_device.device);

    const pipeline = try Pipeline.init(
        scratch_alloc,
        vk_context.logical_device.device,
        vk_context.descriptor_pool.pool,
        &.{},
        &.{},
        "simple_vert.spv",
        "simple_frag.spv",
        vk.VK_FORMAT_B8G8R8A8_SRGB,
        vk.VK_FORMAT_D32_SFLOAT,
        .None,
    );

    std.log.info("pipeline created", .{});

    var render_fd: ?std.posix.fd_t = null;
    var output_fd: std.posix.fd_t = -1;

    while (true) {
        std.log.info("render_fd: {any}", .{render_fd});
        std.log.info("output_fd: {d}", .{output_fd});

        var commit_request: drm.CommitRequest = .{};
        construct_drm_commit_request(
            &commit_request,
            primary_plane_p,
            crtc_p,
            connector_p,
            &vk_context.output_image,
            primary_plane.plane_id,
            primary_plane.crtc_id,
            fb_id,
            connector.connector_id,
            output_mode_blob_id,
            render_fd,
            &output_fd,
        );
        std.log.info("commit", .{});

        const flags = c.DRM_MODE_ATOMIC_NONBLOCK |
            c.DRM_MODE_PAGE_FLIP_EVENT;
        drm.atomic_commit(fd, &commit_request, flags);

        var p = [_]std.posix.pollfd{
            .{
                .fd = fd,
                .events = 1,
                .revents = 0,
            },
        };
        std.log.info("poll", .{});
        const n = try std.posix.poll(&p, -1);
        std.log.info("poll returned: {d}", .{n});
        var buff: [1024]u8 = undefined;
        const nn = try std.posix.read(fd, &buff);
        std.log.info("read: {d}", .{nn});

        if (render_fd) |rf|
            std.posix.close(rf);

        try command.import_output_semaphore_fd(
            vk_context.instance.instance,
            vk_context.logical_device.device,
            output_fd,
        );

        try vk_context.start_command(&command);
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

const VK_EXTENSIONS_NAMES = [_][*c]const u8{"VK_EXT_debug_utils"};
const VK_VALIDATION_LAYERS_NAMES = [_][*c]const u8{"VK_LAYER_KHRONOS_validation"};
const VK_PHYSICAL_DEVICE_EXTENSION_NAMES = [_][*c]const u8{
    vk.VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME,
    vk.VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME,
    vk.VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME,
    vk.VK_KHR_IMAGE_FORMAT_LIST_EXTENSION_NAME,
    vk.VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME,
};

const VulkanContext = struct {
    const Self = @This();
    instance: Instance,
    debug_messanger: DebugMessanger,
    physical_device: PhysicalDevice,
    logical_device: LogicalDevice,
    descriptor_pool: DescriptorPool,
    commands: CommandPool,
    output_image: OutputImage,

    fn init(scratch_alloc: Allocator) !Self {
        const instance = try Instance.init(scratch_alloc);
        const debug_messanger = try DebugMessanger.init(instance.instance);

        const physical_device = try PhysicalDevice.init(scratch_alloc, instance.instance);
        const logical_device = try LogicalDevice.init(scratch_alloc, &physical_device);

        const descriptor_pool = try DescriptorPool.init(logical_device.device, &.{
            .{
                .type = vk.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
                .descriptorCount = 10,
            },
            .{
                .type = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .descriptorCount = 10,
            },
            .{
                .type = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .descriptorCount = 10,
            },
        });

        const commands = try CommandPool.init(
            logical_device.device,
            physical_device.graphics_queue_family,
        );

        return .{
            .instance = instance,
            .debug_messanger = debug_messanger,
            .physical_device = physical_device,
            .logical_device = logical_device,
            .descriptor_pool = descriptor_pool,
            .commands = commands,
            .output_image = undefined,
        };
    }

    const Instance = struct {
        instance: vk.VkInstance,

        pub fn init(
            scratch_alloc: Allocator,
        ) !Instance {
            var extensions_count: u32 = 0;
            try vk.check_result(vk.vkEnumerateInstanceExtensionProperties(
                null,
                &extensions_count,
                null,
            ));
            const extensions = try scratch_alloc.alloc(vk.VkExtensionProperties, extensions_count);
            try vk.check_result(vk.vkEnumerateInstanceExtensionProperties(
                null,
                &extensions_count,
                extensions.ptr,
            ));

            var found_extensions: u32 = 0;
            for (extensions) |e| {
                var required = "--------";
                for (VK_EXTENSIONS_NAMES) |ae| {
                    const extension_name_span = std.mem.span(@as(
                        [*c]const u8,
                        @ptrCast(&e.extensionName),
                    ));
                    const additional_extension_name_span = std.mem.span(@as(
                        [*c]const u8,
                        ae,
                    ));
                    if (std.mem.eql(u8, extension_name_span, additional_extension_name_span)) {
                        found_extensions += 1;
                        required = "required";
                    }
                }
                std.log.debug("({s}) Extension name: {s} version: {}", .{
                    required,
                    e.extensionName,
                    e.specVersion,
                });
            }
            if (found_extensions != VK_EXTENSIONS_NAMES.len) {
                return error.AdditionalExtensionsNotFound;
            }

            var layer_property_count: u32 = 0;
            try vk.check_result(vk.vkEnumerateInstanceLayerProperties(&layer_property_count, null));
            const layers = try scratch_alloc.alloc(vk.VkLayerProperties, layer_property_count);
            try vk.check_result(vk.vkEnumerateInstanceLayerProperties(
                &layer_property_count,
                layers.ptr,
            ));

            var found_validation_layers: u32 = 0;
            for (layers) |l| {
                var required = "--------";
                for (VK_VALIDATION_LAYERS_NAMES) |vln| {
                    const layer_name_span = std.mem.span(@as([*c]const u8, @ptrCast(&l.layerName)));
                    const validation_layer_name_span = std.mem.span(@as([*c]const u8, vln));
                    if (std.mem.eql(u8, layer_name_span, validation_layer_name_span)) {
                        found_validation_layers += 1;
                        required = "required";
                    }
                }
                std.log.debug("({s}) Layer name: {s}, spec version: {}, description: {s}", .{
                    required,
                    l.layerName,
                    l.specVersion,
                    l.description,
                });
            }
            if (found_validation_layers != VK_VALIDATION_LAYERS_NAMES.len) {
                return error.ValidationLayersNotFound;
            }

            const app_info = vk.VkApplicationInfo{
                .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
                .pApplicationName = "test",
                .applicationVersion = vk.VK_MAKE_VERSION(0, 0, 1),
                .pEngineName = "stygian",
                .engineVersion = vk.VK_MAKE_VERSION(0, 0, 1),
                .apiVersion = vk.VK_API_VERSION_1_3,
                .pNext = null,
            };
            const instance_create_info = vk.VkInstanceCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
                .pApplicationInfo = &app_info,
                .ppEnabledExtensionNames = @ptrCast(&VK_EXTENSIONS_NAMES),
                .enabledExtensionCount = @as(u32, @intCast(VK_EXTENSIONS_NAMES.len)),
                .ppEnabledLayerNames = @ptrCast(&VK_VALIDATION_LAYERS_NAMES),
                .enabledLayerCount = @as(u32, @intCast(VK_VALIDATION_LAYERS_NAMES.len)),
            };

            var vk_instance: vk.VkInstance = undefined;
            try vk.check_result(vk.vkCreateInstance(&instance_create_info, null, &vk_instance));
            return .{
                .instance = vk_instance,
            };
        }

        pub fn deinit(self: *const Instance) void {
            vk.vkDestroyInstance(self.instance, null);
        }
    };

    pub fn get_vk_func(comptime Fn: type, instance: vk.VkInstance, name: [*c]const u8) !Fn {
        if (vk.vkGetInstanceProcAddr(instance, name)) |func| {
            return @ptrCast(func);
        } else {
            return error.VKGetInstanceProcAddr;
        }
    }

    const DebugMessanger = struct {
        messanger: vk.VkDebugUtilsMessengerEXT,

        pub fn init(vk_instance: vk.VkInstance) !DebugMessanger {
            const create_fn = (try get_vk_func(
                vk.PFN_vkCreateDebugUtilsMessengerEXT,
                vk_instance,
                "vkCreateDebugUtilsMessengerEXT",
            )).?;
            const create_info = vk.VkDebugUtilsMessengerCreateInfoEXT{
                .sType = vk.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
                .messageSeverity = vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT |
                    vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                    vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT,
                .messageType = vk.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                    vk.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                    vk.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
                .pfnUserCallback = DebugMessanger.debug_callback,
                .pUserData = null,
            };
            var vk_debug_messanger: vk.VkDebugUtilsMessengerEXT = undefined;
            try vk.check_result(create_fn(vk_instance, &create_info, null, &vk_debug_messanger));
            return .{
                .messanger = vk_debug_messanger,
            };
        }

        pub fn deinit(self: *const DebugMessanger, vk_instance: vk.VkInstance) !void {
            const destroy_fn = (try get_vk_func(
                vk.PFN_vkDestroyDebugUtilsMessengerEXT,
                vk_instance,
                "vkDestroyDebugUtilsMessengerEXT",
            )).?;
            destroy_fn(vk_instance, self.messanger, null);
        }

        pub fn debug_callback(
            severity: vk.VkDebugUtilsMessageSeverityFlagBitsEXT,
            msg_type: vk.VkDebugUtilsMessageTypeFlagsEXT,
            data: ?*const vk.VkDebugUtilsMessengerCallbackDataEXT,
            _: ?*anyopaque,
        ) callconv(.C) vk.VkBool32 {
            const ty = switch (msg_type) {
                vk.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT => "general",
                vk.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT => "validation",
                vk.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT => "performance",
                else => "unknown",
            };
            const msg: [*c]const u8 = if (data) |d| d.pMessage else "empty";
            switch (severity) {
                vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT => {
                    std.log.err("[{s}]: {s}", .{ ty, msg });
                },
                vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT => {
                    std.log.warn("[{s}]: {s}", .{ ty, msg });
                },
                vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT => {
                    std.log.debug("[{s}]: {s}", .{ ty, msg });
                },
                else => {},
            }
            return vk.VK_FALSE;
        }
    };

    const PhysicalDevice = struct {
        device: vk.VkPhysicalDevice,
        graphics_queue_family: u32,
        // present_queue_family: u32,
        compute_queue_family: u32,
        transfer_queue_family: u32,

        pub fn init(
            scratch_alloc: Allocator,
            vk_instance: vk.VkInstance,
            // vk_surface: vk.VkSurfaceKHR,
        ) !PhysicalDevice {
            var physical_device_count: u32 = 0;
            try vk.check_result(vk.vkEnumeratePhysicalDevices(
                vk_instance,
                &physical_device_count,
                null,
            ));
            const physical_devices = try scratch_alloc.alloc(
                vk.VkPhysicalDevice,
                physical_device_count,
            );
            try vk.check_result(vk.vkEnumeratePhysicalDevices(
                vk_instance,
                &physical_device_count,
                physical_devices.ptr,
            ));

            for (physical_devices) |pd| {
                var drm_properties = vk.VkPhysicalDeviceDrmPropertiesEXT{
                    .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRM_PROPERTIES_EXT,
                };
                var properties2 = vk.VkPhysicalDeviceProperties2{
                    .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
                    .pNext = &drm_properties,
                };
                var features: vk.VkPhysicalDeviceFeatures = undefined;
                vk.vkGetPhysicalDeviceProperties2(pd, &properties2);
                vk.vkGetPhysicalDeviceFeatures(pd, &features);

                const properties = &properties2.properties;
                std.log.debug("Physical device: {s}", .{properties.deviceName});
                std.log.debug("Physical device drm properties: {any}", .{drm_properties});

                var extensions_count: u32 = 0;
                try vk.check_result(vk.vkEnumerateDeviceExtensionProperties(
                    pd,
                    null,
                    &extensions_count,
                    null,
                ));
                const extensions = try scratch_alloc.alloc(vk.VkExtensionProperties, extensions_count);
                try vk.check_result(vk.vkEnumerateDeviceExtensionProperties(
                    pd,
                    null,
                    &extensions_count,
                    extensions.ptr,
                ));

                var found_extensions: u32 = 0;
                for (extensions) |e| {
                    var required = "--------";
                    for (VK_PHYSICAL_DEVICE_EXTENSION_NAMES) |re| {
                        const extension_name_span = std.mem.span(@as(
                            [*c]const u8,
                            @ptrCast(&e.extensionName),
                        ));
                        const p_extension_name_span = std.mem.span(@as(
                            [*c]const u8,
                            re,
                        ));
                        if (std.mem.eql(u8, extension_name_span, p_extension_name_span)) {
                            found_extensions += 1;
                            required = "required";
                        }
                    }
                    std.log.debug("({s}) extension name: {s}", .{ required, e.extensionName });
                }
                if (found_extensions != VK_PHYSICAL_DEVICE_EXTENSION_NAMES.len) {
                    continue;
                }

                var queue_family_count: u32 = 0;
                vk.vkGetPhysicalDeviceQueueFamilyProperties(pd, &queue_family_count, null);
                const queue_families = try scratch_alloc.alloc(
                    vk.VkQueueFamilyProperties,
                    queue_family_count,
                );
                vk.vkGetPhysicalDeviceQueueFamilyProperties(
                    pd,
                    &queue_family_count,
                    queue_families.ptr,
                );

                var graphics_queue_family: ?u32 = null;
                // var present_queue_family: ?u32 = null;
                var compute_queue_family: ?u32 = null;
                var transfer_queue_family: ?u32 = null;

                for (queue_families, 0..) |qf, i| {
                    if (graphics_queue_family == null and
                        qf.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT != 0)
                    {
                        graphics_queue_family = @intCast(i);
                    }
                    if (compute_queue_family == null and
                        qf.queueFlags & vk.VK_QUEUE_COMPUTE_BIT != 0)
                    {
                        compute_queue_family = @intCast(i);
                    }
                    if (transfer_queue_family == null and
                        qf.queueFlags & vk.VK_QUEUE_TRANSFER_BIT != 0)
                    {
                        transfer_queue_family = @intCast(i);
                    }
                    // if (present_queue_family == null) {
                    //     var supported: vk.VkBool32 = 0;
                    //     try vk.check_result(vk.vkGetPhysicalDeviceSurfaceSupportKHR(
                    //         pd,
                    //         @intCast(i),
                    //         vk_surface,
                    //         &supported,
                    //     ));
                    //     if (supported == vk.VK_TRUE) {
                    //         present_queue_family = @intCast(i);
                    //     }
                    // }
                }

                if (graphics_queue_family != null and
                    // present_queue_family != null and
                    compute_queue_family != null and
                    transfer_queue_family != null)
                {
                    std.log.debug("Selected graphics queue family: {}", .{graphics_queue_family.?});
                    // std.log.debug("Selected present queue family: {}", .{present_queue_family.?});
                    std.log.debug("Selected compute queue family: {}", .{compute_queue_family.?});
                    std.log.debug("Selected transfer queue family: {}", .{transfer_queue_family.?});

                    return .{
                        .device = pd,
                        .graphics_queue_family = graphics_queue_family.?,
                        // .present_queue_family = present_queue_family.?,
                        .compute_queue_family = compute_queue_family.?,
                        .transfer_queue_family = transfer_queue_family.?,
                    };
                }
            }
            return error.PhysicalDeviceNotSelected;
        }
    };

    const LogicalDevice = struct {
        device: vk.VkDevice,
        graphics_queue: vk.VkQueue,
        // present_queue: vk.VkQueue,
        compute_queue: vk.VkQueue,
        transfer_queue: vk.VkQueue,

        pub fn init(scratch_alloc: Allocator, physical_device: *const PhysicalDevice) !LogicalDevice {
            const all_queue_family_indexes: [3]u32 = .{
                physical_device.graphics_queue_family,
                // physical_device.present_queue_family,
                physical_device.compute_queue_family,
                physical_device.transfer_queue_family,
            };
            var i: usize = 0;
            var unique_indexes: [3]u32 = .{
                std.math.maxInt(u32),
                std.math.maxInt(u32),
                std.math.maxInt(u32),
            };
            for (all_queue_family_indexes) |qfi| {
                if (std.mem.count(u32, &unique_indexes, &.{qfi}) == 0) {
                    unique_indexes[i] = qfi;
                    i += 1;
                }
            }
            const unique = std.mem.sliceTo(&unique_indexes, std.math.maxInt(u32));
            const queue_create_infos = try scratch_alloc.alloc(
                vk.VkDeviceQueueCreateInfo,
                unique.len,
            );

            const queue_priority: f32 = 1.0;
            for (queue_create_infos, unique) |*qi, u| {
                qi.* = vk.VkDeviceQueueCreateInfo{
                    .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                    .queueFamilyIndex = u,
                    .queueCount = 1,
                    .pQueuePriorities = &queue_priority,
                };
            }

            var physical_device_features_1_3 = vk.VkPhysicalDeviceVulkan13Features{
                .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
                .dynamicRendering = vk.VK_TRUE,
                .synchronization2 = vk.VK_TRUE,
            };
            const physical_device_features_1_2 = vk.VkPhysicalDeviceVulkan12Features{
                .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
                .bufferDeviceAddress = vk.VK_TRUE,
                // This one is not supported by rp5 mesa driver
                // .descriptorIndexing = vk.VK_TRUE,
                .pNext = @ptrCast(&physical_device_features_1_3),
            };
            const physical_device_features = vk.VkPhysicalDeviceFeatures{};

            const create_info = vk.VkDeviceCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
                .queueCreateInfoCount = @as(u32, @intCast(queue_create_infos.len)),
                .pQueueCreateInfos = queue_create_infos.ptr,
                .ppEnabledLayerNames = null,
                .enabledLayerCount = 0,
                .ppEnabledExtensionNames = @ptrCast(&VK_PHYSICAL_DEVICE_EXTENSION_NAMES),
                .enabledExtensionCount = @as(u32, @intCast(VK_PHYSICAL_DEVICE_EXTENSION_NAMES.len)),
                .pEnabledFeatures = &physical_device_features,
                .pNext = &physical_device_features_1_2,
            };

            var logical_device: LogicalDevice = undefined;
            try vk.check_result(vk.vkCreateDevice(
                physical_device.device,
                &create_info,
                null,
                &logical_device.device,
            ));
            // vk.vkGetDeviceQueue(
            //     logical_device.device,
            //     physical_device.present_queue_family,
            //     0,
            //     &logical_device.present_queue,
            // );
            vk.vkGetDeviceQueue(
                logical_device.device,
                physical_device.graphics_queue_family,
                0,
                &logical_device.graphics_queue,
            );
            vk.vkGetDeviceQueue(
                logical_device.device,
                physical_device.compute_queue_family,
                0,
                &logical_device.compute_queue,
            );
            vk.vkGetDeviceQueue(
                logical_device.device,
                physical_device.transfer_queue_family,
                0,
                &logical_device.transfer_queue,
            );
            return logical_device;
        }

        pub fn deinit(self: *const LogicalDevice) void {
            vk.vkDestroyDevice(self.device, null);
        }
    };

    pub const OutputImage = struct {
        bo: *c.struct_gbm_bo,
        image: vk.VkImage,
        view: vk.VkImageView,
        width: u32,
        height: u32,
        pitch: u32,
        bpp: u32,
        modifier: u64,
        gem_handle: u32,
    };

    fn create_output_attachment(
        self: *Self,
        scratch_alloc: Allocator,
        fd: std.posix.fd_t,
        gbm: *const Gbm,
    ) !void {
        _ = scratch_alloc;
        _ = fd;
        const bo = c.gbm_bo_create(
            gbm.dev,
            gbm.width,
            gbm.height,
            c.GBM_FORMAT_XRGB8888,
            c.GBM_BO_USE_SCANOUT | c.GBM_BO_USE_RENDERING,
        ).?;

        const plane_count: u32 = @intCast(c.gbm_bo_get_plane_count(bo));
        if (plane_count != 1)
            @panic("Plane count is not 1");

        const modifier = c.gbm_bo_get_modifier(bo);
        const plane_fd = c.gbm_bo_get_fd(bo);
        const pitch = c.gbm_bo_get_stride(bo);
        const bpp = c.gbm_bo_get_bpp(bo);
        const gem_handle = c.gbm_bo_get_handle(bo).u32;
        const vk_layout = vk.VkSubresourceLayout{
            .offset = c.gbm_bo_get_offset(bo, 0),
            .rowPitch = c.gbm_bo_get_stride_for_plane(bo, 0),
        };

        const drm_format_create_info = vk.VkImageDrmFormatModifierExplicitCreateInfoEXT{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_EXPLICIT_CREATE_INFO_EXT,
            .drmFormatModifierPlaneCount = plane_count,
            .drmFormatModifier = modifier,
            .pPlaneLayouts = &vk_layout,
        };

        const external_memory_image_create_info = vk.VkExternalMemoryImageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
            .handleTypes = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
            .pNext = &drm_format_create_info,
        };

        const image_create_info = vk.VkImageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .imageType = vk.VK_IMAGE_TYPE_2D,
            .format = vk.VK_FORMAT_B8G8R8A8_SRGB,
            .mipLevels = 1,
            .arrayLayers = 1,
            .tiling = vk.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
            .samples = vk.VK_SAMPLE_COUNT_1_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .extent = .{
                .width = gbm.width,
                .height = gbm.height,
                .depth = 1,
            },
            .usage = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .pNext = &external_memory_image_create_info,
        };

        var image: vk.VkImage = undefined;
        try vk.check_result(vk.vkCreateImage(
            self.logical_device.device,
            &image_create_info,
            null,
            &image,
        ));

        // Now bind memory to the image
        const vkGetMemoryFdPropertiesKHR = (try get_vk_func(
            vk.PFN_vkGetMemoryFdPropertiesKHR,
            self.instance.instance,
            "vkGetMemoryFdPropertiesKHR",
        )).?;
        var vk_mem_fd_prop = vk.VkMemoryFdPropertiesKHR{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_FD_PROPERTIES_KHR,
        };
        try vk.check_result(
            vkGetMemoryFdPropertiesKHR(
                self.logical_device.device,
                vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
                plane_fd,
                &vk_mem_fd_prop,
            ),
        );

        const vk_image_memory_requirements_info = vk.VkImageMemoryRequirementsInfo2{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_REQUIREMENTS_INFO_2,
            .image = image,
        };
        var vk_image_memory_requirements = vk.VkMemoryRequirements2{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_REQUIREMENTS_2,
        };

        vk.vkGetImageMemoryRequirements2(
            self.logical_device.device,
            &vk_image_memory_requirements_info,
            &vk_image_memory_requirements,
        );

        const memory_bits = vk_image_memory_requirements.memoryRequirements.memoryTypeBits &
            vk_mem_fd_prop.memoryTypeBits;
        const memory_type_index = self.physical_device_memory_type_index(0, memory_bits);

        const vk_memory_dedicated_alloc_info = vk.VkMemoryDedicatedAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO,
            .image = image,
        };
        const vk_import_memory_fd_info = vk.VkImportMemoryFdInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR,
            .fd = plane_fd,
            .handleType = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
            .pNext = &vk_memory_dedicated_alloc_info,
        };
        const vk_memory_allocate_info = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = vk_image_memory_requirements.memoryRequirements.size,
            .memoryTypeIndex = memory_type_index,
            .pNext = &vk_import_memory_fd_info,
        };
        var device_memory: vk.VkDeviceMemory = undefined;
        try vk.check_result(vk.vkAllocateMemory(
            self.logical_device.device,
            &vk_memory_allocate_info,
            null,
            &device_memory,
        ));
        const vk_bind_image_memory_info = vk.VkBindImageMemoryInfo{
            .sType = vk.VK_STRUCTURE_TYPE_BIND_IMAGE_MEMORY_INFO,
            .image = image,
            .memory = device_memory,
        };
        try vk.check_result(vk.vkBindImageMemory2(
            self.logical_device.device,
            1,
            &vk_bind_image_memory_info,
        ));

        const view_create_info = vk.VkImageViewCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
            .format = vk.VK_FORMAT_B8G8R8A8_SRGB,
            .components = .{
                .r = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .g = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .b = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .a = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
            },
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseArrayLayer = 0,
                .layerCount = 1,
                .baseMipLevel = 0,
                .levelCount = 1,
            },
            .image = image,
        };
        var view: vk.VkImageView = undefined;
        try vk.check_result(vk.vkCreateImageView(self.logical_device.device, &view_create_info, null, &view));

        self.output_image = .{
            .bo = bo,
            .image = image,
            .view = view,
            .width = gbm.width,
            .height = gbm.height,
            .pitch = pitch,
            .bpp = bpp,
            .modifier = modifier,
            .gem_handle = gem_handle,
        };
    }

    fn physical_device_memory_type_index(self: *const Self, flags: u32, bits: u32) u32 {
        var props: vk.VkPhysicalDeviceMemoryProperties = undefined;
        vk.vkGetPhysicalDeviceMemoryProperties(self.physical_device.device, &props);
        for (0..props.memoryTypeCount) |i| {
            const i_u32: u32 = @intCast(i);
            const mem_type = props.memoryTypes[i];
            if (@as(u32, 1) << @as(u5, @intCast(i_u32)) & bits != 0 and (mem_type.propertyFlags & flags) == flags)
                return i_u32;
        }
        @panic("cound not find physical memory type index");
    }

    fn bo_handle_to_fd(fd: std.posix.fd_t, handle: u32) std.posix.fd_t {
        const O_RDWR = 2;
        const prime = c.drm_prime_handle{
            .handle = handle,
            .flags = O_RDWR, // c.DRM_RDWR | c.DRM_CLOEXEC,
        };
        const r = std.os.linux.ioctl(fd, c.DRM_IOCTL_PRIME_HANDLE_TO_FD, @intFromPtr(&prime));
        std.log.info("bo_handle_to_fd returned: {d}", .{r});
        return prime.fd;
    }

    pub fn wait_for_fence(self: *const Self, fence: vk.VkFence) !void {
        return vk.check_result(vk.vkWaitForFences(
            self.logical_device.device,
            1,
            &fence,
            vk.VK_TRUE,
            TIMEOUT,
        ));
    }

    pub fn reset_fence(self: *const Self, fence: vk.VkFence) !void {
        return vk.check_result(vk.vkResetFences(self.logical_device.device, 1, &fence));
    }

    pub fn queue_submit_2(
        self: *const Self,
        submit_info: *const vk.VkSubmitInfo2,
        fence: vk.VkFence,
    ) !void {
        return vk.check_result(vk.vkQueueSubmit2(
            self.logical_device.graphics_queue,
            1,
            submit_info,
            fence,
        ));
    }

    pub fn start_command(self: *const Self, command: *const RenderCommand) !void {
        try self.wait_for_fence(command.render_fence);
        try self.reset_fence(command.render_fence);

        try vk.check_result(vk.vkResetCommandBuffer(command.cmd, 0));
        const begin_info = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        };
        try vk.check_result(vk.vkBeginCommandBuffer(command.cmd, &begin_info));
    }

    pub fn end_command(self: *const Self, command: *const RenderCommand) !void {
        _ = self;
        try vk.check_result(vk.vkEndCommandBuffer(command.cmd));
    }

    pub fn queue_command(self: *Self, command: *const RenderCommand) !void {
        // Submit commands
        const buffer_submit_info = vk.VkCommandBufferSubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
            .commandBuffer = command.cmd,
            .deviceMask = 0,
        };
        const wait_semaphore_info = vk.VkSemaphoreSubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
            .semaphore = command.output_semaphore,
            .stageMask = vk.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT_KHR,
        };
        const signal_semaphore_info = vk.VkSemaphoreSubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
            .semaphore = command.render_semaphore,
            .stageMask = vk.VK_PIPELINE_STAGE_2_ALL_GRAPHICS_BIT,
        };
        const submit_info = vk.VkSubmitInfo2{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
            .pWaitSemaphoreInfos = &wait_semaphore_info,
            .waitSemaphoreInfoCount = 1,
            .pSignalSemaphoreInfos = &signal_semaphore_info,
            .signalSemaphoreInfoCount = 1,
            .pCommandBufferInfos = &buffer_submit_info,
            .commandBufferInfoCount = 1,
        };
        try self.queue_submit_2(&submit_info, command.render_fence);
    }

    pub fn start_rendering(self: *const Self, command: *const RenderCommand) !void {
        const sc_image = self.output_image.image;
        const sc_view = self.output_image.view;

        transition_image(
            command.cmd,
            sc_image,
            vk.VK_IMAGE_LAYOUT_UNDEFINED,
            vk.VK_IMAGE_LAYOUT_ATTACHMENT_OPTIMAL,
        );

        const color_attachment = vk.VkRenderingAttachmentInfo{
            .sType = vk.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
            .imageView = sc_view,
            .imageLayout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .clearValue = .{ .color = .{ .float32 = .{ 0.0, 0.0, 0.0, 0.0 } } },
            .storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE,
        };

        const render_info = vk.VkRenderingInfo{
            .sType = vk.VK_STRUCTURE_TYPE_RENDERING_INFO,
            .pColorAttachments = &color_attachment,
            .colorAttachmentCount = 1,
            .renderArea = .{
                .extent = .{
                    .width = self.output_image.width,
                    .height = self.output_image.height,
                },
            },
            .layerCount = 1,
        };
        vk.vkCmdBeginRendering(command.cmd, &render_info);

        const viewport = vk.VkViewport{
            .x = 0.0,
            .y = 0.0,
            .width = @floatFromInt(self.output_image.width),
            .height = @floatFromInt(self.output_image.height),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };
        vk.vkCmdSetViewport(command.cmd, 0, 1, &viewport);
        const scissor = vk.VkRect2D{
            .offset = .{
                .x = 0.0,
                .y = 0.0,
            },
            .extent = .{
                .width = self.output_image.width,
                .height = self.output_image.height,
            },
        };
        vk.vkCmdSetScissor(command.cmd, 0, 1, &scissor);
    }

    pub fn transition_swap_chain(self: *Self, command: *const RenderCommand) void {
        transition_image(
            command.cmd,
            self.output_image.image,
            vk.VK_IMAGE_LAYOUT_ATTACHMENT_OPTIMAL,
            vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        );
    }

    pub fn end_rendering(self: *Self, command: *const RenderCommand) !void {
        _ = self;
        vk.vkCmdEndRendering(command.cmd);
    }

    const DescriptorPool = struct {
        pool: vk.VkDescriptorPool,

        pub fn init(
            device: vk.VkDevice,
            pool_sizes: []const vk.VkDescriptorPoolSize,
        ) !DescriptorPool {
            const pool_info = vk.VkDescriptorPoolCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
                .maxSets = 10,
                .pPoolSizes = pool_sizes.ptr,
                .poolSizeCount = @intCast(pool_sizes.len),
            };
            var pool: vk.VkDescriptorPool = undefined;
            try vk.check_result(vk.vkCreateDescriptorPool(device, &pool_info, null, &pool));
            return .{
                .pool = pool,
            };
        }

        pub fn deinit(self: *const DescriptorPool, device: vk.VkDevice) void {
            vk.vkDestroyDescriptorPool(device, self.pool, null);
        }
    };

    pub const RenderCommand = struct {
        cmd: vk.VkCommandBuffer,
        output_semaphore: vk.VkSemaphore,
        render_semaphore: vk.VkSemaphore,
        render_fence: vk.VkFence,

        pub fn get_render_semaphore_fd(
            self: *const RenderCommand,
            instance: vk.VkInstance,
            device: vk.VkDevice,
        ) !std.posix.fd_t {
            const get_info = vk.VkSemaphoreGetFdInfoKHR{
                .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR,
                .semaphore = self.render_semaphore,
                .handleType = vk.VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
            };

            const vkGetSemaphoreFdKHR = (try get_vk_func(
                vk.PFN_vkGetSemaphoreFdKHR,
                instance,
                "vkGetSemaphoreFdKHR",
            )).?;

            var fd: std.posix.fd_t = undefined;
            try vk.check_result(vkGetSemaphoreFdKHR(device, &get_info, &fd));
            return fd;
        }

        pub fn import_output_semaphore_fd(
            self: *const RenderCommand,
            instance: vk.VkInstance,
            device: vk.VkDevice,
            fd: std.posix.fd_t,
        ) !void {
            const import_sem = vk.VkImportSemaphoreFdInfoKHR{
                .sType = vk.VK_STRUCTURE_TYPE_IMPORT_SEMAPHORE_FD_INFO_KHR,
                .handleType = vk.VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
                .flags = vk.VK_SEMAPHORE_IMPORT_TEMPORARY_BIT,
                .fd = fd,
                .semaphore = self.output_semaphore,
            };

            const vkImportSemaphoreFdKHR = (try get_vk_func(
                vk.PFN_vkImportSemaphoreFdKHR,
                instance,
                "vkImportSemaphoreFdKHR",
            )).?;

            try vk.check_result(vkImportSemaphoreFdKHR(device, &import_sem));
        }

        pub fn deinit(self: *const RenderCommand, device: vk.VkDevice) void {
            vk.vkDestroyFence(device, self.render_fence, null);
            vk.vkDestroySemaphore(device, self.render_semaphore, null);
            vk.vkDestroySemaphore(device, self.swap_chain_semaphore, null);
        }
    };

    const CommandPool = struct {
        pool: vk.VkCommandPool,

        pub fn init(device: vk.VkDevice, queue_family_index: u32) !CommandPool {
            const pool_create_info = vk.VkCommandPoolCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
                .flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
                .queueFamilyIndex = queue_family_index,
            };
            var pool: vk.VkCommandPool = undefined;
            try vk.check_result(vk.vkCreateCommandPool(device, &pool_create_info, null, &pool));
            return .{
                .pool = pool,
            };
        }

        pub fn deinit(self: *CommandPool, device: vk.VkDevice) void {
            vk.vkDestroyCommandPool(device, self.pool, null);
        }

        pub fn create_render_command(self: *CommandPool, device: vk.VkDevice) !RenderCommand {
            const allocate_info = vk.VkCommandBufferAllocateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
                .commandPool = self.pool,
                .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
                .commandBufferCount = 1,
            };
            var cmd: vk.VkCommandBuffer = undefined;
            try vk.check_result(vk.vkAllocateCommandBuffers(device, &allocate_info, &cmd));

            const fence_create_info = vk.VkFenceCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
                .flags = vk.VK_FENCE_CREATE_SIGNALED_BIT,
            };
            var render_fence: vk.VkFence = undefined;
            try vk.check_result(vk.vkCreateFence(device, &fence_create_info, null, &render_fence));

            const render_semaphore_export_create_info = vk.VkExportSemaphoreCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO,
                .handleTypes = vk.VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
            };
            const render_semaphore_creaet_info = vk.VkSemaphoreCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
                .pNext = &render_semaphore_export_create_info,
            };
            var render_semaphore: vk.VkSemaphore = undefined;
            try vk.check_result(vk.vkCreateSemaphore(
                device,
                &render_semaphore_creaet_info,
                null,
                &render_semaphore,
            ));

            const output_semaphore_creaet_info = vk.VkSemaphoreCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            };
            var output_semaphore: vk.VkSemaphore = undefined;
            try vk.check_result(vk.vkCreateSemaphore(
                device,
                &output_semaphore_creaet_info,
                null,
                &output_semaphore,
            ));

            return .{
                .cmd = cmd,
                .output_semaphore = output_semaphore,
                .render_semaphore = render_semaphore,
                .render_fence = render_fence,
            };
        }
    };
};

pub fn load_shader_module(
    scratch_alloc: Allocator,
    device: vk.VkDevice,
    path: []const u8,
) !vk.VkShaderModule {
    const file = try std.fs.cwd().openFile(path, .{});
    const meta = try file.metadata();

    const size_in_u32 = meta.size() / @sizeOf(u32);
    const buff_u32 = try scratch_alloc.alloc(u32, size_in_u32);

    var buff_u8: []u8 = undefined;
    buff_u8.ptr = @ptrCast(buff_u32.ptr);
    buff_u8.len = meta.size();
    _ = try file.reader().readAll(buff_u8);

    const create_info = vk.VkShaderModuleCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .pCode = buff_u32.ptr,
        .codeSize = buff_u8.len,
    };

    var module: vk.VkShaderModule = undefined;
    try vk.check_result(vk.vkCreateShaderModule(device, &create_info, null, &module));
    return module;
}

pub const BlendingType = enum {
    None,
    Alpha,
    Additive,
};

pub const Pipeline = struct {
    pipeline: vk.VkPipeline,
    pipeline_layout: vk.VkPipelineLayout,
    descriptor_set: vk.VkDescriptorSet,
    descriptor_set_layout: vk.VkDescriptorSetLayout,

    pub fn init(
        scratch_alloc: Allocator,
        device: vk.VkDevice,
        descriptor_pool: vk.VkDescriptorPool,
        bindings: []const vk.VkDescriptorSetLayoutBinding,
        push_constants: []const vk.VkPushConstantRange,
        vertex_shader_path: [:0]const u8,
        fragment_shader_path: [:0]const u8,
        color_attachment_format: vk.VkFormat,
        depth_format: vk.VkFormat,
        blending: BlendingType,
    ) !Pipeline {

        // create descriptor set layout
        var descriptor_set_layout: vk.VkDescriptorSetLayout = undefined;
        const layout_create_info = vk.VkDescriptorSetLayoutCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pBindings = bindings.ptr,
            .bindingCount = @intCast(bindings.len),
        };
        try vk.check_result(vk.vkCreateDescriptorSetLayout(
            device,
            &layout_create_info,
            null,
            &descriptor_set_layout,
        ));

        // create descriptor set
        const set_alloc_info = vk.VkDescriptorSetAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = descriptor_pool,
            .pSetLayouts = &descriptor_set_layout,
            .descriptorSetCount = 1,
        };
        var descriptor_set: vk.VkDescriptorSet = undefined;
        try vk.check_result(vk.vkAllocateDescriptorSets(
            device,
            &set_alloc_info,
            &descriptor_set,
        ));

        const vertex_shader_module = try load_shader_module(scratch_alloc, device, vertex_shader_path);
        defer vk.vkDestroyShaderModule(device, vertex_shader_module, null);
        const fragment_shader_module = try load_shader_module(
            scratch_alloc,
            device,
            fragment_shader_path,
        );
        defer vk.vkDestroyShaderModule(device, fragment_shader_module, null);

        const layouts = [_]vk.VkDescriptorSetLayout{
            descriptor_set_layout,
        };
        const pipeline_layout_create_info = vk.VkPipelineLayoutCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pSetLayouts = &layouts,
            .setLayoutCount = layouts.len,
            .pPushConstantRanges = push_constants.ptr,
            .pushConstantRangeCount = @intCast(push_constants.len),
        };
        var pipeline_layout: vk.VkPipelineLayout = undefined;
        try vk.check_result(vk.vkCreatePipelineLayout(
            device,
            &pipeline_layout_create_info,
            null,
            &pipeline_layout,
        ));

        var builder: PipelineBuilder = .{};
        _ = builder.layout(pipeline_layout)
            .shaders(vertex_shader_module, fragment_shader_module)
            .input_topology(vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST)
            .polygon_mode(vk.VK_POLYGON_MODE_FILL)
            .cull_mode(vk.VK_CULL_MODE_NONE, vk.VK_FRONT_FACE_CLOCKWISE)
            .multisampling_none()
            .color_attachment_format(color_attachment_format)
            .depthtest(true, vk.VK_COMPARE_OP_GREATER_OR_EQUAL)
            .depth_format(depth_format);
        switch (blending) {
            .None => _ = builder.blending_none(),
            .Alpha => _ = builder.blending_alphablend(),
            .Additive => _ = builder.blending_additive(),
        }
        const pipeline = try builder.build(device);
        return .{
            .pipeline = pipeline,
            .pipeline_layout = pipeline_layout,
            .descriptor_set = descriptor_set,
            .descriptor_set_layout = descriptor_set_layout,
        };
    }

    pub fn deinit(self: *const Pipeline, device: vk.VkDevice) void {
        vk.vkDestroyDescriptorSetLayout(device, self.descriptor_set_layout, null);
        vk.vkDestroyPipelineLayout(device, self.pipeline_layout, null);
        vk.vkDestroyPipeline(device, self.pipeline, null);
    }
};

pub const PipelineBuilder = struct {
    stages: [2]vk.VkPipelineShaderStageCreateInfo = .{
        .{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        },
        .{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        },
    },
    input_assembly: vk.VkPipelineInputAssemblyStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    },
    rasterization: vk.VkPipelineRasterizationStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
    },
    multisampling: vk.VkPipelineMultisampleStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    },
    depth_stencil: vk.VkPipelineDepthStencilStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    },
    rendering: vk.VkPipelineRenderingCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
    },
    color_blend_attachment: vk.VkPipelineColorBlendAttachmentState = .{
        .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT |
            vk.VK_COLOR_COMPONENT_G_BIT |
            vk.VK_COLOR_COMPONENT_B_BIT |
            vk.VK_COLOR_COMPONENT_A_BIT,
    },
    _layout: vk.VkPipelineLayout = undefined,
    _color_attachment_format: vk.VkFormat = undefined,

    const Self = @This();

    pub fn layout(self: *Self, l: vk.VkPipelineLayout) *Self {
        self._layout = l;
        return self;
    }

    pub fn shaders(
        self: *Self,
        vertex_shader: vk.VkShaderModule,
        fragment_shader: vk.VkShaderModule,
    ) *Self {
        self.stages[0].stage = vk.VK_SHADER_STAGE_VERTEX_BIT;
        self.stages[0].module = vertex_shader;
        self.stages[0].pName = "main";

        self.stages[1].stage = vk.VK_SHADER_STAGE_FRAGMENT_BIT;
        self.stages[1].module = fragment_shader;
        self.stages[1].pName = "main";

        return self;
    }

    pub fn input_topology(self: *Self, topology: vk.VkPrimitiveTopology) *Self {
        self.input_assembly.topology = topology;
        self.input_assembly.primitiveRestartEnable = vk.VK_FALSE;
        return self;
    }

    pub fn polygon_mode(self: *Self, mode: vk.VkPolygonMode) *Self {
        self.rasterization.polygonMode = mode;
        self.rasterization.lineWidth = 1.0;
        return self;
    }

    pub fn cull_mode(self: *Self, mode: vk.VkCullModeFlags, front_face: vk.VkFrontFace) *Self {
        self.rasterization.cullMode = mode;
        self.rasterization.frontFace = front_face;
        return self;
    }

    pub fn multisampling_none(self: *Self) *Self {
        self.multisampling.sampleShadingEnable = vk.VK_FALSE;
        self.multisampling.rasterizationSamples = vk.VK_SAMPLE_COUNT_1_BIT;
        self.multisampling.minSampleShading = 1.0;
        self.multisampling.alphaToOneEnable = vk.VK_FALSE;
        self.multisampling.alphaToCoverageEnable = vk.VK_FALSE;
        return self;
    }

    pub fn blending_none(self: *Self) *Self {
        self.color_blend_attachment.blendEnable = vk.VK_FALSE;
        return self;
    }

    pub fn blending_additive(self: *Self) *Self {
        self.color_blend_attachment.colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT |
            vk.VK_COLOR_COMPONENT_G_BIT |
            vk.VK_COLOR_COMPONENT_B_BIT |
            vk.VK_COLOR_COMPONENT_A_BIT;
        self.color_blend_attachment.blendEnable = vk.VK_TRUE;
        self.color_blend_attachment.srcColorBlendFactor = vk.VK_BLEND_FACTOR_SRC_ALPHA;
        self.color_blend_attachment.dstColorBlendFactor = vk.VK_BLEND_FACTOR_ONE;
        self.color_blend_attachment.colorBlendOp = vk.VK_BLEND_OP_ADD;
        self.color_blend_attachment.srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE;
        self.color_blend_attachment.dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ZERO;
        self.color_blend_attachment.colorBlendOp = vk.VK_BLEND_OP_ADD;
        return self;
    }

    pub fn blending_alphablend(self: *Self) *Self {
        self.color_blend_attachment.colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT |
            vk.VK_COLOR_COMPONENT_G_BIT |
            vk.VK_COLOR_COMPONENT_B_BIT |
            vk.VK_COLOR_COMPONENT_A_BIT;
        self.color_blend_attachment.blendEnable = vk.VK_TRUE;
        self.color_blend_attachment.srcColorBlendFactor = vk.VK_BLEND_FACTOR_SRC_ALPHA;
        self.color_blend_attachment.dstColorBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        self.color_blend_attachment.colorBlendOp = vk.VK_BLEND_OP_ADD;
        self.color_blend_attachment.srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE;
        self.color_blend_attachment.dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ZERO;
        self.color_blend_attachment.colorBlendOp = vk.VK_BLEND_OP_ADD;
        return self;
    }

    pub fn color_attachment_format(self: *Self, format: vk.VkFormat) *Self {
        self._color_attachment_format = format;
        return self;
    }

    pub fn depth_format(self: *Self, format: vk.VkFormat) *Self {
        self.rendering.depthAttachmentFormat = format;
        return self;
    }

    pub fn depthtest_none(self: *Self) *Self {
        self.depth_stencil.depthTestEnable = vk.VK_FALSE;
        self.depth_stencil.depthWriteEnable = vk.VK_FALSE;
        self.depth_stencil.depthCompareOp = vk.VK_COMPARE_OP_NEVER;
        self.depth_stencil.depthBoundsTestEnable = vk.VK_FALSE;
        self.depth_stencil.stencilTestEnable = vk.VK_FALSE;
        self.depth_stencil.front = .{};
        self.depth_stencil.back = .{};
        self.depth_stencil.minDepthBounds = 0.0;
        self.depth_stencil.maxDepthBounds = 1.0;
        return self;
    }

    pub fn depthtest(
        self: *Self,
        depth_write_enable: bool,
        depth_compare_op: vk.VkCompareOp,
    ) *Self {
        self.depth_stencil.depthTestEnable = vk.VK_TRUE;
        self.depth_stencil.depthWriteEnable = @intFromBool(depth_write_enable);
        self.depth_stencil.depthCompareOp = depth_compare_op;
        self.depth_stencil.depthBoundsTestEnable = vk.VK_FALSE;
        self.depth_stencil.stencilTestEnable = vk.VK_FALSE;
        self.depth_stencil.front = .{};
        self.depth_stencil.back = .{};
        self.depth_stencil.minDepthBounds = 0.0;
        self.depth_stencil.maxDepthBounds = 1.0;
        return self;
    }

    pub fn build(self: *Self, device: vk.VkDevice) !vk.VkPipeline {
        self.rendering.pColorAttachmentFormats = &self._color_attachment_format;
        self.rendering.colorAttachmentCount = 1;

        const viewport = vk.VkPipelineViewportStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .viewportCount = 1,
            .scissorCount = 1,
        };

        const color_blending = vk.VkPipelineColorBlendStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .logicOpEnable = vk.VK_FALSE,
            .logicOp = vk.VK_LOGIC_OP_COPY,
            .pAttachments = &self.color_blend_attachment,
            .attachmentCount = 1,
        };

        const vertex_input = vk.VkPipelineVertexInputStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        };

        const dynamic_states = [_]vk.VkDynamicState{
            vk.VK_DYNAMIC_STATE_VIEWPORT,
            vk.VK_DYNAMIC_STATE_SCISSOR,
        };
        const dynamic_state_info = vk.VkPipelineDynamicStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .pDynamicStates = &dynamic_states,
            .dynamicStateCount = @intCast(dynamic_states.len),
        };

        const pipeline_create_info = vk.VkGraphicsPipelineCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pStages = &self.stages,
            .stageCount = @intCast(self.stages.len),
            .pVertexInputState = &vertex_input,
            .pInputAssemblyState = &self.input_assembly,
            .pViewportState = &viewport,
            .pRasterizationState = &self.rasterization,
            .pMultisampleState = &self.multisampling,
            .pColorBlendState = &color_blending,
            .pDepthStencilState = &self.depth_stencil,
            .pDynamicState = &dynamic_state_info,
            .layout = self._layout,
            .pNext = &self.rendering,
        };

        var pipeline: vk.VkPipeline = undefined;
        try vk.check_result(vk.vkCreateGraphicsPipelines(
            device,
            null,
            1,
            &pipeline_create_info,
            null,
            &pipeline,
        ));
        return pipeline;
    }
};

pub fn transition_image(
    cmd: vk.VkCommandBuffer,
    image: vk.VkImage,
    source_layout: vk.VkImageLayout,
    target_layout: vk.VkImageLayout,
) void {
    const aspect_mask = if (target_layout == vk.VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL)
        vk.VK_IMAGE_ASPECT_DEPTH_BIT
    else
        vk.VK_IMAGE_ASPECT_COLOR_BIT;
    const subresource = vk.VkImageSubresourceRange{
        .aspectMask = @intCast(aspect_mask),
        .baseMipLevel = 0,
        .levelCount = vk.VK_REMAINING_MIP_LEVELS,
        .baseArrayLayer = 0,
        .layerCount = vk.VK_REMAINING_ARRAY_LAYERS,
    };
    const barrier = vk.VkImageMemoryBarrier2{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .srcStageMask = vk.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
        .srcAccessMask = vk.VK_ACCESS_2_MEMORY_WRITE_BIT,
        .dstStageMask = vk.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
        .dstAccessMask = vk.VK_ACCESS_2_MEMORY_WRITE_BIT | vk.VK_ACCESS_2_MEMORY_READ_BIT,
        .oldLayout = source_layout,
        .newLayout = target_layout,
        .subresourceRange = subresource,
        .image = image,
    };

    const dependency = vk.VkDependencyInfo{
        .sType = vk.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
        .pImageMemoryBarriers = &barrier,
        .imageMemoryBarrierCount = 1,
    };

    vk.vkCmdPipelineBarrier2(cmd, &dependency);
}

pub fn construct_drm_commit_request(
    request: *drm.CommitRequest,
    primary_plane_p: []drm.Property,
    crtc_p: []drm.Property,
    connector_p: []drm.Property,
    output_image: *const VulkanContext.OutputImage,
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
                    std.log.info("adding plane prop name: {s}, id: {d}, value: {d}", .{
                        pp.name,
                        pp.prop_id,
                        p[1],
                    });
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
                    std.log.info("adding plane prop name: {s}, id: {d}, value: {d}", .{
                        pp.name,
                        pp.prop_id,
                        p[1],
                    });
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
                    std.log.info("adding crtc prop name: {s}, id: {d}, value: {d}", .{
                        pp.name,
                        pp.prop_id,
                        p[1],
                    });
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
                    std.log.info("adding output prop name: {s}, id: {d}, value: {d}", .{
                        pp.name,
                        pp.prop_id,
                        p[1],
                    });
                    request.add_prop_id_value(pp.prop_id, p[1]);
                }
            }
        }
    }
}
