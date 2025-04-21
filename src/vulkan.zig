const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("bindings/c.zig").c;
const vk = @import("bindings/vk.zig");
const Gbm = @import("gbm.zig");

const VK_EXTENSIONS_NAMES = [_][*c]const u8{"VK_EXT_debug_utils"};
const VK_VALIDATION_LAYERS_NAMES = [_][*c]const u8{"VK_LAYER_KHRONOS_validation"};
const VK_PHYSICAL_DEVICE_EXTENSION_NAMES = [_][*c]const u8{
    vk.VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME,
    vk.VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME,
    vk.VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME,
    vk.VK_KHR_IMAGE_FORMAT_LIST_EXTENSION_NAME,
    vk.VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME,
};

const TIMEOUT = std.math.maxInt(u64);

pub const Context = struct {
    instance: Instance,
    debug_messanger: DebugMessanger,
    physical_device: PhysicalDevice,
    logical_device: LogicalDevice,
    descriptor_pool: DescriptorPool,
    commands: CommandPool,
    output_image: OutputImage,

    const Self = @This();

    pub fn init(
        scratch_alloc: Allocator,
        gbm: *const Gbm,
    ) !Self {
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

        const output_image = try OutputImage.init(
            instance.instance,
            logical_device.device,
            physical_device.device,
            gbm,
        );
        return .{
            .instance = instance,
            .debug_messanger = debug_messanger,
            .physical_device = physical_device,
            .logical_device = logical_device,
            .descriptor_pool = descriptor_pool,
            .commands = commands,
            .output_image = output_image,
        };
    }

    pub fn get_vk_func(comptime Fn: type, instance: vk.VkInstance, name: [*c]const u8) !Fn {
        if (vk.vkGetInstanceProcAddr(instance, name)) |func| {
            return @ptrCast(func);
        } else {
            return error.VKGetInstanceProcAddr;
        }
    }

    fn physical_device_memory_type_index(
        vk_physical_device: vk.VkPhysicalDevice,
        flags: u32,
        bits: u32,
    ) !u32 {
        var props: vk.VkPhysicalDeviceMemoryProperties = undefined;
        vk.vkGetPhysicalDeviceMemoryProperties(vk_physical_device, &props);
        for (0..props.memoryTypeCount) |i| {
            const i_u32: u32 = @intCast(i);
            const mem_type = props.memoryTypes[i];
            if (@as(u32, 1) << @as(u5, @intCast(i_u32)) & bits != 0 and
                (mem_type.propertyFlags & flags) == flags)
                return i_u32;
        }
        return error.NoPhysicalDeviceMemoryTypeFound;
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

    pub fn end_rendering(self: *Self, command: *const RenderCommand) !void {
        _ = self;
        vk.vkCmdEndRendering(command.cmd);
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
            try vk.check_result(
                vk.vkEnumerateInstanceLayerProperties(&layer_property_count, null),
            );
            const layers = try scratch_alloc.alloc(vk.VkLayerProperties, layer_property_count);
            try vk.check_result(vk.vkEnumerateInstanceLayerProperties(
                &layer_property_count,
                layers.ptr,
            ));

            var found_validation_layers: u32 = 0;
            for (layers) |l| {
                var required = "--------";
                for (VK_VALIDATION_LAYERS_NAMES) |vln| {
                    const layer_name_span =
                        std.mem.span(@as([*c]const u8, @ptrCast(&l.layerName)));
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
        compute_queue_family: u32,
        transfer_queue_family: u32,

        pub fn init(
            scratch_alloc: Allocator,
            vk_instance: vk.VkInstance,
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
                }

                if (graphics_queue_family != null and
                    compute_queue_family != null and
                    transfer_queue_family != null)
                {
                    std.log.debug("Selected graphics queue family: {}", .{graphics_queue_family.?});
                    std.log.debug("Selected compute queue family: {}", .{compute_queue_family.?});
                    std.log.debug("Selected transfer queue family: {}", .{transfer_queue_family.?});

                    return .{
                        .device = pd,
                        .graphics_queue_family = graphics_queue_family.?,
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
        compute_queue: vk.VkQueue,
        transfer_queue: vk.VkQueue,

        pub fn init(scratch_alloc: Allocator, physical_device: *const PhysicalDevice) !LogicalDevice {
            const all_queue_family_indexes: [3]u32 = .{
                physical_device.graphics_queue_family,
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

        pub fn init(
            vk_instance: vk.VkInstance,
            vk_device: vk.VkDevice,
            vk_physical_device: vk.VkPhysicalDevice,
            gbm: *const Gbm,
        ) !OutputImage {
            const bo = c.gbm_bo_create(
                gbm.dev,
                gbm.width,
                gbm.height,
                c.GBM_FORMAT_XRGB8888,
                c.GBM_BO_USE_SCANOUT | c.GBM_BO_USE_RENDERING,
            ).?;

            const plane_count: u32 = @intCast(c.gbm_bo_get_plane_count(bo));
            if (plane_count != 1)
                return error.GbmPlaneHasMoreThanOnePlane;

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
                vk_device,
                &image_create_info,
                null,
                &image,
            ));

            // Now bind memory to the image
            const vkGetMemoryFdPropertiesKHR = (try get_vk_func(
                vk.PFN_vkGetMemoryFdPropertiesKHR,
                vk_instance,
                "vkGetMemoryFdPropertiesKHR",
            )).?;
            var vk_mem_fd_prop = vk.VkMemoryFdPropertiesKHR{
                .sType = vk.VK_STRUCTURE_TYPE_MEMORY_FD_PROPERTIES_KHR,
            };
            try vk.check_result(
                vkGetMemoryFdPropertiesKHR(
                    vk_device,
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
                vk_device,
                &vk_image_memory_requirements_info,
                &vk_image_memory_requirements,
            );

            const memory_bits = vk_image_memory_requirements.memoryRequirements.memoryTypeBits &
                vk_mem_fd_prop.memoryTypeBits;
            const memory_type_index = try physical_device_memory_type_index(
                vk_physical_device,
                0,
                memory_bits,
            );

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
                vk_device,
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
                vk_device,
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
            try vk.check_result(
                vk.vkCreateImageView(vk_device, &view_create_info, null, &view),
            );

            return .{
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
    };

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
            vk.vkDestroySemaphore(device, self.output_semaphore, null);
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
            .color_attachment_format(color_attachment_format);
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
