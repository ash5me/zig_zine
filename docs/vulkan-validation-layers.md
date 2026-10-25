# Vulkan Validation Layers

**Status:** Planned, not implemented. `build.zig` does not define `enable_validation`, and `vulkan_swapchain.zig` creates its instance without the validation layer or a debug messenger. This document is the design for adding them.

## Build option

`build.zig` already creates an options module with `enable_vulkan`. Add a second flag next to it, derived from the standard optimize setting:

```zig
const optimize = b.standardOptimizeOption(.{});

const options = b.addOptions();
options.addOption(bool, "enable_vulkan", enable_vulkan);
options.addOption(bool, "enable_validation", optimize == .Debug);
```

Use the standard `-Doptimize` flag. `build.zig` already passes it to the executable and test artifacts. This replaces an earlier proposal for a custom `-Dmode` option.

Build:

```sh
zig build                          # Debug by default: validation on
zig build -Doptimize=ReleaseFast   # validation off
```

Validation only takes effect when `-Dvulkan=true` is set, because the headless build creates no Vulkan instance.

## Vulkan dispatch entries

Extend `InstanceDispatch` in `vulkan_swapchain.zig`:

```zig
const InstanceDispatch = vk.InstanceWrapper(.{
    .destroyInstance = true,
    .createDebugUtilsMessengerEXT = true,
    .destroyDebugUtilsMessengerEXT = true,
    // ...existing entries
});
```

Add layer enumeration to `BaseDispatch`, so the availability check described under "Runtime requirement" can run before instance creation:

```zig
const BaseDispatch = vk.BaseWrapper(.{
    .createInstance = true,
    .enumerateInstanceExtensionProperties = true,
    .enumerateInstanceLayerProperties = true,
});
```

## Debug callback

The callback receives validation messages and prints the message text:

```zig
fn debugCallback(
    severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    message_types: vk.DebugUtilsMessageTypeFlagsEXT,
    callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    user_data: ?*anyopaque,
) callconv(.c) vk.Bool32 {
    _ = severity;
    _ = message_types;
    _ = user_data;

    if (callback_data) |data| {
        if (data.p_message) |message| {
            std.debug.print("Vulkan validation: {s}\n", .{message});
        }
    }

    return vk.FALSE;
}

fn debugMessengerCreateInfo() vk.DebugUtilsMessengerCreateInfoEXT {
    return .{
        .message_severity = .{
            .verbose_bit_ext = true,
            .info_bit_ext = true,
            .warning_bit_ext = true,
            .error_bit_ext = true,
        },
        .message_type = .{
            .general_bit_ext = true,
            .validation_bit_ext = true,
            .performance_bit_ext = true,
        },
        .pfn_user_callback = debugCallback,
    };
}
```

`verbose` messages are very noisy. Keep them enabled only while debugging a specific problem.

## Instance creation

This uses the unmanaged `std.ArrayList`, the same form as `physics_solver.zig` and `resources.zig`. `vulkan_swapchain.zig` currently uses the managed form, which is one of the known compile issues listed in the README.

```zig
const validation_layer_name: [*:0]const u8 =
    "VK_LAYER_KHRONOS_validation";

var extension_names: std.ArrayList([*:0]const u8) = .empty;
defer extension_names.deinit(allocator);

for (0..ext_count) |i| {
    try extension_names.append(allocator, sdl_extensions[i]);
}

var debug_create_info: ?vk.DebugUtilsMessengerCreateInfoEXT = null;
const validation_layers = [_][*:0]const u8{validation_layer_name};

if (build_options.enable_validation) {
    try extension_names.append(allocator, vk.extensions.ext_debug_utils.name);
    debug_create_info = debugMessengerCreateInfo();
}

const instance = try vkb.createInstance(&.{
    .p_next = if (debug_create_info) |*info| info else null,
    .p_application_info = &app_info,
    .enabled_extension_count = @intCast(extension_names.items.len),
    .pp_enabled_extension_names = extension_names.items.ptr,
    .enabled_layer_count = if (build_options.enable_validation)
        validation_layers.len
    else
        0,
    .pp_enabled_layer_names = if (build_options.enable_validation)
        &validation_layers
    else
        null,
}, null);
```

Passing the debug messenger create info through `p_next` lets validation messages be reported during instance creation itself.

## Messenger lifecycle

After loading the instance dispatch table, create the messenger in Debug mode. Keep the create info in a local variable so its address is valid for the call:

```zig
var debug_messenger: ?vk.DebugUtilsMessengerEXT = null;
if (build_options.enable_validation) {
    var info = debugMessengerCreateInfo();
    debug_messenger = try vki.createDebugUtilsMessengerEXT(instance, &info, null);
}
errdefer if (debug_messenger) |messenger| {
    vki.destroyDebugUtilsMessengerEXT(instance, messenger, null);
};
```

Store the result as an optional field on `VulkanSwapchain`:

```zig
debug_messenger: ?vk.DebugUtilsMessengerEXT,
```

Destroy it before destroying the Vulkan instance, in `VulkanSwapchain.deinit`:

```zig
if (self.debug_messenger) |messenger| {
    self.vki.destroyDebugUtilsMessengerEXT(
        self.instance,
        messenger,
        null,
    );
}

self.vki.destroyInstance(self.instance, null);
```

The `errdefer` placed after instance creation ensures that partially initialized state (for example, a failed surface creation) also destroys the messenger and instance.

## Runtime requirement

The Vulkan SDK must provide the layer named:

```text
VK_LAYER_KHRONOS_validation
```

If the layer is not installed, Debug instance creation fails. A production renderer should enumerate available instance layers first and enable validation only when the requested layer is present. The `enumerateInstanceLayerProperties` entry added to `BaseDispatch` above is what makes that check possible.
